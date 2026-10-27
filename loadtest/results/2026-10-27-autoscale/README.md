# Autoscale 1 ↔ 2 (2026-10-27)

Ngưỡng 2 request/replica, min 1, max 2. Tải gọi thẳng Service `llama31-8b-predictor` bằng key nội bộ
(chưa có key loadtest qua gateway), mỗi request một kết nối mới. Prompt ~400 từ, output 256 token.

| # | Kết quả | Đạt? |
|---|---|---|
| S2 | 3 request song song từ 18:26:26. KEDA quyết định lên 2 sau 47 s, pod mới Ready sau 2 phút 4 s. 346 request, 0 lỗi. TTFT p95 1,29 s khi 1 replica, 0,67 s khi 2 replica. Hai pod nhận 114 / 134 request | Đạt |
| S3 | Hết tải lúc 18:36:32, về 1 replica lúc 18:46:35 (10 phút 2 s) | Đạt (≤ 15 phút) |

**Lần chạy trước đó** (17:54) loadgen giữ kết nối keep-alive: scale lên đúng giờ nhưng pod mới nhận 0 request, TTFT
không giảm (1,28 s → 1,34 s). Service ClusterIP chỉ chia tải theo kết nối, nên kết nối mở trước khi scale vẫn ở pod cũ.
Gateway cũng đi qua ClusterIP và Envoy giữ kết nối lâu, nên có thể bị y như vậy (ADR 0002, phần Hệ quả).

Các file: `timeline.csv` (mỗi 15 s), `requests.csv` (từng request), `summary.txt`.
