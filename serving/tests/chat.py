import argparse
import os
import sys
import time

from openai import OpenAI


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("prompt", nargs="?", default="Giải thích Kubernetes trong 3 câu.")
    parser.add_argument("--base-url", default=os.getenv("VLLM_BASE_URL", "http://localhost:8000/v1"))
    parser.add_argument("--model", default="llama31-8b")
    parser.add_argument("--max-tokens", type=int, default=512)
    args = parser.parse_args()

    api_key = os.getenv("VLLM_API_KEY")
    if not api_key:
        sys.exit("Thiếu biến môi trường VLLM_API_KEY")

    client = OpenAI(base_url=args.base_url, api_key=api_key)
    start = time.perf_counter()
    first_token_at = None
    usage = None

    stream = client.chat.completions.create(
        model=args.model,
        messages=[{"role": "user", "content": args.prompt}],
        max_tokens=args.max_tokens,
        stream=True,
        stream_options={"include_usage": True},
    )
    for chunk in stream:
        if chunk.usage:
            usage = chunk.usage
        if chunk.choices and chunk.choices[0].delta.content:
            if first_token_at is None:
                first_token_at = time.perf_counter()
            print(chunk.choices[0].delta.content, end="", flush=True)
    end = time.perf_counter()

    print("\n")
    if first_token_at is None:
        sys.exit("Không nhận được token nào")
    ttft = first_token_at - start
    line = f"TTFT {ttft:.2f}s · tổng {end - start:.2f}s"
    if usage:
        gen_time = end - first_token_at
        line += f" · prompt {usage.prompt_tokens} tok · sinh {usage.completion_tokens} tok"
        if gen_time > 0:
            line += f" ({usage.completion_tokens / gen_time:.1f} tok/s)"
    print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
