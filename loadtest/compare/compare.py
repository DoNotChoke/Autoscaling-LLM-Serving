# So sánh vLLM (qua KServe Service) và HF Transformers generate() thuần, cùng model/GPU/prompt.
import argparse
import asyncio
import statistics
import threading
import time

PROMPT = "Giải thích chi tiết Kubernetes là gì, các thành phần chính và cách nó lập lịch pod."
NEW_TOKENS = 256
SINGLE_RUNS = 5
CONCURRENCY = 8


def summarize(name, rows):
    ttft = [r[0] for r in rows]
    total = [r[1] for r in rows]
    tps = [NEW_TOKENS / (r[1] - r[0]) for r in rows]
    print(f"{name}: TTFT p50={statistics.median(ttft):.3f}s max={max(ttft):.3f}s | "
          f"total p50={statistics.median(total):.2f}s max={max(total):.2f}s | "
          f"decode {statistics.median(tps):.1f} tok/s/request")


# ---------- vLLM ----------
async def vllm_one(client, model):
    start = time.perf_counter()
    first = None
    stream = await client.chat.completions.create(
        model=model, messages=[{"role": "user", "content": PROMPT}],
        max_tokens=NEW_TOKENS, temperature=0, stream=True,
        extra_body={"ignore_eos": True, "min_tokens": NEW_TOKENS},
    )
    async for chunk in stream:
        if first is None and chunk.choices and chunk.choices[0].delta.content:
            first = time.perf_counter()
    return first - start, time.perf_counter() - start


async def run_vllm(args):
    from openai import AsyncOpenAI
    client = AsyncOpenAI(base_url=args.url, api_key=args.key)
    await vllm_one(client, args.model_name)  # warmup
    single = [await vllm_one(client, args.model_name) for _ in range(SINGLE_RUNS)]
    summarize("vLLM  single    ", single)
    t0 = time.perf_counter()
    conc = await asyncio.gather(*[vllm_one(client, args.model_name) for _ in range(CONCURRENCY)])
    wall = time.perf_counter() - t0
    summarize(f"vLLM  {CONCURRENCY} đồng thời", conc)
    print(f"vLLM  {CONCURRENCY} đồng thời: wall={wall:.2f}s, throughput={CONCURRENCY * NEW_TOKENS / wall:.0f} tok/s")


# ---------- HF Transformers ----------
def run_hf(args):
    import torch
    from transformers import AutoModelForCausalLM, AutoTokenizer
    from transformers.generation.streamers import BaseStreamer

    class FirstTokenTimer(BaseStreamer):
        def __init__(self):
            self.calls = 0
            self.first = None

        def put(self, value):
            self.calls += 1  # lần put đầu tiên là prompt, lần thứ hai là token mới đầu tiên
            if self.calls == 2:
                self.first = time.perf_counter()

        def end(self):
            pass

    t0 = time.perf_counter()
    tok = AutoTokenizer.from_pretrained(args.model)
    model = AutoModelForCausalLM.from_pretrained(args.model, dtype=torch.bfloat16, device_map="cuda")
    torch.cuda.synchronize()
    print(f"HF    load model: {time.perf_counter() - t0:.1f}s, VRAM {torch.cuda.memory_allocated() / 2**30:.1f} GiB")

    ids = tok.apply_chat_template([{"role": "user", "content": PROMPT}], add_generation_prompt=True,
                                  return_tensors="pt", return_dict=True).to("cuda")
    lock = threading.Lock()

    def one():
        timer = FirstTokenTimer()
        start = time.perf_counter()
        with lock, torch.inference_mode():
            out = model.generate(**ids, max_new_tokens=NEW_TOKENS, min_new_tokens=NEW_TOKENS,
                                 do_sample=False, streamer=timer)
        torch.cuda.synchronize()
        assert out.shape[1] - ids["input_ids"].shape[1] == NEW_TOKENS
        return timer.first - start, time.perf_counter() - start

    one()  # warmup
    single = [one() for _ in range(SINGLE_RUNS)]
    summarize("HF    single    ", single)

    # Server HF đơn giản xử lý từng request một: request đến cùng lúc phải xếp hàng
    results = []
    t0 = time.perf_counter()
    threads = [threading.Thread(target=lambda: results.append(one())) for _ in range(CONCURRENCY)]
    [t.start() for t in threads]
    [t.join() for t in threads]
    wall = time.perf_counter() - t0
    summarize(f"HF    {CONCURRENCY} đồng thời", results)
    print(f"HF    {CONCURRENCY} đồng thời: wall={wall:.2f}s, throughput={CONCURRENCY * NEW_TOKENS / wall:.0f} tok/s")


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("mode", choices=["vllm", "hf"])
    p.add_argument("--url")
    p.add_argument("--key")
    p.add_argument("--model-name", default="llama31-8b")
    p.add_argument("--model", default="/mnt/models/current")
    a = p.parse_args()
    asyncio.run(run_vllm(a)) if a.mode == "vllm" else run_hf(a)
