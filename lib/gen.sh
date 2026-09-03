# gen.sh — 목록 행 생성(claude 세션) + 최종 조립 — 행 배지·2행 메타·프로젝트 그룹핑·dir 폭 맞춤.
#   cursor/codex 행은 gen-agents.sh, 화면에 그리는 쪽은 ui.sh 담당.
#
# agentop 이 source 하는 모듈이다 (단독 실행 아님). 상수·헬퍼는 agentop 프로세스
# 하나 안에서 공유되므로, 여기 정의는 다른 모듈에서 그대로 보인다.
# ---------------------------------------------------------------------------
# wt_badge <cwd> : 1행 워크트리 배지 '⑂ <이름>'. 본체 체크아웃이면 빈 값.
#   같은 프로젝트 그룹 안에 워크트리가 여럿일 수 있으므로 이름까지 찍는다
#   (dir 컬럼은 17자로 잘려 서로 구분이 안 되는 경우가 있음).
wt_badge_r() {   # <cwd> [이미 구해 둔 git_dir]
  local w
  git_worktree_r "${1:-}" "${2:-}"; w="$_r"
  _r=""
  [[ -z "$w" ]] && return 0
  if (( ! WIDE )) && (( ${#w} > WT_MAX )); then w="${w:0:$((WT_MAX-1))}…"; fi
  _r="${WTC}⑂ ${w}${RESET}"
}
wt_badge() { wt_badge_r "${1:-}" "${2:-}"; printf '%s' "$_r"; }

# dir_cell <dir> : 1행 dir 컬럼 셀 — 원문을 RS(0x1e)…GS(0x1d) 마커로 감싸 두기만
#   한다. 실제 폭(2단=DIR_W 고정 / 목록만=가장 긴 dir)은 행 전체를 봐야 정해지므로
#   마지막 단계인 fit_dir 이 자르기·패딩을 한다. 생성기 셋(claude/cursor/codex)은
#   서로의 dir 길이를 모르기 때문에 여기서 열을 맞출 수 없다.
dir_cell() { printf '\036%s\035' "${1:-}"; }

# ---------------------------------------------------------------------------
# act_cell [서브에이전트수] [shell수] [monitor수] [서버수] [컨테이너수] : 1행 활동 배지 슬롯.
#   🤖서브에이전트 · ⚡백그라운드 shell · 🔭Monitor · 🌐서버 · 🐳컨테이너 를 state 와
#   ctx 사이에 모은다.
#   🌐🐳 를 뒤에 둔 이유 — 앞의 셋은 '언젠가 끝나는 일' 이라 개수가 오르내리지만
#   서버·컨테이너는 띄워 두면 계속 있다. 변동이 적은 것을 끝에 두면 앞자리가
#   흔들려도 눈이 따라가는 자리가 덜 움직인다. 그중에서도 🐳 가 맨 끝인 건 스택을
#   한 번 올리면 세션이 끝날 때까지 그대로인 쪽이라서다.
#   앞의 icon(1)·state(5) 가 고정폭이라 슬롯 시작점이 항상 같은 자리 — 목록을
#   세로로 훑으면 '지금 뭔가 돌고 있는 세션' 만 한 열에서 바로 잡힌다.
#   (dir 뒤에 두던 시절엔 앞의 워크트리 배지가 행마다 길이가 달라 x 좌표가
#   제각각이었고, 어느 세션에 붙은 배지인지 눈으로 못 따라갔다.)
#
#   dir_cell 과 같은 이유로 여기서는 마커로 감싸 두기만 한다 — 슬롯 폭은 그
#   순간 가장 넓은 행을 봐야 정해지므로 fit_dir 이 맞춘다. 인자 없이 부르면
#   빈 셀(폭 0) — cursor/codex 행이 열만 맞출 때 쓴다.
#
#   폭은 셀과 함께 US 로 붙여 내보낸다. 셀에 ANSI 가 섞여 있어 표시폭을 나중에
#   다시 세기 번거롭고(이모지 2칸 + 공백 1칸 + 색코드 0칸), 헤더도 같은 값이 필요하다.
#   숫자에만 색을 주는 건 이모지가 ANSI 를 안 먹기 때문 (const.sh 참조).
# ---------------------------------------------------------------------------
act_cell_r() {   # 셀은 _r, 표시폭은 _r2 로 낸다 (값이 둘인 유일한 헬퍼)
  local nag="${1:-}" nsh="${2:-0}" nmon="${3:-0}" nsrv="${4:-0}" ndkr="${5:-0}" s="" w=0
  [[ "$nsh"  =~ ^[0-9]+$ ]] || nsh=0
  [[ "$nmon" =~ ^[0-9]+$ ]] || nmon=0
  [[ "$nsrv" =~ ^[0-9]+$ ]] || nsrv=0
  [[ "$ndkr" =~ ^[0-9]+$ ]] || ndkr=0
  [[ -n "$nag" ]] && { s+="${AG_EMOJI} ${YELLOW}${nag}${RESET}";  w=$(( w + 3 + ${#nag} )); }
  (( nsh  > 0 )) && { s+="${SH_EMOJI} ${SHC}${nsh}${RESET}";      w=$(( w + 3 + ${#nsh} )); }
  (( nmon > 0 )) && { s+="${MON_EMOJI} ${MONC}${nmon}${RESET}";   w=$(( w + 3 + ${#nmon} )); }
  (( nsrv > 0 )) && { s+="${SRV_EMOJI} ${SRVC}${nsrv}${RESET}";   w=$(( w + 3 + ${#nsrv} )); }
  (( ndkr > 0 )) && { s+="${DKR_EMOJI} ${DKRC}${ndkr}${RESET}";   w=$(( w + 3 + ${#ndkr} )); }
  _r="${ACT_L}${s}${ACT_R}"; _r2="$w"
}
act_cell() { act_cell_r "${1:-}" "${2:-0}" "${3:-0}" "${4:-0}" "${5:-0}"; printf '%s\037%s' "$_r" "$_r2"; }

# ---------------------------------------------------------------------------
# meta_line <cwd> [model_pretty] [mode_badge] : 행의 2번째 줄.
#   '⎇ 브랜치 · 모델 · 권한모드' 를 ' · ' 로 이어 붙인다. 모델은 1행 배지처럼
#   축약(op5)하지 않고 full name(opus5/sonnet4.5/…) 그대로 — 2행을 쓰는 이유.
#   cursor/codex 세션은 모델/모드가 없어 브랜치만 나온다. git 저장소가 아니면
#   세그먼트를 빼지 않고 'no-git' 을 흐리게 박는다 — 자리가 비면 '브랜치를 못
#   읽은 건지 저장소가 아닌 건지' 헷갈리므로 항상 명시한다.
# ---------------------------------------------------------------------------
meta_line_r() {   # <cwd> [모델] [모드배지] [이미 구해 둔 git_dir]
  local cwd="${1:-}" pretty="${2:-}" badge="${3:-}" gd="${4:-}" br out="" sep mc
  sep="${DIM} · ${RESET}"
  git_branch_r "$cwd" "$gd"; br="$_r"
  if [[ -n "$br" ]]; then
    # 긴 브랜치명이 뒤의 모델/모드를 밀어내지 않게 잘라 표시 (전체 값은 preview 에).
    # 목록만(wide) 모드는 자리가 넉넉하므로 원문 그대로.
    if (( ! WIDE )) && (( ${#br} > META_BR_MAX )); then br="${br:0:$((META_BR_MAX-1))}…"; fi
    out="${GREENB}⎇ ${br}${RESET}"
  else
    out="${DIM}⎇ no-git${RESET}"
  fi
  if [[ -n "$pretty" ]]; then
    model_color_r "$pretty"; mc="$_r"
    out+="${out:+$sep}${mc}${pretty}${RESET}"
  fi
  [[ -n "$badge" ]] && out+="${out:+$sep}${badge}"
  _r="${META_IND}${DIM}└${RESET} ${out}"
}
meta_line() { meta_line_r "${1:-}" "${2:-}" "${3:-}" "${4:-}"; printf '%s' "$_r"; }

# ---------------------------------------------------------------------------
# sub_live <transcript> : 최근 SUB_LIVE 초 안에 쓰기가 있었던 서브에이전트 수.
#   0 이거나 서브에이전트가 없으면 빈 값 — 목록 1행에 '● N agents' 로 붙는다.
#   판정 근거는 preview 와 동일(jsonl mtime = 마지막 활동). subagents 디렉터리가
#   없는 세션은 stat 도 안 돌아서 폴링 부담이 사실상 없다.
# ---------------------------------------------------------------------------
sub_live_r() {   # <transcript> [지금 epoch — 루프에서 한 번만 구해 넘긴다]
  local tx="${1:-}" now="${2:-}" sub n
  _r=""
  [[ -n "$tx" ]] || return 0
  sub="${tx%.jsonl}/subagents"
  [[ -d "$sub" ]] || return 0
  [[ -n "$now" ]] || now=$(date +%s)
  # awk 가 직접 세게 해 wc|tr 두 프로세스를 뺐다 (같은 값).
  n=$(stat -f '%m' "$sub"/agent-*.jsonl 2>/dev/null \
      | LC_ALL=C awk -v n="$now" -v w="$SUB_LIVE" '$1 > n-w { c++ } END { print c+0 }')
  (( ${n:-0} > 0 )) && _r="$n"
  return 0
}
sub_live() { sub_live_r "${1:-}" "${2:-}"; printf '%s' "$_r"; }

# ---------------------------------------------------------------------------
# tx_scan <transcript.jsonl> : model \037 permissionMode \037 cwd \037 ctx토큰.
#   model_of / mode_of / cwd_of / ctx_of 를 각각 부르면 세션마다 꼬리를 네 번
#   읽고 프로세스를 열몇 개 띄우게 된다. 2초 폴링 경로(gen)에서는 tail 1회 +
#   awk 1회로 네 값을 한꺼번에 뽑는다. 개별 헬퍼는 preview(선택 1개)용으로 남긴다.
#   추출 규칙은 개별 헬퍼와 동일하며, 값이 없으면 해당 칸이 빈 문자열이다.
# ---------------------------------------------------------------------------
tx_scan() {
  [[ -f "${1:-}" ]] || { printf '\037\037\037'; return 0; }
  # LC_ALL=C + tail -n +2 : tail -c 는 UTF-8 문자 중간을 자를 수 있고, macOS awk 는
  # 그 조각에서 'towc: multibyte conversion failure' 로 죽어 빈 결과를 낸다.
  # 바이트 모드로 돌리고 잘렸을 수 있는 첫 줄은 버린다(세션 시작 레코드라 무해).
  tail -c 262144 "$1" 2>/dev/null | LC_ALL=C awk '
    { if (match($0, /"model":"[^"<]*"/))         mdl = substr($0, RSTART+9,  RLENGTH-10)
      if (match($0, /"permissionMode":"[^"]*"/)) pm  = substr($0, RSTART+18, RLENGTH-19)
      if (match($0, /"cwd":"[^"]*"/))            cw  = substr($0, RSTART+7,  RLENGTH-8)
      if ($0 ~ /"usage":\{/ && $0 !~ /"isSidechain":true/ && $0 !~ /"isApiErrorMessage":true/) {
        t = 0
        if (match($0, /"input_tokens":[0-9]+/))                t += substr($0, RSTART+15, RLENGTH-15)
        if (match($0, /"cache_read_input_tokens":[0-9]+/))     t += substr($0, RSTART+26, RLENGTH-26)
        if (match($0, /"cache_creation_input_tokens":[0-9]+/)) t += substr($0, RSTART+30, RLENGTH-30)
        toks = t
      }
    }
    END { printf "%s\037%s\037%s\037%s", mdl, pm, cw, toks }'
}

# ---------------------------------------------------------------------------
# --gen : interactive 세션 1개당 레코드 1줄 (화면에는 VT 로 나뉜 2줄로 렌더)
#   필드(\037 구분): 1 표시(col1) 2 pid 3 tty 4 sessionId 5 cwd 6 startedAt
#                    7 status 8 waitingFor 9 name 10 cpu% 11 rssMB 12 project 13 worktree
#                    14 활동슬롯폭 15~19·21 헤더 통계 원자료 20 포트목록(preview 용)
#   12 project 는 목록 그룹핑 키 — git 저장소면 루트(워크트리는 본 저장소), 아니면 cwd.
#   13 worktree 는 행 중복 판정용 — 실효 cwd 가 링크된 워크트리면 그 이름, 아니면 빈 값.
# ---------------------------------------------------------------------------
gen() {
  # 세션 보드 — 겹침 수 맵을 루프 전에 한 번만 만든다. 세션마다 보드를 다시 훑으면
  # 2초 폴링에서 세션 수만큼 프로세스가 늘어난다 (board_badge 는 이 문자열만 본다).
  local BOARD_MAP; BOARD_MAP=$(board_map)
  # 로컬 서버 — 리스닝 포트 맵도 같은 이유로 루프 전 1회 (lsof+ps 각 1번, ~0.15초).
  local SRV_MAP; SRV_MAP=$(srv_map)
  # compose 컨테이너 — 여기서는 캐시만 읽는다. docker ps 는 데몬 상태에 따라 몇
  # 초까지 늘어져 2초 폴링을 통째로 미룰 수 있어, 갱신은 백그라운드로만 건다
  # (dkr_warm). 그래서 이번 목록에 반영되는 건 직전에 받아 둔 한 벌이다.
  dkr_warm
  local DKR_MAP; DKR_MAP=$(dkr_map)
  # 필드 구분자는 US(0x1f). 탭은 bash read 에서 빈 필드가 병합되어 못 씀.
  # 세션 목록을 파이프로 바로 while 에 물리지 않고 한 번 받아 둔다 — 파이프로
  # 흘리면 pid 를 미리 모을 수 없어 ps 를 세션마다 따로 불러야 한다(아래 PS_MAP).
  local rows
  rows=$(claude agents --json 2>/dev/null | jq -r '
    [ .[] | select(.kind=="interactive") ]
    | sort_by(.pid) | .[] |
    [ (.pid|tostring), (.status // "?"), (.waitingFor // ""), .cwd,
      (.name // ""), (.sessionId // "-"), ((.startedAt // 0)|tostring) ] | join("")
  ')
  [[ -n "$rows" ]] || return 0

  # ps 는 한 번만 부른다. 세션마다 부르면 폴링 한 바퀴에 ps 가 세션 수만큼 뜨는데,
  # 이 환경에서 ps 한 번이 ~7ms 라 그것만으로 세션 5개에 35ms 다. pid 를 콤마로
  # 이어 한 번에 묻고, 각 행은 아래에서 파라미터 확장으로 제 줄만 집어 간다.
  # awk 로 필드를 다시 짜는 건 ps -o pid= 가 폭에 맞춰 앞을 공백으로 채우기
  # 때문 — 그대로 두면 pid 앞 공백 수가 자릿수마다 달라 매칭이 어긋난다.
  local plist="" PS_MAP="" NOW p
  while IFS=$'\037' read -r p _; do
    [[ -n "$p" ]] && plist="${plist:+$plist,}$p"
  done <<< "$rows"
  [[ -n "$plist" ]] && PS_MAP=$'\n'$(ps -o pid=,tty=,%cpu=,rss=,stat= -p "$plist" 2>/dev/null \
    | LC_ALL=C awk '{ print $1" "$2" "$3" "$4" "$5 }')$'\n'
  # sub_live 가 세션마다 date 를 부르지 않도록 지금 시각도 한 번만 구한다.
  NOW=$(date +%s)

  # 루프 안에서만 쓰는 값들 — 예전엔 파이프 서브셸이 감싸 줘서 함수 밖으로 안
  # 샜는데, 이제 서브셸이 없으므로 여기서 명시적으로 함수 스코프에 가둔다.
  local tty dir icon st lab col1 psline
  while IFS=$'\037' read -r pid status waiting cwd name sid started; do
        [[ -n "$pid" ]] || continue
        # tty + cpu + rss + stat 은 위에서 받아 둔 ps 한 벌에서 제 줄만 집어 온다.
        # cpu 는 정수%(리스트 표시·서명용), rss 는 MB(요약/preview 용).
        # cpu 정수화로 idle(0%) 은 서명 안정 → 깜빡임 없음.
        local ptty pcpu prss pstat
        ptty=""; pcpu=""; prss=""; pstat=""
        case "$PS_MAP" in *$'\n'"$pid "*)
          psline="${PS_MAP#*$'\n'"$pid" }"; psline="${psline%%$'\n'*}"
          ptty="${psline%% *}";  psline="${psline#* }"
          pcpu="${psline%% *}";  psline="${psline#* }"
          prss="${psline%% *}";  psline="${psline#* }"
          pstat="${psline%% *}" ;;
        esac
        tty="${ptty:-}"
        [[ -z "$tty" || "$tty" == "??" ]] && tty="-"
        local cpu="${pcpu%%.*}"; [[ "$cpu" =~ ^[0-9]+$ ]] || cpu=0
        local rssmb=$(( ${prss:-0} / 1024 ))
        # 정지(ps stat 이 T) 프로세스는 --json 이 마지막으로 보고된 status(대개 idle)를
        # 그대로 주지만, 실물은 SIGTSTP 로 멈춰 자식(MCP 서버·git·좀비)을 물고 남은
        # 잔재다. 워크트리 진입처럼 세션이 프로세스를 갈아탈 때 원본이 이 꼴로 남으면
        # 같은 sessionId 가 목록에 두 줄로 선다 — ps 의 실물 상태로 덮어써 구분한다.
        # waitingFor 도 함께 지운다: 멈춘 세션의 대기 사유는 응답할 사람이 없어
        # HITL 알림·통계에 섞이면 안 된다.
        [[ "$pstat" == T* ]] && { status="stopped"; waiting=""; }
        # basename 프로세스를 안 띄운다 — 마지막 조각이 비는 건 cwd 가 '/' 일 때뿐.
        dir="${cwd##*/}"; [[ -z "$dir" && -n "$cwd" ]] && dir="/"
        # --json 은 waitingFor 를 안 주므로 세션 파일에서 폴백 (HITL 상세 사유).
        # 파일을 셸로 먼저 읽어 그 키가 있을 때만 jq 를 부른다 — 이 파일들엔 대개
        # waitingFor 가 없어서(실측: 10개 중 0개) 세션마다 jq 를 헛돌리고 있었다.
        if [[ -z "$waiting" ]]; then
          local sjf="$HOME/.claude/sessions/$pid.json" sjc
          if [[ -f "$sjf" ]]; then
            sjc=$(< "$sjf")
            case "$sjc" in *'"waitingFor"'*)
              waiting=$(jq -r '.waitingFor // ""' "$sjf" 2>/dev/null) ;;
            esac
          fi
        fi
        case "$status" in
          busy)    icon="${YELLOW}●${RESET}"; st="busy" ;;
          waiting) icon="${RED}◐${RESET}";    st="wait" ;;
          idle)    icon="${GRAY}○${RESET}";   st="idle" ;;
          stopped) icon="${STOPC}⊘${RESET}";  st="stop" ;;
          *)       icon="${DIM}·${RESET}";    st="${status:0:4}" ;;
        esac
        # 세션명 컬럼은 뺐다(디렉터리·프로젝트 구분선과 중복). 이 자리는 워크트리
        # 배지 + 상태 사유(HITL/detached) 전용.
        lab=""
        [[ -n "$waiting" ]] && lab="← $waiting"
        [[ "$tty" == "-" ]] && lab="${lab:+$lab }(detached)"
        # 정지 세션은 st 컬럼('stop')만으로는 '무엇을 해야 하나' 가 안 나온다 —
        # 살릴 수 없는 잔재라는 것과 정리 수단(k)까지 한 줄에 적는다.
        [[ "$status" == stopped ]] && lab="${lab:+$lab }(정지됨 — k 로 정리)"
        # transcript 경로는 model/mode/ctx/실효cwd 공용이라 한 번만 계산.
        local tx mdl pm ecwd toks pretty badge ctxc sc
        tx_of_r "$cwd" "$sid"; tx="$_r"
        # model / mode / 실효cwd / ctx토큰을 tail 1회 + awk 1회로 한꺼번에.
        # 꼬리 256KB 에 없는 값만 개별 헬퍼로 보강한다(그쪽에 전체 스캔 폴백이 있음).
        sc=$(tx_scan "$tx")
        mdl="${sc%%$'\037'*}";  sc="${sc#*$'\037'}"
        pm="${sc%%$'\037'*}";   sc="${sc#*$'\037'}"
        ecwd="${sc%%$'\037'*}"; toks="${sc#*$'\037'}"
        [[ -z "$mdl"  ]] && mdl=$(model_of "$tx")
        [[ -z "$pm"   ]] && pm=$(mode_of "$tx")
        [[ -z "$ecwd" ]] && ecwd=$(cwd_of "$tx")
        [[ -z "$toks" ]] && toks=$(ctx_of "$tx")
        model_pretty_r "$mdl"; pretty="$_r"
        mode_badge_r "$pm";    badge="$_r"       # permission mode — default 면 빈 값
        ctx_cell_n_r "$toks";  ctxc="$_r"        # 목록에는 cpu% 대신 컨텍스트 사용률
        # 프로젝트 그룹과 dir 컬럼은 시작 cwd 로 둔다(세션이 돌아다녀도 자리가
        # 안 튀게). 반면 브랜치·워크트리는 '지금 어디서 일하는지' 가 알고 싶은
        # 값이라 실효 cwd 로 뽑는다. 단 프로젝트 밖으로 나간 경우는 행이
        # 앞뒤로 안 맞게 되므로 시작 cwd 로 되돌린다.
        local proj wt wtb egd
        git_root_r "$cwd"; proj="${_r:-$cwd}"
        case "$ecwd" in "$proj"|"$proj"/*) ;; *) ecwd="$cwd" ;; esac
        # ecwd 의 .git 을 한 번만 찾아 워크트리 이름·배지·2행 브랜치가 나눠 쓴다
        # (예전엔 셋이 각자 상위로 거슬러 올라갔다).
        git_dir_r "$ecwd"; egd="$_r"
        git_worktree_r "$ecwd" "$egd"; wt="$_r"
        wt_badge_r "$ecwd" "$egd";     wtb="$_r"
        # 활동 배지(🤖⚡🔭)는 state 뒤 고정 슬롯으로 — act_cell 주석 참조.
        # dir 뒤에 남는 건 워크트리 배지 → 상태 사유 순.
        local nag nsh nmon nsrv ndkr actc actw tail1 bbadge since tl
        sub_live_r "$tx" "$NOW"; nag="$_r"
        epoch_iso_r "$started"; since="$_r"
        tl=$(tasks_live "$tx" "$since")
        nsh="${tl%%$'\037'*}"; nmon="${tl#*$'\037'}"
        # 서버 수는 transcript 가 아니라 포트 맵에서 온다 — 이 세션 pid 를 조상으로
        # 두고 리스닝 중인 프로세스의 개수다 (servers.sh 주석 참조).
        local sports
        srv_ports_r "$pid";    sports="$_r"
        srv_count_r "$sports"; nsrv="$_r"
        # 컨테이너 수는 귀속 근거가 또 다르다 — 데몬이 물고 있어 프로세스 조상으로는
        # 못 잡으므로, compose 가 박아 둔 working_dir 라벨이 이 세션의 실효 cwd 와
        # 같은 것을 센다. preview 의 🐳 목록과 같은 기준이라 숫자가 어긋나지 않는다.
        dkr_count_r "$ecwd"; ndkr="$_r"
        act_cell_r "$nag" "$nsh" "$nmon" "$nsrv" "$ndkr"; actc="$_r"; actw="$_r2"
        # 보드 배지(⚠ N)는 워크트리 배지 뒤 — '어디서 일하는지' 다음에 '누구와
        # 겹치는지' 가 오는 순서다. 겹침이 없으면 빈 값이라 자리를 안 차지한다.
        board_badge_r "$sid"; bbadge="$_r"
        tail1="$wtb"
        [[ -n "$bbadge" ]] && tail1="${tail1:+$tail1 }$bbadge"
        if [[ "$status" == waiting ]]; then
          # HITL 세션 — 행 강조: ◐ WAIT 배지(icon+state 자리) + 굵은 빨강 텍스트.
          # 배지가 8칸이라 활동 슬롯을 바로 이어 붙이면 뒤 컬럼이 일반 행과 같은 열에 선다.
          printf -v col1 '%s ◐ WAIT %s%s%s %s%s%s %s%s%s%s' \
            "$HL" "$RESET" "$actc" "$ctxc" "${BOLD}${RED}" $'\036'"$dir"$'\035' "$RESET" \
            "${tail1:+$tail1 }" "${BOLD}${RED}" "$lab" "$RESET"
        else
          # 정지 세션은 dir·사유를 한 톤 죽여 살아있는 행들 사이에서 눈에 덜 걸리게
          # 한다 (숨기지는 않는다 — 자식 프로세스를 물고 멈춰 있는 상태라 보여야 한다).
          local dirc="$BLUE" labc="$GRAY"
          [[ "$status" == stopped ]] && { dirc="$STOPC"; labc="$STOPC"; }
          printf -v col1 '%s %-5s %s%s %s%s%s %s%s%s%s' \
            "$icon" "$st" "$actc" "$ctxc" "$dirc" $'\036'"$dir"$'\035' "$RESET" \
            "${tail1:+$tail1 }" "$labc" "$lab" "$RESET"
        fi
        meta_line_r "$ecwd" "$pretty" "$badge" "$egd"
        col1="$col1$VT$_r"
        # 15~19 는 헤더 통계(stats)용 원자료 — 배지 개수와 모델은 col1 에 렌더만 돼
        # 있어 다시 못 뽑으므로 여기서 같이 실어 보낸다. 렌더에는 안 쓴다.
        # 20(포트 목록)은 preview 몫이다 — 별개 프로세스라 SRV_MAP 을 못 물려받는데,
        # 여기서 실어 보내면 패널을 그릴 때마다 lsof+ps 를 다시 도는 0.15초가 빠진다.
        # 21(실효 cwd)은 헤더 통계용이다 — stats 가 '어느 자리에 세션이 있나' 를
        # 알아야 컨테이너를 귀속된 것과 주인 없는 것으로 가를 수 있다. 5(시작 cwd)
        # 로는 안 된다: 배지가 실효 cwd 로 귀속을 판정하므로 기준이 어긋난다.
        # 컨테이너 '개수' 는 안 싣는다 — 같은 자리에 세션이 둘이면 둘 다 그 자리의
        # 개수를 갖고 있어, 행을 가로질러 더하면 같은 컨테이너를 두 번 센다.
        # stats 는 세션이 아니라 자리(working_dir)를 단위로 다시 센다.
        # 20(포트 목록) 뒤에 붙인 건 그 자리 번호를 건드리면 srv_snap_ports 가
        # 엉뚱한 필드를 읽기 때문이다.
        printf '%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\n' \
          "$col1" "$pid" "$tty" "$sid" "$cwd" "$started" "$status" "$waiting" "$name" "$cpu" "$rssmb" "$proj" "$wt" "$actw" \
          "${nag:-0}" "${nsh:-0}" "${nmon:-0}" "$pretty" "${nsrv:-0}" "${sports:-}" "${ecwd:-}"
     done <<< "$rows"
}

# ---------------------------------------------------------------------------
# gen_all : 세 도구의 행을 합쳐 최종 목록 순서로 만든다.
#   project(12) 별로 묶고, 그룹 첫 행 앞에 '━━ <프로젝트> ━━' 구분선을 붙인다.
#   fzf 는 선택 불가능한 행을 못 만들므로, 구분선은 그룹 첫 아이템의 표시
#   문자열(col1) 맨 앞에 VT 로 한 줄 더 얹는 방식이다.
#   그룹 순서는 '그 프로젝트가 처음 등장한 위치' 라 pid 오름차순이 유지되고,
#   세션이 추가/종료돼도 기존 그룹의 상대 순서가 흔들리지 않는다 (행 튐 방지).
#
#   waiting(HITL) 행을 맨 위로 끌어올리는 동작은 없다 — 대기 세션도 자기 프로젝트
#   자리를 지킨다. 인지 수단은 행 강조(◐ WAIT 빨강 배지) + 벨/macOS 알림이다.
#
#   반대로 정지(⊘ stop) 행은 그룹 안에서 맨 아래로 내린다. 살아있는 세션과 달리
#   돌아올 일이 없는 잔재라, 위에 남겨 두면 그 프로젝트에서 지금 뭐가 도는지
#   보려고 눈이 매번 그 줄을 건너뛰어야 한다. 지우지 않는 이유는 자식 프로세스
#   (MCP 서버·shell)를 물고 멈춰 있어서다 — 정리할 대상이 있다는 건 보여야 한다.
#   그룹 자체의 순서(처음 등장 위치)는 그대로라, 정지 세션만 남은 프로젝트도
#   자기 자리를 지킨다.
#
#   같은 그룹 안에서 화면에 보이는 dir 이 겹치는 행에는 pid(#1234)를 덧붙인다.
#   1행에 세션을 특정하는 값이 없어서(dir·워크트리·브랜치·모델 전부 디렉터리
#   속성) 같은 디렉터리의 세션 둘은 글자까지 같아지기 때문. 겹칠 때만 나온다.
# ---------------------------------------------------------------------------
gen_all() {
  local cols avail
  # 목록만(wide) 모드 판정 — 생성기·배지 헬퍼가 WIDE 를 보고 생략 규칙을 끈다.
  WIDE=0; preview_shown || WIDE=1
  # 폭은 파일이 우선 — resize 바인딩이 여기에 새 폭을 써 준다. env(CC_TOP_COLS)는
  # fzf 시작 시점 값으로 고정이라 백그라운드 --poll 프로세스가 갱신을 못 받는다.
  cols=$(cat "${CC_TOP_LST:-}.cols" 2>/dev/null)
  [[ "$cols" =~ ^[0-9]+$ ]] || cols="${CC_TOP_COLS:-80}"
  avail=$(( $(main_width "$cols") - 4 ))   # 메인 영역(패널 유무에 따라 ~48% 또는 전체) 에서 포인터 폭·여백 제외
  (( avail < 20 )) && avail=20
  # 구분선은 목록에서 바로 눈에 띄어야 하므로 DIM 이 아니라 GRAY + 굵은 괘선(━),
  # 프로젝트명은 볼드로 뽑는다 (2행의 흐린 메타 줄과 확실히 대비되게).
  { gen; gen_cursor; gen_codex; } | awk -F'\037' \
      -v VT="$VT" -v RULE="$GRAY" -v NAME="${BOLD}${BLUE}" \
      -v Z="$RESET" -v AV="$avail" '
    NF {
      k=$12
      if (!(k in seen)) { seen[k]=++g; ord[g]=k }
      # 살아있는 행(n)과 정지 행(s)을 따로 담아 END 에서 n → s 순으로 뽑는다.
      # 한 배열에 담고 나중에 정렬하지 않는 이유는 awk 배열이 순서를 안 지켜서다.
      if ($7=="stopped") rows[k,"s" ++scnt[k]]=$0
      else               rows[k,"n" ++ncnt[k]]=$0
      # 같은 자리에 보이는 행끼리 pid 를 덧붙이는 판정은 fit_dir 이 한다 — 그 판정에
      # 쓰는 dir 은 잘린 뒤 화면에 보이는 값이라, 폭이 정해진 뒤에야 비교가 된다.
    }
    END {
      for (n=1; n<=g; n++) {
        k=ord[n]; name=k; sub(/.*\//, "", name)
        pad=AV-length(name)-4; if (pad<0) pad=0
        rule=""; for (z=0; z<pad; z++) rule=rule "━"
        hdr=RULE "━━" Z " " NAME name Z " " RULE rule Z VT
        # 구분선은 그룹의 첫 행에 얹는다 — 정지 세션만 있는 그룹이면 그 행이 첫 행이다.
        first=1
        for (m=1; m<=ncnt[k]; m++) { print (first ? hdr : "") rows[k,"n" m]; first=0 }
        for (m=1; m<=scnt[k]; m++) { print (first ? hdr : "") rows[k,"s" m]; first=0 }
      }
    }' | fit_dir
}

# ---------------------------------------------------------------------------
# fit_dir : dir_cell 이 남긴 RS…GS 마커 구간을 실제 폭에 맞춘 dir 컬럼으로 바꾼다.
#   폭 결정에 '모든 행' 이 필요해서(가장 긴 dir 기준) 마지막 단계로 분리했다.
#     2단 모드   : DIR_W 고정 — 넘치면 … 로 줄임 (좁은 좌측 패널에서 열 유지)
#     목록만 모드: 가장 긴 dir 에 맞춰 확장 — 생략 없이 전부 보여 준다
#   폭 계산은 표시 폭 기준(dispwidth 와 같은 East-Asian 판정)이라 한글 디렉터리도
#   열이 맞는다. 같은 프로젝트·워크트리에서 '화면에 보이는 dir' 이 겹치는 행에는
#   pid(#1234)를 덧붙인다 — 잘린 뒤에야 겹치는 경우가 있어 폭이 정해진 여기서 한다.
#   헤더(build_header)는 같은 폭을 dir_width 로 따로 구한다 — 파일로 주고받지 않는다.
#
#   act_cell 이 남긴 SOH…STX 구간(활동 배지 슬롯)도 같은 이유로 여기서 맞춘다.
#   폭은 그 순간 가장 넓은 행 기준이되 ACT_W 아래로는 안 줄어든다 — 배지 1개짜리
#   (대부분)에서 폭이 고정돼 배지가 붙었다 떨어질 때마다 뒤 컬럼이 흔들리지 않는다.
#   슬롯 폭은 행마다 다시 세지 않고 마지막 필드(14)에 실려 온 값을 쓴다.
# ---------------------------------------------------------------------------
fit_dir() {
  WIDE="${WIDE:-0}" DIR_W="$DIR_W" ACT_W="$ACT_W" \
  PIDC="$GRAY" Z="$RESET" perl -CSA -e '
    no warnings;   # 깨진 UTF-8 이 섞인 경로에서 경고가 fzf 화면으로 새는 것 방지
    my ($wide, $dw0) = ($ENV{WIDE}, $ENV{DIR_W});
    my ($pidc, $z) = ($ENV{PIDC}, $ENV{Z});
    # 표시 폭 — dispwidth 와 같은 기준(East-Asian Wide/Fullwidth=2, 그 외=1)
    sub dw { my $w = 0; $w += (/\p{Ea=W}|\p{Ea=F}/ ? 2 : 1) for split //, ($_[0] // ""); $w }
    sub fit {                                   # 넘치면 … 로 줄이고, 남으면 공백으로 채운다
      my ($d, $w) = @_;
      if (dw($d) > $w) {
        my $o = ""; for my $c (split //, $d) { last if dw($o) + dw($c) > $w - 1; $o .= $c }
        $d = "$o\x{2026}";
      }
      $d . (" " x ($w - dw($d)));
    }
    my (@rows, @dir, @aw);
    my $max = $dw0;
    my $amax = $ENV{ACT_W} + 0;
    while (my $l = <STDIN>) {
      chomp $l;
      push @rows, $l;
      my $d = ($l =~ /\x1e([^\x1d]*)\x1d/) ? $1 : undef;
      push @dir, $d;
      $max = dw($d) if defined $d && dw($d) > $max;
      # 활동 배지 폭은 14번째 필드 (act_cell 이 세어 둔 값). 뒤에 집계용 필드가
      # 더 붙어 있어 맨 뒤에서 잡으면 안 된다. (이 perl 은 bash 작은따옴표 안이라
      # 주석에도 작은따옴표를 쓰면 스크립트가 거기서 끊긴다.)
      my $a = ((split /\x1f/, $l, -1)[13] // 0) + 0;
      push @aw, $a;
      $amax = $a if $a > $amax;
    }
    my $w = $wide ? $max : $dw0;   # 헤더 쪽 폭은 dir_width 가 같은 스냅샷에서 따로 구한다
    # 겹침 판정은 "화면에 보이는 dir" 기준 — 잘린 뒤에야 같아지는 행이 있어
    # 폭이 정해진 여기서 센다. 키: 프로젝트(12) + 보이는 dir + 워크트리(13)
    my (%cnt, @cell);
    for my $i (0 .. $#rows) {
      next unless defined $dir[$i];
      $cell[$i] = fit($dir[$i], $w);
      my @f = split /\x1f/, $rows[$i], -1;
      $cnt{ join "\x1f", $f[11] // "", $cell[$i], $f[12] // "" }++;
    }
    for my $i (0 .. $#rows) {
      my $l = $rows[$i];
      # 활동 배지 슬롯 — 폭을 맞추고 뒤에 구분 1칸. 슬롯을 아예 안 쓰는 설정
      # (ACT_W=0) 에서 아무 세션도 안 돌면 자리째 지운다.
      if ($amax > 0) {
        $l =~ s/\x01([^\x02]*)\x02/$1 . (" " x ($amax - $aw[$i] + 1))/e;
      } else {
        $l =~ s/\x01[^\x02]*\x02//;
      }
      if (defined $cell[$i]) {
        my @f = split /\x1f/, $l, -1;
        my $key = join "\x1f", $f[11] // "", $cell[$i], $f[12] // "";
        # pid 배지는 1행 끝(마커 뒤 첫 VT 앞)에 — 그룹 구분선의 VT 를 건드리면
        # 구분선과 본문이 뒤섞이므로 반드시 마커를 기준점으로 잡는다.
        $l =~ s/(\x1d[^\x0b]*)\x0b/$1 $pidc#$f[1]$z\x0b/ if $cnt{$key} > 1;
        $l =~ s/\x1e[^\x1d]*\x1d/$cell[$i]/;
      }
      print "$l\n";
    }
  '
}
