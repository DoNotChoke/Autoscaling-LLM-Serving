# Số liệu: Model storage (OCI image)

So với cách cũ là copy model vào hostPath `/opt/models` trên từng node. 2026-11-13.

## Cold start

PodScheduled → Ready.

| | Thời gian |
|---|---|
| hostPath (cũ) | 59 s |
| Image Volume, image đã có trên node | 59–60 s |
| Image Volume, image chưa có trên node | 135 s (pull 74 s) |

Pre-pull DaemonSet giữ image trên mọi node GPU, nên lúc scale luôn rơi vào trường hợp đã có image.

## Đĩa và thời gian đóng gói

| | Giá trị |
|---|---|
| Tổng đĩa trước (hostPath) | 10.8 GB |
| Tổng đĩa sau | ~14.6 GB (registry 4.6 GB + ~5 GB mỗi node) |
| Mỗi node khi chưa bật `discard_unpacked_layers` | ~10 GB (giữ cả bản nén lẫn bản giải nén) |
| Đóng gói + push (`package-model.sh`) | 309 s |
