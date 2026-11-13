# Server giả API OpenAI (chat completions, stream) để thử loadgen.py mà không cần GPU
# Usage: mock_server.py [--port 8000] [--ttft 0.05] [--itl 0.002]
#   BASE_URL=http://127.0.0.1:8000 API_KEY=x loadgen.py --rate-profile 60:2
import argparse
import asyncio
import json

from aiohttp import web


def make_app(ttft, itl):
    async def chat(request):
        body = await request.json()
        resp = web.StreamResponse(headers={"Content-Type": "text/event-stream"})
        await resp.prepare(request)
        await asyncio.sleep(ttft)
        for i in range(body.get("max_tokens", 16)):
            chunk = {"choices": [{"index": 0, "delta": {"content": f"t{i} "}}]}
            await resp.write(f"data: {json.dumps(chunk)}\n\n".encode())
            await asyncio.sleep(itl)
        await resp.write(b"data: [DONE]\n\n")
        await resp.write_eof()
        return resp

    app = web.Application()
    app.router.add_post("/v1/chat/completions", chat)
    return app


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8000)
    parser.add_argument("--ttft", type=float, default=0.05)
    parser.add_argument("--itl", type=float, default=0.002)
    args = parser.parse_args()
    web.run_app(make_app(args.ttft, args.itl), host="127.0.0.1", port=args.port, print=None)
