#!/bin/sh
# Samples CPU and memory of a compose project's containers every INTERVAL
# seconds, as CSV, until killed. `make loadtest` runs it next to k6, so a
# latency knee in the report can be matched with the container that saturated.
#
# Usage: stats.sh <compose project> <output.csv> [interval seconds]
set -u
project=$1
out=$2
interval=${3:-5}
echo "time,container,cpu_percent,mem_usage,mem_limit,mem_percent" > "$out"
while :; do
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  docker stats --no-stream --format '{{.Name}},{{.CPUPerc}},{{.MemUsage}},{{.MemPerc}}' \
    $(docker ps -q --filter "label=com.docker.compose.project=$project") 2>/dev/null |
    sed -e 's/%//g' -e 's# / #,#' -e "s/^/$now,/" >> "$out"
  sleep "$interval"
done
