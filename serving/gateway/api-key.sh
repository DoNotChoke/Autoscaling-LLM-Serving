#!/usr/bin/env bash
# Quản lý API key của client trong Secret gateway-api-keys (client-id → key). Không phải restart pod nào.
# Usage: api-key.sh add <name> | revoke <name> | list
set -euo pipefail

NS="${NS:-llm-serving}"
SECRET="${SECRET:-gateway-api-keys}"

usage() { echo "Usage: $0 add <name> | revoke <name> | list" >&2; exit 1; }

has_key() { kubectl -n "$NS" get secret "$SECRET" -o jsonpath="{.data.$1}" 2>/dev/null | grep -q .; }

cmd="${1:-}"; name="${2:-}"
case "$cmd" in
  add|revoke)
    [[ $name =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || { echo "Tên chỉ gồm a-z, 0-9, '-' (tối đa 31 ký tự)" >&2; exit 1; }
    ;;
  list) ;;
  *) usage ;;
esac

case "$cmd" in
  add)
    if has_key "$name"; then echo "Đã có key cho '$name'; revoke trước nếu muốn cấp lại" >&2; exit 1; fi
    key=$(openssl rand -hex 24)
    if kubectl -n "$NS" get secret "$SECRET" >/dev/null 2>&1; then
      kubectl -n "$NS" patch secret "$SECRET" --type merge \
        -p "{\"data\":{\"$name\":\"$(printf '%s' "$key" | base64 -w0)\"}}" >/dev/null
    else
      kubectl -n "$NS" create secret generic "$SECRET" --from-literal="$name=$key" >/dev/null
    fi
    echo "Key của '$name' (chỉ hiện 1 lần, gửi riêng cho người dùng):"
    echo "$key"
    ;;
  revoke)
    has_key "$name" || { echo "Không có key cho '$name'" >&2; exit 1; }
    kubectl -n "$NS" patch secret "$SECRET" --type json -p "[{\"op\":\"remove\",\"path\":\"/data/$name\"}]" >/dev/null
    echo "Đã thu hồi key của '$name'"
    ;;
  list)
    # shellcheck disable=SC2016 # go-template của kubectl, không phải biến shell
    kubectl -n "$NS" get secret "$SECRET" -o go-template='{{range $k, $v := .data}}{{$k}}{{"\n"}}{{end}}'
    ;;
esac
