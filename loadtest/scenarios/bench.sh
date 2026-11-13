#!/usr/bin/env bash
# Đo sức chứa 1 replica bằng vllm bench serve, ghi kèm KV cache và hàng chờ.
# Chạy BÊN TRONG pod vLLM (gọi thẳng localhost:8000, không qua gateway nên không bị rate limit):
#   P=$(kubectl -n llm-serving get pod -l serving.kserve.io/inferenceservice=llama31-8b -o name | head -1)
#   for f in bench.sh kv_sampler.py; do kubectl -n llm-serving exec -i "$P" -- sh -c "cat > /tmp/$f" < loadtest/scenarios/$f; done
#   kubectl -n llm-serving exec -i "$P" -- sh -c 'cat > /tmp/sharegpt.jsonl' < loadtest/datasets/sharegpt-500.jsonl  # MODE=realistic
#   kubectl -n llm-serving exec "$P" -- sh -c "MODE=capacity GIT_COMMIT=$(git rev-parse --short HEAD) setsid nohup bash /tmp/bench.sh > /tmp/bench_main.log 2>&1 < /dev/null &"
#   # chờ có /tmp/bench/DONE rồi copy /tmp/bench về
#
# MODE=capacity  (mặc định) quét request rate, tải Poisson open-loop, random ±30% độ dài, seed khác nhau mỗi mức
# MODE=realistic quét request rate với prompt ShareGPT ($DATASET, JSONL {"id","prompt","output_tokens"}), model tự dừng
# MODE=legacy    cách đo cũ (quét --max-concurrency, seed cố định); chỉ để tái lập số cũ, không dùng chọn ngưỡng
# Usage: bench.sh [rate ...]   (legacy: [concurrency ...]);  DRY_RUN=1 chỉ in lệnh
set -euo pipefail

MODE="${MODE:-capacity}"
MODEL="${MODEL:-llama31-8b}"
INPUT_LEN="${INPUT_LEN:-512}"
OUTPUT_LEN="${OUTPUT_LEN:-256}"
SLO_TTFT_MS="${SLO_TTFT_MS:-2000}"
SLO_TPOT_MS="${SLO_TPOT_MS:-100}"
DATASET="${DATASET:-/tmp/sharegpt.jsonl}"
OUT="${OUT:-/tmp/bench}"
DRY_RUN="${DRY_RUN:-}"
[[ -n $DRY_RUN ]] || : "${VLLM_API_KEY:?Chạy trong pod vLLM (cần VLLM_API_KEY)}"
export OPENAI_API_KEY="${VLLM_API_KEY:-dry}"

run() { if [[ -n $DRY_RUN ]]; then echo "$*"; else "$@"; fi; }

mkdir -p "$OUT"
rm -f "$OUT/DONE"
{
  echo "mode=$MODE commit=${GIT_COMMIT:-unknown} host=$(hostname) date=$(date -Is)"
  # Tham số engine đang chạy (PID 1 của container là vllm serve)
  { tr '\0' ' ' < /proc/1/cmdline; } 2>/dev/null || true; echo
} | tee "$OUT/meta.txt"

# shellcheck disable=SC2054 # dấu phẩy nằm trong giá trị cờ (ttft,tpot,...), không phải phân tách phần tử
common=(vllm bench serve --backend vllm --base-url http://localhost:8000 --model "$MODEL" --tokenizer /models
  --percentile-metrics ttft,tpot,itl,e2el --save-result --result-dir "$OUT")

if [[ $MODE == legacy ]]; then
  if (( $# )); then LEVELS=("$@"); else LEVELS=(1 2 4 8 16 32); fi
  for c in "${LEVELS[@]}"; do
    n=$(( c * 8 < 16 ? 16 : c * 8 ))
    [[ -n $DRY_RUN ]] || { python3 "$(dirname "$0")/kv_sampler.py" > "$OUT/kv_c$c.txt" & sampler=$!; }
    run "${common[@]}" --dataset-name random --random-input-len "$INPUT_LEN" --random-output-len "$OUTPUT_LEN" \
      --ignore-eos --num-prompts "$n" --max-concurrency "$c" --metric-percentiles 50,95 \
      --result-filename "c$c.json" > "$OUT/log_c$c.txt" 2>&1 || true
    [[ -n $DRY_RUN ]] || kill "$sampler"
  done
  echo "done" > "$OUT/DONE"; exit 0
fi

case "$MODE" in
  capacity) data=(--dataset-name random --random-input-len "$INPUT_LEN" --random-output-len "$OUTPUT_LEN"
                  --random-range-ratio 0.3 --ignore-eos) ;;
  realistic) [[ -n $DRY_RUN || -f $DATASET ]] || { echo "Thiếu $DATASET" >&2; exit 1; }
             # Dataset custom cần pandas (image vLLM không có): đổi sang ShareGPT, câu trả lời giả ' x' × output_tokens
             sharegpt="$OUT/sharegpt.json"
             [[ -n $DRY_RUN ]] || python3 - "$DATASET" "$sharegpt" <<'PY'
import json, sys
rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8")]
json.dump([{"id": r["id"], "conversations": [{"from": "human", "value": r["prompt"]},
                                             {"from": "gpt", "value": " x" * r["output_tokens"]}]} for r in rows],
          open(sys.argv[2], "w", encoding="utf-8"))
PY
             data=(--dataset-name sharegpt --dataset-path "$sharegpt") ;;
  *) echo "MODE không hợp lệ: $MODE" >&2; exit 1 ;;
esac

if (( $# )); then RATES=("$@"); else read -ra RATES <<< "${RATES:-0.25 0.5 0.75 1 1.25 1.5 2 2.5 3}"; fi
i=0
for rate in "${RATES[@]}"; do
  # Seed khác nhau mỗi mức: cùng seed thì mức sau gửi lại prompt của mức trước và trúng prefix cache
  seed=$(( 1000 + i )); i=$(( i + 1 ))
  # Ít nhất ~3 phút ở trạng thái ổn định mỗi mức
  n=$(awk -v r="$rate" 'BEGIN { n = int(r * 180); print (n < 100 ? 100 : n) }')
  echo "rate=$rate seed=$seed num_prompts=$n" | tee -a "$OUT/meta.txt"
  [[ -n $DRY_RUN ]] || { python3 "$(dirname "$0")/kv_sampler.py" > "$OUT/kv_r$rate.txt" & sampler=$!; }
  # Không đặt --max-concurrency để tải là open-loop thật
  run "${common[@]}" "${data[@]}" --request-rate "$rate" --seed "$seed" --num-prompts "$n" --num-warmups 4 \
    --goodput "ttft:$SLO_TTFT_MS" "tpot:$SLO_TPOT_MS" --metric-percentiles 50,90,95,99 --save-detailed \
    --result-filename "r$rate.json" > "$OUT/log_r$rate.txt" 2>&1 || true
  [[ -n $DRY_RUN ]] || kill "$sampler"
done
echo "done" > "$OUT/DONE"
