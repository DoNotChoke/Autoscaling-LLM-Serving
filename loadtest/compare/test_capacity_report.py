# python loadtest/compare/test_capacity_report.py
from capacity_report import analyze, report


def run(rate, goodput, e2e_ms=10000, failed=0):
    return {"request_rate": rate, "completed": 100, "failed": failed, "request_throughput": rate,
            "request_goodput": rate * goodput, "mean_e2el_ms": e2e_ms, "output_throughput": 100}


# Đạt tới 1.0 req/s, 1.5 tụt goodput: rate_max 1.0, C_max = 1.0 × 10 s = 10, threshold floor(7.5) = 7
assert analyze([run(0.5, 1.0), run(1.0, 0.96), run(1.5, 0.80)]) == (1.0, 10.0, 10.0, 7)
# Biên: đúng 95% vẫn tính là đạt
assert analyze([run(2.0, 0.95, e2e_ms=4000)])[0] == 2.0
# Có lỗi thì không tính là đạt dù goodput cao
assert analyze([run(0.5, 1.0), run(1.0, 1.0, failed=3)])[0] == 0.5
# Không mức nào đạt
assert analyze([run(0.5, 0.5)]) == (None, None, None, None)
# C_max nhỏ vẫn cho ngưỡng tối thiểu 1
assert analyze([run(0.25, 1.0, e2e_ms=2000)])[3] == 1
# Thiếu request_goodput (chạy không có --goodput) thì coi như không đạt
assert analyze([{**run(1.0, 1.0), "request_goodput": None}])[0] is None
assert "Không mức nào đạt" in report([run(0.5, 0.5)])
print("OK")
