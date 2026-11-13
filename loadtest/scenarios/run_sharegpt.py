# Gửi N mẫu ngẫu nhiên từ ShareGPT qua API (streaming), in TTFT, thời gian request và throughput.
# Usage: py loadtest/scenarios/run_sharegpt.py --url <base-url> --key <api-key> [--n 100] [--concurrency 10]
import argparse
import asyncio
import json
import random
import sys
import time
from pathlib import Path

from openai import AsyncOpenAI

DATASET = Path(__file__).resolve().parents[1] / "datasets" / "sharegpt-500.jsonl"


def percentile(values, p):
    ordered = sorted(values)
    return ordered[int(p * (len(ordered) - 1))]


async def one_request(client, sem, model, sample):
    async with sem:
        start = time.perf_counter()
        first = None
        try:
            stream = await client.chat.completions.create(
                model=model, messages=[{"role": "user", "content": sample["prompt"]}],
                max_tokens=sample["output_tokens"], temperature=0, stream=True,
                extra_body={"ignore_eos": True},  # độ dài output đúng như mẫu
            )
            async for chunk in stream:
                if first is None and chunk.choices and chunk.choices[0].delta.content:
                    first = time.perf_counter()
            if first is None:
                return {"error": "không có token"}
        except Exception as exc:  # 429, mất kết nối...: đếm lỗi, không dừng cả bài
            return {"error": getattr(exc, "status_code", None) or type(exc).__name__}
        return {"ttft": first - start, "e2e": time.perf_counter() - start, "tokens": sample["output_tokens"]}


async def main():
    sys.stdout.reconfigure(encoding="utf-8")  # console Windows mặc định cp1252, không in được tiếng Việt
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", required=True, help="không có /v1 ở cuối")
    parser.add_argument("--key", required=True)
    parser.add_argument("--model", default="llama31-8b")
    parser.add_argument("--n", type=int, default=100)
    parser.add_argument("--concurrency", type=int, default=10)
    parser.add_argument("--seed", type=int, help="bỏ trống: mỗi lần chạy một bộ mẫu khác")
    parser.add_argument("--file", default=str(DATASET))
    args = parser.parse_args()

    samples = [json.loads(line) for line in open(args.file, encoding="utf-8")]
    picked = random.Random(args.seed).sample(samples, args.n)
    client = AsyncOpenAI(base_url=f"{args.url.rstrip('/')}/v1", api_key=args.key, timeout=600, max_retries=0)
    sem = asyncio.Semaphore(args.concurrency)

    print(f"{args.n} request, {args.concurrency} song song, tới {args.url}")
    start = time.perf_counter()
    results = await asyncio.gather(*(one_request(client, sem, args.model, s) for s in picked))
    wall = time.perf_counter() - start

    ok = [r for r in results if "error" not in r]
    errors = {}
    for r in results:
        if "error" in r:
            errors[r["error"]] = errors.get(r["error"], 0) + 1
    print(f"thành công {len(ok)}/{args.n}, lỗi {errors or 0}, tổng thời gian {wall:.1f}s")
    if ok:
        ttft = [r["ttft"] for r in ok]
        e2e = [r["e2e"] for r in ok]
        print(f"TTFT     p50={percentile(ttft, .5):.2f}s p95={percentile(ttft, .95):.2f}s max={max(ttft):.2f}s")
        print(f"Request  p50={percentile(e2e, .5):.2f}s p95={percentile(e2e, .95):.2f}s max={max(e2e):.2f}s")
        print(f"Throughput {sum(r['tokens'] for r in ok) / wall:.0f} tok/s")
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    asyncio.run(main())
