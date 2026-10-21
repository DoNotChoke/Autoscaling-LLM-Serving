# Runbook: Serving Llama-3.1-8B bằng KServe + vLLM

Yêu cầu trước: cluster theo [`cluster-setup.md`](cluster-setup.md), và model đã nằm trên PVC theo [`serving/models/models.md`](../../serving/models/models.md).

| Thành phần | Phiên bản |
|---|---|
| cert-manager | v1.21.2 |
| KServe | v0.21.0 (chart `kserve-crd` + `kserve-resources`, `deploymentMode: Standard`) |
| vLLM | v0.31.0 (`vllm/vllm-openai`) |

## Cài đặt

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# cert-manager (KServe dùng cho webhook)
helm repo add jetstack https://charts.jetstack.io --force-update
helm upgrade --install cert-manager jetstack/cert-manager --version v1.21.2 \
  -n cert-manager --create-namespace --set crds.enabled=true --wait

# KServe
helm upgrade --install kserve-crd oci://ghcr.io/kserve/charts/kserve-crd --version v0.21.0 \
  -n kserve --create-namespace --wait
helm upgrade --install kserve-resources oci://ghcr.io/kserve/charts/kserve-resources --version v0.21.0 \
  -n kserve -f platform/kserve/values.yaml --wait

# API key cho vLLM (1 lần; không commit)
kubectl -n llm-serving create secret generic vllm-api-key --from-literal=key="$(openssl rand -hex 24)"

# Runtime + InferenceService
kubectl apply -k serving/kserve --dry-run=server --validate=strict   # kiểm tra trước
kubectl apply -k serving/kserve
kubectl -n llm-serving wait --for=condition=Ready isvc/llama31-8b --timeout=15m
```

## Gọi thử

```bash
KEY=$(kubectl -n llm-serving get secret vllm-api-key -o jsonpath='{.data.key}' | base64 -d)
kubectl -n llm-serving port-forward svc/llama31-8b-predictor 8000:80 &
./serving/tests/smoke.sh http://localhost:8000 "$KEY"
# PASS models / PASS stream / PASS no-key

curl -s localhost:8000/v1/chat/completions -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"model":"llama31-8b","messages":[{"role":"user","content":"Xin chào"}]}'
```

`/metrics` và `/health` không cần key; `/v1/*` thì cần.

### Gọi từ máy local bằng OpenAI SDK

```bash
# Trên VM: port-forward Service (giữ chạy)
kubectl -n llm-serving port-forward svc/llama31-8b-predictor 8000:80
# Trên máy local: SSH tunnel
ssh -p <port> -N -L 8000:localhost:8000 root@<host>

# Máy local (Windows: py -3.13 -m venv .venv; .venv\Scripts\activate)
python -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt
export VLLM_API_KEY=<key>          # PowerShell: $env:VLLM_API_KEY="<key>"
python serving/tests/chat.py "Giải thích Kubernetes trong 3 câu"
# ... câu trả lời stream ...
# TTFT 0.71s · tổng 3.92s · prompt 47 tok · sinh 177 tok (55.2 tok/s)
```

Có thể đổi endpoint bằng `--base-url` hoặc biến `VLLM_BASE_URL`, đổi model bằng `--model`, đổi độ dài trả lời bằng `--max-tokens`.

## Số đo (RTX 4090, 2026-10-21)

| Mục | Kết quả |
|---|---|
| Cold start (Scheduled → Ready), weights đã có trên PVC | **130 s** (load weights 15 s; profile, compile, KV cache ~45 s; còn lại là khởi động container và các probe) |
| Xoá pod khi đang stream 1500 token | Stream **hoàn tất** (1501 chunk + `[DONE]`); pod tắt sau 26 s |
| 32 request đồng thời liên tục 150 s (max_tokens 512) | 495 request, **0 lỗi**, 0 restart, 0 lần liveness fail |
| VRAM | ~21 / 24.5 GB (`--gpu-memory-utilization 0.90`) |

## Cấu hình vòng đời pod (trong `inferenceservice.yaml`)

| Thiết lập | Giá trị | Lý do |
|---|---|---|
| `startupProbe` `/health` | 10 s × 60 | Cho tối đa 10 phút để load model |
| `readinessProbe` `/health` | mỗi 10 s | Chỉ nhận traffic khi engine sẵn sàng |
| `livenessProbe` `/health` | 30 s, timeout 10 s, × 5 | Không giết pod chỉ vì `/health` chậm khi tải nặng |
| `preStop: sleep 15` | 15 s | Chờ endpoint bị gỡ khỏi Service trước khi tắt |
| `--shutdown-timeout=90` | 90 s | **Bắt buộc**: mặc định `0` làm vLLM huỷ request đang chạy khi nhận SIGTERM |
| `terminationGracePeriodSeconds` | 120 | > 15 + 90 |
| `deploymentStrategy: Recreate` | | Chỉ có 1 GPU; pod mới chờ pod cũ nhả GPU |

## Kiểm tra vòng đời (chạy lại khi đổi runtime, probe hoặc phiên bản)

- [ ] **Cold start**: `kubectl -n llm-serving delete pod -l serving.kserve.io/inferenceservice=llama31-8b`, rồi đo `PodScheduled` → `Ready` (≤ 3 phút)
- [ ] **Graceful shutdown**: gửi stream dài (`max_tokens: 1500, ignore_eos: true`), sau 5 s thì xoá pod → stream phải kết thúc bằng `[DONE]`, `finish_reason: length`
- [ ] **Tải nặng**: ≥ 32 request song song trong ≥ 2 phút → `restartCount = 0`, không có event `Liveness probe failed`
- [ ] **Smoke**: `serving/tests/smoke.sh` pass

> Với 1 replica, **request mới** gửi tới trong lúc pod đang tắt hoặc khởi động sẽ lỗi (không có replica khác). Cần ≥ 2 replica hoặc gateway retry để tránh.

## Sự cố thường gặp

| Triệu chứng | Nguyên nhân / Cách xử lý |
|---|---|
| Pod mới `Pending`, event `Insufficient nvidia.com/gpu` | Pod cũ chưa nhả GPU (đang trong grace period). Chờ; hoặc kiểm tra còn pod khác (ví dụ `vllm-dev`) đang giữ GPU |
| `Startup probe failed: connection refused` vài lần đầu | Bình thường khi vLLM đang load model |
| Pod `CrashLoopBackOff`, log `CUDA out of memory` | Giảm `--max-model-len` hoặc `--gpu-memory-utilization`; kiểm tra không có process khác dùng GPU (`nvidia-smi`) |
| Stream bị cắt khi xoá hoặc rollout pod | Thiếu `--shutdown-timeout`, hoặc `terminationGracePeriodSeconds` quá nhỏ |
| HPA `llama31-8b-predictor` báo `FailedGetResourceMetric` | HPA do KServe tạo theo CPU khi `minReplicas = maxReplicas = 1`; vô hại, sẽ thay bằng KEDA |
| `/v1/models` trả về 401 | Thiếu header `Authorization: Bearer <key>`; key nằm trong Secret `vllm-api-key` |

## Debug nhanh với Deployment thường

`serving/dev/vllm-deployment.yaml` chạy vLLM không qua KServe (cùng PVC, cùng image). Chỉ dùng khi cần khoanh vùng lỗi, và phải **xoá InferenceService trước** vì chỉ có 1 GPU.
