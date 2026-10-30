# StormCrawler backend benchmark

A template for benchmarking the status backends of [Apache StormCrawler](https://stormcrawler.apache.org/), i.e. what stores the URLs and their status, and gives the spouts the URLs to fetch next. Two utilities from `stormcrawler-core` do the measurements, without running a topology:

- **`StatusUpdaterBenchmark`** (writes): feeds the URLs from a file to one or more instances of a status updater bolt and measures how many per second are acked.
- **`SpoutBenchmark`** (reads): runs one or more spouts against a backend that's already populated for a given number of minutes. Every URL emitted is sent back to a status updater as FETCHED, and the utility reports how many *unique* URLs per second were emitted.

This repository holds the project the utilities are run from (`pom.xml` brings in the core, OpenSearch and URLFrontier modules), the configuration, and a script to generate input.

## Contents

| File | What it is |
|---|---|
| `pom.xml` | Crawl project with the dependencies for the backends tested |
| `benchmark-conf.yaml` | Settings for OpenSearch and URLFrontier, passed to both utilities |
| `config.ini` | URLFrontier settings, mounted into its container |
| `generate-input.py` | Generates a synthetic input file |
| `run-benchmark.sh` | Runs the write and the read benchmark against every backend in turn |
| `container-stats.sh` | Samples the CPU and memory of a container as CSV |
| `avg-stats.sh` | Averages a CSV from `container-stats.sh` |
| `src/main/resources/status.mapping` | Mapping of the OpenSearch status index |
| `src/main/java/.../DummyStatusUpdater.java` | Status updater that acks without storing, predates the `baseline` option |

## Build

The utilities are in `stormcrawler-core` 4.0.0-SNAPSHOT, so install StormCrawler from source first, then build this project:

```bash
cd ~/stormcrawler && mvn -q install -DskipTests -pl core,external/urlfrontier,external/opensearch -am
```

```bash
mvn -q package -DskipTests
```

The utilities must be run with `storm local`. Storm is a provided dependency, so `java -cp` fails with a `NoClassDefFoundError`.

`run-benchmark.sh` asks URLFrontier and Horizon how many URLs they ended up holding, which it does with the `uf` command from the [urlfrontier client](https://github.com/DigitalPebble/urlfrontier-client). That is a program of its own rather than part of this repository, so if it isn't on the PATH the script fetches the release build for the platform it is running on, checks it against the `sha256` published beside it and keeps it in `tools/`. Only the first run pays for that, and a run that includes neither frontier never asks for it. The figures are read as JSON, so `jq` has to be there too.

The script needs a client with `get-stats --json`, which is newer than the latest release: until the next one, build it from source with the `cargo install` below and point `UF_CLIENT` at it. A fetched client is checked for it and the run stops before it starts if it is too old.

| Setting | What it does |
|---|---|
| `UF_CLIENT` | A copy you already have, used as it is rather than fetching one |
| `UF_CLIENT_VERSION` | The release to fetch, the latest one by default |
| `UF_CLIENT_DIR` | Where a fetched client is kept between runs, `tools/` by default |

There are release builds for Linux and macOS on x86_64 and aarch64. On anything else, or with no network, install it yourself and point `UF_CLIENT` at it:

```bash
cargo install --git https://github.com/DigitalPebble/urlfrontier-client
```

## Input

The input has the URLFrontier import format: one JSON `URLItem` per line, `discovered` or `known`, gzipped if the file name ends in `.gz`. Discovered items are stored as DISCOVERED. Known items are stored as FETCHED, with their `refetchable_from_date` as next fetch date, or never to be refetched if that's 0 or not set.

```json
{"discovered":{"info":{"url":"https://example.com/page","key":"example.com"}}}
{"known":{"info":{"url":"https://example.com/","key":"example.com"}}}
```

The order matters. In a crawl, the hosts are interleaved, and discovered and known URLs are mixed. A dump sorted by host sends each bulk request to only one or two OpenSearch shards when routing is on, which lowers the throughput. If an input is sorted, shuffle it first:

```bash
zcat urls.ndjson.gz | shuf | gzip > shuffled.ndjson.gz
```

### Synthetic input

`generate-input.py` builds an input of any size, with a set number of queues and of unique URLs per queue. Each queue is a host, `benchmark1.com` … `benchmarkN.com`, whose URLs form a tree with the given fanout, expanded breadth first. The children of a URL are emitted as discovered, then the URL itself as known:

```
https://benchmark1.com/0 … /49        discovered
https://benchmark1.com/               known
https://benchmark1.com/0/0 … /0/49    discovered
https://benchmark1.com/0              known
…
```

The queues are expanded round robin, so that they grow at the same pace and the hosts are interleaved throughout the file.

```bash
./generate-input.py --queues 1500000 --urls-per-queue 100 --fanout 50 -o benchmark.ndjson.gz
```

`--urls-per-queue` counts unique URLs, not lines. Every URL that gets expanded appears twice: once as discovered, then again as known. The example above gives 150M unique URLs on 151.5M lines.

## Running the benchmarks

### Preparing the machine

Run each backend on its own, and start from the same state every time:

```bash
docker context use default
sudo swapoff -a
sync && echo 3 | sudo tee /proc/sys/vm/drop_caches
```

### Baseline

Passing `baseline` instead of a class name acks the URLs as soon as they're received, without storing them. This gives the highest throughput the utility can report on that input and machine. It is not something to compare the backends against: it is a check that the harness isn't the limit. If a backend lands anywhere near it, the figure is about the utility rather than the store. Use the same input and number of instances as for the real runs.

```bash
storm local target/benchmark-0.1-SNAPSHOT.jar org.apache.stormcrawler.persistence.StatusUpdaterBenchmark \
  baseline benchmark-conf.yaml urldump-mixed.ndjson.gz
```

With nothing to store, the throughput is that of the thread reading the input, which depends on the length of the URLs, the presence of metadata and how well the file compresses. Measure the baseline on every input: it can vary by a factor of two or more between files on the same machine.

### Writes

```
StatusUpdaterBenchmark <bolt class>|baseline [<instances>] <conf file>... <input file>
```

```bash
storm local target/benchmark-0.1-SNAPSHOT.jar org.apache.stormcrawler.persistence.StatusUpdaterBenchmark \
  $SUP_CLASS benchmark-conf.yaml urldump-mixed.ndjson.gz
```

The URLs go straight to the bolt's `store` method, so this measures storage only: no cache of discovered URLs, no scheduling and no metadata filtering. The URLs are routed to the instances by hash, as a fields grouping on the URL would do.

### Reads

```
SpoutBenchmark <spout class> <bolt class> <minutes> [<spout instances> [<bolt instances>]] <conf file>...
```

```bash
storm local target/benchmark-0.1-SNAPSHOT.jar org.apache.stormcrawler.persistence.SpoutBenchmark \
  $SPOUT_CLASS $SUP_CLASS 3 10 1 benchmark-conf.yaml
```

Run it on the backend populated by the write benchmark. Here, 10 spouts and 1 status updater run for 3 minutes.

- **Unique URLs count, emitted ones don't.** A spout that emits the same URLs again does no more useful work. This happens, for instance, when the backend hasn't made an update visible by the time the URL leaves the spout's purgatory (`spout.ttl.purgatory`).
- **The fetch interval must outlast the run.** The URLs go through the scheduler, so `fetchInterval.default` (1440 minutes by default) must be longer than the run, or URLs become due again before it ends.
- **The unique URLs are held in memory.** Leave enough heap for them.

### Everything in one go

`run-benchmark.sh` chains the steps above for every backend. For each of them it drops the page cache, starts the backend from an empty data directory, runs the write benchmark, then the read one against what the writes left behind, measures the space used and stops the container before moving on to the next. The baseline has neither a container nor a spout, so it only runs the writes.

```bash
HORIZON_LICENSE=$(cat ~/horizon/digitalPebble.lic) ./run-benchmark.sh
```

It takes the backends to run as arguments, `baseline opensearch urlfrontier horizon` by default, `-o` for the directory everything is written to, and the rest of the settings from the environment: `INPUT`, `HEAP` (the heap of every JVM backend, `6g`, the same for all of them), `WRITE_INSTANCES`, `READ_MINUTES`, `READ_SPOUTS`, `READ_BOLTS`, `SETTLE_SECS` (idle time between the writes and the reads of a backend), `STATS_INTERVAL`, `KEEP_DATA=1` to keep the data directories, and `DROP_CACHES=0 SWAPOFF=0` to run without sudo.

```bash
INPUT=synthetic.ndjson.gz READ_MINUTES=5 ./run-benchmark.sh -o synthetic-run opensearch horizon
```

Each run writes to a directory of its own, `runs/<timestamp>`, so that nothing overwrites an earlier run. Pass `-o` to put it somewhere else (`OUTDIR` in the environment does the same).

| File | What it is |
|---|---|
| `<backend>-<writes\|reads>.log` | Output of the utility |
| `<backend>-<writes\|reads>-backend.csv` | CPU and memory of the backend container, from `container-stats.sh` |
| `<backend>-<writes\|reads>-harness.csv` | CPU and memory of the storm JVM, sampled from `/proc` |
| `<backend>-container.log` | Output of the backend container, both steps |
| `<backend>-disk.txt` | Space the backend used on disk, and the URLs it reported holding |
| `run.log` | What the script did, with timings |
| `summary.txt` | The figures of every step, the averages of the CSVs and the disk use |

Both CSVs have the columns of `container-stats.sh`, so `avg-stats.sh` reads either. For the harness, the memory is the resident size of the JVM and its percentage is a share of the host's RAM rather than of a container limit.

After the writes and again after the reads, each backend is asked how many URLs it is holding: OpenSearch through `_cat/indices`, the two frontiers through `uf get-stats --json`. A frontier reports the URLs it still has to crawl separately from the ones it has finished with, and the client gives their total, which is the figure comparable with the document count of an index, holding one document per URL whatever its status. Every backend is fed the same file, so the figures should agree. The first one measured becomes the reference, the rest are compared against it, and the difference goes into `summary.txt` either way. A backend that disagrees is a warning in `run.log` rather than a reason to stop the chain. Set `EXPECTED_URLS` to say up front what the figure should be, which is what to do when running a single backend on its own.

Each backend keeps its data in a directory of its own under `bench-data`, mounted into the container, so that the space it uses can be measured with `du`. It is measured after the writes and again once the container has stopped, which is the figure to compare: RocksDB only writes out what it holds in memory on a clean shutdown, and OpenSearch keeps a translog until it is flushed. OpenSearch is flushed before being measured and its own view of the index is recorded as well.

URLFrontier is run with `config.ini` mounted into its container and passed to the service with `-c`, so that the tuning it holds is what gets measured; [URLFrontier](#urlfrontier) below has the detail of the two mounts that takes. Horizon is a native binary rather than a JVM, so `HEAP` does not apply to it and it keeps the `config.ini` from its image.

Dropping the page cache and turning swap off need sudo. The script asks for it once at the start and keeps the timestamp alive, so that a write run lasting the best part of an hour doesn't stop for a password prompt. `StatusUpdaterBenchmark` exits 1 when a URL failed, as it does on OpenSearch; the script records the exit code and carries on.

## Backends

### OpenSearch

```bash
docker run -d --rm --name opensearch-bench -p 127.0.0.1:9201:9200 \
  -e discovery.type=single-node -e DISABLE_SECURITY_PLUGIN=true -e bootstrap.memory_lock=true \
  -e "OPENSEARCH_JAVA_OPTS=-Xms6g -Xmx6g" --ulimit memlock=-1:-1 --ulimit nofile=65536:65536 \
  opensearchproject/opensearch:3.9.0
```

```bash
SUP_CLASS=org.apache.stormcrawler.opensearch.persistence.StatusUpdaterBolt
SPOUT_CLASS=org.apache.stormcrawler.opensearch.persistence.AggregationSpout   # or HybridSpout
```

The status updater creates the `status` index from `src/main/resources/status.mapping` if it doesn't exist. The spouts use sampling (`opensearch.status.sample: true`): without it, the aggregations are too slow on an index this size. Sampling looks at part of the index rather than all of it, so the URLs that come back are urgent ones rather than strictly the most urgent: with it on, the priority order is approximate.

### URLFrontier

```bash
docker run -d -p 7071:7071 --entrypoint java urlfrontier:2.7-SNAPSHOT \
  -Xms8G -Xmx8G -XX:+UseG1GC -jar urlfrontier-service.jar
```

```bash
SUP_CLASS=org.apache.stormcrawler.urlfrontier.StatusUpdaterBolt
SPOUT_CLASS=org.apache.stormcrawler.urlfrontier.Spout
```

The image was built from the [url-frontier](https://github.com/crawler-commons/url-frontier) sources. `crawlercommons/url-frontier:latest` also works.

The image ships no `config.ini` and its entrypoint passes none, so the command above runs the service on its defaults. To benchmark it on the settings in `config.ini`, mount the file in and point the service at it with `-c`, as `run-benchmark.sh` does, with the 6 GB of heap it gives every JVM backend:

```bash
docker run -d -p 7071:7071 \
  -v "$PWD/config.ini":/home/urlfrontier/config.ini:ro \
  -v "$PWD/bench-data/urlfrontier":/data/crawl \
  --entrypoint java urlfrontier:2.7-SNAPSHOT \
  -Xms6G -Xmx6G -XX:+UseG1GC -jar urlfrontier-service.jar -c config.ini
```

| Mounted at | Why there |
|---|---|
| `/home/urlfrontier/config.ini` | `/home/urlfrontier` is the image's working directory, so the service finds the file as `-c config.ini`. Read only, nothing writes to it |
| `/data/crawl` | Where `rocksdb.path` in the file points, so that the store ends up on the host and the space it uses can be measured |

The two go together: the service runs as the user `urlfrontier`, uid 1001, which owns nothing outside its own home directory, so `rocksdb.path` has to point either inside that home or at a directory mounted in and writable by that uid. `run-benchmark.sh` creates the one it mounts mode 777 for that reason. Keep the path in `config.ini` and the mount point in step: if they drift apart, the store stays inside the container and the directory being measured is left empty.

The service logs the path it settled on, which is the quickest way to tell whether it read the file at all:

```
INFO c.u.service.rocksdb.RocksDBService - RocksDB data stored in /data/crawl/rocksdb
```

Settings can also be given as `key=value` arguments after the jar, which take precedence over the file.

### Horizon

[Horizon](https://ethicrawl.ai/horizon.html) is DigitalPebble's frontier, which implements the URLFrontier API. It uses the same classes as URLFrontier and needs a license key in `HORIZON_LICENSE`. It was run with no JVM flags set.

```bash
docker run -d -p 7071:7071 -e HORIZON_LICENSE ghcr.io/digitalpebble/horizon:0.4.0
```

## Results

| | |
|---|---|
| **Machine** | Dell XPS 15 9520: Intel Core i7-12700H (14 cores / 20 threads), 31 GiB RAM, Samsung PM9A1 NVMe SSD |
| **Software** | StormCrawler 4.0.0-SNAPSHOT run with `storm local`, Docker 28.3, one backend at a time, swap off and page cache dropped before each run |
| **Input** | `urldump-mixed.ndjson.gz`, status updates from an [Ethicrawl](https://ethicrawl.ai/) crawl, kept in crawl order so that new and known URLs are interleaved |
| **Lines** | 168,383,482 |
| **Unique URLs** | ~40.1M, across ~8.5M queues: about three quarters of the updates are for a URL already seen |
| **Instances** | 1 status updater for the writes; 10 spouts and 1 status updater for 3 minutes for the reads |

### Writes

| Backend | Time | URLs / sec | vs OpenSearch |
|---|---:|---:|---:|
| Horizon 0.4.0 | 7 min 20 s | 382,525 | 6.3x |
| URLFrontier 2.7-SNAPSHOT | 13 min 8 s | 213,782 | 3.5x |
| OpenSearch 3.9.0 | 46 min 25 s | 60,457 | 1x |

The harness writing to nothing managed 3,808,892 URLs / sec in 44 s on the same input, ten times the fastest backend, so none of these figures is bounded by the utility.

OpenSearch failed 111 URLs: their `metadata.anchor` was longer than the 32,766 bytes Lucene allows for a term. Both OpenSearch and URLFrontier ended up holding about 40.1M URLs.

### Reads

| Backend / spout | Unique URLs / sec | Unique URLs in 3 min | vs `HybridSpout` |
|---|---:|---:|---:|
| Horizon 0.4.0 | 51,431 | 9,262,965 | 9.8x |
| URLFrontier 2.7-SNAPSHOT | 34,790 | 6,262,251 | 6.6x |
| OpenSearch 3.9.0, `HybridSpout` | 5,242 | 943,658 | 1x |
| OpenSearch 3.9.0, `AggregationSpout` | 3,021 | 543,833 | 0.58x |

In all four runs every URL emitted was unique: no backend handed out the same URL twice.

Each figure is from a single run on one machine. Treat them as orders of magnitude: rerun them on your own hardware and input before relying on them.
