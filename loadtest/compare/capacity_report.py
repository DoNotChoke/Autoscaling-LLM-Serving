# Bảng sức chứa 1 replica từ kết quả `bench.sh` (r<rate>.json của vllm bench serve) và ngưỡng scale suy ra.
# Usage: capacity_report.py <thư mục chứa r*.json> [--goodput-min 0.95] [--headroom 0.75]
import argparse
import json
import math
from pathlib import Path


def load(directory):
    runs = []
    for path in Path(directory).glob("r*.json"):
        d = json.loads(path.read_text(encoding="utf-8"))
        runs.append(d)
    return sorted(runs, key=lambda d: float(d["request_rate"]))


def goodput_ratio(d):
    # request_goodput chỉ có khi chạy với --goodput; tính trên số request hoàn thành
    if d.get("request_goodput") is None or not d.get("request_throughput"):
        return None
    return d["request_goodput"] / d["request_throughput"]


def analyze(runs, goodput_min=0.95, headroom=0.75):
    """(rate_max, e2e_mean_s, c_max, threshold); rate_max None nếu không mức nào đạt goodput_min"""
    ok = [d for d in runs if (goodput_ratio(d) or 0) >= goodput_min and d.get("failed", 0) == 0]
    if not ok:
        return None, None, None, None
    best = max(ok, key=lambda d: float(d["request_rate"]))
    rate_max = float(best["request_rate"])
    e2e = best["mean_e2el_ms"] / 1000
    c_max = rate_max * e2e
    return rate_max, e2e, c_max, max(1, math.floor(headroom * c_max))


def fmt(v, digits=0):
    return "–" if v is None else f"{v:,.{digits}f}"


def report(runs, goodput_min=0.95, headroom=0.75):
    lines = ["| Rate (req/s) | Hoàn thành | Lỗi | Throughput (req/s) | Goodput | TTFT p50 / p95 / p99 (ms) "
             "| TPOT p50 / p95 (ms) | E2E mean (s) | Output tok/s |",
             "|---|---|---|---|---|---|---|---|---|"]
    for d in runs:
        g = goodput_ratio(d)
        lines.append(
            f"| {d['request_rate']} | {d['completed']} | {d.get('failed', 0)} | {fmt(d['request_throughput'], 2)} "
            f"| {'–' if g is None else f'{g:.0%}'} "
            f"| {fmt(d.get('p50_ttft_ms'))} / {fmt(d.get('p95_ttft_ms'))} / {fmt(d.get('p99_ttft_ms'))} "
            f"| {fmt(d.get('p50_tpot_ms'), 1)} / {fmt(d.get('p95_tpot_ms'), 1)} "
            f"| {fmt(d['mean_e2el_ms'] / 1000, 2)} | {fmt(d['output_throughput'])} |")
    rate_max, e2e, c_max, threshold = analyze(runs, goodput_min, headroom)
    lines.append("")
    if rate_max is None:
        lines.append(f"**Không mức nào đạt goodput ≥ {goodput_min:.0%} và 0 lỗi**: hạ dải rate rồi đo lại.")
    else:
        lines += [f"- `rate_max` = **{rate_max} req/s** (rate cao nhất có goodput ≥ {goodput_min:.0%}, 0 lỗi)",
                  f"- `C_max` ≈ {rate_max} × {e2e:.2f} s = **{c_max:.2f}** request đồng thời",
                  f"- `threshold` = max(1, floor({headroom} × C_max)) = **{threshold}**"]
    lines += ["", "Giả định: goodput theo SLO đặt lúc chạy `bench.sh` (`--goodput`); tải Poisson ổn định trong mỗi mức "
              "nên áp dụng được định luật Little; E2E mean lấy ở mức `rate_max`; ngưỡng là số request "
              "(running + waiting) trung bình mỗi replica, đúng đại lượng trigger `concurrency` đang đo."]
    return "\n".join(lines)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("directory")
    parser.add_argument("--goodput-min", type=float, default=0.95)
    parser.add_argument("--headroom", type=float, default=0.75)
    args = parser.parse_args()
    print(report(load(args.directory), args.goodput_min, args.headroom))
