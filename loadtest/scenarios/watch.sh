#!/usr/bin/env bash
# Cứ INTERVAL giây ghi lại số replica, số HPA muốn, giá trị metric và fallback vào file CSV
# Usage: watch.sh <file.csv>   (Ctrl-C để dừng)
set -uo pipefail

OUT="${1:?Usage: watch.sh <file.csv>}"
NS="${NS:-llm-serving}"
DEPLOY="${DEPLOY:-llama31-8b-predictor}"
SO="${SO:-llama31-8b}"
HPA="${HPA:-keda-hpa-$SO}"
INTERVAL="${INTERVAL:-15}"

echo "time,spec_replicas,ready_replicas,hpa_desired,hpa_metrics,so_fallback,pods" > "$OUT"
while true; do
  spec=$(kubectl -n "$NS" get deploy "$DEPLOY" -o jsonpath='{.spec.replicas}' 2>/dev/null)
  ready=$(kubectl -n "$NS" get deploy "$DEPLOY" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  desired=$(kubectl -n "$NS" get hpa "$HPA" -o jsonpath='{.status.desiredReplicas}' 2>/dev/null)
  # Giá trị từng trigger, vd "s0-prometheus=1500m s1-prometheus=120m"
  metrics=$(kubectl -n "$NS" get hpa "$HPA" \
    -o jsonpath='{range .status.currentMetrics[*]}{.external.metric.name}={.external.current.averageValue}{.external.current.value} {end}' 2>/dev/null)
  fallback=$(kubectl -n "$NS" get scaledobject "$SO" \
    -o jsonpath='{.status.conditions[?(@.type=="Fallback")].status}' 2>/dev/null)
  pods=$(kubectl -n "$NS" get pod -l "serving.kserve.io/inferenceservice=$SO" --no-headers 2>/dev/null |
    awk '{printf "%s/%s ", $3, $2}')
  echo "$(date +%FT%T),${spec:-},${ready:-0},${desired:-},${metrics% },${fallback:-},${pods% }" >> "$OUT"
  sleep "$INTERVAL"
done
