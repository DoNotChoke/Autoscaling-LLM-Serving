#!/usr/bin/env bash
# Kiểm tra rate limit theo token: dùng key ratelimit-test (hạn mức 500 token/phút), phải nhận 429 trong ≤ 10 request.
# Nếu truyền thêm key khác, kiểm tra key đó vẫn gọi được trong lúc ratelimit-test bị chặn.
# Usage: ratelimit.sh <base-url> <ratelimit-test-key> [other-key]
set -uo pipefail

BASE_URL="${1:?Usage: ratelimit.sh <base-url> <ratelimit-test-key> [other-key]}"
TEST_KEY="${2:?Usage: ratelimit.sh <base-url> <ratelimit-test-key> [other-key]}"
OTHER_KEY="${3:-}"
BASE_URL="${BASE_URL%/}"

# Body đi qua stdin: curl trên Windows làm hỏng UTF-8 nếu truyền tiếng Việt bằng -d
call() {
  printf '%s' '{"model":"llama31-8b","max_tokens":200,"messages":[{"role":"user","content":"Kể một câu chuyện."}]}' |
    curl -sS -m 120 -o /dev/null -w '%{http_code}' "$BASE_URL/v1/chat/completions" \
      -H "Authorization: Bearer $1" -H "Content-Type: application/json" --data-binary @-
}

for i in $(seq 1 10); do
  code=$(call "$TEST_KEY")
  echo "request $i: $code"
  [[ $code == 429 ]] && break
  [[ $code == 200 ]] || { echo "FAIL ratelimit (mã lạ $code)"; exit 1; }
done
[[ $code == 429 ]] || { echo "FAIL ratelimit (không nhận 429 sau 10 request)"; exit 1; }
echo "PASS ratelimit   (429 ở request $i)"

if [[ -n $OTHER_KEY ]]; then
  code=$(call "$OTHER_KEY")
  if [[ $code == 200 ]]; then echo "PASS other-key  (200 trong lúc ratelimit-test bị chặn)"; else echo "FAIL other-key  (nhận $code)"; exit 1; fi
fi
