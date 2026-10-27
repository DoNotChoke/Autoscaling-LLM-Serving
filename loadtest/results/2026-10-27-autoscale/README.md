# Autoscale 1 ↔ 2, lần chạy đầu (2026-10-27)

Ngưỡng 2 request/replica, min 1, max 2. Tải gọi thẳng Service `llama31-8b-predictor` bằng key nội bộ
(chưa có key loadtest qua gateway). Prompt ~400 từ, output 256 token.

| # | Kết quả | Đạt? |
|---|---|---|
| S2 | 3 request song song từ 17:54:25. KEDA quyết định lên 2 sau 47 s, pod mới Ready sau 2 phút 4 s. 315 request, 0 lỗi | Lên 2 trong ≤ 5 phút: đạt. TTFT: chưa đạt, xem bên dưới |
| S3 | Hết tải lúc 18:04:33, về 1 replica lúc 18:14:52 (10 phút 19 s) | Đạt (≤ 15 phút) |

**Pod mới không nhận request.** Trong S2, pod thứ 2 nhận 0 request (`vllm:request_success_total`), nên TTFT p95
trước và sau khi scale gần như giống nhau (1,28 s và 1,34 s). Bản loadgen lúc đó giữ kết nối keep-alive; Service
ClusterIP chỉ chia tải theo kết nối, nên 3 kết nối mở từ trước khi scale vẫn ở pod cũ.

Đã sửa loadgen để mỗi request mở kết nối mới, cần chạy lại S2. Gateway cũng đi qua ClusterIP và Envoy giữ kết nối
lâu, nên có thể gặp đúng vấn đề này với người dùng thật (xem ADR 0002, phần Hệ quả).

Các file: `timeline.csv` (mỗi 15 s), `requests.csv` (từng request), `summary.txt`.
