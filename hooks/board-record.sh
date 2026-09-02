#!/bin/bash
# board-record.sh — PostToolUse 훅 — 방금 고친 파일 1건을 세션 보드에 남긴다.
#   매 편집마다 도는 자리라 하는 일을 최소로 둔다: jq 1회로 세 값을 뽑고
#   자기 보드 파일에 한 줄 append. 저장소 밖 경로(임시·scratchpad)는 board_record
#   가 알아서 버린다.
#
#   등록 (settings.json):
#     PostToolUse / matcher "Edit|Write|MultiEdit|NotebookEdit"
#
#   무슨 일이 있어도 exit 0 — PostToolUse 에서 0 이 아닌 종료는 Claude 에게
#   에러로 새어 나가므로, 보드 기록 실패가 작업 흐름을 건드리게 두지 않는다.
set -uo pipefail
source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/board-lib.sh"

INPUT=$(cat)
# 세 값을 jq 한 번에 — 편집마다 프로세스를 세 개 띄우지 않는다.
# NotebookEdit 은 file_path 대신 notebook_path 를 쓰므로 둘 다 본다.
IFS=$'\037' read -r SID TOOL FPATH < <(printf '%s' "$INPUT" | jq -r '
  [ .session_id, .tool_name, (.tool_input.file_path // .tool_input.notebook_path) ]
  | map(. // "") | join("\u001f")' 2>/dev/null)

board_record "${SID:-}" "${TOOL:-}" "${FPATH:-}"
exit 0
