# Triển khai từ đầu: VM GPU trắng → Llama-3.1-8B có API và giao diện web

Làm lần lượt từ trên xuống; chỉ sang bước sau khi **Kết quả** khớp. Tổng thời gian khoảng 40 phút, phần lớn là chờ tải image và model.

Chi tiết từng phần: [`cluster-setup.md`](cluster-setup.md) · [`models.md`](../../serving/models/models.md) · [`serving.md`](serving.md) · [`gateway.md`](gateway.md) · [`open-webui.md`](open-webui.md)

## 0. Chuẩn bị

**VM GPU** (bất kỳ nhà cung cấp nào):

| Hạng mục | Yêu cầu |
|---|---|
| Loại máy | **VM hoặc máy thật** có systemd, không phải container (k3s cần quyền kernel) |
| OS | Ubuntu 22.04 hoặc 24.04, có quyền root qua SSH |
| GPU | 1 × NVIDIA **≥ 24 GB VRAM**, kiến trúc Ampere trở lên (RTX 3090/4090, A10G, L4, A100, ...). Model BF16 nặng 15 GB |
| Driver | NVIDIA driver đã cài sẵn, bản **≥ 580** (`nvidia-smi` chạy được) |
| CPU / RAM | ≥ 8 vCPU, **≥ 16 GB RAM** (khuyến nghị 32 GB). Đo được: toàn hệ thống dùng ~7–8 GB; pod vLLM dùng 2,8 GiB RAM thật, phần còn lại tới limit 12 GiB là page cache khi load model (thu hồi được, không OOM) |
| Đĩa | **≥ 150 GB** (image khoảng 30 GB, model 15 GB, phần còn lại để dự phòng) |
| Mạng | Ra Internet được (Hugging Face, Docker Hub, ghcr.io, Cloudflare). **Không cần mở cổng vào** nào ngoài SSH |

Đã kiểm chứng trên: RTX 4090 24 GB, 32 vCPU, 56 GB RAM, Ubuntu 22.04, driver 580.95.

**Ngoài ra cần:**
- Repo này trên máy local (Git Bash hoặc Linux để chạy script test).
- Token Hugging Face (`hf_...`) của tài khoản **đã được Meta duyệt** cho `meta-llama/Llama-3.1-8B-Instruct`.

`<PORT>` và `<HOST>` bên dưới là thông tin SSH của VM, ví dụ `ssh -p 22 root@1.2.3.4`.

---

## 1. Kiểm tra VM

```bash
ssh -p <PORT> root@<HOST>
systemd-detect-virt; nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader; df -h /
```
**Kết quả:** không phải `docker`/`lxc`; GPU ≥ 24 GB; `/` còn ≥ 100 GB trống.

## 2. Copy code lên VM (chạy ở máy local)

```bash
scp -P <PORT> -r infra platform serving root@<HOST>:/root/
```
Từ đây trở đi, các lệnh chạy **trên VM**, trong thư mục `/root`.

## 3. Container toolkit + k3s + GPU Operator

```bash
cd /root
bash infra/node/prepare-gpu-node.sh
bash infra/node/install-k3s.sh
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml     # các phiên SSH sau tự có

helm repo add nvidia https://helm.ngc.nvidia.com/nvidia && helm repo update
helm upgrade --install gpu-operator nvidia/gpu-operator --version v26.7.2 \
  -n gpu-operator --create-namespace -f platform/gpu-operator/values.yaml --wait --timeout 10m
```
**Kiểm tra** (GPU có thể mất 1–2 phút mới xuất hiện):
```bash
kubectl get nodes
kubectl get node -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}'; echo
```
**Kết quả:** node `Ready`; in ra `1`.

## 4. Secret

```bash
kubectl create namespace llm-serving

read -s HF_TOKEN                      # dán token Hugging Face rồi Enter (không hiện ra màn hình)
kubectl -n llm-serving create secret generic hf-token --from-literal=token="$HF_TOKEN"; unset HF_TOKEN

# Key nội bộ của vLLM: "key" cho vLLM, "apiKey" (cùng giá trị) cho gateway
VK="$(openssl rand -hex 24)"
kubectl -n llm-serving create secret generic vllm-api-key --from-literal=key="$VK" --from-literal=apiKey="$VK"; unset VK
```

## 5. Tải model vào PVC

```bash
kubectl apply -k serving/models
kubectl -n llm-serving logs -f job/download-llama31-8b --pod-running-timeout=20m    # Ctrl+C để thoát, Job vẫn chạy
kubectl -n llm-serving wait --for=condition=complete job/download-llama31-8b --timeout=30m
```
Mất khoảng 6–10 phút. Vài phút đầu pod ở trạng thái `ContainerCreating` (đang kéo image vLLM 9 GB) là bình thường.

**Kết quả:** dòng log cuối là `==> OK: /data/current -> 0e9e39f... (15G)`.
Nếu gặp `401`/`403`/`GatedRepoError`: token sai hoặc chưa được Meta duyệt → tạo lại Secret `hf-token`, chạy `kubectl -n llm-serving delete job download-llama31-8b`, rồi làm lại bước 5.

## 6. KServe + vLLM

```bash
helm repo add jetstack https://charts.jetstack.io --force-update
helm upgrade --install cert-manager jetstack/cert-manager --version v1.21.2 \
  -n cert-manager --create-namespace --set crds.enabled=true --wait
helm upgrade --install kserve-crd oci://ghcr.io/kserve/charts/kserve-crd --version v0.21.0 \
  -n kserve --create-namespace --wait
helm upgrade --install kserve-resources oci://ghcr.io/kserve/charts/kserve-resources --version v0.21.0 \
  -n kserve -f platform/kserve/values.yaml --wait

kubectl apply -k serving/kserve
kubectl -n llm-serving wait --for=condition=Ready isvc/llama31-8b --timeout=15m
```
Mất khoảng 3 phút. Event `Startup probe failed` trong lúc chờ là bình thường.

**Kiểm tra:**
```bash
KEY=$(kubectl -n llm-serving get secret vllm-api-key -o jsonpath='{.data.key}' | base64 -d)
IP=$(kubectl -n llm-serving get svc llama31-8b-predictor -o jsonpath='{.spec.clusterIP}')
bash serving/tests/smoke.sh http://$IP "$KEY"
```
**Kết quả:** 4 dòng `PASS` (models, stream, wrong-model, no-key).

## 7. Gateway (API key, rate limit) + Redis

```bash
kubectl apply -k platform/redis
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm --version v1.8.1 \
  -n envoy-gateway-system --create-namespace -f platform/envoy-gateway/values.yaml --wait
helm upgrade --install aieg-crd oci://docker.io/envoyproxy/ai-gateway-crds-helm --version v1.1.0 \
  -n envoy-ai-gateway-system --create-namespace --wait
helm upgrade --install aieg oci://docker.io/envoyproxy/ai-gateway-helm --version v1.1.0 \
  -n envoy-ai-gateway-system --wait

bash serving/gateway/api-key.sh add <ten-ban>          # in key ra 1 lần, lưu lại
bash serving/gateway/api-key.sh add ratelimit-test     # key để kiểm thử rate limit

kubectl apply -k serving/gateway
kubectl -n llm-serving wait --for=condition=Programmed gateway/llm-gateway --timeout=180s
```
**Kiểm tra:**
```bash
GW=$(kubectl -n envoy-gateway-system get svc llm-gateway-envoy -o jsonpath='{.spec.clusterIP}')
bash serving/tests/smoke.sh http://$GW <key-cua-ban>
bash serving/tests/ratelimit.sh http://$GW <key-ratelimit-test> <key-cua-ban>
```
**Kết quả:** smoke 4/4 PASS; `PASS ratelimit` và `PASS other-key`.

## 8. URL công khai cho API

```bash
kubectl apply -k platform/cloudflared
kubectl -n cloudflared rollout status deploy/cloudflared
kubectl -n cloudflared logs deploy/cloudflared | grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' | tail -1
```
**Kiểm tra** (ở **máy local**, Git Bash hoặc Linux, tại thư mục repo):
```bash
bash serving/tests/smoke.sh <URL> <key-cua-ban>
```
**Kết quả:** 4/4 PASS. URL **đổi mỗi khi pod `cloudflared` restart**.

## 9. Open WebUI (giao diện chat)

```bash
kubectl create namespace open-webui
GK=$(bash serving/gateway/api-key.sh add open-webui | tail -1)
kubectl -n open-webui create secret generic open-webui \
  --from-literal=OPENAI_API_KEY="$GK" --from-literal=WEBUI_SECRET_KEY="$(openssl rand -hex 32)"; unset GK

kubectl apply -k serving/open-webui
kubectl -n open-webui rollout status deploy/open-webui --timeout=15m
```

**Tạo admin trước khi mở URL** (người đăng ký đầu tiên trở thành admin):
```bash
IP=$(kubectl -n open-webui get svc open-webui -o jsonpath='{.spec.clusterIP}')
PW=$(openssl rand -hex 12)
curl -s http://$IP/api/v1/auths/signup -H 'Content-Type: application/json' \
  -d "{\"name\":\"Admin\",\"email\":\"admin@llm.local\",\"password\":\"$PW\"}" | grep -o '"role":"[a-z]*"'
kubectl -n open-webui create secret generic open-webui-admin --from-literal=email=admin@llm.local --from-literal=password="$PW"; unset PW
```
**Kết quả:** `"role":"admin"`.

**Mở URL:**
```bash
kubectl apply -f serving/open-webui/tunnel.yaml
kubectl -n open-webui rollout status deploy/cloudflared
kubectl -n open-webui logs deploy/cloudflared | grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' | tail -1
```

**Cấu hình lần đầu trên trình duyệt** (đăng nhập `admin@llm.local`, mật khẩu xem bằng `kubectl -n open-webui get secret open-webui-admin -o jsonpath='{.data.password}' | base64 -d`):
1. **Admin Panel → Settings → Models → `llama31-8b`**: bỏ chọn **Builtin Tools** (nếu để bật, mỗi tin nhắn tốn khoảng 8.000 token), rồi Save.
2. **Admin Panel → Users → "+"**: tạo tài khoản cho từng người dùng.

**Kết quả:** chat được với `llama31-8b` trên trình duyệt.

---

## Checklist

- [ ] Bước 3: node `Ready`, `nvidia.com/gpu: 1`
- [ ] Bước 5: model 15G trên PVC
- [ ] Bước 6: smoke 4/4 gọi thẳng vLLM
- [ ] Bước 7: smoke 4/4 + ratelimit qua gateway
- [ ] Bước 8: smoke 4/4 qua URL công khai, từ máy local
- [ ] Bước 9: chat được trên Open WebUI; Builtin Tools đã tắt
- [ ] `kubectl get svc -A | grep -E 'LoadBalancer|NodePort'` không in ra gì

## Gửi cho người dùng

| Người dùng | Gửi |
|---|---|
| Chat trên web | URL Open WebUI + email/mật khẩu (tạo ở Admin Panel) |
| Gọi API bằng code | URL API (bước 8) + key riêng (`api-key.sh add <ten>`) + [`docs/user-guide.md`](../user-guide.md) |

## Lưu ý vận hành

- Khi VM khởi động lại, cả hai URL trycloudflare đều đổi; lấy URL mới bằng các lệnh `logs` ở bước 8 và 9. Việc dịch vụ tự lên lại sau reboot **chưa được kiểm chứng**; sau reboot, kiểm tra lại bằng smoke test ở bước 6–8.
- Model, tài khoản và lịch sử chat nằm trên đĩa của VM (PVC `local-path`). **Xoá VM là mất hết.**
