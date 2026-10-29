#!/usr/bin/env bash
#
# Prints the CPU and memory usage of a container as CSV, until it stops.
#
# Usage: ./container-stats.sh <container> [interval secs, default 1] [output file, default stdout]
#
# Columns: time, cpu_perc (100 = one core), mem_mib, mem_perc
# Each sample takes ~1-2 secs on top of the interval, as docker stats waits for two readings.

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <container> [interval secs] [output file]" >&2
  exit 1
fi

CONTAINER="$1"
INTERVAL="${2:-1}"
OUTPUT="${3:-/dev/stdout}"

echo "time,cpu_perc,mem_mib,mem_perc" > "$OUTPUT"

# .State.Running prints false (exit 0) for a stopped container, so check the value
while [[ "$(docker inspect --format '{{.State.Running}}' "$CONTAINER" 2> /dev/null)" == "true" ]]; do
  docker stats --no-stream --format '{{.CPUPerc}},{{.MemUsage}},{{.MemPerc}}' "$CONTAINER" 2> /dev/null \
    | awk -F, -v date="$(date +%T)" '
      function mib(v,   n, u) {
        n = v + 0
        u = v; sub(/^[0-9.]+/, "", u)
        if (u == "B") return n / 1048576
        if (u == "KiB" || u == "kB") return n / 1024
        if (u == "GiB" || u == "GB") return n * 1024
        if (u == "TiB" || u == "TB") return n * 1048576
        return n
      }
      {
        split($2, mem, " / ")
        gsub(/%/, "", $1); gsub(/%/, "", $3)
        printf "%s,%s,%.1f,%s\n", date, $1, mib(mem[1]), $3
      }' >> "$OUTPUT" || true
  sleep "$INTERVAL"
done
