# Runbook: Autoscale vLLM bằng KEDA

Thiết kế và lý do chọn metric, ngưỡng: [ADR 0002](../adr/0002-autoscaling.md).

```
vLLM /metrics ─► Prometheus (recording rule llm_serving:vllm_concurrency:sum) ─► KEDA ─► HPA keda-hpa-llama31-8b ─► Deployment llama31-8b-predictor
```

| Thành phần | Phiên bản | Namespace | Manifest |
|---|---|---|---|
| KEDA | 2.21.0 | `keda` | `platform/keda/values.yaml` |
| ScaledObject `llama31-8b` | | `llm-serving` | `autoscaling/scaledobjects/` |
| PDB `llama31-8b` | | `llm-serving` | `autoscaling/pdb/` |

Yêu cầu trước:
- 2 replica chạy được trên 2 node ([`model-on-nodes.md`](model-on-nodes.md)).
- Prometheus của observability đang chạy, có recording rule `llm_serving:vllm_concurrency:sum` ([`observability.md`](observability.md)).

## 1. Cài KEDA

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
helm upgrade --install keda https://kedacore.github.io/charts/keda-2.21.0.tgz \
  -n keda --create-namespace -f platform/keda/values.yaml --wait
kubectl -n keda get pod                                   # 3 pod Running
kubectl get apiservice v1beta1.external.metrics.k8s.io    # AVAILABLE True
```

Lần đầu `keda-operator` có thể restart 1 lần trong lúc tạo cert, không sao.

## 2. Chế độ quan sát (min = max = 2)

Thứ tự bắt buộc: InferenceService trước, ScaledObject sau. Nếu làm ngược, webhook KEDA từ chối vì Deployment còn
HPA CPU của KServe.

```bash
# Kiểm tra Prometheus trả số trước
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090 &
curl -s 'localhost:9090/api/v1/query' --data-urlencode \
  'query=sum(llm_serving:vllm_concurrency:sum{namespace="llm-serving",model_name="llama31-8b"})'

# 1. Thêm annotation serving.kserve.io/autoscalerClass: external vào InferenceService → KServe xoá HPA của nó.
#    KServe chép annotation ISVC xuống pod template nên 2 pod có thể restart lần lượt (RollingUpdate, luôn còn 1 pod)
kubectl apply -f serving/kserve/models/llama31-8b/inferenceservice.yaml
kubectl -n llm-serving get hpa                            # không còn llama31-8b-predictor

# 2. PDB + ScaledObject
kubectl apply -k autoscaling/pdb
kubectl apply -k autoscaling/scaledobjects
kubectl -n llm-serving get scaledobject llama31-8b        # READY True, ACTIVE theo tải
kubectl -n llm-serving get hpa keda-hpa-llama31-8b        # TARGETS có số, không phải <unknown>
```

Nghiệm thu: để chạy ít nhất 1 ngày, đối chiếu `hpa_desired` (`loadtest/scenarios/watch.sh`) với tải thật. Số replica
HPA muốn phải hợp lý, không nhảy lên xuống liên tục.

## 3. Bật autoscale 1 ↔ 2

Sửa `minReplicaCount: 1` trong `autoscaling/scaledobjects/llama31-8b.yaml`, chốt `threshold` theo SLO (ADR 0002 mục 3),
rồi `kubectl apply -k autoscaling/scaledobjects`. Không tải thì sau khoảng 10 phút còn 1 replica.

## 4. Kịch bản kiểm thử S1–S6

```bash
# Key riêng cho loadtest qua gateway (rate limit 100k token/phút/key là đủ)
bash serving/gateway/api-key.sh add loadtest              # in ra key
kubectl -n llm-serving create secret generic loadtest-api-key --from-literal=key=<key vừa in>

bash loadtest/scenarios/run-scenario.sh S2                # S1..S6; TARGET=<threshold> nếu khác 3
```

| # | Thời gian | Làm gì | Đạt khi |
|---|---|---|---|
| S1 | 30 phút | Không tải | Luôn 1 replica |
| S2 | 10 phút | `1,5 × target` request đồng thời | Lên 2 trong ≤ 5 phút, TTFT p95 về dưới SLO |
| S3 | 20 phút | Chạy ngay sau S2, không tải | Về 1 trong ≤ 15 phút |
| S4 | 20 phút | Dao động `target ± 1` mỗi phút | ≤ 2 lần đổi số replica |
| S5 | 25 phút | Lên 2, rồi 1 stream dài liên tục | Scale xuống trong lúc stream, `requests.csv` 0 lỗi |
| S6 | 20 phút | NetworkPolicy chặn KEDA → Prometheus 5 phút | Condition `Fallback` True, 2 replica |

Kết quả ở `loadtest/results/<ngày>-autoscale/<S>/`:
- `timeline.csv`: mỗi 15 s ghi số replica, quyết định của HPA, giá trị metric, fallback.
- `requests.csv`: mỗi request một dòng, gồm TTFT và lỗi.
- `summary.txt`: TTFT p50/p95 và số lỗi theo từng đoạn.

Chụp Grafana cùng khoảng thời gian.

- Tải chạy bằng Job `loadgen-s<n>` dùng image vLLM có sẵn trên node, không xin GPU. Script tự xoá Job khi xong hoặc khi Ctrl-C.
- S6 không tắt Prometheus. Grafana và Alloy vẫn đọc được, nên dashboard vẫn ghi lại lúc mất metric.
  Trước khi chạy S6, kiểm tra NetworkPolicy có thật sự chặn được không:
  `kubectl -n keda logs deploy/keda-operator | grep -i prometheus` phải thấy lỗi kết nối trong lúc chặn.

## Sự cố thường gặp

| Triệu chứng | Nguyên nhân / Cách xử lý |
|---|---|
| Apply ScaledObject bị từ chối: `already managed by the hpa` | InferenceService chưa có `autoscalerClass: external`: apply lại ISVC, chờ HPA `llama31-8b-predictor` biến mất |
| HPA `TARGETS <unknown>` | KEDA không gọi được Prometheus: kiểm tra pod Prometheus chạy, `kubectl -n keda logs deploy/keda-operator` |
| Metric luôn 0 dù có tải | Recording rule chưa có hoặc sai label: chạy query ở bước 2 |
| Scale lên nhưng pod mới Pending | Node kia chưa có model hoặc nhãn: [`model-on-nodes.md`](model-on-nodes.md) |
| Pod mới mất ~20 phút | Node chưa có image vLLM: `sudo k3s crictl pull vllm/vllm-openai:v0.31.0` trước |

## Gỡ

```bash
kubectl delete -k autoscaling/scaledobjects               # KEDA xoá HPA của nó, số replica giữ nguyên
# Bỏ annotation autoscalerClass trong InferenceService rồi apply: KServe tạo lại HPA theo min/maxReplicas
helm uninstall keda -n keda
```
