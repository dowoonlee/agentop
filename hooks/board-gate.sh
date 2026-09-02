#!/bin/bash
# board-gate.sh — PreToolUse 훅 — 고치려는 파일을 다른 세션이 방금 만졌으면 알려 준다.
#   차단하지 않는다. hookSpecificOutput.additionalContext 로 사실만 주입하고
#   판단은 세션에 맡긴다 — 워크트리를 나눠 정당하게 병행하는 작업까지 막으면
#   도구가 일을 방해하게 된다.
#
#   permissionDecision 은 일부러 넣지 않는다. "allow" 를 주면 권한 프롬프트를
#   건너뛰는 뜻이 되어, 경고를 붙이려던 훅이 승인 자동화로 변한다. 컨텍스트만
#   얹고 권한 판단에는 손대지 않는다.
#
#   두 등급을 구분한다 (같은 저장소에 워크트리가 여럿인 상황에서 이 구분이 값어치):
#     같은 체크아웃 — 절대경로가 같다. 서로의 편집을 실제로 덮어쓸 수 있다.
#     다른 워크트리 — 저장소 상대경로만 같다. 지금은 안전하지만 머지에서 만난다.
#
#   등록 (settings.json):
#     PreToolUse / matcher "Edit|Write|MultiEdit|NotebookEdit"
#
#   무슨 일이 있어도 exit 0 — PreToolUse 에서 exit 2 는 '도구 호출 차단' 이므로,
#   보드 조회 실패가 편집을 막는 일이 없게 종료 코드를 고정한다.
set -uo pipefail
source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/board-lib.sh"

BOARD_HITS="${CC_BOARD_HITS:-4}"   # 주입할 최대 건수 — 컨텍스트를 먹지 않게 상한을 둔다

INPUT=$(cat)
IFS=$'\037' read -r SID FPATH < <(printf '%s' "$INPUT" | jq -r '
  [ .session_id, (.tool_input.file_path // .tool_input.notebook_path) ]
  | map(. // "") | join("\u001f")' 2>/dev/null)

[[ -n "${FPATH:-}" ]] || exit 0
BD=$(board_dir "$FPATH"); [[ -n "$BD" ]] || exit 0
REL=$(board_rel "$FPATH"); [[ -n "$REL" ]] || exit 0

# 같은 파일(절대경로 일치) → 등급 0, 상대경로만 일치 → 등급 1.
# 등급 우선 · 그 안에서 최근 순으로 상한만큼. 정렬까지 awk 안에서 끝낸다 —
# 편집마다 도는 자리라 sort·cut·head 세 프로세스를 아끼는 편이 낫고, 건수는
# 한 자리라 선택 정렬로 충분하다.
HITS=$(board_scan "$BD" "${SID:-}" | LC_ALL=C awk -F'\t' \
    -v rel="$REL" -v abs="$FPATH" -v max="$BOARD_HITS" '
  function age(s) { return s < 60 ? s "s" : (s < 3600 ? int(s/60) "m" : int(s/3600) "h") }
  $6 == abs { n++; rank[n] = 0; sec[n] = $2
              msg[n] = sprintf(" · %s 전  세션 %s  같은 체크아웃 — 서로의 편집을 덮어쓸 수 있습니다",
                               age($2), substr($1,1,8)); next }
  $5 == rel { n++; rank[n] = 1; sec[n] = $2
              msg[n] = sprintf(" · %s 전  세션 %s  %s — 머지에서 충돌할 수 있습니다",
                               age($2), substr($1,1,8), ($4 == "-" ? "본체 체크아웃" : "워크트리 " $4)) }
  END { for (out = 0; out < max; out++) {
          best = 0
          for (i = 1; i <= n; i++) {
            if (used[i]) continue
            if (!best || rank[i] < rank[best] || (rank[i] == rank[best] && sec[i] < sec[best])) best = i }
          if (!best) break
          used[best] = 1; print msg[best] } }')

[[ -n "$HITS" ]] || exit 0

jq -n --arg rel "$REL" --arg hits "$HITS" --arg win "$(( BOARD_WINDOW / 60 ))" '
  { hookSpecificOutput: {
      hookEventName: "PreToolUse",
      additionalContext: ("[세션 보드] \($rel) — 최근 \($win)분 안에 이 파일을 만진 다른 세션이 있습니다:\n"
                          + $hits + "\n"
                          + "겹치는 변경인지 확인하고, 그대로 진행할지 사용자에게 알릴지 판단하세요.") } }'
exit 0
