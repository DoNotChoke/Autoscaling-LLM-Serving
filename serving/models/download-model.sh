#!/usr/bin/env bash
# T4: tải 1 revision model từ Hugging Face vào PVC, chạy trong Job (download-job.yaml).
# Bố cục trên PVC:  <DATA_DIR>/<revision>/  (weights + SHA256SUMS)
#                   <DATA_DIR>/current -> <revision>   (vLLM đọc /mnt/models/current)
# Đã có revision thì chỉ kiểm tra checksum: chạy lại Job = verify.
set -euo pipefail

: "${HF_REPO:?Thiếu HF_REPO, ví dụ meta-llama/Llama-3.1-8B-Instruct}"
: "${HF_REVISION:?Thiếu HF_REVISION (commit hash, không dùng main)}"
DATA_DIR="${DATA_DIR:-/data}"

dest="$DATA_DIR/$HF_REVISION"
staging="$DATA_DIR/.staging-$HF_REVISION"

if [[ -f "$dest/SHA256SUMS" ]]; then
  echo "==> Đã có $HF_REPO@$HF_REVISION, kiểm tra checksum"
  (cd "$dest" && sha256sum --quiet -c SHA256SUMS) || {
    echo "Checksum sai. Xoá $dest rồi chạy lại Job để tải lại." >&2
    exit 1
  }
else
  echo "==> Tải $HF_REPO@$HF_REVISION"
  # Tải vào thư mục staging, xong mới rename: không bao giờ để lại bản dở ở $dest
  hf download "$HF_REPO" --revision "$HF_REVISION" --local-dir "$staging" \
    --exclude "original/*" --exclude "*.pth"
  rm -rf "$staging/.cache"
  (cd "$staging" && find . -type f -print0 | sort -z | xargs -0 sha256sum) > "$staging.sums"
  mv "$staging.sums" "$staging/SHA256SUMS"
  mv -T "$staging" "$dest"
fi

# shortcut: revision cũ không tự xoá; dọn tay khi đĩa đầy
ln -sfn "$HF_REVISION" "$DATA_DIR/current.tmp" && mv -T "$DATA_DIR/current.tmp" "$DATA_DIR/current"
echo "==> OK: $DATA_DIR/current -> $HF_REVISION ($(du -sh "$dest" | cut -f1))"
