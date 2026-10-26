# Spec: Observability

> Phụ trách metrics, dashboard, alert và logs cho toàn bộ hệ thống LLM serving. Prometheus là dependency cung cấp metric cho autoscaling.

## 1. Mục tiêu và phạm vi

Luồng chính:

`vLLM / GPU / Gateway → Prometheus → Grafana / Alertmanager / KEDA`

Thứ tự triển khai:

`Monitoring stack → Metrics checkpoint → Recording rules và dashboard → Alerting → Logging`

Sau checkpoint metrics, phần observability và autoscaling tiếp tục song song.

Ngoài phạm vi phase này: cấu hình KEDA/HPA, node autoscaling, Tempo và OpenCost.

## 2. O1 — Monitoring foundation

Cài `kube-prometheus-stack` bằng Helm. Cấu hình được quản lý tại `platform/kube-prometheus-stack/`; manifest riêng của dự án đặt tại `observability/`.

Stack gồm Prometheus, Grafana, Alertmanager, kube-state-metrics và exporter cần thiết từ chart.

Yêu cầu:

- Scrape interval 15 giây, retention 7 ngày.
- Prometheus dùng PVC `local-path` khoảng 20 GiB.
- Mọi pod có resource requests/limits; tổng RAM monitoring stack dưới 4 GiB.
- Tắt target Kubernetes không tồn tại hoặc không được expose trên k3s để tránh target `DOWN` giả.
- Grafana và Prometheus chỉ truy cập bằng `kubectl port-forward` qua SSH, không mở public tunnel.
- Password admin Grafana nằm trong Secret, không ghi vào values hoặc Git.
- Runbook ghi rõ địa chỉ Prometheus nội bộ cho service trong cluster.

Nghiệm thu:

- Prometheus ổn định và không có target `DOWN` do cấu hình sai.
- Grafana truy cập được qua port-forward.
- Restart Prometheus không làm mất dữ liệu.
- Tổng RAM stack dưới 4 GiB.

## 3. O2 — Metrics pipeline và checkpoint autoscaling

Đây là ưu tiên cao nhất vì KEDA phụ thuộc trực tiếp vào Prometheus.

### 3.1. vLLM

Tạo `PodMonitor` scrape mọi pod của InferenceService `llama31-8b`. Pod hiện có label `serving.kserve.io/inferenceservice=llama31-8b`, port 8000 và endpoint `/metrics`.

Phải kiểm tra `/metrics` của version vLLM đang chạy trước khi viết PromQL hoặc rule. Tối thiểu xác nhận:

- `vllm:num_requests_running`
- `vllm:num_requests_waiting`
- `vllm:kv_cache_usage_perc`

Mỗi replica phải tạo series riêng. Tín hiệu autoscaling chính là tổng `running + waiting`; không dùng GPU utilization, VRAM hoặc riêng `waiting` làm trigger chính.

### 3.2. GPU

Thu metric từ DCGM Exporter của GPU Operator. Tối thiểu quan sát utilization, VRAM, power, temperature và XID errors.

Kiểm tra thực tế trên RTX 3060 12 GB xem có:

- `DCGM_FI_PROF_SM_ACTIVE`
- `DCGM_FI_PROF_PIPE_TENSOR_ACTIVE`
- `DCGM_FI_DEV_POWER_USAGE`

Lập bảng metric có/không, giá trị khi tải thấp và khi nhiều request song song. Không dùng benchmark RTX 4090 trong tài liệu cũ làm ground truth.

### 3.3. Gateway

Thu metric của Envoy Gateway và AI Gateway để theo dõi request/s, HTTP status, 4xx, 5xx và 429. Port/path phải lấy từ version đang chạy, không hard-code trước khi kiểm tra.

### 3.4. Checkpoint bàn giao

Bàn giao cho phần autoscaling ngay khi Prometheus scrape vLLM ổn định:

- Prometheus URL trong cluster.
- Query `running`, `waiting`, concurrency và KV cache.
- Label structure thực tế.
- Bằng chứng metric thay đổi theo tải và mỗi replica có series riêng.

Không chờ toàn bộ observability hoàn thành trước khi bàn giao.

## 4. O3 — Recording rules và dashboard

### 4.1. Recording rules

Lưu tại `observability/rules/recording/`. Tối thiểu tổng hợp:

- TTFT p50 và p95.
- Inter-token latency p95.
- Generation throughput token/giây.
- Concurrency.
- Gateway request/s, 4xx rate và 5xx rate.

Tên raw metric/histogram phải được xác nhận từ endpoint live. Mọi rule phải pass `promtool check rules`; CI phải chạy kiểm tra này.

### 4.2. Grafana dashboards

Lưu JSON tại `observability/dashboards/` và provision bằng ConfigMap/dashboard sidecar. Không tạo dashboard thủ công trong Grafana.

- GPU: utilization, VRAM, power, temperature, XID errors.
- Serving: running/waiting theo pod, concurrency, KV cache, TTFT p95, throughput.
- Gateway: request/s, status, 4xx, 5xx, 429, token usage theo client nếu có metric.
- Autoscaling: concurrency, KV cache, pod Ready và tải theo pod; sau khi có KEDA thêm desired/current replicas, scaler value, threshold và thời điểm scale.

Dashboard autoscaling phải thể hiện chuỗi: tải tăng → vượt threshold → desired replica tăng → pod mới khởi động → pod Ready → tải được chia.

Nghiệm thu bằng load test, phân biệt được từng replica, dashboard còn nguyên sau khi xóa Grafana pod và thể hiện được scale 1 → 2 → 1 sau tích hợp KEDA.

## 5. O4 — Alerting

Rule đặt tại `observability/rules/alerts/`; cấu hình notification đặt tại `observability/alertmanager/`. Credential chỉ nằm trong Secret.

Alert bắt buộc:

- `VLLMDown`
- `GPUXidError`
- `HighTTFT`
- `KVCacheNearFull`
- `GatewayErrorRate`
- `PodCrashLooping`

Sau khi có KEDA và threshold thực tế, thêm `KEDAScalerError` và `AutoscaleAtMax`. HTTP 429 do rate limiting là tín hiệu dashboard, không mặc định là sự cố.

Nghiệm thu bằng một sự cố chủ động: alert chuyển `Firing`, sau xử lý chuyển `Resolved`, notification tới kênh đã chọn hoạt động và load test 429 không tạo alert sai.

## 6. O5 — Centralized logging

Sau khi metrics, dashboard và alert ổn định, cài Loki single-binary và Alloy DaemonSet.

Yêu cầu:

- Loki lưu filesystem/PVC, retention 7 ngày và có resource requests/limits.
- Alloy thu log pod và gửi tới Loki.
- Query được log Envoy Gateway, vLLM, KServe, Open WebUI và KEDA.
- Lọc được gateway access log theo client, model, status và token usage.
- Tìm được log startup/model load/KV cache của vLLM.
- Quét `Bearer` và dấu hiệu API key; không credential nào được xuất hiện trong log.

## 7. O6 — Tích hợp với autoscaling

Dependency cứng duy nhất ban đầu: O2 phải hoàn thành trước khi KEDA dùng Prometheus.

Sau checkpoint, hai nhánh chạy song song. Khi KEDA và threshold thực tế sẵn sàng, bổ sung KEDA metrics, Autoscaling dashboard, `KEDAScalerError` và `AutoscaleAtMax`.

## 8. Phạm vi file và ownership

Phụ trách chính:

- `platform/kube-prometheus-stack/`
- `platform/loki/`
- `platform/alloy/`
- `observability/`

Nếu cần sửa `serving/` hoặc `platform/gpu-operator/`, phải trao đổi với owner phần serving và ghi rõ trong PR. Việc bật `ServiceMonitor` của DCGM qua GPU Operator values thuộc nhóm thay đổi này.

## 9. Quy tắc triển khai

- Làm trên branch `observability`.
- Không commit secret; pin Helm chart và image, không dùng `latest`.
- Mọi pod có resource requests/limits và không request GPU.
- Manifest mới phải qua CI lint; cập nhật kubeconform khi thêm nhóm manifest.
- Có runbook ngắn tại `docs/runbooks/observability.md`.
- Grafana và Prometheus chỉ truy cập nội bộ bằng port-forward.

## 10. Definition of Done

- Prometheus thu đủ vLLM, GPU, Gateway và KEDA metrics cần thiết.
- KEDA sử dụng được Prometheus làm metric source.
- Recording rules pass `promtool`.
- Bốn dashboard được provision từ Git và thể hiện được scale 1 → 2 → 1.
- Alert vận hành chính hoạt động và gửi notification.
- Loki và Alloy thu đủ log cần thiết, không lộ credential.
- Restart Prometheus, Grafana hoặc Loki không làm mất trạng thái cần giữ.
- Runbook đủ để người khác dựng lại mà không cần hỏi thêm.
- CI lint pass.
