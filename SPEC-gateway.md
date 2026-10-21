# Spec: Gateway (module `gateway`)

> Module `gateway` trong capability map của [`SPEC.md`](SPEC.md). Phụ thuộc: `serving-core` (InferenceService `llama31-8b` đã chạy).
> Trạng thái: **Đã triển khai** (T9–T15, 2026-10-21) trên lab 1 máy.

---

## Quyết định đã chốt (2026-10-21)

| # | Quyết định |
|---|---|
| D1 | **Có Redis**: dùng cho rate limit theo token (global rate limit của Envoy Gateway). |
| D2 | **Truy cập từ ngoài bằng Cloudflare Quick Tunnel** (không cần tài khoản hay domain). Pod `cloudflared` trong cluster chủ động kết nối ra Cloudflare và nhận một URL ngẫu nhiên `https://<random>.trycloudflare.com`, trỏ **chỉ tới Service Envoy**. VM không mở cổng nào; Service Envoy là `ClusterIP`. **URL đổi mỗi khi pod `cloudflared` restart**, khi đó admin đọc URL mới từ log rồi gửi lại cho người dùng. Admin vẫn dùng SSH để quản trị. |
| D3 | **Hạn mức mặc định: 100.000 token/phút cho mỗi API key**, tính theo tổng token (input + output). |
| D4 | **Giữ API key ở vLLM** (`VLLM_API_KEY`). Gateway xoá key của client và tự đính key nội bộ khi gọi vào vLLM. |
| D5 | **Mỗi người dùng một API key**, do admin cấp bằng `api-key.sh` (khoảng 5 người dùng test). Key gửi riêng cho từng người. |

## Giả định

| # | Giả định | Nếu sai |
|---|---|---|
| G1 | Cluster 1 node (Vast VM, 32 vCPU, 56 GB RAM). Gateway, Redis và `cloudflared` chỉ chạy CPU, tổng ≤ 2 vCPU và 2 GB RAM | |
| G2 | **Envoy Gateway v1.8.1 + Envoy AI Gateway v1.1.0**: cặp phiên bản mà script cài đặt của KServe v0.21 dùng | Phải đối chiếu lại tên field |
| G3 | Redis không bật persistence: bộ đếm token **mất khi Redis restart** | Chấp nhận được cho lab |
| G4 | Redis không có mật khẩu, chỉ truy cập được trong cluster | Thêm NetworkPolicy hoặc AUTH khi cần |
| G5 | Quick tunnel theo tài liệu Cloudflare: **không hỗ trợ SSE (stream)**, tối đa 200 request đang xử lý (vượt thì trả 429), không cam kết uptime | Nếu stream không chạy được: người dùng gọi `stream=False` (giới hạn 100 giây/request); muốn có stream thì chuyển sang named tunnel (cần domain) hoặc Tailscale Funnel |
| G6 | Dữ liệu test không nhạy cảm: TLS kết thúc tại Cloudflare nên **Cloudflare đọc được prompt và response** | Dữ liệu nhạy cảm thì chuyển sang Tailscale |

---

## Objective

Cho **khoảng 5 người dùng test** gọi LLM qua **một URL HTTPS cố định**, tương thích API OpenAI, gồm:

- **Mỗi người một API key**, cấp và thu hồi từng key bằng một lệnh;
- **giới hạn theo token cho từng key** (100k/phút), trả `429` khi vượt;
- **route theo trường `model`** trong body;
- **stream không bị cắt**;
- **access log** ghi client, model, mã trạng thái, số token; **không ghi nội dung prompt**;
- **không mở cổng nào trên VM**, người dùng không có quyền gì ngoài gọi API.

Phía người dùng:
```python
from openai import OpenAI
client = OpenAI(base_url="https://<random>.trycloudflare.com/v1", api_key="<key riêng>")
client.chat.completions.create(model="llama31-8b", messages=[...], stream=True)
```

---

## Kiến trúc

```
Người dùng (OpenAI SDK, key riêng)
  │  HTTPS
  ▼
Cloudflare edge: https://<random>.trycloudflare.com
  ▲  tunnel (kết nối do cloudflared chủ động mở ra, VM không mở cổng)
  │
Pod cloudflared                                         namespace cloudflared
  │  http://<service-envoy>.envoy-gateway-system:80
  ▼
Service Envoy (ClusterIP)                               namespace envoy-gateway-system
  ├─ 1. apiKeyAuth     key client (Secret gateway-api-keys) ✗ → 401
  │                    ✓ → thêm x-client-id, xoá key client
  ├─ 2. rate limit     bộ đếm token của x-client-id trong Redis; vượt → 429
  ├─ 3. AI Gateway     "model" trong body → route; sau response cộng usage vào Redis
  └─ 4. backend auth   đính key nội bộ (vllm-api-key)
  ▼
Service llama31-8b-predictor (KServe) → vLLM            namespace llm-serving

Admin: SSH vào VM → kubectl, api-key.sh, port-forward để debug
```

Token chỉ được trừ **sau khi response kết thúc**. Vì vậy request làm vượt hạn mức vẫn chạy hết; các request sau của key đó mới bị chặn cho tới khi hết cửa sổ 1 phút.

---

## Tech stack

| Thành phần | Phiên bản | Ghi chú |
|---|---|---|
| Envoy Gateway | **v1.8.1** (`oci://docker.io/envoyproxy/gateway-helm`) | Bật `enableBackend`, extension manager trỏ tới AI Gateway, rate limit backend là Redis |
| Envoy AI Gateway | **v1.1.0** (`ai-gateway-crds-helm` + `ai-gateway-helm`) | `AIGatewayRoute`, `AIServiceBackend`, `BackendSecurityPolicy` |
| Redis | `redis:8.2.4-alpine3.22` | 1 replica, không persistence, namespace `redis-system` |
| cloudflared | **`cloudflare/cloudflared:2026.10.2`** | Deployment 1 replica, namespace `cloudflared`. Quick tunnel: `tunnel --no-autoupdate --url http://llm-gateway-envoy.envoy-gateway-system:80` |

---

## Commands

```bash
# --- Admin, trên VM ---
# Redis
kubectl apply -k platform/redis

# Envoy Gateway + AI Gateway
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm --version v1.8.1 \
  -n envoy-gateway-system --create-namespace -f platform/envoy-gateway/values.yaml --wait
helm upgrade --install aieg-crd oci://docker.io/envoyproxy/ai-gateway-crds-helm --version v1.1.0 \
  -n envoy-ai-gateway-system --create-namespace --wait
helm upgrade --install aieg oci://docker.io/envoyproxy/ai-gateway-helm --version v1.1.0 \
  -n envoy-ai-gateway-system --wait

# Tài nguyên gateway
kubectl apply -k serving/gateway --dry-run=server --validate=strict
kubectl apply -k serving/gateway

# API key
./serving/gateway/api-key.sh add nghia          # in key ra 1 lần → gửi riêng cho người dùng
./serving/gateway/api-key.sh add ratelimit-test
./serving/gateway/api-key.sh list
./serving/gateway/api-key.sh revoke <name>

# Cloudflare Quick Tunnel (không cần tài khoản), rồi lấy URL công khai từ log
kubectl apply -k platform/cloudflared
kubectl -n cloudflared logs deploy/cloudflared | grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' | tail -1

# --- Kiểm tra (từ bất kỳ máy nào) ---
./serving/tests/smoke.sh https://<random>.trycloudflare.com <key>
./serving/tests/ratelimit.sh https://<random>.trycloudflare.com <ratelimit-test-key>
python serving/tests/chat.py --base-url https://<random>.trycloudflare.com/v1 "Xin chào"
```

Service Envoy: `llm-gateway-envoy.envoy-gateway-system` (tên cố định qua `EnvoyProxy.envoyService.name`). Chart đã xác nhận ở T9.

---

## Project structure

```
platform/
├── envoy-gateway/values.yaml          # Envoy Gateway: AI Gateway extension + rate limit Redis
├── redis/
│   ├── kustomization.yaml
│   └── redis.yaml                     # Namespace redis-system, Deployment, Service
└── cloudflared/
    ├── kustomization.yaml
    └── cloudflared.yaml               # Namespace, Deployment quick tunnel tới Service Envoy

serving/gateway/
├── kustomization.yaml
├── gateway.yaml                       # GatewayClass, EnvoyProxy (Service ClusterIP), Gateway
├── route.yaml                         # AIGatewayRoute (route theo model, llmRequestCosts) + AIServiceBackend + Backend
├── backend-security-policy.yaml       # Đính key nội bộ khi gọi vLLM
├── security-policy.yaml               # apiKeyAuth cho client
├── rate-limit.yaml                    # BackendTrafficPolicy: rate limit theo token + timeout
├── api-key.sh                         # add | revoke | list key trong Secret gateway-api-keys
└── api-keys-secret.yaml.example

serving/tests/
├── smoke.sh                           # thêm case wrong-model (404)
└── ratelimit.sh                       # bắn tới khi nhận 429 bằng key ratelimit-test

docs/runbooks/gateway.md               # cài đặt, Cloudflare Tunnel, cấp/thu hồi key, đổi hạn mức, sự cố
docs/user-guide.md                     # Hướng dẫn cho người dùng: URL, key, ví dụ Python/curl, giới hạn
```

**Namespace:** các CR của gateway nằm trong `llm-serving`, cùng chỗ với Service vLLM và các Secret, nên không cần `ReferenceGrant`. Pod Envoy proxy chạy trong `envoy-gateway-system`; `cloudflared` chạy trong namespace riêng.

---

## Code style

Theo `SPEC.md`: YAML thuần, gom bằng Kustomize, comment chỉ ghi lý do, không commit secret (mỗi Secret có file `.example`). Script shell bắt đầu bằng `set -euo pipefail`, chạy lại nhiều lần không lỗi, và phải qua `shellcheck`. Ví dụ cho rule rate limit:

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: BackendTrafficPolicy
metadata:
  name: llm-token-limit
spec:
  targetRefs:
    - { group: gateway.networking.k8s.io, kind: Gateway, name: llm-gateway }
  rateLimit:
    type: Global
    global:
      rules:
        # Mỗi API key (x-client-id do apiKeyAuth gắn) có ngân sách riêng
        - clientSelectors:
            - headers: [{ name: x-client-id, type: Distinct }]
          limit: { requests: 100000, unit: Minute }
          cost:
            request: { from: Number, number: 0 }   # chỉ kiểm tra, không trừ khi request vào
            response:
              from: Metadata
              metadata: { namespace: io.envoy.ai_gateway, key: llm_total_token }
```

---

## Yêu cầu

| ID | Yêu cầu |
|---|---|
| GW-1 | `Gateway` `llm-gateway` có listener HTTP :80. `EnvoyProxy` đặt Service type **ClusterIP**, nghĩa là ServiceLB của k3s không mở cổng trên node. TLS do Cloudflare đảm nhận. |
| GW-2 | `AIGatewayRoute` route `model: llama31-8b` tới `AIServiceBackend` (schema OpenAI), trỏ tới `llama31-8b-predictor.llm-serving.svc.cluster.local:80`. Model không có route thì trả **404**. |
| GW-3 | `SecurityPolicy.apiKeyAuth` đọc key từ header `Authorization` (`Bearer <key>`, đúng chuẩn OpenAI SDK); Secret `gateway-api-keys` có dạng client-id → key; `forwardClientIDHeader: x-client-id`; `sanitize: true`. Thiếu key hoặc sai key trả về **401**. |
| GW-4 | `BackendSecurityPolicy` (type `APIKey`) đính key nội bộ khi gọi vào vLLM. Secret cần có khoá `apiKey`, có giá trị trùng với `vllm-api-key`. |
| GW-5 | Rate limit theo **tổng token, 100.000/phút cho mỗi `x-client-id`**, lưu bộ đếm trên Redis. Client `ratelimit-test` có thêm một rule riêng **500 token/phút** để kiểm thử. Vượt hạn mức trả **429**. |
| GW-6 | Request timeout của route **≥ 300 giây**. Không retry request đã bắt đầu stream; chỉ retry khi lỗi kết nối hoặc 503 trước byte đầu tiên, tối đa 1 lần. |
| GW-7 | Access log có client-id, model, mã trạng thái, số token input/output và thời gian. **Không** có body hay key. |
| GW-8 | `api-key.sh add <name>` sinh key ngẫu nhiên 48 ký tự hex, thêm vào Secret và in key ra **đúng một lần**; `revoke <name>` xoá key; `list` chỉ in tên. Thêm hoặc xoá key không phải restart pod nào; thời gian để có hiệu lực ghi vào runbook. Tên trùng thì báo lỗi, không ghi đè. |
| GW-9 | `cloudflared` (Deployment 1 replica, `cloudflare/cloudflared:2026.10.2`) chạy **quick tunnel** trỏ tới Service Envoy. Có readiness probe (`/ready` trên cổng metrics). Lấy URL bằng `kubectl logs`; runbook ghi cách gửi lại URL khi pod restart. |
| GW-10 | `docs/user-guide.md` cho người dùng: URL, cách đặt key, ví dụ Python và `curl`, hạn mức 100k token/phút, **có dùng được stream hay không qua quick tunnel** (theo kết quả T13), giới hạn 100 giây cho mỗi request không stream, cách lấy URL mới khi tunnel đổi URL, và mã lỗi 401/404/429/524. |

---

## Testing strategy

| Cấp | Công cụ | Kiểm tra gì |
|---|---|---|
| Tĩnh | CI: `kustomize build` cho `serving/gateway`, `platform/redis`, `platform/cloudflared` \| `kubeconform`; `shellcheck` cho `api-key.sh` và `ratelimit.sh` | YAML, field, script |
| Server-side | `kubectl apply --dry-run=server --validate=strict` | Field có tồn tại trong CRD đúng phiên bản đã cài |
| Smoke trong cluster | `smoke.sh` qua port-forward tới Envoy | Kiểm tra gateway riêng, chưa qua Cloudflare |
| Smoke công khai | `smoke.sh https://<random>.trycloudflare.com <key>` **từ máy ngoài cluster** | `models`, `stream`, `no-key` → 401, `wrong-model` → 404 |
| Rate limit | `ratelimit.sh` dùng key `ratelimit-test` | Nhận 429 trong ≤ 10 request ngắn; gọi lại được sau 60 giây; key khác vẫn gọi bình thường trong lúc bị chặn |
| Key | `api-key.sh add`, rồi gọi được; `revoke`, rồi nhận 401 | Đo thời gian để thay đổi có hiệu lực |
| Stream qua quick tunnel | `chat.py` (stream) và `curl -N` qua URL công khai, so với port-forward | Ghi lại thực tế: token về từng phần, về một cục khi xong, hay lỗi (tài liệu Cloudflare nói quick tunnel **không hỗ trợ SSE**) |
| Không stream | `stream=False` với `max_tokens` 512 và 4000 qua URL công khai | 512 token phải thành công; ghi lại 4000 token có bị 524 (quá 100 giây) không |
| Stream dài qua gateway | `chat.py --max-tokens 2000` qua port-forward tới Envoy | Không bị gateway cắt |
| Key nội bộ | `curl` thẳng vào Service vLLM bằng key client | **401** |
| Không lộ cổng | `kubectl get svc -A` và quét cổng IP VM từ ngoài | Không có `LoadBalancer`, `NodePort` hay cổng mới nào |
| Hồi quy | Benchmark `compare.py vllm` qua URL công khai | Ghi lại độ trễ TTFT thêm vào do gateway và Cloudflare (chỉ để biết, không đặt ngưỡng) |

---

## Boundaries

**Always**
- Pin phiên bản chart và image. Chạy dry-run phía server trước khi apply.
- Sau mỗi thay đổi ở `serving/gateway` hoặc `platform/cloudflared`, chạy `smoke.sh` và `ratelimit.sh` qua URL công khai.
- Public hostname của tunnel chỉ trỏ tới Service Envoy.
- Gửi API key riêng cho từng người dùng, không gửi vào nhóm chat chung.

**Ask first**
- Thêm public hostname khác vào tunnel (ví dụ Grafana) hoặc bật Cloudflare Access.
- Đổi hạn mức mặc định hoặc thêm hạn mức theo từng key.
- Bật persistence hoặc mật khẩu cho Redis; thêm replica cho Envoy, Redis hoặc `cloudflared`.

**Never**
- Mở NodePort, LoadBalancer hay cổng Vast nào cho gateway (D2).
- Trỏ tunnel thẳng vào vLLM mà bỏ qua gateway.
- Commit API key, key nội bộ hay token của tunnel; in key ra log.
- Log body của request/response.
- Retry request đã bắt đầu stream.
- Bỏ `VLLM_API_KEY` ở vLLM (D4).

---

## Success criteria

1. Từ một máy **ngoài cluster**, gọi qua URL quick tunnel pass: `models`, chat không stream, `no-key` (401), `wrong-model` (404). Case `stream` pass qua port-forward tới Envoy; qua quick tunnel thì ghi lại kết quả thực tế vào user guide.
2. `ratelimit.sh` nhận 429 với key `ratelimit-test`, gọi lại được sau 1 phút; key khác không bị ảnh hưởng.
3. `api-key.sh` cấp và thu hồi key được; key đã thu hồi nhận 401.
4. Key client không gọi thẳng được vLLM.
5. Stream 2000 token qua gateway (port-forward) không bị cắt.
6. Access log có client-id và số token, không có nội dung prompt.
7. VM không có cổng mới nào mở ra Internet.
8. Có `docs/runbooks/gateway.md` và `docs/user-guide.md`. `deploy-from-scratch.md` có thêm các bước gateway và Cloudflare Tunnel.

---

## Rủi ro cần kiểm chứng sớm

| Rủi ro | Cách kiểm | Phương án dự phòng |
|---|---|---|
| `apiKeyAuth` có thể không bóc tiền tố `Bearer ` khỏi header `Authorization` (tài liệu Envoy Gateway nói không rõ) | Đầu T9: gửi `Authorization: Bearer <key>` | Client gửi thêm header `x-api-key` (OpenAI SDK: `default_headers`), và `extractFrom` đọc cả hai header |
| Filter rate limit chạy **trước** `apiKeyAuth`, nên chưa có header `x-client-id` | Test GW-5 với 2 key khác nhau | Thay `x-client-id` bằng selector theo header `Authorization` (Distinct) |
| Khi stream, vLLM chỉ trả `usage` nếu client gửi `stream_options.include_usage`, nên AI Gateway có thể đếm 0 token | Stream không có `include_usage`, rồi kiểm tra bộ đếm Redis hoặc access log | Kiểm tra AI Gateway có tự thêm `include_usage` không; nếu không thì ghi rõ trong user guide |
| **Quick tunnel không hỗ trợ SSE** (tài liệu Cloudflare): stream có thể không hoạt động | T13 test stream qua URL công khai | Người dùng gọi `stream=False`. Muốn có stream thì chuyển sang named tunnel (cần domain) hoặc Tailscale Funnel (cần quyết định riêng) |
| **Cloudflare cắt request không có byte trả về trong 100 giây (lỗi 524)**: kết hợp với không có stream, câu trả lời dài (~5000 token ở 55 tok/s) hoặc lúc tải cao sẽ bị cắt | Gọi không stream với `max_tokens` 4000 | User guide ghi giới hạn `max_tokens` khuyến nghị |
| URL quick tunnel đổi khi pod `cloudflared` restart; không cam kết uptime | Xoá pod `cloudflared` | Runbook: lệnh lấy URL mới và gửi lại cho người dùng |
| ServiceLB của k3s chiếm cổng 80 của node nếu Service có type `LoadBalancer` | `kubectl get svc -A` sau khi tạo Gateway | GW-1: ép `EnvoyProxy` dùng `ClusterIP` |

### Kết quả kiểm chứng (T9–T14, 2026-10-21)

| Rủi ro | Kết quả |
|---|---|
| `Bearer` trong `Authorization` | ✅ Envoy Gateway tự bóc tiền tố `Bearer `; OpenAI SDK dùng được nguyên trạng |
| Thứ tự filter | ✅ `x-client-id` có trước bước rate limit; Redis có bộ đếm riêng cho từng client |
| `usage` khi stream | ✅ Sau khi cấu hình `llmRequestCosts`, chunk cuối của stream có `usage` dù client không gửi `include_usage` |
| SSE qua quick tunnel | ⚠ Cloudflare không cam kết hỗ trợ, nhưng thực tế **chạy được**: token về liên tục, TTFT 0,6–1,0 s; stream 6500 token (112 s) không bị cắt |
| Request không stream > 100 s | ❌ Bị Cloudflare cắt, client nhận **500** (không phải 524). 4000 token (68 s) thì vẫn ổn |
| ServiceLB | ✅ Service Envoy là `ClusterIP` (`llm-gateway-envoy`); không có LoadBalancer hay NodePort |
| Khác | Timeout mặc định của `AIGatewayRoute` là 60 s, nên đã đặt 300 s. `AIServiceBackend` chỉ trỏ được tới `Backend` FQDN (chưa trỏ thẳng được Service). Trên Windows, `curl -d` làm hỏng UTF-8, nên các script gửi body qua stdin |

## Open questions

1. Danh sách tên người dùng (client-id) cho 5 key, ví dụ tên viết thường không dấu.
