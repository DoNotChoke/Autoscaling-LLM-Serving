# python loadtest/compare/test_ip_report.py
import json
import tempfile
from pathlib import Path

from ip_report import compare, load, table


def stage(rate, achieved, ok, fail, goodput, ttft_p95, tpot_p95, otps):
    # Rút gọn từ stage_N_lifecycle_metrics.json thật, chỉ giữ key ip_report đọc
    lat = lambda p50, p95: {"median": p50, "p95": p95}
    return {"load_summary": {"requested_rate": rate, "achieved_rate": achieved},
            "successes": {"count": ok,
                          "latency": {"time_to_first_token": lat(ttft_p95 / 2, ttft_p95),
                                      "time_per_output_token": lat(tpot_p95 / 2, tpot_p95),
                                      "request_latency": lat(5.0, 8.0)},
                          "throughput": {"output_tokens_per_sec": otps},
                          "goodput_metrics": {"goodput_percentage": goodput}},
            "failures": {"count": fail}}


def write(root, config, stages):
    d = Path(root) / config / "report"
    d.mkdir(parents=True)
    for i, s in enumerate(stages):
        (d / f"stage_{i}_lifecycle_metrics.json").write_text(json.dumps(s))
    (d / "summary_lifecycle_metrics.json").write_text("{}")  # không phải stage, phải bị bỏ qua


with tempfile.TemporaryDirectory() as a, tempfile.TemporaryDirectory() as b:
    write(a, "shared-prefix-high", [stage(0.5, 0.48, 90, 0, 100.0, 0.6, 0.04, 120),
                                    stage(1.5, 1.40, 260, 10, 70.0, 2.8, 0.09, 330)])
    write(a, "decode-heavy", [stage(0.25, 0.24, 45, 0, 100.0, 0.5, 0.03, 250)])
    write(b, "shared-prefix-high", [stage(0.5, 0.49, 90, 0, 100.0, 0.5, 0.04, 121),
                                    stage(1.5, 1.45, 270, 0, 98.0, 1.12, 0.06, 360)])

    rows = load(a)
    # Khoá (config, stage); stage sắp theo số, không theo chuỗi
    assert sorted(rows) == [("decode-heavy", 0), ("shared-prefix-high", 0), ("shared-prefix-high", 1)]
    r = rows[("shared-prefix-high", 1)]
    assert (r["rate"], r["achieved"], r["ok"], r["fail"], r["goodput"]) == (1.5, 1.40, 260, 10, 70.0)
    assert (r["ttft_p95"], r["tpot_p95"], r["otps"]) == (2.8, 0.09, 330)

    t = table(rows)
    assert "| shared-prefix-high | 1.5 / 1.40 | 260 / 10 | 70% |" in t, t
    assert "2.80" in t and "90" in t  # TTFT p95 2,80 s; TPOT p95 90 ms

    c = compare(load(a), load(b))
    # TTFT p95 2,8 → 1,12 s = -60%; goodput 70 → 98 = +28 điểm %; throughput 330 → 360 = +9%
    assert "| shared-prefix-high | 1.5 | 2.80 → 1.12 (-60%) |" in c, c
    assert "70% → 98% (+28)" in c and "330 → 360 (+9%)" in c, c
    # Chỉ so stage có ở cả hai bên
    assert "decode-heavy" not in c

    try:
        load(tempfile.gettempdir() + "/khong-ton-tai-ip-report")
    except SystemExit:
        pass
    else:
        raise AssertionError("thư mục không có report phải báo lỗi")
print("OK")
