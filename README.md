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
| `generate-input.py` | Generates a synthetic input file |
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

Passing `baseline` instead of a class name acks the URLs as soon as they're received, without storing them. This gives the highest throughput the utility can report on that input and machine. The result for a backend can then be expressed as a fraction of the baseline. That ratio, unlike the raw figures, can be compared across machines. Use the same input and number of instances as for the real runs.

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

The status updater creates the `status` index from `src/main/resources/status.mapping` if it doesn't exist. The spouts use sampling (`opensearch.status.sample: true`): without it, the aggregations are too slow on an index this size.

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

| Backend | Time | URLs / sec | % of baseline |
|---|---:|---:|---:|
| Baseline (no storage) | 3 min 36 s | 779,247 | 100% |
| Horizon 0.4.0 | 7 min 20 s | 382,525 | 49% |
| URLFrontier 2.7-SNAPSHOT | 13 min 8 s | 213,782 | 27% |
| OpenSearch 3.9.0 | 46 min 25 s | 60,457 | 7.8% |

OpenSearch failed 111 URLs: their `metadata.anchor` was longer than the 32,766 bytes Lucene allows for a term. Both OpenSearch and URLFrontier ended up holding about 40.1M URLs.

### Reads

| Backend / spout | Unique URLs / sec | Unique URLs in 3 min |
|---|---:|---:|
| Horizon 0.4.0 | 51,431 | 9,262,965 |
| URLFrontier 2.7-SNAPSHOT | 34,790 | 6,262,251 |
| OpenSearch 3.9.0, `HybridSpout` | 5,242 | 943,658 |
| OpenSearch 3.9.0, `AggregationSpout` | 3,021 | 543,833 |

In all four runs every URL emitted was unique: no backend handed out the same URL twice.

Each figure is from a single run on one machine. Treat them as orders of magnitude: rerun them on your own hardware and input before relying on them.
