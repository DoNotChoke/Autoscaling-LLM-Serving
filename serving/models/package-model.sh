#!/usr/bin/env bash
# Đóng gói một thư mục model thành OCI image (busybox + /models) và đẩy lên registry trong cụm (platform/registry).
# Pod mount image bằng Image Volume (subPath: models); layout busybox + /models cũng dùng được với KServe Modelcars.
# Chạy trên node-1 (có Docker + kubectl). Tag = 12 ký tự đầu sha256 của SHA256SUMS, nên cùng nội dung thì cùng tag.
# Usage: package-model.sh <thư mục model có SHA256SUMS> <repo, vd models/llama31-8b> [nguồn gốc, ghi vào label]
set -euo pipefail

SRC="${1:?Usage: package-model.sh <thư mục model> <repo> [nguồn gốc]}"
REPO="${2:?}"
ORIGIN="${3:-}"
PULL_HOST="${PULL_HOST:-192.168.1.147:30500}"
PUSH_HOST=localhost:5000 # qua port-forward: Docker cho phép HTTP tới localhost, NodePort không nghe trên 127.0.0.1
KUBECTL="${KUBECTL:-kubectl}"

[[ -f $SRC/SHA256SUMS ]] || { echo "Thiếu $SRC/SHA256SUMS" >&2; exit 1; }
echo "==> Kiểm checksum $SRC" >&2
(cd "$SRC" && sha256sum --quiet -c SHA256SUMS) >&2
TAG=$(sha256sum "$SRC/SHA256SUMS" | cut -c1-12)
REF="$PUSH_HOST/$REPO:$TAG"

cache_ids() { docker buildx du --verbose 2>/dev/null | awk '/^ID:/{print $2}' | sort; }
# Build để lại cache cỡ model (context + layer COPY): chỉ xoá các mục sinh ra trong lần chạy này, giữ cache khác của Docker
cleanup() {
  kill "$PF" 2>/dev/null
  docker rmi "$REF" >/dev/null 2>&1 || true
  comm -13 <(echo "$CACHE_BEFORE") <(cache_ids) | while read -r id; do
    docker buildx prune -f --all --filter "id=$id" >/dev/null 2>&1 || true
  done
}
CACHE_BEFORE=$(cache_ids)
$KUBECTL -n registry port-forward svc/registry 5000:5000 >/dev/null 2>&1 &
PF=$!
trap cleanup EXIT
for _ in $(seq 1 20); do
  [[ $(curl -s -o /dev/null -w '%{http_code}' "http://$PUSH_HOST/v2/") == 401 ]] && break
  sleep 0.5
done
$KUBECTL -n registry get secret registry-auth -o jsonpath='{.data.password}' | base64 -d |
  docker login "$PUSH_HOST" -u "$($KUBECTL -n registry get secret registry-auth -o jsonpath='{.data.username}' | base64 -d)" --password-stdin >/dev/null

echo "==> Build $REF" >&2
docker build -q -t "$REF" -f - "$SRC" >/dev/null <<EOF
FROM busybox:1.37
COPY . /models/
LABEL org.opencontainers.image.source="$ORIGIN"
EOF
echo "==> Push" >&2
docker push -q "$REF" >/dev/null
DIGEST=$(docker inspect --format '{{index .RepoDigests 0}}' "$REF" | cut -d@ -f2)
echo "$PULL_HOST/$REPO@$DIGEST"
