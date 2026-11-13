# Bảng kết quả inference-perf theo config × stage, và so sánh hai lần đo (A/B).
# Usage: ip_report.py <thư mục>
#        ip_report.py <thư mục A> <thư mục B>   (so B với A)
# Đọc <thư mục>/**/<config>/report/stage_N_lifecycle_metrics.json của inference-perf v0.7.0
import argparse
import json
import re
import sys
from pathlib import Path

STAGE = re.compile(r"stage_(\d+)_lifecycle_metrics\.json$")


def load(directory):
    """{(config, stage): số liệu}; config = tên thư mục chứa report/"""
    rows = {}
    for path in Path(directory).glob("**/report/stage_*_lifecycle_metrics.json"):
        m = STAGE.search(path.name)
        if not m:
            continue
        d = json.loads(path.read_text(encoding="utf-8"))
        s, lat = d["successes"], d["successes"]["latency"]
        rows[(path.parent.parent.name, int(m.group(1)))] = {
            "rate": d["load_summary"]["requested_rate"], "achieved": d["load_summary"]["achieved_rate"],
            "ok": s["count"], "fail": d["failures"]["count"],
            "goodput": (s.get("goodput_metrics") or {}).get("goodput_percentage"),
            "ttft_p50": lat["time_to_first_token"]["median"], "ttft_p95": lat["time_to_first_token"]["p95"],
            "tpot_p50": lat["time_per_output_token"]["median"], "tpot_p95": lat["time_per_output_token"]["p95"],
            "lat_p95": lat["request_latency"]["p95"], "otps": s["throughput"]["output_tokens_per_sec"],
        }
    if not rows:
        sys.exit(f"Không thấy report/stage_*_lifecycle_metrics.json trong {directory}")
    return dict(sorted(rows.items()))


def pct(v):
    return "–" if v is None else f"{v:.0f}%"


def table(rows):
    lines = ["| Config | Rate yêu cầu / đạt (req/s) | Thành công / lỗi | Goodput | TTFT p50 / p95 (s) "
             "| TPOT p50 / p95 (ms) | Latency p95 (s) | Output tok/s |", "|---|---|---|---|---|---|---|---|"]
    for (config, _), r in rows.items():
        lines.append(f"| {config} | {r['rate']} / {r['achieved']:.2f} | {r['ok']} / {r['fail']} | {pct(r['goodput'])} "
                     f"| {r['ttft_p50']:.2f} / {r['ttft_p95']:.2f} | {r['tpot_p50'] * 1000:.0f} / {r['tpot_p95'] * 1000:.0f} "
                     f"| {r['lat_p95']:.1f} | {r['otps']:.0f} |")
    return "\n".join(lines)


def change(a, b, fmt):
    """'a → b (±x%)'; chênh lệch tương đối theo a"""
    return f"{fmt(a)} → {fmt(b)} ({(b - a) / a * 100:+.0f}%)" if a else f"{fmt(a)} → {fmt(b)}"


def compare(rows_a, rows_b):
    lines = ["| Config | Rate (req/s) | TTFT p95 (s) | TPOT p95 (ms) | Goodput | Output tok/s | Lỗi |",
             "|---|---|---|---|---|---|---|"]
    for key in sorted(rows_a.keys() & rows_b.keys()):
        a, b = rows_a[key], rows_b[key]
        good = ("–" if a["goodput"] is None or b["goodput"] is None
                else f"{pct(a['goodput'])} → {pct(b['goodput'])} ({b['goodput'] - a['goodput']:+.0f})")  # điểm %
        lines.append(f"| {key[0]} | {a['rate']} | {change(a['ttft_p95'], b['ttft_p95'], '{:.2f}'.format)} "
                     f"| {change(a['tpot_p95'] * 1000, b['tpot_p95'] * 1000, '{:.0f}'.format)} | {good} "
                     f"| {change(a['otps'], b['otps'], '{:.0f}'.format)} | {a['fail']} → {b['fail']} |")
    return "\n".join(lines)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("dirs", nargs="+", metavar="dir")
    args = parser.parse_args()
    if len(args.dirs) == 1:
        print(table(load(args.dirs[0])))
    elif len(args.dirs) == 2:
        print(compare(load(args.dirs[0]), load(args.dirs[1])))
    else:
        parser.error("tối đa 2 thư mục")
