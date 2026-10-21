# Spec: LLM Serving (Cluster + Storage + Serving, sau đó Gateway + Load test)

> Phạm vi: toàn bộ phần **LLM Serving** của dự án GPU LLM Serving Platform (xem [README](README.md), [kiến trúc](docs/architecture.html)), gồm cả việc **dựng cluster k3s có GPU** cho lab.
> Giai đoạn hiện tại: **1 máy, chưa autoscale**. Gateway và load test làm sau.
> Không bao gồm: Prometheus, KEDA/HPA, Karpenter, Loki/Grafana. Phần này chỉ định nghĩa **hợp đồng giao tiếp** với các thành phần đó (xem [Hợp đồng giao tiếp](#hợp-đồng-giao-tiếp-với-phần-còn-lại)).
> Trạng thái: **DRAFT, chờ duyệt**.

---

## Giả định

| # | Giả định | Ảnh hưởng nếu sai |
|---|---|---|
| A1 | Cluster on-prem gồm **2 máy, mỗi máy 1 GPU NVIDIA 16–24 GB**, chạy k3s (hoặc kubeadm). Sau này có thể chuyển sang AWS EKS. | Manifest phải chạy được trên cả hai môi trường; mọi khác biệt dồn vào StorageClass hoặc `storageUri` và Service type. |
| A2 | Mục tiêu scale là **1 → 2 replica**, mỗi replica dùng 1 GPU (1 node). | `minReplicas: 1`, `maxReplicas: 2`. |
| A3 | Model là **Llama-3.1-8B-Instruct BF16** (`meta-llama/Llama-3.1-8B-Instruct@0e9e39f`, khoảng 16 GB weights) trên GPU 24 GB. | Nếu có máy 16 GB tham gia cluster, mọi replica phải chuyển sang AWQ INT4 (HPA cần các replica giống hệt nhau). |
| A4 | GPU có compute capability ≥ 7.5. Lab hiện tại: RTX 4090 (8.9). | |
| A5 | Weights nằm trên **PVC `model-llama31-8b`** (StorageClass `local-path` của k3s, tức đĩa của node), được tải bằng **Job** từ Hugging Face. vLLM đọc `/mnt/models/current`. Không chạy storage service. | PV `local-path` gắn với 1 node. Khi có nhiều node hoặc lên AWS: S3 làm kho gốc + KServe LocalModelCache. |
| A8 | **Lab hiện tại**: 1 **VM** Vast.ai (`vastai/kvm`, Ubuntu 22.04), RTX 4090 24 GB, disk 150 GB. Container Vast.ai thường không chạy được k3s. | Dữ liệu PVC mất khi destroy instance; tải lại từ Hugging Face. |
| A6 | GPU Operator, Prometheus Operator và KEDA đã được cài sẵn (thuộc phần việc khác). Trước khi có chúng, phần Serving vẫn chạy được ở số replica cố định. | |
| A7 | Có tài khoản Hugging Face đã chấp nhận license Llama 3.1, kèm `HF_TOKEN`. | Không tải được model gốc. |

---

## Objective

Cung cấp một **endpoint LLM tương thích OpenAI**, chạy trên GPU trong Kubernetes, có các đặc điểm sau:

- **Streaming** token qua SSE, có xác thực bằng API key và giới hạn theo token.
- **Xuất metrics vLLM** đúng chuẩn để phần autoscaling dùng làm tín hiệu scale.
- **Khởi động lại và scale an toàn**: cold start ngắn nhờ cache weights trên node, scale-down không làm rớt request.
- **Có số liệu load test** để chốt threshold scale (số request mỗi replica) dựa trên SLO.

**Người dùng:**
- *Client / ứng dụng*: gọi `POST /v1/chat/completions` qua gateway.
- *Phần autoscaling*: đọc metrics `vllm:*`, điều khiển số replica của InferenceService.
- *Phần observability*: scrape `/metrics`, thu log có label `model`.

---

## Capability map

| Module id | Trách nhiệm | Phụ thuộc |
|---|---|---|
| `cluster` | k3s single-node, NVIDIA Container Toolkit, GPU Operator (device plugin, DCGM) | — |
| `model-store` | PVC `local-path` + Job tải weights từ HF, kèm checksum | `cluster` |
| `serving-core` | KServe (Standard mode), ClusterServingRuntime vLLM, InferenceService, probe, graceful shutdown | `model-store` |
| `gateway` | Envoy Gateway + Envoy AI Gateway: API key, giới hạn theo token, route theo model, timeout/retry | `serving-core` |
| `loadtest` | Kịch bản tải, Job chạy benchmark, báo cáo và chọn threshold | `serving-core`, `gateway` |

**Thứ tự xây dựng:** `cluster` → `model-store` → `serving-core` → `gateway` → `loadtest`

Ngoài phạm vi (giai đoạn sau): nhánh B KubeRay + Ray Serve, canary, multi-model.

---

## Tech stack

Phiên bản cụ thể **được pin trong Helm values / manifest khi cài** và ghi lại vào `docs/adr/`. Bảng dưới là mức tối thiểu.

| Thành phần | Phiên bản tối thiểu | Ghi chú |
|---|---|---|
| Kubernetes (k3s) | 1.30+ | |
| KServe | **v0.21.0 (pin)** + cert-manager v1.21.2 | Chế độ `Standard` (trước v0.15 gọi là RawDeployment); chart `kserve-crd` + `kserve-resources`. Hỗ trợ `autoscalerClass: keda` cho giai đoạn sau |
| vLLM (`vllm/vllm-openai`) | **0.31.0 (pin)** | Cùng bản với `vastai/vllm` ở giai đoạn 0. Dùng image chính thức, **không** dùng `kserve-huggingfaceserver`, để giữ nguyên metrics `vllm:*` và API OpenAI gốc |
| Envoy Gateway | **v1.8.1 (pin)** | Xem [`SPEC-gateway.md`](SPEC-gateway.md) |
| Envoy AI Gateway | **v1.1.0 (pin)** | Xem [`SPEC-gateway.md`](SPEC-gateway.md); cùng Redis `8.2.4-alpine3.22` cho rate limit |
| Công cụ load test | `vllm bench serve` (có sẵn trong image vLLM) | Không thêm dependency mới |

---

## Commands

```bash
# Cài operator (Helm values nằm trong platform/)
helm upgrade --install cert-manager jetstack/cert-manager --version v1.21.2 -n cert-manager --create-namespace --set crds.enabled=true --wait
helm upgrade --install kserve-crd oci://ghcr.io/kserve/charts/kserve-crd --version v0.21.0 -n kserve --create-namespace --wait
helm upgrade --install kserve-resources oci://ghcr.io/kserve/charts/kserve-resources --version v0.21.0 -n kserve -f platform/kserve/values.yaml --wait
# Gateway: xem lệnh trong SPEC-gateway.md

# Model store: PVC + Job tải model (chạy lại Job = verify checksum)
kubectl -n llm-serving create secret generic hf-token --from-literal=token=$HF_TOKEN
kubectl apply -k serving/models
kubectl -n llm-serving wait --for=condition=complete job/download-llama31-8b --timeout=30m

# Serving
kubectl apply -k serving/kserve
kubectl get isvc -n llm-serving -w

# Gateway
kubectl apply -k serving/gateway

# Kiểm tra
kubeconform -strict -ignore-missing-schemas -summary <(kubectl kustomize serving/kserve)
./serving/tests/smoke.sh http://<gateway-addr> $API_KEY

# Load test (chạy dưới dạng Job trong cluster)
kubectl apply -f loadtest/scenarios/<scenario>.yaml
kubectl logs -f job/<scenario> -n llm-loadtest > loadtest/results/<yyyy-mm-dd>-<scenario>.txt
```

Sau khi phần platform dùng Argo CD, mọi `kubectl apply` ở trên được thay bằng việc commit vào Git và để Argo CD sync. Các lệnh thủ công chỉ dùng trong lab.

---

## Project structure

```
platform/
├── kserve/values.yaml                  # Bật raw deployment, tắt Knative/Istio
├── envoy-gateway/values.yaml           # Xem SPEC-gateway.md
├── redis/                              # Redis cho rate limit
└── cloudflared/                        # Cloudflare Tunnel tới gateway

serving/
├── models/
│   ├── kustomization.yaml              # namespace llm-serving + PVC + Job + ConfigMap script
│   ├── namespace.yaml
│   ├── download-model.sh               # HF → PVC (idempotent, checksum, rename nguyên tử)
│   ├── hf-token-secret.yaml.example
│   ├── models.md                       # Danh mục model: nguồn, revision, kích thước, tên metric
│   └── llama31-8b/{pvc,download-job}.yaml
├── dev/
│   └── vllm-deployment.yaml            # vLLM dạng Deployment thường (T5), bị xoá sau T6
├── kserve/
│   ├── kustomization.yaml
│   ├── runtimes/vllm.yaml              # ClusterServingRuntime vllm-openai
│   └── models/llama31-8b/
│       └── inferenceservice.yaml
├── gateway/                            # Gateway, route, apiKeyAuth, rate limit: xem SPEC-gateway.md
├── images/vllm/                        # Chỉ dùng nếu phải tùy biến image
└── tests/
    └── smoke.sh                        # Kiểm tra end-to-end qua gateway

loadtest/
├── scenarios/
│   ├── bench.sh                        # Quét concurrency bằng vllm bench serve, ghi kết quả kèm metadata
│   ├── baseline.yaml                   # Job: 1 replica, chạy bench.sh
│   ├── ramp.yaml                       # Job: tăng tải để kích scale 1 → 2
│   └── prompts/                        # Bộ prompt cố định (độ dài input/output)
└── results/
    └── README.md                       # Bảng tổng hợp + threshold đã chọn

docs/
├── adr/0001-kserve-standard-vllm-runtime.md
├── adr/0002-model-choice.md
└── runbooks/serving.md                 # Cold start chậm, OOM, pod không Ready
```

---

## Code style

**Manifest:** YAML thuần, sắp xếp bằng Kustomize, không dùng Helm template cho tài nguyên riêng của dự án.

- Tên tài nguyên viết kebab-case, có tiền tố theo model: `llama31-8b`, `llama31-8b-route`.
- Mọi pod model đều có label `app.kubernetes.io/part-of: llm-serving` và `model: llama31-8b`.
- Chỉ ghi comment cho lý do, không mô tả lại field.
- Không commit secret. Mỗi secret có file mẫu `*.yaml.example`.

Ví dụ phong cách mong muốn (bản đầy đủ đang chạy: `serving/kserve/models/llama31-8b/inferenceservice.yaml`):

```yaml
apiVersion: serving.kserve.io/v1beta1
kind: InferenceService
metadata:
  name: llama31-8b
  namespace: llm-serving
  labels:
    model: llama31-8b
  annotations:
    serving.kserve.io/deploymentMode: Standard
spec:
  predictor:
    minReplicas: 1
    maxReplicas: 2
    # Lớn hơn request dài nhất (max_tokens 2048 ≈ 60s) cộng thời gian drain
    terminationGracePeriodSeconds: 120
    tolerations:
      - { key: nvidia.com/gpu, operator: Exists, effect: NoSchedule }
    model:
      modelFormat: { name: vllm }
      runtime: vllm-openai
      # PVC do serving/models tạo (A5); lên AWS thì đổi sang s3://
      storageUri: pvc://model-llama31-8b/current
      args:
        - --served-model-name=llama31-8b
        - --max-model-len=16384
        - --gpu-memory-utilization=0.90
      resources:
        limits: { nvidia.com/gpu: "1", cpu: "6", memory: 24Gi }
        requests: { nvidia.com/gpu: "1", cpu: "4", memory: 16Gi }
```

**Shell script:** bắt đầu bằng `set -euo pipefail`, nhận tham số qua argument hoặc biến môi trường, có thể chạy lại nhiều lần (idempotent), và in usage khi thiếu tham số.

---

## Đặc tả từng module

### `model-store`

**Mục tiêu:** weights có sẵn trong cluster, pod khởi động không phụ thuộc Internet và không tải lại mỗi lần.

| Yêu cầu | Chi tiết |
|---|---|
| MS-1 | PVC `model-llama31-8b` (`local-path`, RWO, 60 Gi) trong namespace `llm-serving`. |
| MS-2 | Job `download-llama31-8b` (image `vllm/vllm-openai:v0.31.0`, có CLI `hf`) tải `HF_REPO@HF_REVISION` vào `.staging-<rev>`, ghi `SHA256SUMS`, rename thành `<rev>/`, rồi trỏ symlink `current` tới đó. Không bao giờ để lại bản dở ở `<rev>/`. |
| MS-3 | Revision đã có thì Job chỉ kiểm tra checksum: **chạy lại Job = verify**. Sai checksum thì Job fail và hướng dẫn xoá thư mục đó. |
| MS-4 | `HF_TOKEN` lấy từ Secret `hf-token` (optional, để model không gated vẫn chạy được). Không commit token. |
| MS-5 | Ghi repo, revision và kích thước vào `serving/models/models.md`. Không dùng `main` trôi nổi. |

**Nghiệm thu:** Job lần đầu `Complete`; chạy lại Job kết thúc dưới 30s mà không tải lại; sửa 1 byte trong weights thì Job fail; không còn thư mục `.staging-*`.

### `serving-core`

**Mục tiêu:** InferenceService `llama31-8b` chạy vLLM, có API OpenAI, metrics và vòng đời pod an toàn.

| Yêu cầu | Chi tiết |
|---|---|
| SC-1 | KServe ở chế độ raw deployment (không Knative, không Istio). |
| SC-2 | `ClusterServingRuntime vllm-openai` dùng image `vllm/vllm-openai:<pinned>`, mở cổng 8000 cho cả API lẫn `/metrics`. |
| SC-3 | InferenceService `llama31-8b` trong namespace `llm-serving`, `minReplicas: 1`, `maxReplicas: 2`, 1 GPU mỗi pod, có toleration cho taint `nvidia.com/gpu`. |
| SC-4 | `--served-model-name=llama31-8b`. Client gọi bằng đúng tên này. |
| SC-5 | **startupProbe** gọi `GET /health`, cho phép tối đa 10 phút. **readinessProbe** gọi `/health` mỗi 10s. **livenessProbe** gọi `/health` với `failureThreshold` đủ lớn để không giết pod đang chịu tải nặng. |
| SC-6 | **Graceful shutdown**: `preStop` sleep khoảng 15s để endpoint bị gỡ khỏi Service trước, sau đó vLLM nhận SIGTERM và xử lý xong các request đang chạy nhờ **`--shutdown-timeout=90`** (mặc định 0 = huỷ request). `terminationGracePeriodSeconds: 120`. |
| SC-7 | Pod anti-affinity theo `model`: hai replica phải nằm trên hai node khác nhau. |
| SC-8 | Khối `autoScaling` / `autoscalerClass: keda` được khai báo trong InferenceService, nhưng **query và threshold** lấy từ hợp đồng với phần autoscaling (xem bên dưới). Trước khi KEDA sẵn sàng, chạy cố định 1 replica. |
| SC-9 | Log vLLM ghi ra stdout (mặc định). Không ghi log nội dung prompt ở mức INFO. |

**Nghiệm thu:**
- `kubectl get isvc llama31-8b -n llm-serving` báo `READY=True`.
- Gọi `curl <svc>:8000/v1/models` trả về `llama31-8b`.
- `curl <svc>:8000/metrics` có đủ: `vllm:num_requests_running`, `vllm:num_requests_waiting`, `vllm:kv_cache_usage_perc` (hoặc tên tương đương của bản đang chạy, ghi vào hợp đồng), `vllm:time_to_first_token_seconds_bucket`.
- Cold start với weights đã cache (tính từ lúc pod được tạo tới lúc Ready): **≤ 3 phút**. Ghi số đo thực tế vào `docs/runbooks/serving.md`.
- `kubectl scale` (hoặc đổi `minReplicas`) từ 2 về 1 khi đang có 20 request stream: **0 request bị lỗi**.

### `gateway`

Đặc tả chi tiết ở [`SPEC-gateway.md`](SPEC-gateway.md). Đã chốt: có Redis để rate limit theo token (100k token/phút cho mỗi key), người dùng truy cập qua **Cloudflare Tunnel** (HTTPS, VM không mở cổng), mỗi người một API key, giữ key nội bộ ở vLLM.

### `loadtest`

**Mục tiêu:** có số liệu thật để chốt threshold scale và kiểm chứng việc scale 1 → 2.

| Yêu cầu | Chi tiết |
|---|---|
| LT-1 | Load test chạy dưới dạng Job trong namespace `llm-loadtest`, dùng `vllm bench serve` với bộ prompt cố định (input khoảng 512 token, output khoảng 256 token, cộng một biến thể prompt dài). |
| LT-2 | **baseline**: 1 replica, quét `--max-concurrency` 1, 2, 4, 8, 16, 32. Ghi lại throughput (tok/s), TTFT p50/p95, ITL p95 và tỷ lệ lỗi. |
| LT-3 | Chọn **threshold** = mức concurrency cao nhất mà vẫn đạt **TTFT p95 ≤ 1s** và **lỗi < 1%**. Ghi vào `loadtest/results/README.md`. |
| LT-4 | **ramp**: tải tăng dần vượt threshold của 1 replica trong 10 phút, sau đó giảm. Dùng để kiểm chứng scale 1 → 2 → 1 khi autoscaling đã bật. |
| LT-5 | Mỗi lần chạy ghi đủ phiên bản vLLM, model, GPU và tham số vào file kết quả, để có thể chạy lại và so sánh. |
| LT-6 | Mặc định gọi qua gateway. Có tùy chọn gọi thẳng Service để tách độ trễ do gateway gây ra. |

**Nghiệm thu:**
- Có bảng baseline đủ 6 mức concurrency và một threshold được chốt.
- Ở kịch bản ramp có autoscaling bật: replica tăng lên 2 khi tải vượt threshold, quay về 1 sau khi tải giảm (tính cả stabilization window), và **tỷ lệ lỗi < 1% trong suốt quá trình**.

---

## Hợp đồng giao tiếp với phần còn lại

Phần Serving **cung cấp** các mục sau, và không đổi nếu không báo trước:

| Mục | Giá trị |
|---|---|
| Namespace | `llm-serving` |
| Label pod | `model=llama31-8b`, `app.kubernetes.io/part-of=llm-serving` |
| Metrics endpoint | Cổng `8000`, path `/metrics`, cổng có tên `http` (để PodMonitor chọn) |
| Tên metric | Ghi trong `serving/models/models.md` theo đúng bản vLLM đang chạy |
| Threshold scale | Lấy từ `loadtest/results/README.md` |
| Thời gian cold start | Lấy từ `docs/runbooks/serving.md`; phần autoscaling dùng số này để đặt stabilization window |
| Node selector / toleration | Toleration `nvidia.com/gpu`; không tự thêm nodeSelector ngoài GPU |

Phần Serving **cần** từ phần khác: GPU Operator chạy trên cả hai node, taint `nvidia.com/gpu`, Prometheus scrape được `llm-serving`, và KEDA đã cài (cho SC-8).

---

## Testing strategy

| Cấp | Công cụ | Ở đâu | Khi nào |
|---|---|---|---|
| Tĩnh | `kubectl kustomize` + `kubeconform -strict` | CI (`.github/workflows/`) | Mỗi PR |
| Script | `shellcheck` | CI | Mỗi PR chạm `*.sh` |
| Smoke E2E | `serving/tests/smoke.sh` (curl): models, chat stream, 401, 404, 429 | Lab cluster | Sau mỗi lần deploy |
| Vòng đời | Thủ công theo checklist trong `docs/runbooks/serving.md`: cold start, scale-down khi đang có tải, xoá pod | Lab cluster | Khi đổi runtime, probe hoặc phiên bản |
| Hiệu năng | Job `loadtest/` | Lab cluster | Khi đổi model, vLLM, GPU hoặc tham số engine |

Không đặt mục tiêu coverage, vì phần này chủ yếu là cấu hình. Thước đo chất lượng là smoke test xanh và load test có kết quả lặp lại được (sai lệch < 10% giữa hai lần chạy).

---

## Boundaries

**Always**
- Pin phiên bản image và chart. Ghi lại lý do khi nâng phiên bản.
- Chạy `kustomize build | kubeconform` trước khi commit manifest.
- Chạy smoke test sau mỗi thay đổi ở `serving/`.
- Kiểm tra `/metrics` sau khi nâng vLLM và cập nhật tên metric trong hợp đồng.
- Giữ các replica giống hệt nhau (cùng model, cùng tham số engine).

**Ask first**
- Đổi tên model, namespace, label hoặc tên metric (vì phá hợp đồng với phần autoscaling và observability).
- Đổi bản model hoặc mức lượng tử hoá.
- Thêm thành phần mới chạy thường trực (Redis, sidecar, ...).
- Đụng tới taint, node pool hoặc tài nguyên của phần autoscaling và observability.

**Never**
- Commit `HF_TOKEN` hay API key.
- Log nội dung prompt hoặc response ở mức mặc định.
- Bật retry cho request đã bắt đầu stream.
- Đặt `minReplicas: 0` trên môi trường demo hoặc prod.
- `kubectl edit` trực tiếp tài nguyên đã quản lý bằng Git mà không cập nhật Git.

---

## Success criteria (tổng)

1. `smoke.sh` pass toàn bộ qua gateway: stream, 401, 404, 429.
2. `/metrics` của mỗi pod vLLM có đủ 4 metric trong hợp đồng, và Prometheus scrape được (xác nhận cùng phần observability).
3. Cold start với weights đã cache ≤ 3 phút. Không phát sinh lỗi khi scale-down trong lúc có tải.
4. `loadtest/results/README.md` có bảng baseline và threshold đã chốt theo SLO TTFT p95 ≤ 1s.
5. Ở kịch bản ramp, khi autoscaling bật: 1 → 2 → 1 replica, lỗi < 1%.
6. Có ADR cho quyết định runtime (vLLM image thay vì huggingfaceserver) và quyết định chọn bản model (BF16 hay AWQ).

---

## Open questions

1. ~~Model GPU của lab~~: đã chốt RTX 4090 24 GB (Vast VM). Còn mở: GPU của máy on-prem thứ 2, vì nếu chỉ có 16 GB thì phải chuyển sang AWQ.
2. Nếu phải dùng AWQ: lấy bản cộng đồng (`hugging-quants/Meta-Llama-3.1-8B-Instruct-AWQ-INT4`) hay tự lượng tử hoá?
3. **SLO**: TTFT p95 ≤ 1s và lỗi < 1% đã phù hợp chưa?
4. **Mức giới hạn token** mặc định mỗi client: 100k token/phút có hợp lý không?
5. Hai máy **chỉ làm worker** hay một máy kiêm luôn control plane? Nếu kiêm, cần chừa CPU và RAM cho control plane khi đặt `requests`.
6. **Truy cập từ ngoài**: chỉ trong LAN (NodePort) hay cần domain và TLS?
