#!/usr/bin/env bash
#
# Averages a CSV produced by container-stats.sh
#
# Usage: ./avg-stats.sh <csv file> [cores, default nproc]
#
# cpu_perc is summed over cores by docker stats (100 = one core),
# also shown as a share of the given number of cores

awk -F, -v cores="${2:-$(nproc)}" 'NR>1{c+=$2;m+=$3;n++} END{printf "avg cpu %.2f%% (%.1f cores, %.1f%% of host)  avg mem %.1f MiB  (%d samples)\n", c/n, c/n/100, c/n/cores, m/n, n}' "$1"
