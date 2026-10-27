# Runbook: Observability

Ghi lại cách triển khai và kết quả nghiệm thu từng bước theo [spec observability](../specs/observability.md). Các bước tiếp theo được bổ sung vào cùng file này khi có kết quả thực tế.

## 1. Monitoring foundation — hoàn thành

Cluster k3s có hai node `Ready`. `kubectl` và Helm được chạy trên node điều khiển với kubeconfig `/etc/rancher/k3s/k3s.yaml`. Chart `kube-prometheus-stack` được pin ở phiên bản `89.2.0`; cấu hình của project nằm tại [`platform/kube-prometheus-stack/values.yaml`](../../platform/kube-prometheus-stack/values.yaml).

### 1.1. Cấu hình và triển khai

Prometheus scrape mỗi `15s`, giữ dữ liệu `7d` trên PVC `local-path` `20Gi` (`RWO`). Grafana và Prometheus dùng Service `ClusterIP`, không có Ingress hay public tunnel. Password admin Grafana chỉ nằm trong Secret `monitoring/grafana-admin`. Các target etcd, controller-manager, scheduler và kube-proxy không scrape trực tiếp được trong cấu hình k3s hiện tại đã được tắt cùng các rule phụ thuộc.

Tạo namespace và Secret **một lần** trước khi cài chart; không ghi password vào Git:

```bash
kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml create namespace monitoring
kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml -n monitoring \
  create secret generic grafana-admin \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="$(openssl rand -base64 32)"
```

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm --kubeconfig /etc/rancher/k3s/k3s.yaml upgrade --install kube-prometheus-stack \
  prometheus-community/kube-prometheus-stack \
  --version 89.2.0 -n monitoring \
  -f platform/kube-prometheus-stack/values.yaml \
  --wait --timeout 10m
```

Kết quả triển khai được ghi nhận: release `kube-prometheus-stack` trong namespace `monitoring` ở trạng thái `deployed`.

### 1.2. Kiểm tra workload và lưu trữ

```bash
kubectl -n monitoring get pods,pvc
kubectl -n monitoring get prometheus kube-prometheus-stack-prometheus \
  -o jsonpath='{.spec.scrapeInterval}{"\n"}{.spec.retention}{"\n"}'
```

Prometheus, Grafana, Alertmanager, Prometheus Operator và kube-state-metrics chạy bình thường; node-exporter có hai Pod, mỗi node một Pod. PVC Prometheus ở trạng thái `Bound`, dung lượng `20Gi`, access mode `RWO`, StorageClass `local-path`. Prometheus nhận `scrapeInterval: 15s` và `retention: 7d`.

### 1.3. Truy cập nội bộ

Prometheus có địa chỉ cho workload trong cluster: `http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090`.

Trên node có quyền truy cập cluster, chạy một trong các lệnh sau và giữ terminal mở. Nếu thao tác qua VS Code Remote SSH, forward port tương ứng qua tab **Ports**; nếu thao tác ngay trên máy đó, mở `localhost` trong trình duyệt của máy.

```bash
kubectl -n monitoring port-forward --address 127.0.0.1 \
  svc/kube-prometheus-stack-prometheus 9090:9090
# http://localhost:9090/targets
```

```bash
kubectl -n monitoring port-forward --address 127.0.0.1 \
  svc/kube-prometheus-stack-grafana 3000:80
# http://localhost:3000
```

Kết quả ghi nhận: các target thuộc monitoring stack đã kiểm tra ở trạng thái `UP`; giao diện Prometheus và Grafana truy cập được qua port-forward.

### 1.4. Nghiệm thu RAM và dữ liệu sau restart

```bash
kubectl -n monitoring top pods --sum
```

Tổng RAM đo được là **923Mi**, dưới ngưỡng **4GiB** (4096Mi) ở thời điểm kiểm tra.

Để kiểm tra dữ liệu lưu bền, truy vấn `count(up)` tại thời điểm Unix `1793010634` trước restart Prometheus: kết quả **17**. Sau khi chạy:

```bash
kubectl -n monitoring rollout restart \
  statefulset/prometheus-kube-prometheus-stack-prometheus
kubectl -n monitoring rollout status \
  statefulset/prometheus-kube-prometheus-stack-prometheus --timeout=5m
```

StatefulSet hoàn tất rollout. Port-forward được mở lại, Prometheus trả `Prometheus Server is Ready.` và truy vấn lại **cùng thời điểm**:

```bash
curl -fsSG http://127.0.0.1:9090/api/v1/query \
  --data-urlencode 'query=count(up)' \
  --data-urlencode 'time=1793010634'
```

API trả `status: success` và giá trị vẫn là **17**. Dữ liệu tại thời điểm đã kiểm tra còn sau restart. Lần truy vấn đầu ngay sau rollout lỗi do port-forward cũ bị ngắt; đó không phải kết quả kiểm tra PVC.

**Kết luận O1:** Monitoring stack đã triển khai và đạt các kiểm tra về workload, PVC, cấu hình scrape/retention, truy cập nội bộ, RAM tại thời điểm đo và dữ liệu sau restart. Các metric vLLM/GPU/Gateway, dashboard, alert và logging được nghiệm thu ở các bước tiếp theo.

## 2. Metrics pipeline — checkpoint autoscaling đã sẵn sàng

Prometheus trong cluster: `http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090`. Các manifest được lưu tại [`observability/`](../../observability/); apply từ thư mục gốc repository:

```bash
kubectl apply -f observability/podmonitors/vllm.yaml
kubectl apply -f observability/servicemonitors/dcgm-exporter.yaml
kubectl apply -f observability/podmonitors/llm-gateway-envoy.yaml
kubectl apply -f observability/servicemonitors/gateway-components.yaml
```

### 2.1. vLLM và checkpoint cho autoscaling

PodMonitor `monitoring/vllm` chọn Pod có label `serving.kserve.io/inferenceservice=llama31-8b` trong `llm-serving`, scrape container port tên `http` (8000), path `/metrics`, mỗi `15s`. Prometheus trả `up{job="monitoring/vllm"}=1` cho predictor Pod đang chạy. Series thực tế có `job="monitoring/vllm"`, `namespace="llm-serving"`, `model_name="llama31-8b"`, `pod`, `instance`, `container`, `endpoint` và `engine`. Dùng `pod` hoặc `instance` để phân biệt replica.

PromQL bàn giao cho autoscaling:

```promql
sum(vllm:num_requests_running{job="monitoring/vllm",namespace="llm-serving",model_name="llama31-8b"})
```

```promql
sum(vllm:num_requests_waiting{job="monitoring/vllm",namespace="llm-serving",model_name="llama31-8b"})
```

```promql
sum(vllm:num_requests_running{job="monitoring/vllm",namespace="llm-serving",model_name="llama31-8b"}) + sum(vllm:num_requests_waiting{job="monitoring/vllm",namespace="llm-serving",model_name="llama31-8b"})
```

```promql
max(vllm:kv_cache_usage_perc{job="monitoring/vllm",namespace="llm-serving",model_name="llama31-8b"})
```

Kiểm tra theo replica: bỏ `sum`/`max` và xem label `pod` của từng series. Đợt thử trước với 80 request, concurrency 8, trả toàn bộ HTTP 200; `running` tăng 0 → 8, KV cache tăng 0 → khoảng 0.106, `waiting` vẫn 0. Đợt đo bổ sung 24 request, concurrency 8, cũng trả 24/24 HTTP 200; Prometheus ghi nhận `running=8`, `waiting=0` và KV cache khoảng 0.0157 tại mẫu đang tải. Query tổng `running + waiting` trả vector giá trị `0` khi nhàn rỗi, phù hợp làm tín hiệu concurrency cho KEDA.

**Chưa kiểm tra hai replica:** InferenceService hiện đặt `minReplicas: 1`, `maxReplicas: 1` và chỉ có một predictor Pod. PodMonitor sẽ chọn thêm Pod cùng label, nhưng chưa có bằng chứng hai series đồng thời hoặc tải được chia giữa hai replica. Phần serving/autoscaling cần bật replica thứ hai rồi xác nhận bằng `count(vllm:num_requests_running{job="monitoring/vllm",namespace="llm-serving",model_name="llama31-8b"})` trả `2` và hai giá trị `pod` khác nhau.

### 2.2. GPU/DCGM

ServiceMonitor `monitoring/nvidia-dcgm-exporter` chọn Service trong `gpu-operator`, scrape port `gpu-metrics` (9400), path `/metrics`, mỗi `15s`. Prometheus trả hai series `up{job="nvidia-dcgm-exporter"}=1`, một trên mỗi node. Các metric `DCGM_FI_DEV_GPU_UTIL`, `DCGM_FI_DEV_FB_USED`, `DCGM_FI_DEV_POWER_USAGE`, `DCGM_FI_DEV_GPU_TEMP` đều có hai series, phân biệt bằng `hostname`, `UUID` và `instance`. GPU node chạy vLLM còn có `exported_namespace="llm-serving"` và `exported_pod` trỏ tới predictor Pod.

Mẫu Prometheus tại thời điểm nhàn rỗi (`1793012600`) và khi `vllm:num_requests_running=8` (`1793013936`):

| Node | Trạng thái | GPU util (%) | VRAM dùng (MiB) | Power (W) | Nhiệt độ (°C) |
| --- | --- | ---: | ---: | ---: | ---: |
| `s12gbn3-system-product-name` | Nhàn rỗi | 0 | 9088 | 13.712 | 46 |
| `s12gbn3-system-product-name` | Đang tải | 100 | 9088 | 166.701 | 63 |
| `ubuntu` | Nhàn rỗi | 0 | 104 | 7.466 | 47 |
| `ubuntu` | Trong đợt tải trên node kia | 0 | 104 | 7.083 | 46 |

Trước khi mở rộng collector, `DCGM_FI_DEV_XID_ERRORS`, `DCGM_FI_PROF_SM_ACTIVE` và `DCGM_FI_PROF_PIPE_TENSOR_ACTIVE` đều trả **không có series**. DaemonSet dùng CSV mặc định của image `4.6.1-4.8.4-distroless`; kiểm tra trực tiếp `/metrics` cũng chưa thấy XID. Kết quả rỗng không có nghĩa XID bằng 0. `DCGM_FI_PROF_SM_ACTIVE` được comment trong CSV của exporter 4.8.4; `DCGM_FI_PROF_PIPE_TENSOR_ACTIVE` có trong CSV nhưng chưa phát series trên RTX 3060.

Để quan sát được trạng thái XID khi không có lỗi, [GPU Operator values](../../platform/gpu-operator/values.yaml) nay tạo ConfigMap collector qua Helm: giữ 26 field đang bật trong CSV của exporter 4.8.4 và bổ sung `DCGM_EXP_XID_ERRORS_COUNT`. ServiceMonitor tự sinh của GPU Operator được tắt để giữ một target DCGM do manifest của project quản lý. Helm release `gpu-operator` được upgrade từ revision 1 lên 2 với chart vẫn pin `v26.7.2`; DaemonSet exporter rollout thành công 2/2 Pod và ClusterPolicy ở trạng thái `ready`.

```bash
helm --kubeconfig /etc/rancher/k3s/k3s.yaml upgrade gpu-operator nvidia/gpu-operator \
  --version v26.7.2 -n gpu-operator \
  -f platform/gpu-operator/values.yaml \
  --no-hooks --wait --timeout 10m --rollback-on-failure
kubectl -n gpu-operator rollout status daemonset/nvidia-dcgm-exporter --timeout=5m
```

`--no-hooks` chỉ áp dụng ở lần đổi cấu hình này vì giữ nguyên chart `v26.7.2`; khi nâng chart version cần xem lại các hook nâng CRD. Prometheus trả hai series `DCGM_EXP_XID_ERRORS_COUNT{job="nvidia-dcgm-exporter"}=0`, phân biệt bằng `hostname` và `UUID` của hai GPU. Các metric `DCGM_FI_DEV_GPU_UTIL`, `DCGM_FI_DEV_FB_USED`, `DCGM_FI_DEV_POWER_USAGE`, `DCGM_FI_DEV_GPU_TEMP` vẫn có 2/2 series và hai target exporter đều `UP`. Giá trị 0 chỉ cho biết không có mẫu XID hợp lệ trong cửa sổ quan sát; không chứng minh GPU chưa từng lỗi.

### 2.3. Gateway

Envoy proxy của `llm-gateway` có container port `metrics:19001`, path `/stats/prometheus`; PodMonitor `monitoring/llm-gateway-envoy` scrape mỗi `15s`. ServiceMonitor trong `gateway-components.yaml` scrape Envoy Gateway controller (`metrics:19001`), AI Gateway controller (`http-metrics:8080`) và rate-limit (`metrics:19001`) tại `/metrics`. Endpoint và tên port đã được xác nhận trên workload đang chạy. Bốn target đều `UP` (1/1 từng target). Hai controller cung cấp metric vận hành controller; request/status của luồng phục vụ đến từ Envoy proxy.

PromQL cho request/s và tỷ lệ lỗi của HTTP listener `http-10080`:

```promql
sum(rate(envoy_http_downstream_rq_completed{job="monitoring/llm-gateway-envoy",envoy_http_conn_manager_prefix="http-10080"}[5m]))
```

```promql
sum by (envoy_response_code_class) (rate(envoy_http_downstream_rq_xx{job="monitoring/llm-gateway-envoy",envoy_http_conn_manager_prefix="http-10080"}[5m]))
```

Lọc `envoy_response_code_class="4"` hoặc `"5"` để lấy riêng 4xx/5xx. Counter tại lúc kiểm tra: `envoy_http_downstream_rq_completed=73`, class 2xx=`55`, 4xx=`18`, 5xx=`0`. Chúng là số tích lũy, không phải request/s. Counter `envoy_cluster_upstream_rq{envoy_response_code="429",envoy_cluster_name="httproute/llm-serving/llm-route/rule/0"}=2` có trong Prometheus; rate-limit exporter có `ratelimit_service_rate_limit_over_limit=446`. Có thể theo dõi tín hiệu rate limiting qua `rate(ratelimit_service_rate_limit_over_limit{job="envoy-ratelimit"}[5m])`. Các counter này chưa chứng minh chính xác số HTTP 429 mà client nhận; metric downstream hiện chỉ tách theo lớp 4xx.

Thử nghiệm qua port-forward Service `llm-gateway-envoy` bằng key `ratelimit-test`: năm request đầu trả HTTP 200, request thứ sáu trả HTTP **429**; script `serving/tests/ratelimit.sh` báo `PASS`. Envoy access log cùng đợt ghi `status=429`, `client=ratelimit-test`, `details=request_rate_limited`. Như vậy đã xác nhận HTTP 429 đến client và nguyên nhân rate limiting. Prometheus hiện chưa có series downstream tách riêng mã 429, nên không dùng counter upstream/rate-limit để khẳng định số HTTP 429 chính xác ở phía client.

### 2.4. Trạng thái O2

**Checkpoint autoscaling đã bàn giao được:** Prometheus URL, tên metric, PromQL, labels thực tế và bằng chứng vLLM thay đổi theo tải. vLLM (1/1), DCGM (2/2) và bốn target Gateway đều `UP`. KEDA/ScaledObject chưa có trên cluster tại lúc kiểm tra, nên phần KEDA metrics thuộc giai đoạn tích hợp sau.

**O2 chưa nghiệm thu toàn bộ:** còn thiếu bằng chứng hai replica vLLM đồng thời. Khi thử `minReplicas=maxReplicas=2`, Pod thứ hai `Pending`; scheduler báo một node thiếu `nvidia.com/gpu`, node còn lại không khớp node affinity của PV `local-path` chứa model. Đã trả InferenceService về `minReplicas=maxReplicas=1`; Pod gốc tiếp tục `Running`, Pod `Pending` đã được xóa. Cluster hiện chỉ có StorageClass `local-path`, nên cần thêm backend RWX, di chuyển model sang PVC mới và xác nhận hai Pod Ready trước khi đánh dấu O2 hoàn tất theo đầy đủ spec.
