# GPU LLM Serving Platform

Nền tảng phục vụ mô hình ngôn ngữ lớn (LLM) trên GPU, chạy trên Kubernetes, **tự động scale theo tải thật** ở cả hai mức: số replica model server và số node GPU.

> Tài liệu kiến trúc chi tiết, có sơ đồ: [`docs/architecture.html`](docs/architecture.html)
>
> Triển khai từ đầu (máy trắng → model chạy trên K8s): [`docs/runbooks/deploy-from-scratch.md`](docs/runbooks/deploy-from-scratch.md)
>
> Đặc tả: [`Serving`](docs/specs/serving.md) · [`Gateway`](docs/specs/gateway.md) · [`Observability`](docs/specs/observability.md)

---

## Mục lục

- [Mục tiêu](#mục-tiêu)
- [Kiến trúc tổng thể](#kiến-trúc-tổng-thể)
- [Bốn luồng chính](#bốn-luồng-chính)
- [Thành phần](#thành-phần)
- [Chiến lược autoscaling](#chiến-lược-autoscaling)
- [KServe hay Ray Serve](#kserve-hay-ray-serve)
- [Cấu trúc thư mục](#cấu-trúc-thư-mục)
- [Quy ước chung](#quy-ước-chung)
- [Lộ trình](#lộ-trình)
- [Điểm dễ sai khi chạy thật](#điểm-dễ-sai-khi-chạy-thật)
- [Tài liệu tham khảo](#tài-liệu-tham-khảo)

---

## Mục tiêu

- Cung cấp **API tương thích OpenAI** (`/v1/chat/completions`, `/v1/completions`) có hỗ trợ streaming.
- **Tự scale replica** theo hàng đợi request của vLLM, và **tự thêm hoặc bớt node GPU** khi thiếu hoặc dư tài nguyên.
- Bám **SLO** về độ trễ (TTFT p95) và tỷ lệ lỗi, không chỉ nhìn GPU utilization.
- Quan sát đầy đủ qua metrics, logs và traces trên cùng một Grafana.
- Theo dõi **chi phí**: $/GPU-hour và chi phí trên 1M token.
- Toàn bộ hạ tầng và cấu hình được quản lý bằng code trong Git (Terraform + Argo CD).

## Kiến trúc tổng thể

```
                         ┌──────────────────────────── KUBERNETES CLUSTER ────────────────────────────┐
 Client (OpenAI API) ──► │ Envoy AI Gateway ──► KServe InferenceService ──► vLLM pods (GPU)           │
                         │  authN · rate-limit      (hoặc RayService)          │ :8000/metrics        │
                         │  routing · retry                                    │                      │
                         │                                                     ▼                      │
                         │  DCGM exporter :9400 ───────────────────────► Prometheus ──► Alertmanager ─┼─► Slack / PagerDuty
                         │                                                │                           │
                         │                                   PromQL       ▼                           │
                         │                              KEDA ──► ScaledObject ──► HPA ──► replicas    │
                         │                                                                            │
                         │  Pod Pending (thiếu GPU) ──► Karpenter / Cluster Autoscaler ──► GPU node ──┼─► Cloud API
                         │                                                                            │
                         │  Alloy (DaemonSet) ──► Loki ──┐                                            │
                         │  OTel Collector ──► Tempo ────┼──► Grafana ◄── Prometheus                  │
                         │                     S3 / GCS ◄┘                                            │
                         └────────────────────────────────────────────────────────────────────────────┘
   Ngoài cluster: Container + model registry (ECR · S3 · HF mirror) · Git + CI/CD + Argo CD · Terraform
```

Các plane chính:

| Plane | Vai trò |
|---|---|
| **Serving (GPU)** | Gateway, KServe/Ray Serve, vLLM. Nhận request và sinh token. |
| **Metrics & Autoscaling** | GPU Operator, DCGM, Prometheus, KEDA, HPA, Karpenter. Đo tải và ra quyết định scale. |
| **Observability** | Alloy, Loki, Tempo, Grafana, Alertmanager, OpenCost. Quan sát, cảnh báo, tính chi phí. |
| **Platform** | Terraform, Argo CD, CI/CD, registry. Dựng và đồng bộ mọi thứ từ Git. |

## Bốn luồng chính

**1. Request**
1. Client gọi API tương thích OpenAI tới Envoy AI Gateway.
2. Gateway xác thực, giới hạn theo token, chọn backend theo model.
3. Request đi tới Service của InferenceService (hoặc Ray Serve).
4. vLLM gộp request bằng continuous batching và stream token về client.

**2. Metrics → quyết định scale**
1. vLLM và DCGM exporter mở endpoint `/metrics`.
2. Prometheus scrape qua ServiceMonitor / PodMonitor.
3. KEDA chạy PromQL theo `pollingInterval` và đưa kết quả vào external metrics API.
4. HPA tính `ceil(current × metric / target)` rồi chỉnh số replica.

**3. Scale node GPU**
1. Pod mới ở trạng thái Pending vì không còn GPU trống.
2. Karpenter hoặc Cluster Autoscaler gọi cloud API để thêm GPU node.
3. GPU Operator cài driver và device plugin trên node mới.
4. Pod được schedule, tải weights, qua readiness probe rồi bắt đầu nhận traffic.

**4. Logs và traces**
1. Alloy (DaemonSet) đọc log container trên mỗi node.
2. Gắn label `namespace`, `pod`, `model` rồi đẩy sang Loki.
3. Loki lưu chunk trên object storage.
4. Grafana truy vấn LogQL song song với PromQL, dùng chung label để đối chiếu.

## Thành phần

| Tầng | Thành phần | Vai trò | Lưu ý |
|---|---|---|---|
| Edge | Envoy AI Gateway | Điểm vào duy nhất: authN, rate-limit theo token, routing theo model, retry, timeout | Timeout dài cho response stream (SSE) |
| Serving | KServe InferenceService | Quản lý vòng đời model server, tải model từ `storageUri`, canary | `autoscalerClass: keda` |
| Serving | vLLM | Engine suy luận: continuous batching, PagedAttention, xuất metrics | 1 pod = 1 replica; model lớn hơn 1 GPU thì dùng tensor parallel |
| Serving | KubeRay + Ray Serve | Phương án thay KServe khi cần pipeline nhiều model hoặc logic Python | Bật GCS fault tolerance cho Ray head |
| GPU | NVIDIA GPU Operator | Driver, container toolkit, device plugin, GFD, DCGM | Taint `nvidia.com/gpu` |
| GPU | DCGM exporter | `DCGM_FI_DEV_GPU_UTIL`, `FB_USED`, `POWER_USAGE`, nhiệt độ | DaemonSet, cổng 9400 |
| Metrics | Prometheus Operator | Time-series, ServiceMonitor, recording rule, alert rule | Thanos hoặc Mimir khi cần lưu dài hạn |
| Metrics | Alertmanager | Gom và định tuyến cảnh báo | Cảnh báo theo SLO |
| Autoscale | KEDA | PromQL → `external.metrics.k8s.io` → sinh HPA | |
| Autoscale | HPA | Tính và chỉnh số replica | Tự cấu hình `behavior`, không dùng mặc định |
| Autoscale | KubeRay autoscaler | Thêm Ray worker pod (chỉ nhánh B) | |
| Autoscale | Karpenter / CA | Thêm hoặc bớt GPU node | Pool on-demand cho tải nền, spot cho đỉnh tải |
| Logs | Grafana Alloy | Thu log container | Thay Promtail (hết hỗ trợ từ 02/03/2026) |
| Logs | Loki | Lưu và truy vấn log, chunk nằm trên S3 | Giữ ít label |
| Traces | OTel Collector + Tempo | Trace request từ gateway tới vLLM | Tùy chọn |
| Viz | Grafana | Dashboard và alert | Provision bằng code |
| Cost | OpenCost | GPU-hour → chi phí theo namespace và model | Kết hợp throughput để ra $/1M token |
| Platform | Git, CI/CD, Argo CD, Terraform | GitOps, build image, hạ tầng | |
| Platform | Registry + model store | Image và weights; LocalModelCache trên NVMe | Yếu tố quyết định để giảm cold start |

## Chiến lược autoscaling

| Tín hiệu | PromQL | Vai trò |
|---|---|---|
| Hàng đợi + request đang chạy | `sum(vllm:num_requests_running) + sum(vllm:num_requests_waiting)` | **Trigger chính**. Threshold là số request mỗi replica chịu được, đo bằng load test |
| KV cache | `avg(vllm:kv_cache_usage_perc)` | Guard rail. Gần 1.0 nghĩa là sắp thiếu bộ nhớ cho request mới |
| TTFT p95 | `histogram_quantile(0.95, sum by (le) (rate(vllm:time_to_first_token_seconds_bucket[2m])))` | SLO và cảnh báo; có thể dùng làm trigger phụ |
| GPU util (DCGM) | `avg(avg_over_time(DCGM_FI_DEV_GPU_UTIL[5m]))` | Cho dashboard và chi phí. **Không dùng làm trigger duy nhất**, vì continuous batching đẩy chỉ số này lên cao dù còn dư công suất |

Tham số HPA mặc định của dự án (sẽ chỉnh lại sau load test):

| Tham số | Giá trị | Lý do |
|---|---|---|
| `minReplicas` | 2 | Cao hơn tải nền một chút; production không scale về 0 |
| `maxReplicas` | 8 | Trên đỉnh tải và nằm trong quota GPU |
| `pollingInterval` | 15s | |
| scale-up | không có stabilization, tối đa +2 pod / 60s | Phản ứng nhanh khi tải tăng |
| scale-down | stabilization 900s, tối đa −1 pod / 120s | Dài hơn thời gian khởi động một replica, tránh flapping |

> Tên metric `vllm:*` có thể đổi giữa các phiên bản vLLM (ví dụ `gpu_cache_usage_perc` thành `kv_cache_usage_perc`). Luôn kiểm tra `/metrics` của đúng bản đang chạy trước khi viết query.

## KServe hay Ray Serve

| Tiêu chí | A · KServe + vLLM | B · KubeRay + Ray Serve |
|---|---|---|
| Điều khiển | CRD Kubernetes, GitOps thuần | Ray Serve app, khai báo qua CRD `RayService` |
| Scale replica | KEDA + HPA từ Prometheus | Serve controller, theo `target_ongoing_requests` |
| Scale node | Karpenter / CA | KubeRay autoscaler, rồi tới Karpenter / CA |
| Nhiều model, pipeline | Mỗi model một InferenceService | Ghép RAG, rerank và LLM trong một app Python |
| Độ phức tạp vận hành | Thấp hơn | Cao hơn (Ray head, GCS) |

**Quyết định:** làm **nhánh A trước** vì bám sát sách và ít phần phải tự viết. Nhánh B chỉ thêm khi xuất hiện nhu cầu pipeline. Hai nhánh dùng chung Prometheus, Loki, Grafana và node pool GPU.

## Cấu trúc thư mục

```
GPU-autoscaling-LLM/
├── README.md
├── docs/
│   ├── architecture.html           # Tài liệu kiến trúc có sơ đồ
│   ├── adr/                        # Architecture Decision Records
│   └── runbooks/                   # Hướng dẫn xử lý sự cố
│
├── infra/terraform/                # Hạ tầng cloud
│   ├── modules/
│   │   ├── cluster/                # Kubernetes cluster
│   │   ├── gpu-nodepool/           # Node pool GPU (on-demand, spot)
│   │   ├── storage/                # S3/GCS: model weights, Loki, Tempo
│   │   └── iam/                    # Role, service account
│   └── envs/{dev,prod}/
│
├── clusters/{dev,prod}/            # Argo CD app-of-apps cho từng môi trường
│
├── platform/                       # Helm values để cài các operator / add-on
│   ├── gpu-operator/
│   ├── keda/
│   ├── karpenter/
│   ├── kube-prometheus-stack/      # Prometheus + Alertmanager + Grafana
│   ├── loki/
│   ├── alloy/
│   ├── tempo/
│   ├── opencost/
│   ├── kserve/
│   ├── envoy-ai-gateway/
│   └── kuberay/
│
├── serving/                        # LLM Serving
│   ├── gateway/                    # Gateway, route, rate-limit, authN
│   ├── kserve/
│   │   ├── runtimes/               # ServingRuntime cho vLLM
│   │   ├── model-cache/            # LocalModelCache, LocalModelNodeGroup
│   │   └── models/llama3-8b/       # InferenceService theo từng model
│   ├── rayserve/                   # RayService + app Python (nhánh B)
│   ├── images/vllm/                # Dockerfile tùy biến (nếu cần)
│   └── models/                     # Script đồng bộ weights lên model store
│
├── autoscaling/
│   ├── nodepools/                  # Karpenter NodePool / EC2NodeClass
│   ├── placeholder/                # PriorityClass + pod giữ chỗ GPU
│   ├── scaledobjects/              # KEDA ScaledObject (khi tự quản lý Deployment)
│   └── pdb/                        # PodDisruptionBudget
│
├── observability/
│   ├── monitors/                   # ServiceMonitor / PodMonitor
│   ├── rules/
│   │   ├── recording/              # Tín hiệu scale đã tính sẵn
│   │   └── alerts/                 # Cảnh báo SLO, replica chạm trần
│   ├── alertmanager/               # Routing tới Slack / PagerDuty
│   └── dashboards/                 # Grafana dashboard (JSON)
│
├── loadtest/
│   ├── scenarios/                  # Kịch bản tải nền, đỉnh, burst
│   └── results/                    # Kết quả dùng để chọn threshold
│
└── .github/workflows/              # CI: lint manifest, build image
```

Nguyên tắc: `platform/` chỉ chứa phần **cài đặt** operator (Helm values). Các tài nguyên riêng của dự án (InferenceService, NodePool, rules, dashboard) nằm trong thư mục theo chức năng. Argo CD ở `clusters/<env>/` trỏ tới các thư mục này.

## Quy ước chung

| Mục | Quy ước |
|---|---|
| Namespace | `llm-serving`, `monitoring`, `keda`, `karpenter`, `gpu-operator`, `kserve` |
| Label bắt buộc trên pod model | `model=<tên-model>`, dùng chung cho PromQL, LogQL và dashboard |
| Label log trong Loki | Chỉ dùng `namespace`, `pod`, `model`, `container` (tránh label có cardinality cao) |
| Node GPU | Taint `nvidia.com/gpu=present:NoSchedule`; chỉ pod serving mới có toleration |
| Thay đổi cluster | Chỉ đi qua Git và Argo CD, không `kubectl apply` thủ công trên prod |
| Quyết định kiến trúc | Ghi một ADR trong `docs/adr/` |

## Lộ trình

1. **Nền tảng**: cluster, node pool GPU, Argo CD, GPU Operator, Prometheus.
2. **Serving cơ bản**: KServe + vLLM chạy một model, gọi được API OpenAI, Prometheus scrape được metrics.
3. **Gateway và cold start**: Envoy AI Gateway, LocalModelCache, probe, graceful shutdown.
4. **Load test**: đo số request mỗi replica giữ được SLO TTFT, từ đó chốt threshold.
5. **Autoscaling**: KEDA + HPA theo hàng đợi vLLM, Karpenter cho node GPU, pod placeholder, PDB.
6. **Observability đầy đủ**: Loki + Alloy, dashboard, cảnh báo SLO, OpenCost.
7. **Mở rộng (tùy chọn)**: Tempo tracing, Ray Serve cho pipeline, Thanos/Mimir.

## Điểm dễ sai khi chạy thật

- **Cold start dài**: image nặng vài GB, weights hàng chục GB, cộng thời gian khởi tạo CUDA. Khắc phục bằng pre-pull image, LocalModelCache trên NVMe, pod placeholder ưu tiên thấp và `startupProbe` đủ dài.
- **Scale down làm rớt request**: đặt `terminationGracePeriodSeconds` lớn hơn request dài nhất, thêm `preStop` để drain, và dùng PodDisruptionBudget.
- **Flapping**: dùng giá trị trung bình theo thời gian, stabilization window khi scale-down phải dài hơn thời gian khởi động, và xóa từng pod một.
- **CPU/RAM nghẽn trước GPU**: tokenizer và lớp API cần đủ CPU và RAM. Nếu thiếu, GPU không bao giờ đạt ngưỡng nên hệ thống không scale.
- **Scale-to-zero**: không áp dụng cho production; chỉ dùng cho dev hoặc job theo hàng đợi.
- **Quota và chi phí**: `maxReplicas` phải nằm trong quota GPU. Đặt cảnh báo khi replica chạm trần để phân biệt đỉnh tải thật với tấn công.

## Tài liệu tham khảo

- [vLLM](https://docs.vllm.ai) · [KServe](https://kserve.github.io/website/) · [KEDA](https://keda.sh) · [Karpenter](https://karpenter.sh)
- [NVIDIA GPU Operator](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/) · [DCGM exporter](https://github.com/NVIDIA/dcgm-exporter)
- [Envoy AI Gateway](https://aigateway.envoyproxy.io) · [KubeRay](https://docs.ray.io/en/latest/cluster/kubernetes/)
- [Grafana Alloy](https://grafana.com/docs/alloy/) · [Loki](https://grafana.com/docs/loki/) · [Tempo](https://grafana.com/docs/tempo/) · [OpenCost](https://opencost.io)
