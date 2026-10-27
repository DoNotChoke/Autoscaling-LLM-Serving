# Runbook: Đặt model lên các node GPU

Mỗi node GPU giữ một bản model ở **cùng đường dẫn** `/opt/models/<model>`. InferenceService mount thư mục này
bằng `hostPath`, nên pod chạy được trên bất kỳ node nào đã có model. Không dùng PVC `local-path`: volume chỉ
nằm trên node tạo ra nó, replica ở node khác bị Pending.

| Model | Thư mục | Nhãn node |
|---|---|---|
| llama31-8b (AWQ INT4, 5,4 GB) | `/opt/models/llama31-8b` | `llm-serving/model-llama31-8b=true` |

Đã đặt trên 2 node `s12gbn3-system-product-name` và `ubuntu` (2026-10-27).

## Thêm model vào một node

```bash
# 1. Trên node mới (lần đầu, cần sudo): tạo thư mục, giao cho user thường
sudo install -d -o "$USER" -g "$USER" /opt/models

# 2. Từ node đã có model (ssh -A để dùng key của máy local)
rsync -a /opt/models/llama31-8b <user>@<ip-node-mới>:/opt/models/

# 3. Trên node mới: kiểm tra rồi gắn nhãn (kubectl chạy trên server)
cd /opt/models/llama31-8b && sha256sum -c SHA256SUMS
kubectl label node <node> llm-serving/model-llama31-8b=true
```

Pod chỉ xếp lên node có nhãn (`nodeSelector`). Gắn nhãn khi thư mục chưa có thì pod lỗi `hostPath type Directory`.

## Lưu ý

- Thư mục mount read-only; vLLM chạy `vllm serve /models`. Không mount vào `/mnt/models`: webhook KServe luôn tự
  thêm mount ở đó, trùng đường dẫn thì pod bị từ chối.
- Không có `storageUri` nên KServe gắn sidecar `agent`; probe phải ghi port bằng số (8000), port tên `http` làm agent
  lỗi và pod không bao giờ Ready.
- Node mới chưa có image vLLM (9 GB) mất ~20 phút để pull lần đầu. Pull trước khi rollout:
  `sudo k3s crictl pull vllm/vllm-openai:v0.31.0` trên node đó.
- Đổi bản model: chép sang thư mục mới (vd `llama31-8b-v2`) trên **mọi** node, kiểm tra checksum, rồi mới đổi
  `hostPath` trong InferenceService. Không ghi đè thư mục đang được pod đọc.
