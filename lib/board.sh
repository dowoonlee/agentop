# board.sh — 세션 보드 조회 — hooks/board-*.sh 가 쌓아 둔 편집 기록을 읽어
#   목록 1행 배지(⚠N)와 preview 상세 섹션으로 만든다.
#
#   보드에 쓰는 쪽은 훅(hooks/board-record.sh), 여기는 읽기만 한다. 저장 규칙·
#   경로 판정은 hooks/board-lib.sh 를 그대로 쓴다 — 같은 규칙을 두 곳에 적으면
#   TUI 와 훅이 서로 다른 보드를 보게 된다.
#
# agentop 이 source 하는 모듈이다 (단독 실행 아님). 상수·헬퍼는 agentop 프로세스
# 하나 안에서 공유되므로, 여기 정의는 다른 모듈에서 그대로 보인다.
# ---------------------------------------------------------------------------
# 저장 규칙은 훅과 공용이라 hooks/board-lib.sh 에서 가져온다. 이미 읽혔으면
# (훅 쪽에서 source 된 경우) 다시 읽지 않는다. 위치는 SELF 가 아니라 자기
# BASH_SOURCE 로 구한다 — 이 모듈만 놓고 테스트할 때도 경로가 맞아야 한다.
[[ -n "${BOARD_ROOT:-}" ]] \
  || . "$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../hooks" && pwd)/board-lib.sh" 2>/dev/null \
  || true

# ---------------------------------------------------------------------------
# board_map [시간창초] : 모든 보드를 한 번 훑어 만든 '세션별 겹침 수' 맵.
#   형식은 " <sid>:<개수> <sid>:<개수> " — gen 의 세션 루프가 프로세스를 하나도
#   더 띄우지 않고 파라미터 확장만으로 조회할 수 있게 문자열 하나로 낸다
#   (2초 폴링에서 세션마다 grep 을 띄우면 그게 다 프로세스다).
#
#   '겹침' = 그 세션이 만진 저장소 상대 경로 중, 같은 보드의 다른 세션도 시간창
#   안에 만진 것의 개수. 워크트리가 달라도 상대 경로가 같으면 세는 이유는
#   board-gate 와 같다 — 지금은 안 부딪혀도 머지에서 만난다.
# ---------------------------------------------------------------------------
board_map() {
  local win="${1:-$BOARD_WINDOW}" now
  [[ -d "${BOARD_ROOT:-}" ]] || return 0
  now=$(date +%s)
  printf ' '
  LC_ALL=C awk -F'\t' -v now="$now" -v win="$win" '
    FNR == 1 { sid = FILENAME; sub(/.*\//, "", sid); sub(/\.tsv$/, "", sid)
               board = FILENAME; sub(/\/[^\/]*$/, "", board) }
    $1 ~ /^[0-9]+$/ && now - $1 <= win {
      k = board SUBSEP $4                      # 보드 + 상대경로 = 같은 논리 파일
      if (!((k SUBSEP sid) in mark)) { mark[k SUBSEP sid] = 1; owners[k]++ }
      mine[sid SUBSEP k] = 1 }
    END { for (mk in mine) { split(mk, a, SUBSEP)
            if (owners[a[2] SUBSEP a[3]] > 1) cnt[a[1]]++ }
          for (s in cnt) printf "%s:%d ", s, cnt[s] }
  ' "$BOARD_ROOT"/*/*.tsv 2>/dev/null
  return 0
}

# ---------------------------------------------------------------------------
# board_badge <sid> : 1행 배지 '⚠N'. 겹침이 없으면 빈 값.
#   맵은 BOARD_MAP 에 담겨 있다고 본다 (gen 이 루프 전에 한 번 채운다).
#   프로세스를 띄우지 않는다 — 파라미터 확장만 쓴다.
# ---------------------------------------------------------------------------
board_badge() {
  local sid="${1:-}" rest cnt
  [[ -n "$sid" && -n "${BOARD_MAP:-}" ]] || return 0
  case "$BOARD_MAP" in *" $sid:"*) ;; *) return 0 ;; esac
  rest="${BOARD_MAP##* "$sid":}"; cnt="${rest%% *}"
  [[ "$cnt" =~ ^[0-9]+$ ]] && (( cnt > 0 )) || return 0
  printf '%s%s%s%s' "$BOARDC" "$BOARD_EMOJI" "$cnt" "$RESET"
}

# ---------------------------------------------------------------------------
# board_block <sid> <cwd> : preview 하단 '이 세션이 만진 파일' 섹션.
#   자기 기록과 이웃 기록을 한 awk 에 같이 넘겨(FILENAME 으로 구분) 교차시킨다 —
#   겹치는 줄에는 ⚠ 와 상대 세션(짧은 id)을 붙인다.
#   보드가 없거나(훅 미설치) 기록이 없으면 아무것도 그리지 않는다.
# ---------------------------------------------------------------------------
board_block() {
  local sid="${1:-}" cwd="${2:-}" bd now rows nfile ncon
  [[ -n "$sid" && -n "$cwd" ]] || return 0
  bd=$(board_dir "$cwd/."); [[ -n "$bd" && -d "$bd" ]] || return 0
  [[ -f "$bd/$sid.tsv" ]] || return 0
  now=$(date +%s)
  # 출력: <경과초> \t <상대경로> \t <겹치는 세션들(공백 구분, 없으면 -)>
  rows=$(LC_ALL=C awk -F'\t' -v now="$now" -v win="$BOARD_WINDOW" -v self="$sid" '
    FNR == 1 { sid = FILENAME; sub(/.*\//, "", sid); sub(/\.tsv$/, "", sid); mine = (sid == self) }
    $1 ~ /^[0-9]+$/ && now - $1 <= win {
      age = now - $1
      if (mine) { if (!($4 in own) || age < own[$4]) own[$4] = age }
      else if (!(($4 SUBSEP sid) in seen)) {
        seen[$4 SUBSEP sid] = 1
        peer[$4] = (($4 in peer) ? peer[$4] " " : "") substr(sid, 1, 8) } }
    END { for (f in own) printf "%d\t%s\t%s\n", own[f], f, (f in peer ? peer[f] : "-") }
  ' "$bd"/*.tsv 2>/dev/null | sort -n)
  [[ -n "$rows" ]] || return 0

  nfile=$(printf '%s\n' "$rows" | wc -l | tr -d ' ')
  ncon=$(printf '%s\n' "$rows" | LC_ALL=C awk -F'\t' '$3 != "-"' | wc -l | tr -d ' ')

  printf '\n%s🗂 보드%s  내 편집 %s' "$GRAY" "$RESET" "$nfile"
  (( ncon > 0 )) && printf '%s · 겹침 %s%s' "$BOARDC" "$ncon" "$RESET"
  printf '\n'

  local shown=0 age path peers mark col
  while IFS=$'\t' read -r age path peers; do
    (( shown >= BOARD_BLK_MAX )) && { printf '%s  … 외 %s개%s\n' "$DIM" "$(( nfile - shown ))" "$RESET"; break; }
    shown=$(( shown + 1 ))
    if [[ "$peers" == "-" ]]; then mark=' '; col="$GRAY"
    else                           mark="$BOARD_EMOJI"; col="$BOARDC"; fi
    printf '  %s%4s%s %s%s%s %s' \
      "$DIM" "$(age_short "$age")" "$RESET" "$col" "$mark" "$RESET" \
      "$(trunc_disp "$path" "$BOARD_BLK_PATH_W")"
    [[ "$peers" != "-" ]] && printf ' %s← %s%s' "$BOARDC" "$peers" "$RESET"
    printf '\n'
  done < <(printf '%s\n' "$rows")
  return 0
}
