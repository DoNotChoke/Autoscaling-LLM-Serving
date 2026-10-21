#!/usr/bin/env bash
# Smoke test endpoint OpenAI-compatible. Dùng được cho Service vLLM, InferenceService và gateway.
# Usage: smoke.sh <base-url> <api-key> [model]
set -uo pipefail

BASE_URL="${1:?Usage: smoke.sh <base-url> <api-key> [model]}"
API_KEY="${2:?Usage: smoke.sh <base-url> <api-key> [model]}"
MODEL="${3:-llama31-8b}"
BASE_URL="${BASE_URL%/}"
fails=0

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }

# models: endpoint liệt kê đúng tên model
body=$(curl -sS -m 10 -H "Authorization: Bearer $API_KEY" "$BASE_URL/v1/models")
if grep -q "\"id\":\"$MODEL\"" <<<"$body"; then pass "models     ($MODEL)"; else fail "models     ($body)"; fi

# stream: nhận nhiều chunk SSE và kết thúc bằng [DONE]
# Body đi qua stdin: curl trên Windows làm hỏng UTF-8 nếu truyền tiếng Việt bằng -d
out=$(printf '{"model":"%s","stream":true,"max_tokens":32,"messages":[{"role":"user","content":"Đếm từ 1 đến 10."}]}' "$MODEL" |
  curl -sS -N -m 120 "$BASE_URL/v1/chat/completions" \
    -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" --data-binary @-)
chunks=$(grep -c '^data: {' <<<"$out")
if (( chunks >= 2 )) && grep -q '^data: \[DONE\]' <<<"$out"; then
  pass "stream     ($chunks chunks, [DONE])"
else
  fail "stream     ($chunks chunks: $(head -c 300 <<<"$out"))"
fi

# wrong-model: model không tồn tại phải trả 404
code=$(curl -sS -m 30 -o /dev/null -w '%{http_code}' "$BASE_URL/v1/chat/completions" \
  -H "Authorization: Bearer $API_KEY" -H "Content-Type: application/json" \
  -d '{"model":"khong-co-model-nay","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}')
if [[ $code == 404 ]]; then pass "wrong-model (404)"; else fail "wrong-model (nhận $code, cần 404)"; fi

# no-key: thiếu key phải bị từ chối
code=$(curl -sS -m 10 -o /dev/null -w '%{http_code}' "$BASE_URL/v1/models")
if [[ $code == 401 ]]; then pass "no-key     (401)"; else fail "no-key     (nhận $code, cần 401)"; fi

exit $(( fails > 0 ))
