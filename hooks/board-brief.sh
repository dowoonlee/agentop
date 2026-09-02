#!/bin/bash
# board-brief.sh — SessionStart 훅 — 같은 저장소에서 지금 도는 다른 세션을 요약해
#   새 세션의 컨텍스트에 얹는다. 이 훅이 이 도구의 존재 이유다: 세션에게 물어보지
#   (SendMessage) 않고도 "누가 무엇을 하고 있나" 를 시작 시점에 알게 한다.
#
#   보여주는 것 — 세션별로: 이름·상태, 워크트리, 마지막 사용자 지시(의도),
#   최근 만진 파일. 의도는 보드가 아니라 상대 세션의 transcript 에서 읽는다
#   (사용자 입력은 이미 거기 다 있어서 따로 기록할 이유가 없다 — 훅을 하나 덜 둔다).
#
#   등록 (settings.json): SessionStart
#   출력 규약: exit 0 + 평문 stdout → 그대로 세션 컨텍스트로 주입된다.
#              이웃이 없으면 아무것도 내지 않는다 (조용한 기본값).
set -uo pipefail
source "$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)/board-lib.sh"

BRIEF_WINDOW="${CC_BOARD_BRIEF_WINDOW:-3600}"  # 브리핑 시간창(초). 기본 1시간 —
                                               #   충돌 게이트(15분)보다 넓게 잡는다.
                                               #   시작 시점엔 '방금' 보다 '요즘 누가
                                               #   뭘 하고 있나' 가 알고 싶은 값이다.
BRIEF_SESSIONS="${CC_BOARD_BRIEF_SESSIONS:-6}" # 나열할 최대 세션 수
BRIEF_FILES="${CC_BOARD_BRIEF_FILES:-4}"       # 세션당 나열할 최대 파일 수
BRIEF_INTENT_MAX=160                           # 의도 문구 최대 길이(문자)

INPUT=$(cat)
IFS=$'\037' read -r SID CWD < <(printf '%s' "$INPUT" | jq -r '
  [ .session_id, .cwd ] | map(. // "") | join("\u001f")' 2>/dev/null)

board_sweep     # 방치된 보드 파일 수거는 이 자리에서만 한다 (세션 시작 1회)

[[ -n "${CWD:-}" ]] || exit 0
BD=$(board_dir "$CWD/."); [[ -n "$BD" ]] || exit 0   # cwd 자체의 저장소 — board_dir 은 파일 경로를 받으므로 /. 을 붙인다

ROWS=$(board_scan "$BD" "${SID:-}" "$BRIEF_WINDOW")
[[ -n "$ROWS" ]] || exit 0

# ---------------------------------------------------------------------------
# 살아있는 세션의 이름·상태 — 여기서는 부를 만하다 (세션 시작 1회, ~0.4s).
# 보드에만 있고 여기 없는 세션은 이미 끝난 세션이라 '(종료)' 로 구분해 준다.
# bash 3.2 에 연관배열이 없어 맵은 임시파일로 둔다.
# ---------------------------------------------------------------------------
MAP=$(mktemp) || exit 0
trap 'rm -f "$MAP"' EXIT
claude agents --json 2>/dev/null | jq -r '.[] | [ (.sessionId // ""), (.name // ""), (.status // "") ] | @tsv' > "$MAP" 2>/dev/null

# 세션별로 접어 최근 순으로 정렬 — 대표 경과초 + 워크트리 + 파일 목록.
GROUPED=$(printf '%s\n' "$ROWS" | LC_ALL=C awk -F'\t' -v maxf="$BRIEF_FILES" '
  { if (!($1 in first) || $2 < first[$1]) { first[$1] = $2; wt[$1] = $4 }
    if (n[$1] < maxf) { files[$1] = (n[$1]++ ? files[$1] " · " : "") $5 }
    else if (n[$1] == maxf) { files[$1] = files[$1] " …"; n[$1]++ } }
  END { for (s in first) printf "%d\t%s\t%s\t%s\n", first[s], s, wt[s], files[s] }' \
  | sort -n | head -n "$BRIEF_SESSIONS")

[[ -n "$GROUPED" ]] || exit 0

printf '## 같은 저장소의 다른 세션 (agentop 세션 보드)\n\n'
printf '%s\n' "$GROUPED" | while IFS=$'\t' read -r age sid wt files; do
  # 이름·상태 — 살아있는 세션만 claude agents 에 잡힌다.
  name=""; status=""
  IFS=$'\t' read -r _ name status < <(LC_ALL=C grep -F "$sid" "$MAP" 2>/dev/null | head -1)
  label="${name:-${sid:0:8}}"
  [[ -n "$name" ]] && label="$label(${sid:0:8})"
  state="${status:-종료}"
  place="본체 체크아웃"; [[ "$wt" != "-" ]] && place="워크트리 $wt"
  # 경과초 → 사람이 읽는 단위
  if   (( age < 60 ));   then ago="${age}초"
  elif (( age < 3600 )); then ago="$((age/60))분"
  else                        ago="$((age/3600))시간"
  fi
  printf -- '- %s [%s] · %s · 마지막 편집 %s 전\n' "$label" "$state" "$place" "$ago"

  # 의도 = 그 세션의 마지막 사용자 지시. 보드에 없는 값이라 transcript 에서 읽는다.
  # 꼬리 1MB 우선, 거기 없으면 전체 (core.sh 의 조회 헬퍼들과 같은 방침).
  # 반복 횟수는 200 — BSD grep 은 \{n,m\} 의 m 이 255 를 넘으면 에러다.
  # 필터: tool_result·system-reminder·슬래시 커맨드 확장·중단 표시는 지시가 아니다.
  tx=$(tx_of "" "$sid")
  if [[ -n "$tx" && -f "$tx" ]]; then
    pat='"type":"user","message":{"role":"user","content":"[^"]\{1,200\}'
    raw=$(tail -c 1048576 "$tx" 2>/dev/null | tail -n +2 | LC_ALL=C grep -o "$pat" 2>/dev/null \
          | LC_ALL=C grep -v 'content":"\(<system-reminder>\|<command-\|\[Request \|Caveat: \)' | tail -1)
    [[ -z "$raw" ]] && raw=$(LC_ALL=C grep -o "$pat" "$tx" 2>/dev/null \
          | LC_ALL=C grep -v 'content":"\(<system-reminder>\|<command-\|\[Request \|Caveat: \)' | tail -1)
    intent="${raw##*content\":\"}"
    intent="${intent//\\n/ }"
    if [[ -n "$intent" ]]; then
      (( ${#intent} > BRIEF_INTENT_MAX )) && intent="${intent:0:$BRIEF_INTENT_MAX}…"
      printf '  의도: %s\n' "$intent"
    fi
  fi
  printf '  최근 편집: %s\n' "$files"
done

printf '\n같은 파일을 고치기 전에 위를 참고하세요. 편집 시점의 실제 충돌은 훅이 그때 알려 줍니다.\n'
exit 0
