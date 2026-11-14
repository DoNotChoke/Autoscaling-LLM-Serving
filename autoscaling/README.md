# Số liệu: Autoscaling

## Ngưỡng

Ngưỡng concurrency = floor(0.75 × C max) = floor(0.75 × 8.5) = **6** request mỗi replica. C max lấy từ [sức chứa 1 replica](../serving/kserve/README.md).

## Kịch bản S1–S6

`loadtest/scenarios/run-scenario.sh`, qua gateway, 2026-11-11. Thời gian tính từ lúc bắt đầu kịch bản.

| | Kịch bản | Kết quả | Đạt |
|---|---|---|---|
| S1 | Không tải 30 phút | Giữ 1 replica | ✓ |
| S2 | 9 request đồng thời (1.5 × ngưỡng), 10 phút | Quyết định scale +46 s, pod 2 Ready +123 s. 746 request, 0 lỗi, TTFT p95 3.7 s | ✓ |
| S3 | Dừng tải | Về 1 replica ở +618 s | ✓ |
| S4 | Rate dao động quanh ngưỡng, 20 phút | Scale lên +16 s, Ready +108 s, giữ 2 replica tới hết. 1,103 request, 0 lỗi | ✓ |
| S5 | Stream dài (2048 token) lúc scale xuống | Lên 2 ở +109 s, xuống 1 ở +958 s khi đang stream. 129 request, 0 lỗi | ✓ |
| S6 | Tắt Prometheus 5 phút | Fallback +31 s, lên 2 replica. Prometheus về thì hết fallback, về 1 ở +912 s | ✓ |

- Từ lúc tải tăng tới khi pod 2 nhận việc mất ~1.5–2 phút, phần lớn là cold start. Trong khoảng này TTFT p95 vượt SLO.
- Đo trước khi có cache compile và Image Volume, nên thời gian Ready hiện tại ngắn hơn ~20 s.
