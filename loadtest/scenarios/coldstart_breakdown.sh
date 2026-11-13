#!/usr/bin/env bash
# Tách thời gian khởi động một pod vLLM thành từng chặng, từ trạng thái pod và log (kubectl logs --timestamps).
# Chạy khi pod vừa lên (log khởi động còn trong `kubectl logs`).
# Usage: coldstart_breakdown.sh <pod> [namespace]
set -euo pipefail

POD="${1:?Usage: coldstart_breakdown.sh <pod> [namespace]}"
NS="${2:-llm-serving}"
KUBECTL="${KUBECTL:-kubectl}"
# Mẫu dòng log vLLM v0.31 cho từng mốc. CUDA graph được capture 2 lần
# (profile rồi capture thật), "CUDA graph pool memory" chỉ in sau lần cuối
MARKS=(
  "tiến trình vLLM bắt đầu|version 0.31"
  "engine bắt đầu khởi tạo|Initializing a V1 LLM engine"
  "load weights xong|Model loading took"
  "torch.compile xong|torch.compile took"
  "CUDA graph xong|CUDA graph pool memory"
  "engine khởi tạo xong|init engine"
  "server lắng nghe|Application startup complete"
)

to_epoch() { date -d "$1" +%s.%N; }

pod_json=$($KUBECTL -n "$NS" get pod "$POD" -o json)
cond() { python3 -c "import json,sys; d=json.load(sys.stdin); print(next((c['lastTransitionTime'] for c in d['status']['conditions'] if c['type']=='$1'), ''))" <<< "$pod_json"; }
created=$(python3 -c "import json,sys; print(json.load(sys.stdin)['metadata']['creationTimestamp'])" <<< "$pod_json")
logs=$($KUBECTL -n "$NS" logs "$POD" -c kserve-container --timestamps)

t0=$(to_epoch "$created")
prev=$t0
printf '%-26s %10s %10s\n' "Mốc" "Từ tạo pod" "Chặng"
row() {  # <tên> <thời điểm RFC3339 hoặc rỗng>
  if [[ -z $2 ]]; then printf '%-26s %10s %10s\n' "$1" "–" "–"; return; fi
  local t; t=$(to_epoch "$2")
  awk -v n="$1" -v a="$t" -v z="$t0" -v p="$prev" 'BEGIN { printf "%-26s %9.1fs %9.1fs\n", n, a - z, a - p }'
  prev=$t
}
row "pod được tạo" "$created"
# Pod thay thế phải chờ pod cũ trả GPU (preStop + vLLM shutdown) mới được xếp lịch: chặng này không phải cold start
row "được xếp lịch (có GPU)" "$(cond PodScheduled)"
row "container chạy" "$(python3 -c "import json,sys; d=json.load(sys.stdin); print(next((c['state'].get('running', {}).get('startedAt', '') for c in d['status'].get('containerStatuses', []) if c['name']=='kserve-container'), ''))" <<< "$pod_json")"
for m in "${MARKS[@]}"; do
  row "${m%%|*}" "$(grep -m1 -F "${m#*|}" <<< "$logs" | cut -d' ' -f1 || true)"
done
row "ContainersReady" "$(cond ContainersReady)"
row "Ready (nhận traffic)" "$(cond Ready)"
