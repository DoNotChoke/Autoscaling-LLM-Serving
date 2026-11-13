#!/usr/bin/env bash
# Xuất metric vLLM theo từng pod (step 15s) ra CSV: running, waiting, KV cache, tỉ lệ trúng prefix cache.
# Usage: pod_metrics.sh <start_unix_ts> <end_unix_ts> <out.csv>
set -euo pipefail

START="${1:?Usage: pod_metrics.sh <start_ts> <end_ts> <out.csv>}"
END="${2:?}"
OUT="${3:?}"
PROM=/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/query_range
KUBECTL="${KUBECTL:-kubectl}"
SEL='namespace="llm-serving",model_name="llama31-8b"'

# In "<ts> <pod> <value>" mỗi dòng
series() {
  $KUBECTL get --raw "$PROM?query=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$1")&start=$START&end=$END&step=15" |
    python3 -c '
import json, sys
d = json.load(sys.stdin)
if d.get("status") != "success":
    sys.exit("Prometheus lỗi: " + str(d))
for s in d["data"]["result"]:
    for ts, v in s["values"]:
        print(int(float(ts)), s["metric"].get("pod", "?"), v)'
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
series "sum by (pod) (vllm:num_requests_running{$SEL})" > "$tmp/running"
series "sum by (pod) (vllm:num_requests_waiting{$SEL})" > "$tmp/waiting"
series "max by (pod) (vllm:kv_cache_usage_perc{$SEL})" > "$tmp/kv"
series "sum by (pod) (rate(vllm:prefix_cache_hits_total{$SEL}[1m])) / sum by (pod) (rate(vllm:prefix_cache_queries_total{$SEL}[1m]))" > "$tmp/prefix"
[[ -s $tmp/running ]] || { echo "Không có metric vLLM trong khoảng $START–$END" >&2; exit 1; }

echo "time,pod,running,waiting,kv_cache_usage,prefix_hit_rate" > "$OUT"
awk 'FILENAME ~ /running$/ {r[$1" "$2]=$3} FILENAME ~ /waiting$/ {w[$1" "$2]=$3}
     FILENAME ~ /kv$/ {k[$1" "$2]=$3} FILENAME ~ /prefix$/ {p[$1" "$2]=$3}
     END {for (key in r) {split(key, a, " "); printf "%s,%s,%s,%s,%s,%s\n", a[1], a[2], r[key], w[key], k[key], p[key]}}' \
  "$tmp/running" "$tmp/waiting" "$tmp/kv" "$tmp/prefix" | sort -t, -k1,1n -k2,2 >> "$OUT"
echo "$(( $(wc -l < "$OUT") - 1 )) dòng → $OUT"
