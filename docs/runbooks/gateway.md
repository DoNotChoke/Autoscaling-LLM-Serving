# Runbook: Gateway (Envoy AI Gateway + Redis + Cloudflare Quick Tunnel)

Spec: [`SPEC-gateway.md`](../../SPEC-gateway.md). Hướng dẫn cho người dùng: [`docs/user-guide.md`](../user-guide.md).

```
Người dùng ─HTTPS─► https://<random>.trycloudflare.com ─► cloudflared ─► llm-gateway-envoy (ClusterIP)
   ├ apiKeyAuth (Secret gateway-api-keys) ─ 401
   ├ rate limit 100k token/phút/key (Redis) ─ 429
   ├ AI Gateway: route theo "model" ─ 404, đếm token từ usage
   └ đính key nội bộ (Secret vllm-api-key, khoá apiKey) ─► llama31-8b-predictor (vLLM)
```

| Thành phần | Phiên bản | Namespace |
|---|---|---|
| Envoy Gateway | v1.8.1 (`oci://docker.io/envoyproxy/gateway-helm`) | `envoy-gateway-system` |
| Envoy AI Gateway | v1.1.0 (`ai-gateway-crds-helm`, `ai-gateway-helm`) | `envoy-ai-gateway-system` |
| Redis | `redis:8.2.4-alpine3.22`, không persistence | `redis-system` |
| cloudflared | `cloudflare/cloudflared:2026.10.2`, quick tunnel | `cloudflared` |
| CR của gateway (`Gateway`, `AIGatewayRoute`, policy) | | `llm-serving` |

## Cài đặt

Yêu cầu trước: InferenceService `llama31-8b` đã Ready ([`deploy-from-scratch.md`](deploy-from-scratch.md) bước 1–10).

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; cd /root

# 1. Redis
kubectl apply -k platform/redis
kubectl -n redis-system rollout status deploy/redis

# 2. Envoy Gateway (values gồm cấu hình extension cho AI Gateway và backend rate limit Redis) + AI Gateway
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm --version v1.8.1 \
  -n envoy-gateway-system --create-namespace -f platform/envoy-gateway/values.yaml --wait
helm upgrade --install aieg-crd oci://docker.io/envoyproxy/ai-gateway-crds-helm --version v1.1.0 \
  -n envoy-ai-gateway-system --create-namespace --wait
helm upgrade --install aieg oci://docker.io/envoyproxy/ai-gateway-helm --version v1.1.0 \
  -n envoy-ai-gateway-system --wait

# 3. Key nội bộ cho gateway: Secret vllm-api-key phải có thêm khoá "apiKey" (cùng giá trị với "key")
k=$(kubectl -n llm-serving get secret vllm-api-key -o jsonpath='{.data.key}')
kubectl -n llm-serving patch secret vllm-api-key -p "{\"data\":{\"apiKey\":\"$k\"}}"

# 4. Key cho client (tối thiểu 1 key + key ratelimit-test)
bash serving/gateway/api-key.sh add nghia
bash serving/gateway/api-key.sh add ratelimit-test

# 5. Tài nguyên gateway
kubectl apply -k serving/gateway --dry-run=server --validate=strict
kubectl apply -k serving/gateway
kubectl -n llm-serving wait --for=condition=Programmed gateway/llm-gateway --timeout=180s

# 6. Quick tunnel và URL công khai
kubectl apply -k platform/cloudflared
kubectl -n cloudflared rollout status deploy/cloudflared
kubectl -n cloudflared logs deploy/cloudflared | grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' | tail -1
```

> Nếu cài Redis **sau** Envoy Gateway, chạy `kubectl -n envoy-gateway-system rollout restart deploy/envoy-gateway` để controller tạo deployment `envoy-ratelimit`.

## Kiểm tra

```bash
U=<URL ở bước 6>; K=<key client>; T=<key ratelimit-test>
bash serving/tests/smoke.sh $U "$K"          # 4 PASS: models, stream, wrong-model (404), no-key (401)
bash serving/tests/ratelimit.sh $U "$T" "$K" # 429 ở khoảng request thứ 4; key K vẫn 200
kubectl get svc -A | grep -E 'LoadBalancer|NodePort'   # không có dòng nào
```

Số đo thực tế (2026-10-21, RTX 4090; client và VM ở hai châu lục khác nhau):

| Kiểm tra | Kết quả |
|---|---|
| Stream qua quick tunnel | Token về liên tục; TTFT 0,6–1,0 s (trong cluster 0,04 s); ~60 tok/s |
| Stream 6500 token (112 s) qua tunnel | Không bị cắt; chunk cuối có `usage` |
| Không stream 4000 token qua tunnel | 200 sau 68 s |
| Không stream 6500 token qua tunnel | **500 sau 112 s**: Cloudflare cắt request quá ~100 s mà chưa có byte trả về (gọi trong cluster thì 200) |
| Cấp hoặc thu hồi key | Có hiệu lực gần như ngay lập tức, không phải restart |
| Rate limit `ratelimit-test` (500 token/phút) | 429 ở request thứ 4; hết phút thì gọi lại được; key khác không bị ảnh hưởng |
| Redis restart | Gateway vẫn phục vụ; bộ đếm reset |

## Vận hành hằng ngày

### Cấp và thu hồi key
```bash
bash serving/gateway/api-key.sh add <ten>      # in key ra 1 lần → gửi riêng cho người dùng (không gửi vào nhóm chung)
bash serving/gateway/api-key.sh revoke <ten>   # key đó nhận 401 ngay, người khác không bị ảnh hưởng
bash serving/gateway/api-key.sh list           # chỉ in tên
```
Tên chỉ gồm `a-z`, `0-9`, `-`. Tên là client-id, xuất hiện trong access log và là đơn vị tính hạn mức. Muốn cấp lại key cho cùng một người: `revoke` rồi `add`.

### URL tunnel đổi
URL đổi mỗi khi pod `cloudflared` restart (reboot VM, pod bị xoá, ...). Lấy URL mới rồi gửi lại cho người dùng:
```bash
kubectl -n cloudflared logs deploy/cloudflared | grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' | tail -1
```

### Đổi hạn mức
Sửa `limit.requests` trong `serving/gateway/rate-limit.yaml` (đơn vị là **token**, theo `unit: Minute`), rồi `kubectl apply -k serving/gateway`. Muốn một người có hạn mức riêng: thêm một rule `type: Exact, value: <ten>` giống rule của `ratelimit-test`.

### Xem ai dùng bao nhiêu
Access log JSON của Envoy có `client`, `model`, `status`, `details`, `duration_ms`, `input_tokens`, `output_tokens`, `total_tokens` (không có prompt hay key):
```bash
POD=$(kubectl -n envoy-gateway-system get pod -l gateway.envoyproxy.io/owning-gateway-name=llm-gateway -o name | head -1)
kubectl -n envoy-gateway-system logs $POD -c envoy --since=1h | grep '"client"' | tail
# Tổng token theo client trong 1 giờ (cần jq)
kubectl -n envoy-gateway-system logs $POD -c envoy --since=1h | grep '"client"' \
  | jq -s 'map(select(.total_tokens != null)) | group_by(.client) | map({client: .[0].client, requests: length, tokens: (map(.total_tokens) | add)})'
```

## Sự cố thường gặp

| Triệu chứng | Nguyên nhân / Cách xử lý |
|---|---|
| Người dùng báo `401` | Key sai hoặc đã thu hồi; kiểm tra `api-key.sh list`. Header phải là `Authorization: Bearer <key>` |
| `429` dù ít người dùng | Một key đã vượt 100k token/phút; xem access log theo `client`. Quick tunnel còn giới hạn **200 request đang xử lý cùng lúc**; vượt mức này Cloudflare cũng trả 429 |
| `404` | Trường `model` sai (chỉ có `llama31-8b`) |
| `413` (`details: request_payload_too_large`) | Body vượt bộ đệm của gateway (`serving/gateway/client-traffic-policy.yaml`, đang là 4 MiB). Mặc định của Envoy chỉ khoảng 32 KiB, tương đương 7–8K token |
| `500` sau khoảng 100 s, request không stream | Cloudflare cắt request quá ~100 s. Dùng `stream=True` hoặc giảm `max_tokens` |
| URL trả lỗi Cloudflare 530 / 1033 | Tunnel đã đổi URL hoặc pod `cloudflared` không chạy. Kiểm tra `kubectl -n cloudflared get pods` rồi lấy URL mới |
| `502` / `503` từ gateway | vLLM chưa Ready (ví dụ đang khởi động lại): `kubectl -n llm-serving get isvc,pods` |
| Mọi request 401 kể cả key đúng, log Envoy có lỗi auth tới backend | Secret `vllm-api-key` thiếu khoá `apiKey` (bước 3 phần cài đặt) |
| Không bị 429 khi vượt hạn mức | Pod `envoy-ratelimit` không chạy hoặc không kết nối Redis: `kubectl -n envoy-gateway-system logs deploy/envoy-ratelimit` |
| Token về theo cụm hoặc stream bị lỗi qua tunnel | Cloudflare không cam kết hỗ trợ SSE cho quick tunnel. Gọi lại; nếu kéo dài, người dùng chuyển sang `stream=False` với câu trả lời ngắn |

## Gỡ cài đặt

```bash
kubectl delete -k platform/cloudflared
kubectl delete -k serving/gateway
helm uninstall aieg aieg-crd -n envoy-ai-gateway-system
helm uninstall eg -n envoy-gateway-system
kubectl delete -k platform/redis
```
