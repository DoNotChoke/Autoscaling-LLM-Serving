#!/usr/bin/env bash
# T2: cài k3s. Chạy sau prepare-gpu-node.sh.
#   Server (node đầu tiên):  install-k3s.sh [đường-dẫn-k3s-config.yaml]
#   Agent (join cụm có sẵn): sudo K3S_URL=https://<ip-server>:6443 NODE_IP=<ip-lan-node-này> bash install-k3s.sh
#     Token lấy trên server: sudo cat /var/lib/rancher/k3s/server/node-token
#     Truyền qua K3S_TOKEN, hoặc để trống thì script hỏi (không hiện ra màn hình, không lưu vào history).
#     NODE_IP: bắt buộc khi máy có nhiều mạng (ZeroTier, Tailscale, ...) để flannel đi đúng LAN.
set -euo pipefail

K3S_VERSION="${K3S_VERSION:-v1.36.5+k3s1}"
HELM_VERSION="${HELM_VERSION:-v4.3.1}"
K3S_URL="${K3S_URL:-}"
NODE_IP="${NODE_IP:-}"

if [[ -n $K3S_URL ]]; then
  ROLE=agent
  SERVICE=k3s-agent
  CONFIG_SRC="${1:-$(dirname "$0")/k3s-agent-config.yaml}"
else
  ROLE=server
  SERVICE=k3s
  CONFIG_SRC="${1:-$(dirname "$0")/k3s-config.yaml}"
fi

[[ $EUID -eq 0 ]] || { echo "Cần chạy bằng root" >&2; exit 1; }
[[ -f $CONFIG_SRC ]] || { echo "Không thấy $CONFIG_SRC" >&2; exit 1; }
command -v nvidia-container-runtime >/dev/null || { echo "Chạy prepare-gpu-node.sh trước" >&2; exit 1; }

install -D -m 0644 "$CONFIG_SRC" /etc/rancher/k3s/config.yaml
if [[ -n $NODE_IP ]]; then
  echo "node-ip: ${NODE_IP}" >> /etc/rancher/k3s/config.yaml
fi

if [[ $ROLE == agent ]]; then
  if [[ -z ${K3S_TOKEN:-} ]]; then
    read -rsp "K3S_TOKEN: " K3S_TOKEN
    echo
  fi
  [[ -n $K3S_TOKEN ]] || { echo "Thiếu K3S_TOKEN" >&2; exit 1; }
  export K3S_URL K3S_TOKEN
fi

if [[ "$(k3s --version 2>/dev/null | head -1 | awk '{print $3}')" != "$K3S_VERSION" ]]; then
  echo "==> Cài k3s ${K3S_VERSION} (${ROLE})"
  curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh -s - "$ROLE"
else
  echo "==> k3s ${K3S_VERSION} đã có, chỉ restart để nhận config"
  systemctl restart "$SERVICE"
fi

if [[ $ROLE == agent ]]; then
  # Agent không có kubeconfig; kiểm tra node Ready từ server
  systemctl is-active --quiet "$SERVICE" || { echo "${SERVICE} không chạy: journalctl -u ${SERVICE}" >&2; exit 1; }
  echo "==> ${SERVICE} đang chạy. Trên server: kubectl get nodes"
  exit 0
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
