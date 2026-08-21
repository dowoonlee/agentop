# gen-agents.sh — 목록 행 생성(cursor-agent / codex CLI) — 두 도구는 라이브 status 를 안 내보내므로
#   iTerm2 화면 텍스트를 읽어 상태를 판정한다. claude 경로와 완전히 독립적.
#
# agentop 이 source 하는 모듈이다 (단독 실행 아님). 상수·헬퍼는 agentop 프로세스
# 하나 안에서 공유되므로, 여기 정의는 다른 모듈에서 그대로 보인다.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# --gen-cursor : 터미널에서 실행한 cursor-agent CLI 세션을 claude 와 같은 행 포맷으로.
#   cursor 는 라이브 status/waitingFor 를 안 내보내므로 iTerm2 화면 텍스트
#   (하단 CUR_TAIL 줄)를 읽어 HITL 문구를 매칭해 상태를 판정한다:
#     CUR_PAT_PERM 매칭          → waiting (권한 승인 — HITL 알림 대상)
#     CUR_PAT_ASK 매칭           → waiting (AskQuestion 응답 대기)
#     CUR_PAT_IDLE 매칭          → idle   (follow-up 입력 대기)
#     그 외 (화면 읽힘)          → busy   (생성 중)
#     화면 못 읽음(iTerm 외 등)  → cursor (기존 동작 — 상태 미상)
#   sid 는 "cursor:<pid>" 로 둬서 (1) preview 의 claude transcript 조회를 건너뛰고
#   (2) 커서 추적(posof)의 키를 고유하게 만든다.
# ---------------------------------------------------------------------------
parse_etime() {  # ps etime ([[dd-]hh:]mm:ss) → 초
  local e="${1:-}" d=0 h=0 m=0 s=0 a b c
  [[ -z "$e" ]] && { echo 0; return; }
  [[ "$e" == *-* ]] && { d="${e%%-*}"; e="${e#*-}"; }
  IFS=: read -r a b c <<<"$e"
  if [[ -n "$c" ]]; then h=$a; m=$b; s=$c; else m=$a; s=$b; fi
  echo $(( 10#${d:-0}*86400 + 10#${h:-0}*3600 + 10#${m:-0}*60 + 10#${s:-0} ))
}

# cursor_screens <tty>... : 넘긴 tty 들의 iTerm2 화면 텍스트를 한 번의
#   osascript 호출로 전부 가져온다 (호출당 100ms+ 라 tty 마다 부르면 폴링이 밀림).
#   출력: "@@TTY:<tty>" 마커 줄 + 해당 화면 내용 블록의 반복.
cursor_screens() {
  osascript - "$@" 2>/dev/null <<'OSA'
on run argv
  set out to ""
  tell application "iTerm2"
    repeat with w in windows
      repeat with t in tabs of w
        repeat with s in sessions of t
          # 주의: 비교값을 변수로 빼면(예: set st to tty of s) iTerm2 사전 용어와
          # 충돌해 osascript 문법 오류가 난다 — 직접 비교 유지할 것
          repeat with a in argv
            if (tty of s) is ("/dev/" & a) then
              set out to out & "@@TTY:" & a & linefeed & (contents of s) & linefeed
            end if
          end repeat
        end repeat
      end repeat
    end repeat
  end tell
  return out
end run
OSA
}

# ---------------------------------------------------------------------------
# cursor_classify : stdin=화면 텍스트(하단 CUR_TAIL 줄) → "상태\037대기사유" 한 줄.
#   관측 결과 권한 메뉴·AskQuestion 활성 박스는 처리되는 즉시 화면에서 지워지고
#   요약 잔상으로 교체된다 → PERM/PERM_LIVE/ASK_LIVE 는 잔상이 불가능한 상태
#   정확 마커라 화면 전체 매칭이 안전하다. IDLE 만 하단 입력박스(마지막 ▄▄▄
#   경계 이후) 한정으로 매칭해 본문 텍스트 오탐을 막는다.
# ---------------------------------------------------------------------------
cursor_classify() {
  local scr active
  scr=$(cat)
  [[ -z "${scr//[$' \t\n']/}" ]] && { printf 'cursor\037\n'; return 0; }
  active=$(printf '%s\n' "$scr" | awk '/▄▄▄/{n=NR} {l[NR]=$0} END{if(n) for(i=n;i<=NR;i++) print l[i]}')
  [[ -z "${active//[$' \t\n']/}" ]] && active="$scr"   # 박스 경계 못 찾으면 전체로 폴백
  if grep -qE "$CUR_PAT_PERM|$CUR_PAT_PERM_LIVE" <<<"$scr"; then
    printf 'waiting\037권한 승인\n'
  elif grep -qE "$CUR_PAT_ASK_LIVE" <<<"$scr"; then
    printf 'waiting\037질문 응답\n'
  elif grep -qE "$CUR_PAT_IDLE" <<<"$active"; then
    printf 'idle\037\n'
  else
    printf 'busy\037\n'
  fi
}

gen_cursor() {
  local now; now=$(date +%s)
  local pids=() ttys=() cwds=() cpus=() rsss=() starteds=()
  local pid ptty pcpu prss etime tty cpu cwd
  # cmdline 에 '/cursor-agent ' 를 가진 것만 → IDE 내장 extension-host 는 제외됨
  while read -r pid; do
    read -r ptty pcpu prss etime < <(ps -o tty=,%cpu=,rss=,etime= -p "$pid" 2>/dev/null)
    tty="${ptty:-}"
    [[ -z "$tty" || "$tty" == "??" ]] && continue   # tty 없는 백그라운드/플러그인 제외
    cpu="${pcpu%%.*}"; [[ "$cpu" =~ ^[0-9]+$ ]] || cpu=0
    cwd=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
    [[ -z "$cwd" ]] && cwd="?"
    pids+=("$pid"); ttys+=("$tty"); cwds+=("$cwd"); cpus+=("$cpu")
    rsss+=( $(( ${prss:-0} / 1024 )) )
    starteds+=( $(( (now - $(parse_etime "$etime")) * 1000 )) )
  done < <(pgrep -f '/cursor-agent ' 2>/dev/null)
  (( ${#pids[@]} )) || return 0

  local screens; screens=$(cursor_screens "${ttys[@]}")

  local i dir lab col1 status waiting scrtail icon st proj wtb ctxc
  ctxc=$(ctx_cell "")   # claude transcript 가 없어 컨텍스트 사용률은 미상('-')
  for i in "${!pids[@]}"; do
    pid="${pids[$i]}"; tty="${ttys[$i]}"; cwd="${cwds[$i]}"
    dir=$(basename "$cwd" 2>/dev/null)
    scrtail=$(printf '%s\n' "$screens" \
      | awk -v t="@@TTY:${tty}" '$0==t{f=1;next} /^@@TTY:/{f=0} f' \
      | tail -n "$CUR_TAIL")
    IFS=$'\037' read -r status waiting < <(printf '%s\n' "$scrtail" | cursor_classify)
    status="${status:-cursor}"; waiting="${waiting:-}"
    wtb=$(wt_badge "$cwd")
    lab=""
    [[ -n "$waiting" ]] && lab="← $waiting"
    if [[ "$status" == waiting ]]; then
      # HITL — claude 의 ◐ WAIT 행과 같은 강조, ◆ 로 cursor 임만 구분
      col1=$(printf '%s ◆ WAIT %s%s%s %s%s%s %s%s%s%s' \
        "$HL" "$RESET" "$ACT_L$ACT_R" "$ctxc" "${BOLD}${RED}" "$(dir_cell "$dir")" "$RESET" \
        "${wtb:+$wtb }" "${BOLD}${RED}" "$lab" "$RESET")
    else
      case "$status" in
        busy) icon="${YELLOW}◆${RESET}"; st="busy" ;;
        idle) icon="${CYAN}◆${RESET}";   st="idle" ;;
        *)    icon="${CYAN}◆${RESET}";   st="cur" ;;
      esac
      col1=$(printf '%s %-5s %s%s %s%s%s %s%s%s%s' \
        "$icon" "$st" "$ACT_L$ACT_R" "$ctxc" "$BLUE" "$(dir_cell "$dir")" "$RESET" \
        "${wtb:+$wtb }" "$GRAY" "$lab" "$RESET")
    fi
    col1="$col1$VT$(meta_line "$cwd")"   # cursor 는 모델/모드가 없어 브랜치만
    proj=$(git_root "$cwd"); proj="${proj:-$cwd}"
    printf '%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\0370\0370\0370\0370\037\n' \
      "$col1" "$pid" "$tty" "cursor:$pid" "$cwd" "${starteds[$i]}" "$status" "$waiting" "$dir" "${cpus[$i]}" "${rsss[$i]}" "$proj" "$(git_worktree "$cwd")"
  done
}

# ---------------------------------------------------------------------------
# codex_classify : stdin=화면 텍스트(하단 CDX_TAIL 줄) → "상태\037대기사유" 한 줄.
#   PERM 마커(승인 모달) → waiting, BUSY 마커(인터럽트 힌트) → busy, 그 외 → idle.
#   cursor 와 달리 ▄▄▄ 입력박스 경계가 없어 화면 전체(tail)를 매칭한다 — 두 마커
#   모두 codex 고유 문구라 본문 오탐 위험이 낮다.
# ---------------------------------------------------------------------------
codex_classify() {
  local scr
  scr=$(cat)
  [[ -z "${scr//[$' \t\n']/}" ]] && { printf 'codex\037\n'; return 0; }
  if grep -qE "$CDX_PAT_PERM" <<<"$scr"; then
    printf 'waiting\037승인 대기\n'
  elif grep -qE "$CDX_PAT_BUSY" <<<"$scr"; then
    printf 'busy\037\n'
  else
    printf 'idle\037\n'
  fi
}

# ---------------------------------------------------------------------------
# --gen-codex : 터미널에서 실행한 codex CLI 세션을 claude 와 같은 행 포맷으로.
#   cursor 와 동일하게 라이브 status 를 안 내보내므로 iTerm2 화면 텍스트를 읽어
#   판정한다. 후보는 `pgrep -x codex`(comm 정확매칭) — 여기엔 GUI(Codex.app)의
#   `codex app-server` 도 섞이지만 tty 가 ??(없음)이라 아래 tty 필터로 제외된다.
#   sid 는 "codex:<pid>" 로 둬서 preview transcript 조회를 건너뛰고 커서 추적
#   키를 고유화한다.
# ---------------------------------------------------------------------------
gen_codex() {
  local now; now=$(date +%s)
  local pids=() ttys=() cwds=() cpus=() rsss=() starteds=()
  local pid ptty pcpu prss etime tty cpu cwd
  while read -r pid; do
    [[ -z "$pid" ]] && continue
    read -r ptty pcpu prss etime < <(ps -o tty=,%cpu=,rss=,etime= -p "$pid" 2>/dev/null)
    tty="${ptty:-}"
    [[ -z "$tty" || "$tty" == "??" ]] && continue   # app-server·GUI 헬퍼(tty 없음) 제외
    cpu="${pcpu%%.*}"; [[ "$cpu" =~ ^[0-9]+$ ]] || cpu=0
    cwd=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
    [[ -z "$cwd" ]] && cwd="?"
    pids+=("$pid"); ttys+=("$tty"); cwds+=("$cwd"); cpus+=("$cpu")
    rsss+=( $(( ${prss:-0} / 1024 )) )
    starteds+=( $(( (now - $(parse_etime "$etime")) * 1000 )) )
  done < <(pgrep -x codex 2>/dev/null)
  (( ${#pids[@]} )) || return 0

  local screens; screens=$(cursor_screens "${ttys[@]}")   # 화면 캡처 헬퍼는 cursor 와 공용

  local i dir lab col1 status waiting scrtail icon st proj wtb ctxc
  ctxc=$(ctx_cell "")   # claude transcript 가 없어 컨텍스트 사용률은 미상('-')
  for i in "${!pids[@]}"; do
    pid="${pids[$i]}"; tty="${ttys[$i]}"; cwd="${cwds[$i]}"
    dir=$(basename "$cwd" 2>/dev/null)
    # codex 는 내용이 화면 상단에 몰리고 하단이 공백인 경우가 많아, 그냥 tail 하면
    # 빈 줄만 잡힌다 → trailing 공백 줄을 먼저 제거한 뒤 마지막 CDX_TAIL 줄을 본다.
    scrtail=$(printf '%s\n' "$screens" \
      | awk -v t="@@TTY:${tty}" '$0==t{f=1;next} /^@@TTY:/{f=0} f' \
      | awk 'NF{last=NR} {ln[NR]=$0} END{for(i=1;i<=last;i++) print ln[i]}' \
      | tail -n "$CDX_TAIL")
    IFS=$'\037' read -r status waiting < <(printf '%s\n' "$scrtail" | codex_classify)
    status="${status:-codex}"; waiting="${waiting:-}"
    wtb=$(wt_badge "$cwd")
    lab=""
    [[ -n "$waiting" ]] && lab="← $waiting"
    if [[ "$status" == waiting ]]; then
      # HITL — claude 의 ◐ WAIT 행과 같은 강조, ◈ 로 codex 임만 구분
      col1=$(printf '%s ◈ WAIT %s%s%s %s%s%s %s%s%s%s' \
        "$HL" "$RESET" "$ACT_L$ACT_R" "$ctxc" "${BOLD}${RED}" "$(dir_cell "$dir")" "$RESET" \
        "${wtb:+$wtb }" "${BOLD}${RED}" "$lab" "$RESET")
    else
      case "$status" in
        busy) icon="${YELLOW}◈${RESET}";  st="busy" ;;
        idle) icon="${MAGENTA}◈${RESET}"; st="idle" ;;
        *)    icon="${MAGENTA}◈${RESET}"; st="cdx" ;;
      esac
      col1=$(printf '%s %-5s %s%s %s%s%s %s%s%s%s' \
        "$icon" "$st" "$ACT_L$ACT_R" "$ctxc" "$BLUE" "$(dir_cell "$dir")" "$RESET" \
        "${wtb:+$wtb }" "$MAGENTA" "$lab" "$RESET")
    fi
    col1="$col1$VT$(meta_line "$cwd")"   # codex 도 모델/모드가 없어 브랜치만
    proj=$(git_root "$cwd"); proj="${proj:-$cwd}"
    printf '%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\0370\0370\0370\0370\037\n' \
      "$col1" "$pid" "$tty" "codex:$pid" "$cwd" "${starteds[$i]}" "$status" "$waiting" "$dir" "${cpus[$i]}" "${rsss[$i]}" "$proj" "$(git_worktree "$cwd")"
  done
}
