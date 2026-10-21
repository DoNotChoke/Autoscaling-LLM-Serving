# Hướng dẫn sử dụng LLM API (Llama-3.1-8B)

API tương thích OpenAI: dùng được thư viện `openai` (Python, JS, ...) hoặc bất kỳ công cụ nào hỗ trợ OpenAI, chỉ cần đổi **địa chỉ** và **API key**.

## Cách dễ nhất: giao diện web (Open WebUI)

Admin gửi bạn **URL trang web** và **email + mật khẩu**. Mở URL bằng trình duyệt, đăng nhập, chọn model `llama31-8b` và chat như ChatGPT. Không cần cài gì, không cần API key.

- Không tự đăng ký được tài khoản: hãy nhờ admin tạo.
- Hạn mức 100k token/phút **dùng chung cho cả nhóm**: nếu nhiều người cùng chat nhiều, có thể gặp lỗi 429 trong chốc lát.
- URL cũng có thể đổi khi máy chủ khởi động lại.

Muốn gọi bằng code (Python, curl), dùng phần bên dưới, với **API key riêng** do admin cấp.

## Bạn nhận được từ admin (khi gọi bằng code)

| Thông tin | Ví dụ |
|---|---|
| URL | `https://abc-def-ghi.trycloudflare.com` |
| API key riêng của bạn | chuỗi 48 ký tự hex |
| Tên model | `llama31-8b` |

> **URL có thể đổi** khi máy chủ khởi động lại. Nếu đột nhiên không gọi được (lỗi Cloudflare 530/1033), hãy hỏi admin URL mới.
> **Không chia sẻ key** cho người khác. Mỗi key có hạn mức riêng, và admin có thể thu hồi từng key.

## Python

```bash
pip install openai
```

```python
from openai import OpenAI

client = OpenAI(
    base_url="https://<URL>/v1",      # nhớ thêm /v1
    api_key="<API key của bạn>",
)

# Khuyên dùng stream: chữ hiện ra dần, và không bị giới hạn 100 giây
stream = client.chat.completions.create(
    model="llama31-8b",
    messages=[{"role": "user", "content": "Giải thích Kubernetes trong 3 câu."}],
    max_tokens=512,
    stream=True,
)
for chunk in stream:
    if chunk.choices and chunk.choices[0].delta.content:
        print(chunk.choices[0].delta.content, end="", flush=True)

# Không stream: chờ trả lời đầy đủ (phải xong trong ~100 giây)
resp = client.chat.completions.create(
    model="llama31-8b",
    messages=[{"role": "user", "content": "Xin chào"}],
    max_tokens=256,
)
print(resp.choices[0].message.content, resp.usage)
```

## curl

```bash
curl https://<URL>/v1/chat/completions \
  -H "Authorization: Bearer <API key>" -H "Content-Type: application/json" \
  -d '{"model":"llama31-8b","max_tokens":128,"messages":[{"role":"user","content":"Hello"}]}'
```

> Trên **Windows**, `curl` làm hỏng tiếng Việt có dấu khi truyền bằng `-d`. Hãy dùng Python, hoặc ghi body ra file UTF-8 rồi gửi bằng `--data-binary @body.json`.

## Giới hạn

| Giới hạn | Giá trị | Ghi chú |
|---|---|---|
| Hạn mức mỗi key | **100.000 token/phút** (prompt + trả lời) | Vượt thì nhận `429` tới khi sang phút mới |
| Độ dài tối đa | **16.384 token** cho prompt + trả lời | Vượt thì nhận `400` |
| Request **không stream** | Phải xong trong khoảng **100 giây** (~5.000 token khi máy rảnh, ít hơn khi đông người) | Quá thời gian thì nhận `500`. Câu trả lời dài thì dùng `stream=True` |
| Request stream | Không giới hạn thời gian (đã thử 6.500 token, 112 giây) | Đường truyền tạm (Cloudflare Quick Tunnel) không cam kết hỗ trợ stream; nếu stream lỗi, thử lại hoặc dùng không stream |
| Tốc độ | Token đầu tiên sau ~0,6–1 s, sau đó ~60 token/s | Chậm hơn khi nhiều người cùng gọi |

## Mã lỗi

| Mã | Nghĩa | Làm gì |
|---|---|---|
| 401 | Thiếu key, sai key hoặc key đã bị thu hồi | Kiểm tra `api_key`; hỏi admin |
| 404 | Sai tên model | Dùng `llama31-8b` |
| 429 | Vượt 100k token/phút | Đợi sang phút mới |
| 500 (sau ~100 s) | Request không stream quá lâu | Dùng `stream=True` hoặc giảm `max_tokens` |
| 502 / 503 | Máy chủ model đang khởi động lại | Thử lại sau 2–3 phút |
| 530 / 1033 (trang Cloudflare) | URL đã đổi hoặc tunnel không chạy | Hỏi admin URL mới |

## Quyền riêng tư

Dữ liệu đi qua Cloudflare, và Cloudflare đọc được nội dung. **Không gửi dữ liệu nhạy cảm** (mật khẩu, dữ liệu cá nhân, tài liệu mật). Máy chủ chỉ ghi lại *ai gọi, model nào, bao nhiêu token*, không lưu nội dung prompt.
