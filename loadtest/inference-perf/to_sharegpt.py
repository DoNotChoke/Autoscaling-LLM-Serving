# Chuyển loadtest/datasets/sharegpt-500.jsonl ({"id","prompt","output_tokens"}) sang ShareGPT JSON cho inference-perf.
# Loader shareGPT (API completion) lấy max_tokens = số token câu trả lời "gpt": dựng câu giả " x" × output_tokens.
# Usage: python to_sharegpt.py <in.jsonl> <out.json>
import json
import sys

rows = [json.loads(line) for line in open(sys.argv[1], encoding="utf-8") if line.strip()]
assert rows and all({"id", "prompt", "output_tokens"} <= r.keys() for r in rows), "sai định dạng jsonl"
json.dump([{"id": r["id"], "conversations": [{"from": "human", "value": r["prompt"]},
                                             {"from": "gpt", "value": " x" * r["output_tokens"]}]} for r in rows],
          open(sys.argv[2], "w", encoding="utf-8"))
print(f"{len(rows)} conversations -> {sys.argv[2]}")
