#!/usr/bin/env bash
#
# Chains the benchmark steps for every backend: baseline, OpenSearch, URLFrontier, Horizon.
#
# For each backend it runs the write benchmark (StatusUpdaterBenchmark, one status updater bolt)
# then the read one (SpoutBenchmark, several spouts against the index the writes left behind),
# starting the backend from an empty data directory, with swap off and the page cache dropped
# before each backend. The baseline has no backend and no spout, so it only runs the writes.
#
# Usage: ./run-benchmark.sh [-o dir] [backend...]
#
#   -o, --output dir   where the logs, the CSVs and the summary go. The default is a directory of
#                      its own per run, runs/<timestamp>; what a run writes into a directory that
#                      already holds files replaces what is there.
#   backend...         baseline, opensearch, urlfrontier or horizon, all four by default,
#                      in that order
#
# Each step leaves these files in the output directory:
#
#   <backend>-<writes|reads>.log          output of the utility
#   <backend>-<writes|reads>-backend.csv  CPU and memory of the backend container
#   <backend>-<writes|reads>-harness.csv  CPU and memory of the storm JVM
#   <backend>-container.log               stdout of the backend container, both steps
#   <backend>-disk.txt                    bytes the backend had on disk, after the writes and cold
#   run.log                               what this script did, with timings
#   summary.txt                           the figures of every step and the averages of the CSVs
#
# URLFrontier is run with config.ini from this directory mounted into the container and passed to
# the service with -c, so the tuning it holds is what the benchmark measures. Its rocksdb.path must
# stay under /data/crawl, which is where the data directory is mounted.
#
# After the writes and again after the reads, each backend is asked how many URLs it is holding:
# OpenSearch through _cat/indices, the two frontiers through `uf get-stats` from the urlfrontier
# client. All three are fed the same file, so the figures should agree; the first one measured
# becomes the reference and a backend that disagrees with it is reported as a warning rather than
# stopping the run.
#
# Every backend keeps its data in a directory of its own under bench-data, mounted into the
# container, so that the space it uses can be measured with du. OpenSearch is flushed before being
# measured and its own view of the index is kept too; for the frontiers the figure is the RocksDB
# directory. The measurement after the container has stopped is the comparable one: the stores
# only write out what they hold in memory when they shut down.
#
# Both CSVs have the columns of container-stats.sh (time,cpu_perc,mem_mib,mem_perc) so that
# avg-stats.sh reads either. 100% of cpu_perc is one core. For the harness, mem_mib is the RSS
# of the storm JVM and mem_perc its share of the host's RAM, not of a container limit.
#
# Settings, all overridable from the environment:
#
#   INPUT=urldump-mixed.ndjson.gz   input file for the writes
#   HEAP=6g                         heap of every JVM backend, same for all of them
#   READ_MINUTES=3 READ_SPOUTS=10 READ_BOLTS=1 WRITE_INSTANCES=1
#   SETTLE_SECS=30                  idle time between the writes and the reads of a backend
#   DROP_CACHES=1 SWAPOFF=1         need sudo; set to 0 to run without it
#   KEEP_DATA=0                     1 keeps each backend's data directory after its run
#   OUTDIR=runs/<timestamp>         same as -o
#   STATS_INTERVAL=2                seconds between samples
#   UF_CLIENT=uf                    urlfrontier client, used to read the frontiers' own stats.
#                                   When it isn't on the PATH the release build for this platform
#                                   is fetched and kept under UF_CLIENT_DIR
#   UF_CLIENT_VERSION=              version to fetch, the latest release when left empty
#   UF_CLIENT_DIR=tools             where a fetched client is kept between runs
#   EXPECTED_URLS=                  URLs every backend should end up holding; by default the
#                                   first backend measured sets the figure the others are checked
#                                   against

set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

JAR=${JAR:-target/benchmark-0.1-SNAPSHOT.jar}
CONF=${CONF:-benchmark-conf.yaml}
INPUT=${INPUT:-urldump-mixed.ndjson.gz}
UF_CONFIG=${UF_CONFIG:-config.ini}

WRITE_INSTANCES=${WRITE_INSTANCES:-1}
READ_MINUTES=${READ_MINUTES:-3}
READ_SPOUTS=${READ_SPOUTS:-10}
READ_BOLTS=${READ_BOLTS:-1}

HEAP=${HEAP:-6g}
SETTLE_SECS=${SETTLE_SECS:-30}
READY_TIMEOUT=${READY_TIMEOUT:-300}
STATS_INTERVAL=${STATS_INTERVAL:-2}
DROP_CACHES=${DROP_CACHES:-1}
SWAPOFF=${SWAPOFF:-1}
KEEP_DATA=${KEEP_DATA:-0}

UF_CLIENT=${UF_CLIENT:-uf}
UF_CLIENT_VERSION=${UF_CLIENT_VERSION:-}
UF_CLIENT_DIR=${UF_CLIENT_DIR:-$PWD/tools}
UF_CLIENT_REPO=DigitalPebble/urlfrontier-client

DATA_ROOT=${DATA_ROOT:-bench-data}
OUTDIR=${OUTDIR:-runs/$(date +%Y%m%d-%H%M%S)}

OS_IMAGE=${OS_IMAGE:-opensearchproject/opensearch:3.9.0}
UF_IMAGE=${UF_IMAGE:-urlfrontier:2.7-SNAPSHOT}
HORIZON_IMAGE=${HORIZON_IMAGE:-ghcr.io/digitalpebble/horizon:0.4.0}
WIPE_IMAGE=${WIPE_IMAGE:-alpine:latest}

OS_PORT=9201
UF_PORT=7071

WRITE_CLASS=org.apache.stormcrawler.persistence.StatusUpdaterBenchmark
READ_CLASS=org.apache.stormcrawler.persistence.SpoutBenchmark

usage() {
  printf 'Usage: %s [-o|--output dir] [baseline|opensearch|urlfrontier|horizon ...]\n' "${0##*/}"
}

BACKENDS=()
while [[ $# -gt 0 ]]; do
  case $1 in
    -o | --output)
      if [[ $# -lt 2 ]]; then
        usage >&2
        exit 1
      fi
      OUTDIR=$2
      shift 2
      ;;
    -o=* | --output=*)
      OUTDIR=${1#*=}
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      printf 'unknown option %s\n' "$1" >&2
      usage >&2
      exit 1
      ;;
    *)
      BACKENDS+=("$1")
      shift
      ;;
  esac
done

if [[ ${#BACKENDS[@]} -eq 0 ]]; then
  BACKENDS=(baseline opensearch urlfrontier horizon)
fi

CONTAINER=
STATS_PIDS=()
SUDO_KEEPALIVE=
REFERENCE_URLS=${EXPECTED_URLS:-}
REFERENCE_FROM="EXPECTED_URLS"

log() {
  printf '%s  %s\n' "$(date +%T)" "$*" | tee -a "$OUTDIR/run.log"
}

say() { # to summary.txt only
  printf '%s\n' "$*" >> "$OUTDIR/summary.txt"
}

die() {
  log "ERROR: $*"
  exit 1
}

fmt_dur() {
  printf '%dm %02ds' $(($1 / 60)) $(($1 % 60))
}

# ---------------------------------------------------------------- checks

check() {
  local backend
  command -v storm > /dev/null || die "storm is not on the PATH"
  command -v docker > /dev/null || die "docker is not on the PATH"
  [[ -f $JAR ]] || die "$JAR not found, run mvn package -DskipTests"
  [[ -f $CONF ]] || die "$CONF not found"
  [[ -x ./container-stats.sh ]] || die "./container-stats.sh not found or not executable"
  [[ -x ./avg-stats.sh ]] || die "./avg-stats.sh not found or not executable"

  for backend in "${BACKENDS[@]}"; do
    case $backend in
      baseline) [[ -f $INPUT ]] || die "input $INPUT not found" ;;
      opensearch)
        [[ -f $INPUT ]] || die "input $INPUT not found"
        port_free "$OS_PORT" || die "something is already listening on $OS_PORT"
        ;;
      urlfrontier)
        [[ -f $INPUT ]] || die "input $INPUT not found"
        [[ -f $UF_CONFIG ]] || die "$UF_CONFIG not found, URLFrontier is run with it mounted"
        port_free "$UF_PORT" || die "something is already listening on $UF_PORT"
        need_uf_client
        ;;
      horizon)
        [[ -f $INPUT ]] || die "input $INPUT not found"
        [[ -n ${HORIZON_LICENSE:-} ]] || die "HORIZON_LICENSE is not set, Horizon needs it"
        port_free "$UF_PORT" || die "something is already listening on $UF_PORT"
        need_uf_client
        ;;
      *) die "unknown backend '$backend', expected baseline, opensearch, urlfrontier or horizon" ;;
    esac
  done
}

port_free() {
  ! (exec 3<> "/dev/tcp/127.0.0.1/$1") 2> /dev/null
}

# The frontiers are asked for their own figures with the urlfrontier client, which is a program in
# its own right rather than part of this repository. When it isn't on the PATH, the release build
# for this platform is fetched, checked against the sha256 published beside it and kept under
# UF_CLIENT_DIR, so only the first run pays for it. Set UF_CLIENT to use a copy you already have.
need_uf_client() {
  if command -v "$UF_CLIENT" > /dev/null; then
    return 0
  fi
  if [[ -x $UF_CLIENT_DIR/uf ]]; then
    UF_CLIENT="$UF_CLIENT_DIR/uf"
    log "urlfrontier client: $UF_CLIENT"
    return 0
  fi
  fetch_uf_client
  UF_CLIENT="$UF_CLIENT_DIR/uf"
}

# sha256sum on Linux, shasum on macOS
sha256_of() {
  if command -v sha256sum > /dev/null; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

fetch_uf_client() {
  local os arch target version base archive tmp want got
  case "$(uname -s)" in
    Linux) os=unknown-linux-gnu ;;
    Darwin) os=apple-darwin ;;
    *) die "the urlfrontier client has no release build for $(uname -s), install it from https://github.com/$UF_CLIENT_REPO and set UF_CLIENT" ;;
  esac
  case "$(uname -m)" in
    x86_64 | amd64) arch=x86_64 ;;
    aarch64 | arm64) arch=aarch64 ;;
    *) die "the urlfrontier client has no release build for $(uname -m), install it from https://github.com/$UF_CLIENT_REPO and set UF_CLIENT" ;;
  esac
  target=$arch-$os

  # the asset names carry the version, so the latest one has to be resolved before downloading
  version=$UF_CLIENT_VERSION
  if [[ -z $version ]]; then
    version=$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
      "https://github.com/$UF_CLIENT_REPO/releases/latest") \
      || die "could not reach the releases of $UF_CLIENT_REPO, set UF_CLIENT_VERSION or UF_CLIENT"
    version=${version##*/}
    [[ -n $version && $version != latest ]] \
      || die "could not work out the latest version of the urlfrontier client, set UF_CLIENT_VERSION"
  fi

  base="https://github.com/$UF_CLIENT_REPO/releases/download/$version"
  archive="uf-$version-$target.tar.gz"
  tmp=$(mktemp -d)

  log "fetching the urlfrontier client $version for $target"
  curl -fsSL -o "$tmp/$archive" "$base/$archive" \
    || { rm -rf "$tmp"; die "could not download $base/$archive"; }
  curl -fsSL -o "$tmp/sha256" "$base/uf-$version-$target.sha256" \
    || { rm -rf "$tmp"; die "could not download the checksum of $archive"; }

  want=$(awk '{print $1; exit}' "$tmp/sha256")
  got=$(sha256_of "$tmp/$archive")
  if [[ -z $want || $want != "$got" ]]; then
    rm -rf "$tmp"
    die "the checksum of $archive is not the one the release publishes, refusing to use it"
  fi

  tar -xzf "$tmp/$archive" -C "$tmp" uf \
    || { rm -rf "$tmp"; die "no uf binary inside $archive"; }
  mkdir -p "$UF_CLIENT_DIR"
  mv "$tmp/uf" "$UF_CLIENT_DIR/uf"
  chmod +x "$UF_CLIENT_DIR/uf"
  rm -rf "$tmp"
  log "urlfrontier client $version kept at $UF_CLIENT_DIR/uf"
}

need_sudo() {
  (( DROP_CACHES || SWAPOFF )) || return 0
  sudo -v || die "sudo is needed to drop the page cache, set DROP_CACHES=0 SWAPOFF=0 to skip it"
  # the write benchmark can run for the best part of an hour, keep the timestamp alive so that
  # nothing asks for a password in the middle of the chain
  while true; do
    sudo -n true 2> /dev/null || break
    sleep 50
  done &
  SUDO_KEEPALIVE=$!
}

drop_caches() {
  if (( ! DROP_CACHES )); then
    log "page cache left alone (DROP_CACHES=0)"
    return 0
  fi
  sync
  echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
  log "page cache dropped"
}

# ---------------------------------------------------------------- backend containers

start_backend() {
  local backend=$1 data="$DATA_ROOT/$backend"

  mkdir -p "$DATA_ROOT"
  wipe "$data"
  mkdir -p "$data"
  chmod 777 "$data" # the containers run as their own user, the data stays on the host

  case $backend in
    opensearch)
      CONTAINER=opensearch-bench
      docker rm -f "$CONTAINER" > /dev/null 2>&1 || true
      docker run -d --name "$CONTAINER" -p "127.0.0.1:$OS_PORT:9200" \
        -v "$data":/usr/share/opensearch/data \
        -e discovery.type=single-node -e DISABLE_SECURITY_PLUGIN=true -e bootstrap.memory_lock=true \
        -e "OPENSEARCH_JAVA_OPTS=-Xms$HEAP -Xmx$HEAP" \
        --ulimit memlock=-1:-1 --ulimit nofile=65536:65536 \
        "$OS_IMAGE" > /dev/null
      ;;
    urlfrontier)
      # the image has no config.ini and its entrypoint passes none, so mount ours and point
      # the service at it with -c. rocksdb.path in it must sit under the mounted data directory.
      CONTAINER=urlfrontier-bench
      docker rm -f "$CONTAINER" > /dev/null 2>&1 || true
      docker run -d --name "$CONTAINER" -p "$UF_PORT:7071" \
        -v "$UF_CONFIG":/home/urlfrontier/config.ini:ro \
        -v "$data":/data/crawl \
        --entrypoint java "$UF_IMAGE" \
        "-Xms$HEAP" "-Xmx$HEAP" -XX:+UseG1GC -jar urlfrontier-service.jar -c config.ini > /dev/null
      ;;
    horizon)
      # Horizon is a native binary, not a JVM, so there is no heap to set. It comes with its own
      # config.ini at /etc/horizon/config.ini and its default command writes to /data/rocksdb.
      CONTAINER=horizon-bench
      docker rm -f "$CONTAINER" > /dev/null 2>&1 || true
      docker run -d --name "$CONTAINER" -p "$UF_PORT:7071" -e HORIZON_LICENSE \
        -v "$data":/data \
        "$HORIZON_IMAGE" > /dev/null
      ;;
  esac
  log "started $CONTAINER"
}

wait_ready() {
  local backend=$1 deadline=$((SECONDS + READY_TIMEOUT))
  while (( SECONDS < deadline )); do
    if [[ "$(docker inspect --format '{{.State.Running}}' "$CONTAINER" 2> /dev/null)" != "true" ]]; then
      docker logs "$CONTAINER" > "$OUTDIR/$backend-container.log" 2>&1 || true
      die "$CONTAINER stopped while starting up, see $OUTDIR/$backend-container.log"
    fi
    case $backend in
      opensearch)
        if curl -fsS "http://localhost:$OS_PORT/_cluster/health?wait_for_status=yellow&timeout=5s" \
          > /dev/null 2>&1; then
          return 0
        fi
        ;;
      *)
        if ! port_free "$UF_PORT"; then
          return 0
        fi
        ;;
    esac
    sleep 2
  done
  die "$backend was not ready after ${READY_TIMEOUT}s"
}

stop_container() {
  [[ -n $CONTAINER ]] || return 0
  # give it time to flush and close cleanly, RocksDB only writes its memtables out on shutdown
  docker stop -t 120 "$CONTAINER" > /dev/null 2>&1 || true
  docker rm -f "$CONTAINER" > /dev/null 2>&1 || true
  log "stopped $CONTAINER"
  CONTAINER=
}

wipe() {
  local dir=$1
  [[ -e $dir ]] || return 0
  if rm -rf "$dir" 2> /dev/null; then
    return 0
  fi
  # the backends run as their own user, so their files are not ours to delete
  docker run --rm -v "$(dirname "$dir")":/wipe "$WIPE_IMAGE" \
    rm -rf "/wipe/$(basename "$dir")" > /dev/null
}

# ---------------------------------------------------------------- disk use

# Space the backend has on disk. Taken with the container running after the writes, and again
# once it has stopped, which is the figure to compare: RocksDB only writes its memtables out on
# a clean shutdown, and OpenSearch keeps a translog until it is flushed.
measure_disk() {
  local backend=$1 label=$2 data="$DATA_ROOT/$backend" kb bytes human
  [[ -d $data ]] || return 0

  if ! kb=$(du -sk "$data" 2> /dev/null | cut -f1); then
    # some of it belongs to the container's user and is not ours to read
    kb=$(docker run --rm -v "$DATA_ROOT":/data "$WIPE_IMAGE" du -sk "/data/$backend" | cut -f1)
  fi
  bytes=$((kb * 1024))
  human=$(numfmt --to=iec --suffix=B "$bytes" 2> /dev/null || printf '%s bytes' "$bytes")

  say "$(printf 'disk %-18s %10s  (%s bytes)' "$label:" "$human" "$bytes")"
  printf '%s\t%s\t%s\n' "$label" "$bytes" "$human" >> "$OUTDIR/$backend-disk.txt"
  log "$backend on disk $label: $human"
}

# what OpenSearch itself reports, which counts the segments rather than the directory
os_index_stats() {
  local backend=$1 label=$2 line
  curl -fsS -XPOST "http://localhost:$OS_PORT/status/_flush?wait_if_ongoing=true" > /dev/null 2>&1 || true
  line=$(curl -fsS \
    "http://localhost:$OS_PORT/_cat/indices/status?h=docs.count,docs.deleted,store.size,pri.store.size" \
    2> /dev/null) || return 0
  say "index (docs, deleted, store, primaries): $(printf '%s' "$line" | tr -s ' ')"
  printf 'index\t%s\n' "$(printf '%s' "$line" | tr -s ' ')" >> "$OUTDIR/$backend-disk.txt"
  check_count "$backend" "$label" "$(printf '%s' "$line" | awk '{print $1}')"
}

# what the frontier itself reports, read with the urlfrontier client over the published port
frontier_stats() {
  local backend=$1 label=$2 out
  if ! out=$("$UF_CLIENT" --host localhost --port "$UF_PORT" get-stats 2>&1); then
    log "could not read the stats from $backend $label: $out"
    return 0
  fi
  say "frontier stats $label:"
  printf '%s\n' "$out" | sed 's/^/  /' >> "$OUTDIR/summary.txt"
  printf '%s\n' "$out" | sed 's/^/stats\t/' >> "$OUTDIR/$backend-disk.txt"
  check_count "$backend" "$label" "$(printf '%s' "$out" | awk '/^URLs:/ {print $2}')"
}

# Every backend is fed the same file, so they should all end up holding the same number of URLs.
# The first figure measured becomes the reference and the rest are checked against it, unless
# EXPECTED_URLS says what to expect. A mismatch is worth knowing about but is not a reason to
# stop the chain, so it is logged as a warning.
check_count() {
  local backend=$1 label=$2 count=$3 diff
  [[ $count =~ ^[0-9]+$ ]] || return 0
  if [[ -z $REFERENCE_URLS ]]; then
    REFERENCE_URLS=$count
    REFERENCE_FROM="$backend $label"
    say "$(printf 'URLs held %-16s %12s  (the reference for this run)' "$label:" "$count")"
    log "$backend holds $count URLs $label, the reference for this run"
    return 0
  fi
  diff=$((count - REFERENCE_URLS))
  say "$(printf 'URLs held %-16s %12s  (%+d against %s)' "$label:" "$count" "$diff" "$REFERENCE_FROM")"
  if (( diff == 0 )); then
    log "$backend holds $count URLs $label, the same as $REFERENCE_FROM"
  else
    log "WARNING: $backend holds $count URLs $label, $diff against $REFERENCE_FROM ($REFERENCE_URLS)"
  fi
}

# ---------------------------------------------------------------- stats

# CPU ticks and resident pages of a process and its descendants
proc_sample() {
  local pids p line rest ticks=0 pages=0
  pids=$(pid_tree "$1")
  for p in $pids; do
    [[ -r /proc/$p/stat ]] || continue
    line=$(< "/proc/$p/stat") || continue
    rest=${line#*') '} # the command name is parenthesised and can hold anything
    # shellcheck disable=SC2086 # the fields are numbers, splitting is the point
    set -- $rest
    ticks=$((ticks + ${12:-0} + ${13:-0})) # utime, stime
    pages=$((pages + ${22:-0}))            # rss
  done
  printf '%s %s\n' "$ticks" "$pages"
}

pid_tree() {
  local child
  printf '%s\n' "$1"
  for child in $(pgrep -P "$1" 2> /dev/null); do
    pid_tree "$child"
  done
}

# Same columns as container-stats.sh, for a process tree rather than a container
harness_stats() {
  local pid=$1 out=$2 hz page mem_kb t0 t1 u0 u1 sample pages
  hz=$(getconf CLK_TCK)
  page=$(getconf PAGESIZE)
  mem_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)

  echo "time,cpu_perc,mem_mib,mem_perc" > "$out"
  t0=$(proc_sample "$pid" | cut -d' ' -f1)
  u0=$(cut -d' ' -f1 /proc/uptime)

  while kill -0 "$pid" 2> /dev/null; do
    sleep "$STATS_INTERVAL"
    kill -0 "$pid" 2> /dev/null || break
    sample=$(proc_sample "$pid")
    t1=${sample% *}
    pages=${sample#* }
    u1=$(cut -d' ' -f1 /proc/uptime)
    if (( t1 < t0 )); then
      break
    fi
    awk -v t0="$t0" -v t1="$t1" -v u0="$u0" -v u1="$u1" -v hz="$hz" \
      -v pages="$pages" -v page="$page" -v memkb="$mem_kb" -v now="$(date +%T)" 'BEGIN {
        dt = u1 - u0
        if (dt <= 0) dt = 1
        mib = pages * page / 1048576
        printf "%s,%.1f,%.1f,%.1f\n", now, (t1 - t0) / hz / dt * 100, mib, mib * 1024 / memkb * 100
      }' >> "$out"
    t0=$t1
    u0=$u1
  done
}

# the storm script is a wrapper, the work happens in the java process it starts
find_java_pid() {
  local class=$1 deadline=$((SECONDS + 120)) pid exe
  while (( SECONDS < deadline )); do
    for pid in $(pgrep -f "$class" 2> /dev/null); do
      exe=$(readlink -f "/proc/$pid/exe" 2> /dev/null) || continue
      if [[ ${exe##*/} == java ]]; then
        printf '%s\n' "$pid"
        return 0
      fi
    done
    sleep 1
  done
  return 1
}

start_stats() {
  local step=$1 class=$2 pid
  if [[ -n $CONTAINER ]]; then
    ./container-stats.sh "$CONTAINER" "$STATS_INTERVAL" "$OUTDIR/$step-backend.csv" &
    STATS_PIDS+=("$!")
  fi
  if pid=$(find_java_pid "$class"); then
    harness_stats "$pid" "$OUTDIR/$step-harness.csv" &
    STATS_PIDS+=("$!")
  else
    log "could not find the storm JVM, no harness stats for $step"
  fi
}

stop_stats() {
  local pid
  for pid in ${STATS_PIDS[@]+"${STATS_PIDS[@]}"}; do
    pkill -P "$pid" 2> /dev/null || true
    kill "$pid" 2> /dev/null || true
    wait "$pid" 2> /dev/null || true
  done
  STATS_PIDS=()
}

# ---------------------------------------------------------------- steps

run_step() {
  local step=$1 class=$2
  shift 2
  local out="$OUTDIR/$step.log" start=$SECONDS rc=0 cmd_pid tail_pid secs

  log "$step: storm local $JAR $class $*"
  : > "$out"
  storm local "$JAR" "$class" "$@" > "$out" 2>&1 &
  cmd_pid=$!
  tail -f --pid="$cmd_pid" -n +1 "$out" &
  tail_pid=$!

  start_stats "$step" "$class"
  wait "$cmd_pid" || rc=$?
  stop_stats
  wait "$tail_pid" 2> /dev/null || true

  secs=$((SECONDS - start))
  # StatusUpdaterBenchmark exits 1 when a URL failed, which is a result, not a reason to stop
  log "$step finished in $(fmt_dur "$secs"), exit $rc"
  summarise "$step" "$rc" "$secs"
}

summarise() {
  local step=$1 rc=$2 secs=$3 out="$OUTDIR/$step.log" csv label
  say ""
  say "## $step  (exit $rc, wall $(fmt_dur "$secs"))"
  grep -E '^((Instances|Parsers|Spout instances|Bolt instances): [0-9]+|Max spout pending: .+|(Sent|Acked|Failed|Emitted|Unique): [0-9,]+|Total time: [0-9,]+ msec|Average (OPS|unique URLs/sec): [0-9,]+)$' \
    "$out" >> "$OUTDIR/summary.txt" || say "no figures in $step.log"
  for csv in "$OUTDIR/$step-backend.csv" "$OUTDIR/$step-harness.csv"; do
    [[ -s $csv ]] || continue
    (( $(wc -l < "$csv") > 1 )) || continue
    label=${csv##*-}
    say "$(printf '%-9s %s' "${label%.csv}:" "$(./avg-stats.sh "$csv")")"
  done
}

run_backend() {
  local backend=$1 sup spout data="$DATA_ROOT/$1"

  case $backend in
    baseline)
      sup=baseline
      spout=
      ;;
    opensearch)
      sup=org.apache.stormcrawler.opensearch.persistence.StatusUpdaterBolt
      spout=org.apache.stormcrawler.opensearch.persistence.AggregationSpout
      ;;
    urlfrontier | horizon)
      sup=org.apache.stormcrawler.urlfrontier.StatusUpdaterBolt
      spout=org.apache.stormcrawler.urlfrontier.Spout
      ;;
  esac

  log "===== $backend ====="
  say ""
  say "# $backend"

  drop_caches
  if [[ $backend != baseline ]]; then
    : > "$OUTDIR/$backend-disk.txt"
    start_backend "$backend"
    wait_ready "$backend"
    log "$backend is up"
  fi

  run_step "$backend-writes" "$WRITE_CLASS" "$sup" "$WRITE_INSTANCES" "$CONF" "$INPUT"

  case $backend in
    opensearch) os_index_stats "$backend" "after the writes" ;;
    urlfrontier | horizon) frontier_stats "$backend" "after the writes" ;;
  esac
  measure_disk "$backend" "after the writes"

  if [[ -z $spout ]]; then
    log "no spout to benchmark for $backend, skipping the reads"
    say "read benchmark skipped, the baseline has no spout"
    say "nothing stored, nothing to measure on disk"
  else
    log "letting $backend settle for ${SETTLE_SECS}s"
    sleep "$SETTLE_SECS"
    if [[ $backend == opensearch ]]; then
      if curl -fsS -XPOST "http://localhost:$OS_PORT/status/_refresh" > /dev/null 2>&1; then
        log "status index refreshed"
      fi
    fi
    run_step "$backend-reads" "$READ_CLASS" \
      "$spout" "$sup" "$READ_MINUTES" "$READ_SPOUTS" "$READ_BOLTS" "$CONF"
  fi

  if [[ -n $CONTAINER ]]; then
    case $backend in
      opensearch) os_index_stats "$backend" "after the reads" ;;
      urlfrontier | horizon) frontier_stats "$backend" "after the reads" ;;
    esac
    docker logs "$CONTAINER" > "$OUTDIR/$backend-container.log" 2>&1 || true
    stop_container
    measure_disk "$backend" "after shutdown"
    if (( ! KEEP_DATA )); then
      wipe "$data"
    fi
  fi
}

cleanup() {
  local rc=$?
  stop_stats
  stop_container
  if [[ -n $SUDO_KEEPALIVE ]]; then
    kill "$SUDO_KEEPALIVE" 2> /dev/null || true
  fi
  exit $rc
}

# ---------------------------------------------------------------- go

mkdir -p "$OUTDIR" "$DATA_ROOT"
if [[ -n $(ls -A "$OUTDIR" 2> /dev/null) ]]; then
  printf 'the output directory %s is not empty, what this run writes replaces what is there\n' \
    "$OUTDIR" >&2
fi
: > "$OUTDIR/run.log"
: > "$OUTDIR/summary.txt"
# the paths go into docker mounts, which take nothing but absolute ones
DATA_ROOT=$(cd "$DATA_ROOT" && pwd)
if [[ -f $UF_CONFIG ]]; then
  UF_CONFIG=$(readlink -f "$UF_CONFIG")
fi

trap cleanup EXIT
trap 'log "interrupted"; exit 130' INT TERM

check

# once for the whole chain, the page cache is the only thing dropped again for each backend
need_sudo
docker context use default > /dev/null 2>&1
if (( SWAPOFF )); then
  sudo swapoff -a
  log "swap off"
fi

{
  echo "# $(date -Is)  $(hostname)"
  echo "kernel $(uname -r), $(nproc) threads, $(free -g | awk '/^Mem:/ {print $2}') GiB RAM"
  echo "docker $(docker version --format '{{.Server.Version}}')"
  echo "backends: ${BACKENDS[*]}"
  echo "input: $INPUT ($(du -h "$INPUT" | cut -f1))"
  echo "conf: $CONF, URLFrontier config: $UF_CONFIG"
  echo "heap of every JVM backend: $HEAP (Horizon is a native binary, no heap to set)"
  echo "writes: $WRITE_INSTANCES status updater(s)"
  echo "reads: $READ_SPOUTS spout(s), $READ_BOLTS status updater(s), $READ_MINUTES min"
  echo "settle between writes and reads: ${SETTLE_SECS}s, drop_caches: $DROP_CACHES, swapoff: $SWAPOFF"
  echo "images: $OS_IMAGE, $UF_IMAGE, $HORIZON_IMAGE"
} >> "$OUTDIR/summary.txt"

log "run directory $OUTDIR"
for backend in "${BACKENDS[@]}"; do
  run_backend "$backend"
done

log "done"
printf '\n'
cat "$OUTDIR/summary.txt"
