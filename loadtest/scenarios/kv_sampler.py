"""Ghi KV cache usage, số request running/waiting của vLLM mỗi 2s (dùng cùng bench.sh)."""
import time
import urllib.request

URL = "http://localhost:8000/metrics"


def value(lines, prefix):
    return next(line.split()[-1] for line in lines if line.startswith(prefix))


while True:
    try:
        lines = urllib.request.urlopen(URL, timeout=5).read().decode().splitlines()
        kv = value(lines, "vllm:kv_cache_usage_perc")
        running = value(lines, "vllm:num_requests_running")
        waiting = value(lines, "vllm:num_requests_waiting{")
        print(f"{time.time():.0f} kv={kv} running={running} waiting={waiting}", flush=True)
    except Exception as e:  # pod đang bận hoặc vừa restart: ghi lại rồi thử tiếp
        print("err", e, flush=True)
    time.sleep(2)
