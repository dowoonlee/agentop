# preview.sh — 우측 상세 패널 — 선택 세션의 cpu/mem·git·모델·컨텍스트 사용률과
#   서브에이전트/백그라운드 태스크 목록을 그린다.
#
# agentop 이 source 하는 모듈이다 (단독 실행 아님). 상수·헬퍼는 agentop 프로세스
# 하나 안에서 공유되므로, 여기 정의는 다른 모듈에서 그대로 보인다.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# --preview pid tty sid cwd started status waiting name
# ---------------------------------------------------------------------------
preview() {
  local pid="${1:-}" tty="${2:-}" sid="${3:-}" cwd="${4:-}" started="${5:-0}"
  local status="${6:-}" waiting="${7:-}" name="${8:-}"
  local title="${name:-$(basename "$cwd" 2>/dev/null)}"

  printf '%s%s%s\n' "$BLUE" "$title" "$RESET"
  printf '%s\n' "${DIM}────────────────────────────────────────${RESET}"

  if [[ "$sid" == cursor:* || "$sid" == codex:* ]]; then
    local toolname toolcol fb
    if [[ "$sid" == cursor:* ]]; then toolname="cursor-agent"; toolcol="$CYAN"; fb="cursor"
    else                              toolname="codex";        toolcol="$MAGENTA"; fb="codex"; fi
    printf '%stool   %s %s%s%s\n' "$GRAY" "$RESET" "$toolcol" "$toolname" "$RESET"
    if [[ "$status" != "$fb" ]]; then
      local stline="$status"
      [[ -n "$waiting" ]] && stline="$status  ${RED}← $waiting${RESET}"
      printf '%sstatus %s %s\n' "$GRAY" "$RESET" "$stline"
    fi
  else
    local stline="$status"
    [[ -n "$waiting" ]] && stline="$status  ${RED}← $waiting${RESET}"
    printf '%sstatus %s %s\n' "$GRAY" "$RESET" "$stline"
  fi
  printf '%scwd    %s %s\n' "$GRAY" "$RESET" "$cwd"
  # 세션이 시작 디렉터리를 떠나 워크트리 등에서 작업 중이면 현재 위치를 덧붙이고,
  # 브랜치·워크트리도 그 위치 기준으로 뽑는다 (목록 행과 같은 기준).
  local tx0 ecwd proj0 br wt
  tx0=$(tx_of "$cwd" "$sid")
  proj0=$(git_root "$cwd"); proj0="${proj0:-$cwd}"
  ecwd=$(cwd_of "$tx0")
  case "$ecwd" in "$proj0"|"$proj0"/*) ;; *) ecwd="$cwd" ;; esac
  [[ "$ecwd" != "$cwd" ]] && printf '       %s↳ %s%s\n' "$DIM" "${ecwd#$cwd/}" "$RESET"
  br=$(git_branch "$ecwd"); wt=$(git_worktree "$ecwd")
  if [[ -n "$br" ]]; then
    printf '%sbranch %s %s⎇ %s%s\n' "$GRAY" "$RESET" "$GREENB" "$br" "$RESET"
  else
    printf '%sbranch %s %s⎇ no-git%s\n' "$GRAY" "$RESET" "$DIM" "$RESET"
  fi
  [[ -n "$wt" ]] && printf '%swtree  %s %s⑂ %s%s\n' "$GRAY" "$RESET" "$WTC" "$wt" "$RESET"
  printf '%spid    %s %s   %stty%s %s\n' "$GRAY" "$RESET" "$pid" "$GRAY" "$RESET" "$tty"
  local tx
  tx=$(tx_of "$cwd" "$sid")
  if [[ "$sid" != cursor:* && "$sid" != codex:* ]]; then
    printf '%ssession%s %s\n' "$GRAY" "$RESET" "$sid"
    local model pretty mode badge
    model=$(model_of "$tx")
    if [[ -n "$model" ]]; then
      pretty=$(model_pretty "$model")
      printf '%smodel  %s %s%s%s\n' "$GRAY" "$RESET" "$(model_color "$pretty")" "$pretty" "$RESET"
    fi
    mode=$(mode_of "$tx")
    if [[ -n "$mode" ]]; then
      badge=$(mode_badge "$mode")
      printf '%smode   %s %s\n' "$GRAY" "$RESET" "${badge:-$mode}"
    fi
  fi

  # 실시간 cpu / 메모리 (선택 세션 1개라 ps 재호출 비용 작음)
  local pcpu prss
  read -r pcpu prss < <(ps -o %cpu=,rss= -p "$pid" 2>/dev/null)
  if [[ -n "$pcpu" ]]; then
    printf '%scpu/mem%s %s%%   %sMB\n' "$GRAY" "$RESET" "$pcpu" "$(( ${prss:-0} / 1024 ))"
  fi

  # 실행 경과(age)
  if [[ "$started" =~ ^[0-9]+$ && "$started" -gt 0 ]]; then
    local now diff
    now=$(date +%s); diff=$(( now - started/1000 ))
    local age
    if   (( diff < 60 ));    then age="${diff}s"
    elif (( diff < 3600 ));  then age="$((diff/60))m"
    elif (( diff < 86400 )); then age="$((diff/3600))h $(((diff%3600)/60))m"
    else age="$((diff/86400))d $(((diff%86400)/3600))h"
    fi
    printf '%sage    %s %s\n' "$GRAY" "$RESET" "$age"
  fi

  # 컨텍스트 사용률 + 마지막 user 메시지 (transcript 있을 때만)
  [[ -f "$tx" ]] || return 0

  local toks
  toks=$(ctx_of "$tx")            # 목록 ctx 컬럼과 같은 값을 쓰도록 헬퍼 공용
  [[ "$toks" =~ ^[0-9]+$ ]] || toks=0

  if (( toks > 0 )); then
    # 상한은 CTX_MAX 기준이되, 관측 토큰이 그걸 넘으면 1M 세션이 확실하므로 자동 상향
    local cm=$CTX_MAX
    (( toks > cm )) && cm=1000000
    local pct=$(( toks * 100 / cm )); (( pct > 100 )) && pct=100
    # 임박 경고: 90%+ 빨강, 75%+ 노랑 (auto-compact 사전 인지)
    local cfill="$BLUE" cpct="$GRAY" warn=""
    if   (( pct >= 90 )); then cfill="$RED";    cpct="$RED";    warn="  ${RED}⚠ compact 임박${RESET}"
    elif (( pct >= 75 )); then cfill="$YELLOW"; cpct="$YELLOW"; fi
    local filled=$(( pct / 10 )) bar="" i
    for ((i=0; i<10; i++)); do
      if (( i < filled )); then bar+="${cfill}█${RESET}"; else bar+="${DIM}░${RESET}"; fi
    done
    printf '\n%sctx    %s %s %s%d%% (%dk / %dk)%s%s\n' \
      "$GRAY" "$RESET" "$bar" "$cpct" "$pct" "$((toks/1000))" "$((cm/1000))" "$RESET" "$warn"
  fi

  subagents_block "$tx"
  tasks_block "$tx" "$(epoch_iso "$started")"

  local last
  last=$(jq -rs '
    [ .[] | select(.type=="user")
      | select(.message.content | type=="string"
               or (type=="array" and any(.[]; .type=="text"))) ]
    | reverse
    | map(.message.content
          | if type=="string" then .
            else [ .[] | select(.type=="text") | .text ] | join(" ") end
          | gsub("\n"; " ") | gsub("  +"; " "))
    | map(select(startswith("[Request interrupted") or startswith("[Request cancelled") or . == "" | not))
    | first // ""' < "$tx" 2>/dev/null)
  if [[ -n "$last" ]]; then
    printf '\n%s💬 last%s %s\n' "$GRAY" "$RESET" "${last:0:240}"
  fi
}

# ---------------------------------------------------------------------------
# trunc_disp <문자열> <최대 폭> : 표시 폭 기준으로 자르고 넘치면 … 를 붙인다.
#   글자 수가 아니라 폭으로 세야 한다 — 한글 설명은 글자당 2칸이라 글자 수로
#   자르면 두 배로 삐져나온다. ASCII=1 / 그 외=2 의 근사이며(dispwidth 의 perl
#   프로세스를 preview 행마다 띄우지 않으려는 절충), 자르는 위치에만 영향을 준다.
# ---------------------------------------------------------------------------
trunc_disp() {
  local s="${1:-}" max="${2:-40}" out="" w=0 tw=0 i c cw
  for ((i=0; i<${#s}; i++)); do
    c="${s:$i:1}"
    if [[ "$c" == [[:ascii:]] ]]; then tw=$(( tw + 1 )); else tw=$(( tw + 2 )); fi
  done
  (( tw <= max )) && { printf '%s' "$s"; return 0; }
  # 잘릴 때는 … 가 차지할 1칸을 미리 빼둔다 (안 그러면 결과가 max+1 칸이 된다)
  for ((i=0; i<${#s}; i++)); do
    c="${s:$i:1}"
    if [[ "$c" == [[:ascii:]] ]]; then cw=1; else cw=2; fi
    (( w + cw > max - 1 )) && break
    out+="$c"; w=$(( w + cw ))
  done
  printf '%s…' "$out"
}

# ---------------------------------------------------------------------------
# age_short <초> : '46s' / '30m' / '2h' / '3d' 꼴 짧은 경과 표기 (최대 4칸).
# ---------------------------------------------------------------------------
age_short() {
  local s=${1:-0}
  if   (( s < 60 ));    then printf '%ds' "$s"
  elif (( s < 3600 ));  then printf '%dm' "$((s/60))"
  elif (( s < 86400 )); then printf '%dh' "$((s/3600))"
  else                       printf '%dd' "$((s/86400))"
  fi
}

# ---------------------------------------------------------------------------
# subagents_block <transcript> : preview 하단 '이 세션이 띄운 서브에이전트' 섹션.
#   Claude Code 는 서브에이전트를 <transcript 에서 .jsonl 을 뗀 경로>/subagents/
#   아래에 agent-<id>.jsonl + agent-<id>.meta.json 으로 남긴다. meta 에
#   agentType / description / spawnDepth 가 있어 그대로 보여준다.
#
#   '실행 중' 을 정확히 알 방법은 없다 — 백그라운드 spawn 이나 서브에이전트가
#   또 띄운 중첩 spawn(spawnDepth>=2) 은 완료돼도 부모 transcript 에 tool_result
#   가 안 남기 때문(실측: 43개 중 tool_result 로 잡히는 건 0개). 그래서 판정
#   대신 jsonl mtime 을 '마지막 활동' 으로 쓰고, SUB_LIVE 초 안이면 ● 로 둔다.
#   preview 는 선택된 세션에서만 도는 경로라 stat 1회 + jq 1회면 충분하다.
# ---------------------------------------------------------------------------
subagents_block() {
  local tx="${1:-}" sub listing now total live
  [[ -n "$tx" ]] || return 0
  sub="${tx%.jsonl}/subagents"
  [[ -d "$sub" ]] || return 0
  listing=$(stat -f '%m %N' "$sub"/agent-*.jsonl 2>/dev/null | sort -rn)
  [[ -n "$listing" ]] || return 0

  now=$(date +%s)
  total=$(printf '%s\n' "$listing" | wc -l | tr -d ' ')
  live=$(printf '%s\n' "$listing" | awk -v n="$now" -v w="$SUB_LIVE" '$1 > n-w' | wc -l | tr -d ' ')

  # description 은 한 행에 딱 맞게 자른다 — preview 창은 wrap 이라 안 자르면
  # 긴 설명 하나가 두세 줄을 먹는다. 폭은 fzf 가 preview 프로세스에 넘겨주는
  # FZF_PREVIEW_COLUMNS 를 쓰고, 직접 --preview 를 부른 경우만 폭을 추정한다.
  local pw dmax
  pw=${FZF_PREVIEW_COLUMNS:-0}
  (( pw > 0 )) || pw=$(( ${CC_TOP_COLS:-80} * 52 / 100 - 2 ))
  dmax=$(( pw - SUB_PREFIX_W ))
  (( dmax < 12 )) && dmax=12

  printf '\n%sagents %s %s개' "$GRAY" "$RESET" "$total"
  (( live > 0 )) && printf '   %s● %s개 활동중%s' "$YELLOW" "$live" "$RESET"
  printf '\n'

  local mts=() metas=() mt f
  while read -r mt f; do
    mts+=( "$mt" ); metas+=( "${f%.jsonl}.meta.json" )
    (( ${#metas[@]} >= SUB_MAX )) && break
  done <<< "$listing"

  # 구분자는 US(0x1f) — 탭은 IFS 공백류라 description 이 빈 값일 때 필드가
  # 병합돼 spawnDepth 가 description 자리로 밀려든다.
  local i=0 at ds dep mark diff nest dm
  while IFS=$'\037' read -r at ds dep; do
    diff=$(( now - ${mts[$i]} )); i=$((i+1))
    if (( diff < SUB_LIVE )); then mark="${YELLOW}●${RESET}"; else mark="${DIM}○${RESET}"; fi
    # spawnDepth>=2 는 서브에이전트가 또 띄운 것 — ↳ 로 한 단계 들여쓴다
    nest=""; dm=$dmax
    (( ${dep:-1} > 1 )) && { nest="${DIM}↳ ${RESET}"; dm=$(( dm - 2 )); }
    ds=$(trunc_disp "$ds" "$dm")
    [[ -z "$ds" ]] && ds="${DIM}(제목 없음)${RESET}"
    printf '  %s %s%4s%s %s%-*s%s %s%s\n' \
      "$mark" "$GRAY" "$(age_short "$diff")" "$RESET" \
      "$BLUE" "$SUB_TYPE_W" "$(trunc_disp "$at" "$SUB_TYPE_W")" "$RESET" "$nest" "$ds"
  done < <(jq -r '[(.agentType // "?"), (.description // ""), (.spawnDepth // 1 | tostring)]
                  | join("\u001f")' "${metas[@]}" 2>/dev/null)

  (( total > SUB_MAX )) && printf '  %s… 외 %s개%s\n' "$DIM" "$(( total - SUB_MAX ))" "$RESET"
}
# ---------------------------------------------------------------------------
# tasks_block <transcript> [since(ISO)] : preview 하단 '이 세션이 띄운 백그라운드
#   태스크' 섹션. 1열 아이콘이 상태 겸 종류다 — 실행 중이면 종류 아이콘
#   (▶ shell / ◉ monitor)에 색을 주고, 끝났으면 결과 표시(✓ 정상 / ✗ 실패 /
#   ⊘ 강제종료·타임아웃)로 바꾼다. since 보다 먼저 시작한 '실행 중' 은 이전
#   프로세스가 띄웠던 것이라 이미 죽었으므로 ⊘ 로 내린다 (epoch_iso 주석 참고).
#   age 는 '마지막 활동' 이 아니라 '시작 후 경과' — 실행 중인 태스크는 얼마나
#   오래 물고 있는지가, 끝난 태스크는 언제 것인지가 알고 싶은 값이다.
#   최신 것이 위로 오도록 뒤집어 찍는다 (subagents_block 과 같은 정렬).
# ---------------------------------------------------------------------------
tasks_block() {
  local tx="${1:-}" since="${2:-}" rows total run
  [[ -n "$tx" ]] || return 0
  rows=$(tasks_scan "$tx")
  [[ -n "$rows" ]] || return 0
  total=$(printf '%s\n' "$rows" | wc -l | tr -d ' ')
  run=$(printf '%s\n' "$rows" | awk -F'\037' -v since="$since" \
    '$2=="run" && (since=="" || $3=="" || $3>=since){n++} END{print n+0}')

  # 설명은 한 행에 딱 맞게 자른다 (subagents_block 과 같은 이유·같은 폭 계산)
  local pw dmax
  pw=${FZF_PREVIEW_COLUMNS:-0}
  (( pw > 0 )) || pw=$(( ${CC_TOP_COLS:-80} * 52 / 100 - 2 ))
  dmax=$(( pw - TASK_PREFIX_W ))
  (( dmax < 12 )) && dmax=12

  printf '\n%stasks  %s %s개' "$GRAY" "$RESET" "$total"
  (( run > 0 )) && printf '   %s● %s개 실행중%s' "$YELLOW" "$run" "$RESET"
  printf '\n'

  local now shown=0 k st ts ds mark kc age
  now=$(date +%s)
  while IFS=$'\037' read -r k st ts ds; do
    (( shown >= TASK_MAX )) && break
    shown=$(( shown + 1 ))
    if [[ "$k" == mon ]]; then kc="$MONC"; else kc="$SHC"; fi
    # 이전 프로세스가 띄운 미완결 태스크는 종료 기록이 없을 뿐 이미 죽었다
    [[ "$st" == run && -n "$since" && -n "$ts" && "$ts" < "$since" ]] && st="stale"
    case "$st" in
      run)       mark="${kc}$([[ "$k" == mon ]] && printf '%s' "$MON_ICON" || printf '%s' "$SH_ICON")${RESET}" ;;
      completed) mark="${DIM}✓${RESET}"; kc="$DIM" ;;
      failed)    mark="${RED}✗${RESET}";  kc="$DIM" ;;
      *)         mark="${DIM}⊘${RESET}"; kc="$DIM" ;;
    esac
    age=""
    local ep; ep=$(iso_epoch "$ts")
    [[ "$ep" =~ ^[0-9]+$ ]] && age=$(age_short $(( now - ep > 0 ? now - ep : 0 )))
    ds=$(trunc_disp "$ds" "$dmax")
    [[ -z "$ds" ]] && ds="${DIM}(설명 없음)${RESET}"
    printf '  %s %s%4s%s %s%-*s%s %s\n' \
      "$mark" "$GRAY" "$age" "$RESET" \
      "$kc" "$TASK_KIND_W" "$([[ "$k" == mon ]] && printf 'monitor' || printf 'shell')" "$RESET" "$ds"
  done < <(printf '%s\n' "$rows" | tail -r)

  (( total > TASK_MAX )) && printf '  %s… 외 %s개%s\n' "$DIM" "$(( total - TASK_MAX ))" "$RESET"
  return 0
}
