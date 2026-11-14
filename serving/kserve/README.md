# Số liệu: vLLM 1 replica

## Sức chứa

`loadtest/scenarios/bench.sh capacity` trên node-1, 2026-11-10. Input 512 / output 256 token (±30%), tải Poisson. SLO: TTFT ≤ 2 s, TPOT ≤ 100 ms.

| Rate (req/s) | Đạt (req/s) | Goodput | TTFT p50 / p95 (ms) | TPOT p50 / p95 (ms) | E2E TB (s) |
|---|---|---|---|---|---|
| 0.5 | 0.49 | 100% | 353 / 493 | 19 / 27 | 5.5 |
| 0.75 | 0.73 | 100% | 388 / 687 | 24 / 34 | 6.8 |
| 1.0 | 0.97 | 100% | 430 / 996 | 31 / 46 | 8.5 |
| 1.25 | 1.22 | 92% | 499 / 2,559 | 43 / 77 | 12.9 |
| 1.5 | 1.37 | 30% | 4,559 / 10,748 | 74 / 88 | 23.2 |
| 2.0 | 1.38 | 12% | 36,676 / 70,024 | 77 / 87 | 55.1 |

- Rate tối đa giữ goodput ≥ 95%: **1.0 req/s**. Node-2 đạt 1.25 req/s; lấy node-1 vì yếu hơn.
- Bão hòa ở ~1.4 req/s, vượt mức này hàng chờ tăng mãi.
- C max = 1.0 × 8.49 s ≈ **8.5** request đồng thời (định luật Little). Ngưỡng scale suy ra từ đây, xem [autoscaling](../../autoscaling/README.md).

## Cold start và cache compile

Xóa pod trên từng node, đo pod thay thế từ PodScheduled → Ready (`coldstart_breakdown.sh`), 2026-11-12.

| | node-1 | node-2 | torch.compile | CUDA graph |
|---|---|---|---|---|
| Không cache | 81 / 77 s | 81 / 80 s | 12–13 s | ~28 s |
| Cache ấm | 59 / 58 s | 60 / 60 s | ~1 s | ~27 s |

Giảm 79 → 59 s. Cache chiếm 26 MB mỗi node. Phần còn lại chủ yếu là CUDA graph (~27 s) và import Python (~13 s).
