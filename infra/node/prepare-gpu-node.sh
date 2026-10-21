#!/usr/bin/env bash
# T1: chuẩn bị GPU node (Ubuntu 22.04/24.04). Chạy lại nhiều lần không sao.
# Driver NVIDIA phải có sẵn: cài driver cần reboot nên không làm tự động ở đây.
set -euo pipefail

CTK_VERSION="${CTK_VERSION:-1.20.1-1}"
DATA_ROOT="${DATA_ROOT:-/var}"
MIN_FREE_GB="${MIN_FREE_GB:-50}" # đủ cho 1 revision model mới (~16 GB) + image

[[ $EUID -eq 0 ]] || { echo "Cần chạy bằng root" >&2; exit 1; }

echo "==> Kiểm tra driver NVIDIA"
if ! nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader; then
  echo "Chưa có driver NVIDIA. Cài driver (ví dụ: ubuntu-drivers install --gpgpu) rồi reboot." >&2
  exit 1
fi

echo "==> Cài NVIDIA Container Toolkit ${CTK_VERSION}"
if ! dpkg -s nvidia-container-toolkit 2>/dev/null | grep -q "^Version: ${CTK_VERSION}$"; then
  keyring=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor --yes -o "$keyring"
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed "s#deb https://#deb [signed-by=${keyring}] https://#g" \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt-get update -qq
  apt-get install -y -qq --allow-downgrades \
    "nvidia-container-toolkit=${CTK_VERSION}" "nvidia-container-toolkit-base=${CTK_VERSION}" \
    "libnvidia-container-tools=${CTK_VERSION}" "libnvidia-container1=${CTK_VERSION}"
fi
nvidia-ctk --version | head -1

# PVC local-path (/var/lib/rancher/k3s/storage) và image đều nằm dưới /var
echo "==> Dung lượng trống ở ${DATA_ROOT}"
free_gb=$(df --output=avail -BG "$DATA_ROOT" | tail -1 | tr -dc '0-9')
echo "Còn trống ${free_gb} GB"
if (( free_gb < MIN_FREE_GB )); then
  echo "Cần ít nhất ${MIN_FREE_GB} GB trống cho model và image" >&2
  exit 1
fi

echo "OK: node sẵn sàng cài k3s"
