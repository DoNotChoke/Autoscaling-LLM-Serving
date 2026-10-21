# Danh mục model

| Model | Repo HF | Revision | Định dạng | Kích thước | PVC | Đường dẫn trong pod |
|---|---|---|---|---|---|---|
| `llama31-8b` | `meta-llama/Llama-3.1-8B-Instruct` (gated) | `0e9e39f249a16976918f6564b8830bc894c89659` | BF16 safetensors | 15 GB (4 shard) | `model-llama31-8b` | `/mnt/models/current` |

Job bỏ qua thư mục `original/` (checkpoint định dạng Meta, vLLM không dùng).

## Tải / kiểm tra model

```bash
kubectl create namespace llm-serving                                                  # 1 lần, trước khi tạo Secret
kubectl -n llm-serving create secret generic hf-token --from-literal=token=$HF_TOKEN   # 1 lần
kubectl apply -k serving/models
kubectl -n llm-serving wait --for=condition=complete job/download-llama31-8b --timeout=30m
kubectl -n llm-serving logs job/download-llama31-8b | tail -3

# Chạy lại = verify checksum (Job là immutable nên phải xoá trước)
kubectl -n llm-serving delete job download-llama31-8b && kubectl apply -k serving/models
```

Nâng revision: sửa `HF_REVISION` trong `llama31-8b/download-job.yaml`, xoá Job rồi apply lại. `current` chỉ đổi sang revision mới khi tải xong. Revision cũ vẫn nằm trên PVC, cần dọn tay.

> ⚠ Xoá PVC `model-llama31-8b` là **xoá luôn weights** (reclaim policy `Delete` của `local-path`).

## Tên metric vLLM (vLLM 0.31.0, kiểm tra ở T5)

| Vai trò | Tên metric |
|---|---|
| Request đang chạy | `vllm:num_requests_running` (gauge) |
| Request đang chờ | `vllm:num_requests_waiting` (gauge) |
| KV cache usage | `vllm:kv_cache_usage_perc` (gauge, 0–1) |
| TTFT histogram | `vllm:time_to_first_token_seconds` (histogram, dùng `_bucket`) |

## Tham số engine (RTX 4090 24 GB, BF16)

| Tham số | Giá trị | Kết quả đo ở T5 |
|---|---|---|
| `--max-model-len` | 16384 | Tăng từ 8192 (2026-10-21): hội thoại dài trong Open WebUI vượt 8K. KV cache 36.752 token vẫn chứa được 2 request dài tối đa |
| `--gpu-memory-utilization` | 0.90 | VRAM dùng 21.1 / 24.5 GB; weights + non-torch 15.25 GiB |
| `--shutdown-timeout` | 90 | Bắt buộc để không cắt request khi pod tắt (mặc định 0 = huỷ) |
| `--enable-auto-tool-choice`, `--tool-call-parser=llama3_json`, `--chat-template=...tool_chat_template_llama3.1_json.jinja` | | Bật tool calling (function calling). Thiếu thì request có `tools` + `tool_choice: auto` (ví dụ từ Open WebUI) nhận lỗi 400 |
| KV cache | (tự tính) | 4.49 GiB, 36.736 token: khoảng 2,2 request song song ở 16K context (request ngắn thì nhiều hơn) |
| Thời gian | | Load weights 15 s; init engine (profile, KV, compile) 45 s; Ready sau ~140 s tính từ lúc tạo pod |
