#!/usr/bin/env bash
# Xuất nhiệt độ, SM clock, công suất GPU của mọi node trong một khoảng thời gian đo (step 15s) ra CSV.
# Usage: gpu_conditions.sh <start_unix_ts> <end_unix_ts> <out.csv>
set -euo pipefail

START="${1:?Usage: gpu_conditions.sh <start_ts> <end_ts> <out.csv>}"
END="${2:?}"
OUT="${3:?}"
PROM=/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/query_range
KUBECTL="${KUBECTL:-kubectl}"

# In "<ts> <hostname> <value>" mỗi dòng
series() {
  $KUBECTL get --raw "$PROM?query=$1&start=$START&end=$END&step=15" |
    python3 -c '
import json, sys
d = json.load(sys.stdin)
if d.get("status") != "success":
    sys.exit("Prometheus lỗi: " + str(d))
for s in d["data"]["result"]:
    for ts, v in s["values"]:
        print(int(float(ts)), s["metric"].get("hostname", "?"), v)'
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
series DCGM_FI_DEV_GPU_TEMP > "$tmp/temp"
series DCGM_FI_DEV_SM_CLOCK > "$tmp/clock"
series DCGM_FI_DEV_POWER_USAGE > "$tmp/power"
[[ -s $tmp/temp ]] || { echo "Không có dữ liệu DCGM trong khoảng $START–$END" >&2; exit 1; }

echo "time,hostname,temp_c,sm_clock_mhz,power_w" > "$OUT"
awk 'FILENAME ~ /temp$/ {t[$1" "$2]=$3} FILENAME ~ /clock$/ {c[$1" "$2]=$3} FILENAME ~ /power$/ {p[$1" "$2]=$3}
     END {for (k in t) {split(k, a, " "); printf "%s,%s,%s,%s,%s\n", a[1], a[2], t[k], c[k], p[k]}}' \
  "$tmp/temp" "$tmp/clock" "$tmp/power" | sort -t, -k1,1n -k2,2 >> "$OUT"
echo "$(( $(wc -l < "$OUT") - 1 )) dòng → $OUT"
