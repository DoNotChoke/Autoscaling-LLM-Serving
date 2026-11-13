# Tạo tải stream theo từng đoạn thời gian, dùng cho run-scenario.sh
# Mỗi request in một dòng CSV ra stdout, cuối mỗi đoạn in tóm tắt ra stderr
import argparse
import asyncio
import json
import os
import random
import statistics
import sys
import time

import aiohttp

BASE_URL = os.environ.get("BASE_URL", "http://llm-gateway-envoy.envoy-gateway-system.svc").rstrip("/")
API_KEY = os.environ["API_KEY"]
MODEL = os.environ.get("MODEL", "llama31-8b")


def parse_profile(text, value=int):
    segments = []
    for part in text.split(","):
        seconds, v = part.split(":")
        segments.append((int(seconds), value(v)))
    return segments


def parse_range(text):
    lo, hi = (int(x) for x in text.split(":"))
    assert 0 < lo <= hi, f"range sai: {text}"
    return lo, hi


def pick(args):
    if args.max_tokens_range or args.prompt_words_range:
        mt = random.randint(*args.max_tokens_range) if args.max_tokens_range else args.max_tokens
        pw = random.randint(*args.prompt_words_range) if args.prompt_words_range else args.prompt_words
        return mt, pw, False  # độ dài ngẫu nhiên thì để model tự dừng như traffic thật
    return args.max_tokens, args.prompt_words, True  # độ dài output cố định để tải ổn định


def emit(start, segment, status, ok, ttft, e2e, error, max_tokens, prompt_words):
    print(f"{start:.3f},{segment},{status},{int(ok)},{f'{ttft:.3f}' if ttft is not None else ''},{e2e:.3f},{error},"
          f"{max_tokens},{prompt_words}", flush=True)


async def one_request(session, args, segment, rows):
    max_tokens, prompt_words, ignore_eos = pick(args)
    # Thêm timestamp vào prompt để prefix cache không làm TTFT đẹp hơn thực tế
    words = f"{time.time_ns()} " + "Kubernetes autoscaling vLLM GPU " * (prompt_words // 4)
    body = {
        "model": MODEL,
        "stream": True,
        "max_tokens": max_tokens,
        "messages": [{"role": "user", "content": words + "\nTóm tắt đoạn trên."}],
    }
    if ignore_eos:
        body["ignore_eos"] = True
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
    emit(start, segment, status, ok, ttft, end - start, error, max_tokens, prompt_words)


async def worker(session, args, segment, deadline, rows):
    while time.time() < deadline:
        await one_request(session, args, segment, rows)


async def open_loop(session, args, segment, seconds, rate, rows, inflight):
    deadline = time.time() + seconds
    while True:
        await asyncio.sleep(random.expovariate(rate))
        if time.time() >= deadline:
            return
        if len(inflight) >= args.max_inflight:
            # Không chờ chỗ trống: chờ sẽ làm tốc độ gửi giảm theo hệ thống (coordinated omission)
            rows.append((segment, False, None))
            emit(time.time(), segment, 0, False, None, 0.0, "client_overflow", *pick(args)[:2])
            continue
        task = asyncio.create_task(one_request(session, args, segment, rows))
        inflight.add(task)
        task.add_done_callback(inflight.discard)


async def main():
    parser = argparse.ArgumentParser()
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--profile")
    mode.add_argument("--rate-profile")
    parser.add_argument("--max-tokens", type=int, default=256)
    parser.add_argument("--prompt-words", type=int, default=400)
    parser.add_argument("--max-tokens-range", type=parse_range)
    parser.add_argument("--prompt-words-range", type=parse_range)
    parser.add_argument("--max-inflight", type=int, default=512)
    parser.add_argument("--seed", type=int)
    args = parser.parse_args()
    random.seed(args.seed)

    rows = []
    print("start_ts,segment,status,ok,ttft_s,e2e_s,error,max_tokens,prompt_words", flush=True)
    timeout = aiohttp.ClientTimeout(total=600)
    # Mỗi request một kết nối mới. Giữ kết nối thì Service ClusterIP dồn hết vào pod cũ,
    # pod mới scale lên không nhận được request nào
    connector = aiohttp.TCPConnector(force_close=True)
    async with aiohttp.ClientSession(timeout=timeout, connector=connector) as session:
        if args.rate_profile:
            inflight = set()
            for i, (seconds, rate) in enumerate(parse_profile(args.rate_profile, float)):
                print(f"[{time.strftime('%H:%M:%S')}] đoạn {i}: {seconds}s, {rate} req/s", file=sys.stderr, flush=True)
                if rate <= 0:
                    await asyncio.sleep(seconds)
                else:
                    await open_loop(session, args, i, seconds, rate, rows, inflight)
            # Hết giờ thì không gửi thêm, request đang chạy vẫn để chạy xong
            if inflight:
                await asyncio.gather(*inflight)
        for i, (seconds, conc) in enumerate(parse_profile(args.profile) if args.profile else []):
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
