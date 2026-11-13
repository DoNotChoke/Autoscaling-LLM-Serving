#!/usr/bin/env bash
# Chạy một config inference-perf trong cluster (qua gateway, key loadtest), chờ xong, copy report về repo.
# Chạy trên node server, đứng ở thư mục gốc repo.
# Usage: run.sh <config> [--replicas2]
#   config: tên file trong loadtest/inference-perf/configs/ (không đuôi .yaml)
#   --replicas2: giữ 2 replica cố định trong lúc đo (tách ảnh hưởng autoscale khỏi routing)
# Kết quả: loadtest/results/<ngày>-ip-baseline/<config>[-replicas2]/ (OUT_ROOT để đổi thư mục gốc)
# QUICK_DURATION=<giây>: ghi đè thời gian mọi stage (tập dượt)
# SEED_OVERRIDE=<số>: ghi đè load.base_seed (lặp lại cùng config với chuỗi request khác)
set -euo pipefail

CONFIG="${1:?Usage: run.sh <config> [--replicas2]}"
REPLICAS2="${2:-}"
NS=llm-serving
DIR="$(cd "$(dirname "$0")" && pwd)"
[[ -f $DIR/configs/$CONFIG.yaml ]] || { echo "Không có config $CONFIG" >&2; exit 1; }
RUN="$CONFIG${REPLICAS2:+-replicas2}-$(date +%Y%m%d-%H%M%S)"
JOB="ip-$(tr '._' '--' <<< "$CONFIG")"
OUT="${OUT_ROOT:-loadtest/results/$(date +%F)-ip-baseline}/$CONFIG${REPLICAS2:+-replicas2}"
HELPER=ip-report-copy

log() { echo "[$(date +%T)] $*"; }
cleanup() {
  kubectl -n "$NS" delete pod "$HELPER" --ignore-not-found --wait=false >/dev/null
  # Log đã lưu vào $OUT; không để Job đã xong (và Secret key trong env) nằm lại trên cụm
  kubectl -n "$NS" delete job "$JOB" --ignore-not-found --wait=false >/dev/null
  if [[ -n $REPLICAS2 ]]; then
    kubectl -n "$NS" patch scaledobject llama31-8b --type merge -p '{"spec":{"minReplicaCount":1}}' >/dev/null
    log "minReplicaCount = 1 (restore)"
  fi
}
trap cleanup EXIT

kubectl -n "$NS" get secret loadtest-api-key >/dev/null
kubectl apply -k "$DIR" >/dev/null
# Server-side apply: ConfigMap ~950 KB, client-side apply sẽ vượt giới hạn annotation last-applied (256 KB)
if [[ -f $DIR/../datasets/sharegpt-500.jsonl ]]; then
  kubectl -n "$NS" create configmap inference-perf-sharegpt --from-file="$DIR/../datasets/sharegpt-500.jsonl" \
    --dry-run=client -o yaml | kubectl apply --server-side --force-conflicts -f - >/dev/null
fi
if [[ -n $REPLICAS2 ]]; then
  kubectl -n "$NS" patch scaledobject llama31-8b --type merge -p '{"spec":{"minReplicaCount":2}}' >/dev/null
  log "minReplicaCount = 2, chờ 2 pod Ready"
  kubectl -n "$NS" wait --for=jsonpath='{.status.readyReplicas}'=2 deploy/llama31-8b-predictor --timeout=15m >/dev/null
fi

kubectl -n "$NS" delete job "$JOB" --ignore-not-found --wait=true >/dev/null
# Tokenizer lấy từ đúng image model vLLM đang phục vụ
MODEL_IMAGE=$(kubectl -n "$NS" get inferenceservice llama31-8b -o jsonpath='{.spec.predictor.volumes[?(@.name=="model")].image.reference}')
[[ -n $MODEL_IMAGE ]] || { echo "Không đọc được image model từ InferenceService llama31-8b" >&2; exit 1; }
sed -e "s/^  name: inference-perf$/  name: $JOB/" \
    -e "s#reference: model-image#reference: $MODEL_IMAGE#" \
    -e "s/value: baseline-random }/value: $CONFIG }/" \
    -e "s/value: baseline-random-manual }/value: $RUN }/" \
    -e "s/name: DURATION, value: \"\" }/name: DURATION, value: \"${QUICK_DURATION:-}\" }/" \
    -e "s/name: SEED, value: \"\" }/name: SEED, value: \"${SEED_OVERRIDE:-}\" }/" "$DIR/job.yaml" | kubectl apply -f - >/dev/null
start=$(date +%s); log "Job $JOB ($RUN) bắt đầu"
# Chờ Job xong hoặc lỗi (kubectl wait chỉ chờ được một điều kiện, Job lỗi sẽ treo tới hết timeout)
status=timeout
for _ in $(seq 1 750); do
  s=$(kubectl -n "$NS" get job "$JOB" -o jsonpath='{.status.succeeded}/{.status.failed}')
  [[ $s == 1/* ]] && { status=complete; break; }
  [[ $s == */1 ]] && { status=failed; break; }
  sleep 10
done
end=$(date +%s)
log "Job $status"

mkdir -p "$OUT"
# inference-perf in nguyên config ra log, kể cả server.api_key: che trước khi lưu
kubectl -n "$NS" logs "job/$JOB" 2>&1 | sed -E 's/(api_key:).*/\1 <redacted>/' > "$OUT/inference-perf.log" || true
[[ $status == complete ]] || { log "Job không complete, xem $OUT/inference-perf.log"; exit 1; }
# Pod tạm mount PVC để lấy report ra (image inference-perf là alpine, có tar cho kubectl cp)
kubectl -n "$NS" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: { name: $HELPER, labels: { app.kubernetes.io/component: loadtest } }
spec:
  nodeSelector: { kubernetes.io/hostname: s12gbn3-system-product-name }
  containers:
    - name: copy
      image: quay.io/inference-perf/inference-perf:v0.7.0
      command: [sleep, "600"]
      resources: { requests: { cpu: 10m, memory: 16Mi }, limits: { cpu: 100m, memory: 64Mi } }
      volumeMounts: [{ name: reports, mountPath: /reports }]
  volumes: [{ name: reports, persistentVolumeClaim: { claimName: inference-perf-reports } }]
EOF
kubectl -n "$NS" wait --for=condition=Ready "pod/$HELPER" --timeout=2m >/dev/null
kubectl -n "$NS" cp "$HELPER:/reports/$RUN" "$OUT/report" >/dev/null
# report/config.yaml là bản sao config đã có key: che ở bản copy, xoá bản trên PVC
find "$OUT/report" -name '*.yaml' -exec sed -i -E 's/(api_key:).*/\1 <redacted>/' {} +
kubectl -n "$NS" exec "$HELPER" -- rm -rf "/reports/$RUN"
bash "$DIR/../scenarios/gpu_conditions.sh" "$start" "$end" "$OUT/gpu_conditions.csv" || true
bash "$DIR/../scenarios/pod_metrics.sh" "$start" "$end" "$OUT/pod_metrics.csv" || true
log "Xong $(( (end - start) / 60 )) phút, report ở $OUT"
