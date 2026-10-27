#!/usr/bin/env bash
# Chạy một kịch bản test autoscale, kết quả lưu ở loadtest/results/<ngày>-autoscale/<S>/
# Chạy trên node server, đứng ở thư mục gốc repo. Hướng dẫn: docs/runbooks/autoscaling.md
# Usage: run-scenario.sh S1|S2|S3|S4|S5|S6
#   S1 không tải 30 phút           S4 tải lên xuống quanh ngưỡng 20 phút
#   S2 1,5 × ngưỡng trong 10 phút  S5 stream dài trong lúc scale xuống
#   S3 dừng tải, chờ về 1 replica  S6 KEDA không đọc được Prometheus 5 phút
set -euo pipefail

S="${1:?Usage: run-scenario.sh S1..S6}"
NS=llm-serving
# Lấy ngưỡng đang dùng trong ScaledObject
TARGET="${TARGET:-$(kubectl -n "$NS" get scaledobject llama31-8b \
  -o jsonpath='{.spec.triggers[?(@.name=="concurrency")].metadata.threshold}')}"
HIGH=$(( (TARGET * 3 + 1) / 2 ))            # 1,5 × ngưỡng, làm tròn lên
KEY_SECRET="${KEY_SECRET:-loadtest-api-key}"
BASE_URL="${BASE_URL:-http://llm-gateway-envoy.envoy-gateway-system.svc}"
DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="${OUT:-loadtest/results/$(date +%F)-autoscale/$S}"
JOB="loadgen-$(tr '[:upper:]' '[:lower:]' <<<"$S")"

mkdir -p "$OUT"
kubectl -n "$NS" get secret "$KEY_SECRET" >/dev/null

cleanup() {
  [[ -n ${WATCH_PID:-} ]] && kill "$WATCH_PID" 2>/dev/null || true
  kubectl -n "$NS" delete job "$JOB" --ignore-not-found --wait=false >/dev/null
  kubectl -n "$NS" delete configmap loadgen --ignore-not-found >/dev/null
  kubectl -n monitoring delete networkpolicy s6-block-keda --ignore-not-found >/dev/null
}
trap cleanup EXIT

log() { echo "[$(date +%T)] $*" | tee -a "$OUT/summary.txt"; }

# Tạo tải bằng Job, dùng lại image vLLM có sẵn trên node (có sẵn aiohttp)
start_load() {  # <profile> [max-tokens]
  kubectl -n "$NS" create configmap loadgen --from-file="$DIR/loadgen.py" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n "$NS" apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: $JOB
  labels: { app.kubernetes.io/part-of: llm-serving, app.kubernetes.io/component: loadtest }
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: loadgen
          image: vllm/vllm-openai:v0.31.0
          command: [python3, /scripts/loadgen.py, --profile, "$1", --max-tokens, "${2:-256}"]
          env:
            - { name: BASE_URL, value: "$BASE_URL" }
            - name: API_KEY
              valueFrom: { secretKeyRef: { name: $KEY_SECRET, key: key } }
            # Image vLLM để NVIDIA_VISIBLE_DEVICES=all, tắt đi để Job không đụng vào GPU
            - { name: NVIDIA_VISIBLE_DEVICES, value: void }
          resources:
            requests: { cpu: 200m, memory: 256Mi }
            limits: { cpu: "1", memory: 1Gi }
          volumeMounts: [{ name: scripts, mountPath: /scripts }]
      volumes: [{ name: scripts, configMap: { name: loadgen } }]
EOF
  log "tải: profile $1, max_tokens ${2:-256}"
}

wait_load() {
  kubectl -n "$NS" wait --for=condition=complete "job/$JOB" --timeout=2h >/dev/null ||
    log "Job không complete: kubectl -n $NS describe job/$JOB"
  kubectl -n "$NS" logs "job/$JOB" > "$OUT/loadgen.log"
  grep -E '^(start_ts|[0-9])' "$OUT/loadgen.log" > "$OUT/requests.csv" || true
  grep -E '^\{' "$OUT/loadgen.log" | tee -a "$OUT/summary.txt" || true
}

idle() { log "không tải $1 giây"; sleep "$1"; }

bash "$DIR/watch.sh" "$OUT/timeline.csv" &
WATCH_PID=$!
log "$S bắt đầu (target $TARGET, 1,5 × target = $HIGH, base $BASE_URL)"

case "$S" in
  S1) idle 1800 ;;
  S2) start_load "600:$HIGH"; wait_load ;;
  S3) idle 1200 ;;  # scaleDown stabilization 600 s + 1 pod / 60 s, kỳ vọng về 1 trong ≤ 15 phút
  S4)
    # 10 lần: 1 phút trên ngưỡng, 1 phút dưới ngưỡng
    profile=$(for _ in $(seq 10); do printf '60:%d,60:%d,' $((TARGET + 1)) $((TARGET - 1)); done)
    start_load "${profile%,}"; wait_load ;;
  S5)
    # Đẩy lên 2 replica, sau đó chỉ giữ 1 stream dài để KEDA scale xuống trong lúc đang stream
    start_load "300:$HIGH,1200:1" 1024; wait_load ;;
  S6)
    kubectl apply -f - >/dev/null <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: s6-block-keda
  namespace: monitoring
spec:
  podSelector:
    matchLabels: { app.kubernetes.io/name: prometheus }
  policyTypes: [Ingress]
  ingress:
    # Chỉ chặn namespace keda, Grafana vẫn xem được bình thường
    - from:
        - namespaceSelector:
            matchExpressions:
              - { key: kubernetes.io/metadata.name, operator: NotIn, values: [keda] }
EOF
    log "chặn keda → Prometheus 300 giây"
    sleep 300
    kubectl -n monitoring delete networkpolicy s6-block-keda >/dev/null
    log "bỏ chặn"
    idle 900 ;;
  *) echo "Không có kịch bản $S" >&2; exit 1 ;;
esac

log "$S xong, kết quả ở $OUT"
