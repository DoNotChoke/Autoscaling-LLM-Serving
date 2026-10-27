#!/usr/bin/env bash
# Đo sức chứa 1 replica: quét --max-concurrency bằng vllm bench serve, ghi kèm KV cache và hàng chờ.
# Chạy BÊN TRONG pod vLLM (gọi thẳng localhost:8000, không qua gateway nên không bị rate limit):
#   P=$(kubectl -n llm-serving get pod -l serving.kserve.io/inferenceservice=llama31-8b -o name | head -1)
#   for f in bench.sh kv_sampler.py; do kubectl -n llm-serving exec -i "$P" -- sh -c "cat > /tmp/$f" < loadtest/scenarios/$f; done
#   kubectl -n llm-serving exec "$P" -- sh -c 'setsid nohup bash /tmp/bench.sh > /tmp/bench_main.log 2>&1 < /dev/null &'
#   # chờ có /tmp/bench/DONE rồi lấy kết quả:
#   kubectl -n llm-serving exec "$P" -- tar -C /tmp -cf - bench | tar -xf - -C loadtest/results/<yyyy-mm-dd>-baseline/
# Usage: bench.sh [concurrency ...]   (mặc định 1 2 4 8 16 32)
set -euo pipefail

: "${VLLM_API_KEY:?Chạy trong pod vLLM (cần VLLM_API_KEY)}"
MODEL="${MODEL:-llama31-8b}"
INPUT_LEN="${INPUT_LEN:-512}"
OUTPUT_LEN="${OUTPUT_LEN:-256}"
OUT="${OUT:-/tmp/bench}"
if (( $# )); then LEVELS=("$@"); else LEVELS=(1 2 4 8 16 32); fi

export OPENAI_API_KEY="$VLLM_API_KEY"
mkdir -p "$OUT"
rm -f "$OUT/DONE"

for c in "${LEVELS[@]}"; do
  # Ít nhất 16 request mỗi mức để p95 có nghĩa
  n=$(( c * 8 < 16 ? 16 : c * 8 ))
  python3 "$(dirname "$0")/kv_sampler.py" > "$OUT/kv_c$c.txt" &
  sampler=$!
  vllm bench serve --backend vllm --base-url http://localhost:8000 --model "$MODEL" \
    --tokenizer /mnt/models --dataset-name random \
    --random-input-len "$INPUT_LEN" --random-output-len "$OUTPUT_LEN" --ignore-eos \
    --num-prompts "$n" --max-concurrency "$c" \
    --percentile-metrics ttft,tpot,itl,e2el --metric-percentiles 50,95 \
    --save-result --result-dir "$OUT" --result-filename "c$c.json" > "$OUT/log_c$c.txt" 2>&1 || true
  kill "$sampler"
done
echo "done" > "$OUT/DONE"
