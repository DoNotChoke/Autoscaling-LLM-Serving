# ADR-0002: Autoscale vLLM 1 ↔ 2 replica bằng KEDA theo metric vLLM

- Trạng thái: **Nháp**. SLO TTFT p95 ≤ 2 s (nới từ 1 s ngày 2026-10-28), chờ kết quả S1–S6 để chốt
- Ngày: 2026-10-24

## Bối cảnh

- Lab có **2 máy, mỗi máy 1 RTX 3060 12 GB**, cùng LAN, đã ghép thành cụm k3s 2 node (2026-10-24, `docs/runbooks/cluster-setup.md`).
- Model là Llama-3.1-8B-Instruct **AWQ INT4** (BF16 15 GB không vừa 12 GB). Cold start ~2 phút (ADR-0001, đo trên 4090; cần đo lại trên 3060).
- InferenceService `llama31-8b` chạy KServe v0.21 Standard mode. Mặc định KServe tự tạo một HPA theo CPU cho predictor.
- Yêu cầu: tự scale giữa 1 và 2 replica theo tải thật, giữ TTFT p95 dưới SLO, không flapping, không rớt request khi scale xuống.

## Quyết định

### 1. Tích hợp KServe: `autoscalerClass: external` + ScaledObject tự viết

Đối chiếu source KServe v0.21.0:

| Cách | Hành vi trong code | Kết luận |
|---|---|---|
| `autoscalerClass: none` | Xoá HPA của KServe, nhưng đặt `Deployment.replicas = minReplicas` và **không bỏ qua `replicas`** khi so sánh (`deployment_reconciler.go`, nhánh `AutoscalerClassNone`) | ❌ KServe và HPA giành nhau đặt `replicas` |
| `autoscalerClass: keda` | KServe tự sinh ScaledObject từ `spec.predictor.autoScaling`: chỉ có trigger, min/max và `stabilizationWindowSeconds` (`keda_reconciler.go`) | ❌ Không có `fallback`, `scalingModifiers`, `policies`, `pollingInterval`, không đặt được `metricType: Value`; sửa tay thì bị ghi đè |
| **`autoscalerClass: external`** | Xoá HPA của KServe (`shouldDeleteHPA`) và **bỏ `replicas`** khỏi so sánh/cập nhật Deployment | ✅ Một HPA duy nhất do KEDA sinh, cấu hình được đầy đủ |

ScaledObject ở `autoscaling/scaledobjects/llama31-8b.yaml`, trỏ vào Deployment `llama31-8b-predictor`. KEDA v2.21.0 (`platform/keda/`).

### 2. Metric scale

| Trigger | PromQL | Kiểu | Target |
|---|---|---|---|
| `concurrency` (chính) | `llm_serving:vllm_concurrency:sum` (recording rule = running + waiting) | `AverageValue` | **4** (xem mục 3) |
| `kvcache` (phụ) | `avg(vllm:kv_cache_usage_perc)` | `Value` | 0,8 |

- **Không dùng `DCGM_FI_DEV_GPU_UTIL`**: lên ~100% chỉ với 1 request (mỗi bước decode đọc toàn bộ weights), và vẫn 100% khi throughput tăng gấp nhiều lần nhờ batching. `FB_USED` luôn cao vì vLLM giữ trước VRAM (`--gpu-memory-utilization`). Scale theo hai metric này thì lên với 1 người dùng và không bao giờ xuống.
- **Không dùng riêng `num_requests_waiting`**: đủ replica thì waiting về 0, HPA tính ra cần ít replica hơn, scale xuống, waiting lại tăng (flapping). `running + waiting` đo tổng tải nên giữ nguyên khi đã đủ replica.
- **Chưa dùng metric GPU**. Nếu cần thì kết hợp kiểu AND qua `scalingModifiers`, không thêm thành trigger riêng: các trigger được gộp kiểu OR, một metric luôn cao sẽ giữ số replica ở mức tối đa.

### 3. Sức chứa, SLO và ngưỡng

Baseline 1 replica, gọi thẳng vLLM, 512 token vào / 256 token ra (`loadtest/results/2026-10-24-baseline-1-replica/`):

| Concurrency | TTFT p95 | Throughput | KV cache max |
|---|---|---|---|
| 1 | 0,35 s | 59 tok/s | 0,04 |
| 2 | 0,05 s | 121 tok/s | 0,08 |
| 4 | 1,28 s | 201 tok/s | 0,16 |
| 8 | 2,42 s | 280 tok/s | 0,33 |
| 16 | 3,90 s | 381 tok/s | 0,67 |
| 32 | 8,84 s | 340 tok/s | 1,00 |

Đo thêm các mức 4–8 (2026-10-28, node `ubuntu`, cùng tham số, 16 request mỗi luồng, 0 lỗi; `loadtest/results/2026-10-28-capacity-c4-c8/`):

| Concurrency | TTFT p50 | TTFT p95 | Throughput | KV cache max | Waiting max |
|---|---|---|---|---|---|
| 4 | 1,24 s | 1,25 s | 181 tok/s | 0,17 | 0 |
| 5 | 1,55 s | 1,56 s | 212 tok/s | 0,20 | 0 |
| 6 | 1,55 s | 1,86 s | 242 tok/s | 0,25 | 1 |
| 7 | 1,86 s | 2,16 s | 268 tok/s | 0,29 | 2 |
| 8 | 1,87 s | 2,18 s | 283 tok/s | 0,33 | 3 |

- **SLO: TTFT p95 ≤ 2 s** (nới từ 1 s: với 1 s thì `C_max = 2`, chỉ vài người dùng đã phải lên 2 replica). `C_max = 6`, target = 0,75 × 6 = 4,5, làm tròn xuống **4** request/replica để còn dư 1 request trong ~2 phút chờ pod mới Ready. Lên 2 replica khi tổng ≥ 5 request.
- TTFT vượt SLO khi KV cache mới ~30%, nên `concurrency` là trigger quyết định; `kvcache` chỉ bắt trường hợp ít request nhưng prompt dài.
- _Số trên đo gọi thẳng vLLM, chưa qua gateway._

### 4. Tham số HPA

| Tham số | Giá trị | Lý do |
|---|---|---|
| `minReplicaCount` | 1 | Không về 0 vì cold start mất vài phút |
| `maxReplicaCount` | 2 | 2 GPU |
| `pollingInterval` | 15 s | Bằng chu kỳ scrape |
| scaleUp | stabilization 0 s, +1 pod / 60 s | Lên sớm: pod mới mất ~2 phút mới nhận request |
| scaleDown | stabilization 600 s, −1 pod / 60 s | Xuống chậm, tránh load lại model liên tục |
| `fallback` | 2 replica sau 3 lần lỗi | Mất Prometheus thì giữ đủ sức chứa (KEDA ≥ 2.18 hỗ trợ cả trigger `Value`) |

### 5. Vòng đời pod khi có 2 replica

- `deploymentStrategy: RollingUpdate`, `maxSurge: 0`, `maxUnavailable: 1`: không có GPU thứ 3 để tạo pod mới trước; `Recreate` tắt cả 2 pod cùng lúc.
- PDB `minAvailable: 1` (`autoscaling/pdb/`).
- Scale xuống không rớt request nhờ cấu hình sẵn có: `preStop` 15 s, `--shutdown-timeout=90`, `terminationGracePeriodSeconds: 120` (ADR-0001).

## Hệ quả

- **Có sửa `serving/`**: annotation `autoscalerClass: external`, strategy RollingUpdate. Apply InferenceService trước để KServe xoá HPA CPU, rồi mới apply ScaledObject (webhook KEDA từ chối nếu Deployment đã có HPA khác).
- 1 replica 3060 chỉ giữ SLO 2 s tới 6 request song song; 2 replica tới ~12.
- Khi chỉ có 1 replica, rollout vẫn gây gián đoạn ngắn (pod duy nhất bị tắt trước); PDB chặn drain node đó.
- Model trên PVC `local-path` chỉ đọc được ở node 1, nên đã chuyển sang bản chép trên mỗi node ở `/opt/models/llama31-8b`, mount `hostPath` (2026-10-27, `docs/runbooks/model-on-nodes.md`). 2 replica chạy trên 2 node, 20 request chia 9/11.
- _Mở_: gateway trỏ ClusterIP qua `Backend` FQDN, mà ClusterIP chỉ chia tải theo kết nối. S2 cho thấy client giữ kết nối thì pod mới scale lên nhận 0 request (`loadtest/results/2026-10-27-autoscale/`). Envoy cũng giữ kết nối lâu nên cần đo qua gateway; hướng sửa là Service headless để Envoy thấy từng pod và chia theo request.

## Kết quả kiểm thử

| # | Kịch bản | Kỳ vọng | Kết quả |
|---|---|---|---|
| S1 | Không tải 30 phút | 1 replica, không scale | _chưa chạy_ |
| S2 | ~1,5 × target, 10 phút | Lên 2 trong ≤ 5 phút, TTFT về dưới SLO | Lên 2 sau 2 phút 4 s, 0 lỗi, TTFT p95 1,29 s → 0,67 s (gọi thẳng Service, chưa qua gateway) |
| S3 | Dừng tải sau S2 | Về 1 trong ≤ 15 phút | Về 1 sau 10 phút 2 s |
| S4 | Dao động quanh target 20 phút | ≤ 2 lần đổi số replica | _chưa chạy_ |
| S5 | Đang stream thì scale xuống | 0 lỗi | _chưa chạy_ |
| S6 | Tắt Prometheus 5 phút | Fallback 2 replica | _chưa chạy_ |
