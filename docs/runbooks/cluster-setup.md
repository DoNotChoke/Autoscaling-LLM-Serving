# Runbook: Dựng cluster K8s có GPU (single-node)

Dựng từ máy trắng tới cluster k3s có GPU dùng được trong pod. Đã kiểm chứng trên:

| Mục | Giá trị |
|---|---|
| Máy | VM GPU (KVM), Ubuntu 22.04.5, kernel 6.8 |
| GPU | RTX 4090 24 GB, driver 580.95.05 (có sẵn), CUDA 13.0 |
| k3s | v1.36.5+k3s1 (containerd 2.3.4) |
| NVIDIA Container Toolkit | 1.20.1 |
| Helm | v4.3.1 |
| GPU Operator | v26.7.2 |

> Cần **VM hoặc máy thật**, không dùng được container (thiếu systemd, cgroups chỉ đọc, không có `/dev/kmsg`). Cấu hình tối thiểu: xem [`deploy-from-scratch.md`](deploy-from-scratch.md#0-chuẩn-bị).

## Yêu cầu
- Ubuntu 22.04/24.04, quyền root, **driver NVIDIA đã cài** (`nvidia-smi` chạy được)
- Đĩa trống ≥ 50 GB ở `/var` (VM nên tạo ≥ 150 GB)

## Các bước

```bash
# Từ máy local: copy script lên node
scp -P <port> -r infra platform serving root@<host>:/root/

# Trên node
bash /root/infra/node/prepare-gpu-node.sh      # T1: container toolkit, kiểm tra đĩa
bash /root/infra/node/install-k3s.sh           # T2: k3s + Helm, chờ node Ready
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# T3: GPU Operator (driver và toolkit dùng bản trên host)
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia && helm repo update
helm upgrade --install gpu-operator nvidia/gpu-operator --version v26.7.2 \
  -n gpu-operator --create-namespace -f /root/platform/gpu-operator/values.yaml --wait
```

Cả ba bước đều chạy lại được nhiều lần (idempotent).

## Kiểm tra

```bash
kubectl get nodes                                   # Ready
kubectl get node -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}'   # 1
kubectl apply -f /root/infra/node/gpu-test-pod.yaml
kubectl logs gpu-test                               # bảng nvidia-smi
kubectl delete pod gpu-test
# DCGM exporter
ip=$(kubectl get pod -n gpu-operator -l app=nvidia-dcgm-exporter -o jsonpath='{.items[0].status.podIP}')
curl -s $ip:9400/metrics | grep DCGM_FI_DEV_GPU_UTIL
```

## Dùng kubectl từ máy local

```bash
scp -P <port> root@<host>:/etc/rancher/k3s/k3s.yaml ~/.kube/gpu-lab.yaml
ssh -p <port> -N -L 6443:localhost:6443 root@<host> &     # API server không mở ra Internet
KUBECONFIG=~/.kube/gpu-lab.yaml kubectl get nodes
```

## Ghi chú cấu hình
- `default-runtime: nvidia` trong `infra/node/k3s-config.yaml`: mọi pod chạy qua `nvidia-container-runtime`, nên pod GPU không cần khai báo `runtimeClassName`. Pod không xin GPU vẫn chạy bình thường.
- Traefik đã tắt; ingress sau này dùng Envoy Gateway.
- GPU Operator để `cdi.enabled: false`, vì toolkit trên host không sinh CDI spec cho operator.
- Node chưa gắn taint `nvidia.com/gpu`, vì single-node phải chạy cả pod hệ thống. Thêm taint khi có node CPU riêng.

## Join node thứ 2

Hai máy phải thông nhau qua TCP 6443 (API server), TCP 10250 (kubelet) và UDP 8472 (flannel VXLAN). Đã kiểm chứng 2026-10-24: 2 máy RTX 3060 cùng LAN `192.168.1.0/24`.

```bash
# Trên node 1: lấy token (bí mật, không commit, không dán vào chat)
sudo cat /var/lib/rancher/k3s/server/node-token

# Trên node 2
sudo bash infra/node/prepare-gpu-node.sh
sudo K3S_URL=https://<ip-lan-node-1>:6443 NODE_IP=<ip-lan-node-2> bash infra/node/install-k3s.sh   # hỏi token
```

`NODE_IP` bắt buộc khi node có nhiều mạng (ZeroTier, Tailscale, Docker bridge): thiếu thì k3s có thể lấy nhầm IP và pod giữa 2 node không gọi được nhau.

Kiểm tra trên node 1:

```bash
kubectl get nodes -o custom-columns=NAME:.metadata.name,IP:.status.addresses[0].address,GPU:.status.allocatable.nvidia\\.com/gpu
# 2 node, mỗi node GPU=1 (GPU Operator tự cài device plugin + DCGM lên node mới trong ~1 phút)
```

Gỡ node 2: `kubectl drain <node> --ignore-daemonsets && kubectl delete node <node>` trên node 1, rồi `/usr/local/bin/k3s-agent-uninstall.sh` trên node 2.

## Gỡ cài đặt

```bash
helm uninstall gpu-operator -n gpu-operator
/usr/local/bin/k3s-uninstall.sh
```

## Sự cố thường gặp

| Triệu chứng | Nguyên nhân / Cách xử lý |
|---|---|
| `allocatable nvidia.com/gpu` trống | Device plugin chưa chạy: `kubectl logs -n gpu-operator ds/nvidia-device-plugin-daemonset`. Kiểm tra `grep nvidia /var/lib/rancher/k3s/agent/etc/containerd/config.toml` |
| containerd không có runtime `nvidia` | Toolkit được cài sau k3s: chạy `systemctl restart k3s` |
| Pod GPU báo `libnvidia-ml.so not found` | Runtime mặc định không phải `nvidia`: kiểm tra `default-runtime` trong `/etc/rancher/k3s/config.yaml` |
