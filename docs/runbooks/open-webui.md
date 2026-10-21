# Runbook: Open WebUI (giao diện chat web)

Open WebUI v0.12.3 (`ghcr.io/open-webui/open-webui`, ứng dụng có sẵn, không tự code) gọi gateway bằng **một key chung** (client-id `open-webui`):

```
Trình duyệt ─HTTPS─► https://<random>.trycloudflare.com ─► cloudflared (ns open-webui) ─► Open WebUI ─[key open-webui]─► gateway ─► vLLM
```

- Người dùng đăng nhập bằng **tài khoản Open WebUI**, do admin tạo. Họ không cầm API key của gateway.
- Hạn mức **100k token/phút tính chung** cho mọi người dùng Open WebUI. Access log của gateway chỉ thấy `client: open-webui`.
- Lịch sử chat và tài khoản nằm trên PVC `open-webui-data` (10 Gi, `local-path`). **Xoá PVC hoặc destroy VM là mất hết.**

## Cài đặt

Yêu cầu trước: gateway đã chạy ([`gateway.md`](gateway.md)).

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; cd /root
kubectl create namespace open-webui

# Key gateway cho Open WebUI + khoá ký session
GK=$(bash serving/gateway/api-key.sh add open-webui | tail -1)
kubectl -n open-webui create secret generic open-webui \
  --from-literal=OPENAI_API_KEY="$GK" --from-literal=WEBUI_SECRET_KEY="$(openssl rand -hex 32)"
unset GK

kubectl apply -k serving/open-webui
kubectl -n open-webui rollout status deploy/open-webui --timeout=15m    # lần đầu khoảng 2–3 phút
```

### Tạo admin TRƯỚC khi mở tunnel
**Người đăng ký đầu tiên trở thành admin**, nên phải tạo admin khi Open WebUI chưa có URL công khai:
```bash
IP=$(kubectl -n open-webui get svc open-webui -o jsonpath='{.spec.clusterIP}')
PW=$(openssl rand -hex 12)
curl -s http://$IP/api/v1/auths/signup -H 'Content-Type: application/json' \
  -d "{\"name\":\"Admin\",\"email\":\"admin@llm.local\",\"password\":\"$PW\"}" | grep -o '"role":"[a-z]*"'   # "role":"admin"
kubectl -n open-webui create secret generic open-webui-admin --from-literal=email=admin@llm.local --from-literal=password="$PW"
unset PW
```
Sau khi có admin, Open WebUI v0.12 **tự tắt chức năng đăng ký** (người lạ đăng ký sẽ nhận 403).

### Mở tunnel
```bash
kubectl apply -f serving/open-webui/tunnel.yaml
kubectl -n open-webui logs deploy/cloudflared | grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' | tail -1
```

## Vận hành

| Việc | Cách làm |
|---|---|
| Xem mật khẩu admin | `kubectl -n open-webui get secret open-webui-admin -o jsonpath='{.data.password}' \| base64 -d` |
| Tạo tài khoản cho người dùng | Đăng nhập admin → **Admin Panel → Users → "+"** (role `user`) → gửi riêng email và mật khẩu cho từng người |
| Khoá hoặc xoá người dùng | Admin Panel → Users |
| URL đổi (pod `cloudflared` restart) | Lệnh lấy URL ở trên, rồi gửi lại cho mọi người |
| Đổi key gateway của Open WebUI | `api-key.sh revoke open-webui` rồi `add open-webui`, cập nhật Secret `open-webui`, sau đó `kubectl -n open-webui rollout restart deploy/open-webui` |

## Đã kiểm chứng (2026-10-21, từ máy local qua tunnel)

| Kiểm tra | Kết quả |
|---|---|
| Trang chủ | 200 |
| Đăng nhập admin | OK |
| Websocket (trình duyệt dùng để nhận stream) | 101 |
| Chat stream qua `/api/chat/completions` | 127 chunk + `[DONE]` |
| Người lạ đăng ký | 403 |
| Access log của gateway | `client: open-webui`, có số token |

## Sự cố

| Triệu chứng | Xử lý |
|---|---|
| Không thấy model `llama31-8b` | Kiểm tra key: `kubectl -n envoy-gateway-system logs <envoy-pod> -c envoy \| grep open-webui` phải có `status 200` cho `/v1/models`. Nếu 401 thì key sai |
| Mọi người cùng bị 429 | Hết hạn mức chung 100k token/phút. Tăng bằng một rule riêng `Exact: open-webui` trong `serving/gateway/rate-limit.yaml` |
| Trả lời dài bị cắt hoặc lỗi | Giới hạn của quick tunnel (xem `gateway.md`) |
| Pod khởi động lâu lần đầu | Open WebUI tải model embedding cho RAG; `startupProbe` cho tối đa 10 phút |
