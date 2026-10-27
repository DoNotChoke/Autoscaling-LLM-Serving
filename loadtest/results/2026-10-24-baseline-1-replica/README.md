# Baseline 1 replica (2026-10-24)

Đo sức chứa của **một** replica để chọn ngưỡng trigger `concurrency` (ADR 0002).

| Mục | Giá trị |
|---|---|
| GPU | RTX 3060 12 GB, driver 595.99.02 (node `s12gbn3-system-product-name`) |
| Model | Llama-3.1-8B-Instruct **AWQ INT4** (served name `llama31-8b`) |
| vLLM | v0.31.0, `--gpu-memory-utilization=0.80`, `--max-model-len=16384`, KV cache 18.400 token |
| Tải | `loadtest/scenarios/bench.sh`: random 512 token vào / 256 token ra, `--ignore-eos`, 8 request mỗi mức concurrency (tối thiểu 16) |
| Đường đi | Gọi thẳng `localhost:8000` trong pod vLLM, **không qua gateway** |

## Kết quả

| Concurrency | Request | Lỗi | TTFT p50 | TTFT p95 | TPOT p95 | Throughput ra | KV cache max | Waiting max |
|---|---|---|---|---|---|---|---|---|
| 1 | 16 | 0 | 318 ms | 350 ms | 15,9 ms | 59 tok/s | 0,04 | 0 |
| 2 | 16 | 0 | 45 ms | 53 ms | 16,5 ms | 121 tok/s | 0,08 | 0 |
| 4 | 32 | 0 | 211 ms | 1.282 ms | 21,1 ms | 201 tok/s | 0,16 | 0 |
| 8 | 64 | 0 | 1.715 ms | 2.420 ms | 27,4 ms | 280 tok/s | 0,33 | 3 |
| 16 | 128 | 0 | 2.950 ms | 3.896 ms | 39,5 ms | 381 tok/s | 0,67 | 11 |
| 32 | 256 | 0 | 5.245 ms | 8.839 ms | 106,3 ms | 340 tok/s | 1,00 | 27 |

File thô: `c<N>.json` (output của `vllm bench serve`), `kv_c<N>.txt` (mẫu `/metrics` mỗi 2s).

## Nhận xét

- Throughput bão hoà ở ~16 request song song (~380 tok/s). Ở 32, KV cache đầy 100% và throughput giảm.
- TTFT xấu đi trước khi KV cache đầy: từ concurrency 8 đã có request chờ dù KV cache mới 33%. Nghi do giới hạn số token prefill mỗi bước (`--max-num-batched-tokens`); chưa kiểm chứng.
- TTFT ở concurrency 1 (318 ms) cao hơn concurrency 2 (45 ms), khả năng do warm-up các request đầu.

## Ngưỡng suy ra

| SLO TTFT p95 | C_max | Target `concurrency` (× 0,75) |
|---|---|---|
| 1 s (SPEC) | 2 | 1,5 → 2 |
| 2 s (team-tasks) | 4 | 3 |

**Chưa chốt**: SLO đang để tạm 1 s; cần đo lại qua gateway trước khi chốt ngưỡng.
