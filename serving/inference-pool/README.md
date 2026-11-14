# Số liệu: EPP so với Service ClusterIP

Cùng config inference-perf, 2 replica cố định, qua gateway. ClusterIP là kube-proxy chia round-robin. 2026-11-12, mỗi bên 1 lần đo.

- Goodput: % request đạt cả TTFT ≤ 2 s và TPOT ≤ 100 ms.
- `a → b`: a là kết quả qua ClusterIP, b là qua EPP.

| Config | Rate (req/s) | TTFT p95 (s) | Goodput |
|---|---|---|---|
| shared-prefix-high | 0.5 | 1.65 → 0.38 | 94% → 100% |
| | 1.0 | 3.80 → 0.39 | 76% → 100% |
| | 1.5 | 19.23 → 0.59 | 30% → 96% |
| | 2.0 | 57.63 → 47.21 | 7% → 31% |
| shared-prefix-low | 0.25 | 1.79 → 3.12 | 100% → 82% |
| | 0.5 | 3.42 → 3.22 | 78% → 70% |
| prefill-heavy | 0.5 | 9.74 → 5.02 | 18% → 23% |
| decode-heavy | 1.0 | 0.35 → 0.38 | 97% → 100% |
| baseline-random | 2.5 | 2.09 → 2.57 | 92% → 90% |
| sharegpt | 5.0 | 0.62 → 0.77 | 100% → 98% |

- `shared-prefix-high`: 10 system prompt dài dùng chung. EPP route theo prefix nên cache trúng đúng pod, chịu được 1.5 req/s thay vì 0.5.
- Không có prefix dùng chung thì EPP ngang hoặc kém hơn chút.
- Chỉ 1 lần đo mỗi bên, chênh lệch dưới ±20% coi là nhiễu.
- Bỏ qua `burst-multistage` (goodput 36% → 99%): ở lần EPP, pod 2 tình cờ đã được scale lên trước khi burst tới.
