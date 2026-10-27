#!/usr/bin/env python3
"""
Generates a synthetic input for the benchmarks, in the URLFrontier ndjson
import format.

Each queue is a host https://benchmarkN.com/ whose URLs form a tree with a
fixed fanout, expanded breadth first. For each parent, its children are
emitted as discovered, then the parent itself as known:

  https://benchmark1.com/0 ... /<fanout-1>      discovered
  https://benchmark1.com/                        known
  https://benchmark1.com/0/0 ... /0/<fanout-1>   discovered
  https://benchmark1.com/0                       known
  ...

Parents are expanded round robin across the queues so that they all grow
at the same pace. Generation for a queue stops once it holds
--urls-per-queue unique URLs.

Usage:
  ./generate-input.py --queues 100 --urls-per-queue 10000 --fanout 50 -o input.ndjson.gz
"""

import argparse
import gzip
import json
import sys
from collections import deque


def record(status, url, key):
    return json.dumps({status: {"info": {"url": url, "key": key}}}, separators=(",", ":"))


def generate(queues, urls_per_queue, fanout, out):
    states = []
    for q in range(1, queues + 1):
        host = f"benchmark{q}.com"
        # the root counts as one URL, it is only ever emitted as known
        states.append({"host": host, "parents": deque(["/"]), "count": 1})

    active = states
    while active:
        still_active = []
        for state in active:
            host = state["host"]
            parent = state["parents"].popleft()
            prefix = parent if parent.endswith("/") else parent + "/"
            n = min(fanout, urls_per_queue - state["count"])
            for i in range(n):
                child = f"{prefix}{i}"
                out.write(record("discovered", f"https://{host}{child}", host))
                out.write("\n")
                state["parents"].append(child)
            state["count"] += n
            out.write(record("known", f"https://{host}{parent}", host))
            out.write("\n")
            if state["count"] < urls_per_queue and state["parents"]:
                still_active.append(state)
        active = still_active


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--queues", type=int, required=True, help="number of queues (hosts)")
    parser.add_argument("--urls-per-queue", type=int, required=True, help="unique URLs per queue")
    parser.add_argument("--fanout", type=int, default=100, help="children per URL (default 100)")
    parser.add_argument("-o", "--output", default="-", help="output file, gzipped if it ends with .gz (default stdout)")
    args = parser.parse_args()

    if args.queues < 1 or args.urls_per_queue < 1 or args.fanout < 1:
        parser.error("--queues, --urls-per-queue and --fanout must be positive")

    if args.output == "-":
        generate(args.queues, args.urls_per_queue, args.fanout, sys.stdout)
    elif args.output.endswith(".gz"):
        with gzip.open(args.output, "wt", encoding="utf-8") as out:
            generate(args.queues, args.urls_per_queue, args.fanout, out)
    else:
        with open(args.output, "w", encoding="utf-8") as out:
            generate(args.queues, args.urls_per_queue, args.fanout, out)


if __name__ == "__main__":
    main()
