#!/usr/bin/env bash
# 🔭 회귀 — 수명이 다한 Monitor 를 '실행 중' 으로 세지 않는가.
#
# Monitor 는 끝나도 <status> 가 안 붙는 경로가 있다 — 30분 수명이 다하면
# <event> 안의 문구 하나로만 끝난다. tasks.sh 가 옛 문구('Monitor timed out')
# 만 알던 때는 지금 쓰이는 문구('[Monitor expired after 30m …]')를 못 알아봐
# 만료된 Monitor 가 영영 run 으로 남았다 (실측: 한 세션에 🔭 16 — 실제 0).
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
for module in const tasks; do
  . "lib/$module.sh"
done

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
TASK_CACHE="$TMP/cache"
TX="$TMP/fx.jsonl"

# tool_use(①) / tool_result(②) / task-notification(③) 세 레코드로 한 태스크가 선다.
use() {  # <toolu> <name> <설명> [추가필드]
  printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"%s","name":"%s","input":{"description":"%s"%s}}]}}\n' \
    "$1" "$2" "$3" "${4:-}"
}
res() {  # <toolu> <taskId> <시각>
  printf '{"type":"user","toolUseResult":{"taskId":"%s"},"message":{"content":[{"tool_use_id":"%s"}]},"timestamp":"%s.000Z"}\n' \
    "$2" "$1" "$3"
}
bgres() { # <toolu> <taskId> <시각>  — Bash 백그라운드는 backgroundTaskId 로 온다
  printf '{"type":"user","toolUseResult":{"backgroundTaskId":"%s"},"message":{"content":[{"tool_use_id":"%s"}]},"timestamp":"%s.000Z"}\n' \
    "$2" "$1" "$3"
}
evt() {  # <taskId> <event 문구>
  printf '{"type":"user","message":{"content":"<task-notification>\\n<task-id>%s</task-id>\\n<summary>Monitor event: \\"감시\\"</summary>\\n<event>%s</event>\\n</task-notification>"}}\n' \
    "$1" "$2"
}

{
  # ① 지금 쓰이는 만료 문구
  use toolu_a Monitor '만료(신)';    res toolu_a btaska 2026-09-18T07:40:40
  evt btaska '[Monitor expired after 30m with 1 event delivered. Re-arm it if you still need the watch.]'
  # ② 이벤트가 하나도 없이 만료된 경우 — 문구 꼬리가 다르다
  use toolu_b Monitor '만료(무이벤트)'; res toolu_b btaskb 2026-09-18T08:10:50
  evt btaskb '[Monitor expired after 30m with no events delivered. Re-arm it if you still need the watch — and widen the filter if silence was unexpected.]'
  # ③ 옛 로그에 남아 있는 문구도 계속 받는다
  use toolu_c Monitor '만료(구)';    res toolu_c btaskc 2026-09-18T08:40:00
  evt btaskc '[Monitor timed out — re-arm if needed.]'
  # ④ <status> 로 끝난 Monitor
  use toolu_d Monitor '정상종료';    res toolu_d btaskd 2026-09-18T09:10:00
  printf '{"type":"user","message":{"content":"<task-notification>\\n<task-id>btaskd</task-id>\\n<status>completed</status>\\n</task-notification>"}}\n'
  # ⑤ 아직 도는 Monitor — 종료 기록이 없다
  use toolu_e Monitor '실행중';      res toolu_e btaske 2026-09-18T09:40:00
  # ⑥ 아직 도는 백그라운드 shell — 🔭 를 고치면서 ⚡ 가 같이 죽지 않았는지
  use toolu_f Bash '빌드' ',"run_in_background":true'; bgres toolu_f btaskf 2026-09-18T09:50:00
  # ⑦ 만료 문구를 '인용' 하기만 한 줄(제 로그를 grep 한 세션) — 종료로 읽히면 안 된다.
  #    <task-id> 태그가 없으므로 어느 태스크에도 안 걸린다.
  printf '{"type":"user","message":{"content":"grep 결과: Monitor expired after 30m 이라는 문구를 찾았다"}}\n'
} > "$TX"

got=$(tasks_extract "$TX" | awk -F'\037' '{print $1":"$2}' | tr '\n' ' ')
want='mon:timeout mon:timeout mon:timeout mon:completed mon:run sh:run '
[[ "$got" == "$want" ]] || fail "상태가 어긋난다 — 기대 '$want' 실제 '$got'"

live=$(tasks_live "$TX")
[[ "$live" == $'1\0371' ]] || fail "실행 중 집계가 shell 1 · monitor 1 이어야 하는데 '$(printf '%s' "$live" | tr '\037' '/')'"

# since 보다 먼저 시작한 것은 이전 프로세스 것이라 안 센다 (기존 규칙이 그대로인지)
live=$(tasks_live "$TX" 2026-09-19T00:00:00)
[[ "$live" == $'0\0370' ]] || fail "since 필터가 안 먹는다: '$(printf '%s' "$live" | tr '\037' '/')'"

echo "ok: monitor-expiry"
