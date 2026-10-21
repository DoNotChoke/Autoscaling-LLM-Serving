#!/usr/bin/env bash
# T2: cài k3s single-node (server). Chạy sau prepare-gpu-node.sh.
# Usage: install-k3s.sh [đường-dẫn-k3s-config.yaml]
set -euo pipefail

K3S_VERSION="${K3S_VERSION:-v1.36.5+k3s1}"
HELM_VERSION="${HELM_VERSION:-v4.3.1}"
CONFIG_SRC="${1:-$(dirname "$0")/k3s-config.yaml}"

[[ $EUID -eq 0 ]] || { echo "Cần chạy bằng root" >&2; exit 1; }
[[ -f $CONFIG_SRC ]] || { echo "Không thấy $CONFIG_SRC" >&2; exit 1; }
command -v nvidia-container-runtime >/dev/null || { echo "Chạy prepare-gpu-node.sh trước" >&2; exit 1; }

install -D -m 0644 "$CONFIG_SRC" /etc/rancher/k3s/config.yaml

if [[ "$(k3s --version 2>/dev/null | head -1 | awk '{print $3}')" != "$K3S_VERSION" ]]; then
  echo "==> Cài k3s ${K3S_VERSION}"
  curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh -s - server
else
  echo "==> k3s ${K3S_VERSION} đã có, chỉ restart để nhận config"
  systemctl restart k3s
fi

if [[ "$(helm version --short 2>/dev/null | cut -d+ -f1)" != "$HELM_VERSION" ]]; then
  echo "==> Cài Helm ${HELM_VERSION}"
  tmp=$(mktemp -d)
  curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" | tar -xz -C "$tmp"
  install -m 0755 "$tmp/linux-amd64/helm" /usr/local/bin/helm
  rm -rf "$tmp"
fi

grep -q KUBECONFIG /root/.bashrc || echo 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml' >> /root/.bashrc
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo "==> Chờ node Ready"
kubectl wait --for=condition=Ready node --all --timeout=180s
kubectl get nodes -o wide
