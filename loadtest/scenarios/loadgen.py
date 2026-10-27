# Giữ N request stream chạy song song theo từng đoạn thời gian, dùng cho run-scenario.sh
# Mỗi request in một dòng CSV ra stdout, cuối mỗi đoạn in tóm tắt ra stderr
# Usage: loadgen.py --profile 600:5,300:2 [--max-tokens 256] [--prompt-words 400]
#   profile: các đoạn <giây>:<số request song song>, 0 là nghỉ
# Env: BASE_URL (mặc định là gateway trong cluster), API_KEY, MODEL
import argparse
import asyncio
import json
import os
import statistics
import sys
import time

import aiohttp

BASE_URL = os.environ.get("BASE_URL", "http://llm-gateway-envoy.envoy-gateway-system.svc").rstrip("/")
API_KEY = os.environ["API_KEY"]
MODEL = os.environ.get("MODEL", "llama31-8b")


def parse_profile(text):
    segments = []
    for part in text.split(","):
        seconds, conc = part.split(":")
        segments.append((int(seconds), int(conc)))
    return segments


async def one_request(session, args, segment, rows):
    # Thêm timestamp vào prompt để prefix cache không làm TTFT đẹp hơn thực tế
    words = f"{time.time_ns()} " + "Kubernetes autoscaling vLLM GPU " * (args.prompt_words // 4)
    body = {
        "model": MODEL,
        "stream": True,
        "max_tokens": args.max_tokens,
        "messages": [{"role": "user", "content": words + "\nTóm tắt đoạn trên."}],
        "ignore_eos": True,  # độ dài output cố định để tải ổn định
    }
    start = time.time()
    ttft = None
    status = 0
    error = ""
    try:
        async with session.post(f"{BASE_URL}/v1/chat/completions", json=body,
                                headers={"Authorization": f"Bearer {API_KEY}"}) as resp:
            status = resp.status
            if status != 200:
                error = (await resp.text())[:120].replace(",", " ").replace("\n", " ")
            else:
                done = False
                async for line in resp.content:
                    if ttft is None and line.startswith(b"data: {"):
                        ttft = time.time() - start
                    if line.startswith(b"data: [DONE]"):
                        done = True
                if not done:
                    error = "stream cắt trước [DONE]"
    except Exception as exc:  # pod bị tắt giữa chừng cũng tính là lỗi
        error = type(exc).__name__
    end = time.time()
    ok = status == 200 and not error
    rows.append((segment, ok, ttft))
    print(f"{start:.3f},{segment},{status},{int(ok)},{f'{ttft:.3f}' if ttft is not None else ''},{end - start:.3f},{error}",
          flush=True)


async def worker(session, args, segment, deadline, rows):
    while time.time() < deadline:
        await one_request(session, args, segment, rows)


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", required=True)
    parser.add_argument("--max-tokens", type=int, default=256)
    parser.add_argument("--prompt-words", type=int, default=400)
    args = parser.parse_args()

    rows = []
    print("start_ts,segment,status,ok,ttft_s,e2e_s,error", flush=True)
    timeout = aiohttp.ClientTimeout(total=600)
    # Mỗi request một kết nối mới. Giữ kết nối thì Service ClusterIP dồn hết vào pod cũ,
    # pod mới scale lên không nhận được request nào
    connector = aiohttp.TCPConnector(force_close=True)
    async with aiohttp.ClientSession(timeout=timeout, connector=connector) as session:
        for i, (seconds, conc) in enumerate(parse_profile(args.profile)):
            print(f"[{time.strftime('%H:%M:%S')}] đoạn {i}: {seconds}s, concurrency {conc}", file=sys.stderr, flush=True)
            deadline = time.time() + seconds
            if conc == 0:
                await asyncio.sleep(seconds)
                continue
            # Hết giờ thì không gửi thêm, request đang chạy vẫn để chạy xong
            await asyncio.gather(*(worker(session, args, i, deadline, rows) for _ in range(conc)))

    for seg in sorted({r[0] for r in rows}):
        seg_rows = [r for r in rows if r[0] == seg]
        ttfts = sorted(r[2] for r in seg_rows if r[1] and r[2] is not None)
        p95 = ttfts[int(0.95 * (len(ttfts) - 1))] if ttfts else float("nan")
        errors = sum(1 for r in seg_rows if not r[1])
        print(json.dumps({"segment": seg, "requests": len(seg_rows), "errors": errors,
                          "ttft_p50": round(statistics.median(ttfts), 3) if ttfts else None,
                          "ttft_p95": round(p95, 3)}), file=sys.stderr, flush=True)


if __name__ == "__main__":
    asyncio.run(main())
