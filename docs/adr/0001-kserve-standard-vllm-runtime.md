# ADR-0001: KServe Standard mode, runtime vLLM chính thức, weights trên PVC

- Trạng thái: Đã chấp nhận
- Ngày: 2026-10-21

## Bối cảnh

Cần phục vụ Llama-3.1-8B qua API tương thích OpenAI trên Kubernetes. Sau này phần autoscaling sẽ điều khiển số replica bằng KEDA dựa trên metric `vllm:*`. Lab hiện tại có 1 node GPU (RTX 4090), chưa có ingress controller, Knative hay Istio.

## Quyết định

1. **KServe v0.21.0, `deploymentMode: Standard`** (trước v0.15 gọi là RawDeployment). KServe tạo Deployment, Service và HPA thường; không cần Knative hay Istio. Cài bằng chart `kserve-crd` + `kserve-resources`, kèm cert-manager v1.21.2. Tắt tạo Ingress (`disableIngressCreation: true`).
2. **Tự khai báo `ClusterServingRuntime vllm-openai`** chạy image `vllm/vllm-openai:v0.31.0`, **không** dùng runtime `kserve-huggingfaceserver` có sẵn (chart `kserve-runtime-configs` không cài).
3. **Weights nằm trên PVC `local-path`** và được trỏ bằng `storageUri: pvc://model-llama31-8b/current`. KServe mount thẳng PVC (read-only, `subPath: current`) vào `/mnt/models`, không dùng storage-initializer để tải.

## Lý do

- Image vLLM chính thức giữ nguyên **API OpenAI gốc** và **metrics `vllm:*`** theo đúng bản vLLM đã pin. Đây là hợp đồng với phần autoscaling và observability. Runtime huggingfaceserver bọc vLLM thêm một lớp, và tên metric có thể khác.
- Standard mode ít thành phần nhất, mà vẫn hỗ trợ `autoscalerClass: keda` cho giai đoạn sau.
- PVC mount trực tiếp nên pod khởi động **không phải tải lại 15 GB**: cold start chỉ còn thời gian load weights từ NVMe (~15 s) cộng khởi tạo engine.
- Symlink `current` trong `subPath` được kubelet chấp nhận (đã kiểm chứng), nên đổi revision model không phải sửa InferenceService.

## Hệ quả

- Tham số engine (`--max-model-len`, `--gpu-memory-utilization`, ...) đặt trong InferenceService; runtime chỉ chứa lệnh và cổng.
- Với `minReplicas = maxReplicas = 1`, KServe vẫn tạo một HPA theo CPU. HPA này vô hại và sẽ được thay khi bật KEDA.
- PV `local-path` gắn với 1 node. Khi có nhiều node phải chuyển sang S3 + LocalModelCache (ADR mới).
- Tên field và chart của KServe đổi theo phiên bản (ví dụ v0.21 đổi tên chart `kserve` thành `kserve-resources`, đổi RawDeployment thành Standard). Phải đối chiếu khi nâng cấp.
