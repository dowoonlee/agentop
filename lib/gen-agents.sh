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
# ---------------------------------------------------------------------------
# agent_act_r <세션pid> <cwd> [서브에이전트 수] : cursor/codex 행의 활동 셀.
#   _r=셀, _r2=표시폭, _r3=포트 목록(레코드 20번 — preview 가 lsof 를 다시 안 돌게),
#   _r4=서버 수(레코드 19번 — 헤더 통계가 🌐 합계를 낼 때 본다).
#
#   claude 행(gen)과 근거를 맞춘다 — 🌐 는 이 pid 를 조상으로 두고 리스닝 중인
#   포트 수, 🐳 는 이 자리에서 뜬 compose 컨테이너 수다. 둘 다 맵 조회라 프로세스를
#   더 띄우지 않는다 (맵은 gen_all 이 루프 전에 한 벌 채워 둔다).
#
#   ⚡🔭 는 0 으로 둔다 — 백그라운드 shell·Monitor 는 claude transcript 에서만
#   읽히는 값이라 이 두 도구엔 근거가 아예 없다. 0 을 넘기면 배지가 안 붙는다.
# ---------------------------------------------------------------------------
agent_act_r() {
  local pid="${1:-}" cwd="${2:-}" nag="${3:-}" ports nsrv ndkr
  srv_ports_r "$pid";    ports="$_r"
  srv_count_r "$ports";  nsrv="$_r"
  dkr_count_r "$cwd";    ndkr="$_r"
  act_cell_r "$nag" 0 0 "$nsrv" "$ndkr"     # _r/_r2 는 여기서 확정된다
  _r3="$ports"; _r4="$nsrv"
}

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

  local i dir lab col1 status waiting scrtail icon proj wtb ctxc
  local actc actw sports nsrv ecwd
  ctxc=$(ctx_cell "")   # claude transcript 가 없어 컨텍스트 사용률은 미상('-')
  for i in "${!pids[@]}"; do
    pid="${pids[$i]}"; tty="${ttys[$i]}"; cwd="${cwds[$i]}"
    dir=$(basename "$cwd" 2>/dev/null)
    # 실효 cwd — cursor 는 claude 의 transcript 같은 '마지막으로 옮긴 자리' 기록이
    # 없어 프로세스 cwd 가 그대로 실효 cwd 다. 헤더 통계가 컨테이너를 귀속시킬 때
    # 이 값을 보므로(레코드 21), 비어 있으면 이 세션 자리의 스택이 통째로 주인
    # 없는 것으로 세어진다.
    ecwd="$cwd"; [[ "$ecwd" == "?" ]] && ecwd=""
    agent_act_r "$pid" "$ecwd"; actc="$_r"; actw="$_r2"; sports="$_r3"; nsrv="$_r4"
    scrtail=$(printf '%s\n' "$screens" \
      | awk -v t="@@TTY:${tty}" '$0==t{f=1;next} /^@@TTY:/{f=0} f' \
      | tail -n "$CUR_TAIL")
    IFS=$'\037' read -r status waiting < <(printf '%s\n' "$scrtail" | cursor_classify)
    status="${status:-cursor}"; waiting="${waiting:-}"
    wtb=$(wt_badge "$cwd")
    lab=""
    [[ -n "$waiting" ]] && lab="← $waiting"
    if [[ "$status" == waiting ]]; then
      # HITL — claude 의 대기 행과 같은 강조, ◆ 로 cursor 임만 구분. 배지 폭은
      # icon(1)+공백(1)+AGENT_W — 일반 행의 앞 블록과 같아 뒤 컬럼이 안 밀린다.
      col1=$(printf '%s◆ %-*s%s %s%s %s%s%s %s%s%s%s' \
        "$HL" "$AGENT_W" "$AGENT_CURSOR" "$RESET" "$actc" "$ctxc" \
        "${BOLD}${RED}" "$(dir_cell "$dir")" "$RESET" \
        "${wtb:+$wtb }" "${BOLD}${RED}" "$lab" "$RESET")
    else
      # 모양(◆)이 cursor 임을, 색이 상태를 말한다 — 이름은 뒤 agent 컬럼이 적으므로
      # 여기서 상태 단어를 또 쓰지 않는다 (gen.sh 의 claude 행과 같은 규칙).
      case "$status" in
        busy) icon="${YELLOW}◆${RESET}" ;;
        *)    icon="${CYAN}◆${RESET}"   ;;
      esac
      col1=$(printf '%s %s%-*s%s %s%s %s%s%s %s%s%s%s' \
        "$icon" "$AGENT_CURSOR_C" "$AGENT_W" "$AGENT_CURSOR" "$RESET" "$actc" "$ctxc" \
        "$BLUE" "$(dir_cell "$dir")" "$RESET" \
        "${wtb:+$wtb }" "$GRAY" "$lab" "$RESET")
    fi
    col1="$col1$VT$(meta_line "$cwd")"   # cursor 는 모델/모드가 없어 브랜치만
    proj=$(git_root "$cwd"); proj="${proj:-$cwd}"
    # 필드 배치는 claude 행(gen)과 같다 — 14 활동폭, 15~17 🤖⚡🔭, 18 모델,
    # 19 서버 수, 20 포트 목록, 21 실효 cwd, 22~23 headless 부모(cursor 엔 없다).
    # 18 은 비워 둔다: cursor 는 모델을 안 내보낸다.
    printf '%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\0370\0370\0370\037\037%s\037%s\037%s\037\037\n' \
      "$col1" "$pid" "$tty" "cursor:$pid" "$cwd" "${starteds[$i]}" "$status" "$waiting" "$dir" "${cpus[$i]}" "${rsss[$i]}" "$proj" "$(git_worktree "$cwd")" \
      "$actw" "${nsrv:-0}" "${sports:-}" "$ecwd"
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
# codex_subagent_parents <'pid pid' 세션 집합> : codex 세션이 낳은 서브에이전트를
#   자식 하나당 부모 세션 pid 한 줄로 낸다. 부모를 못 찾은 자식(GUI·플러그인이
#   직접 띄운 app-server)은 아무 줄도 안 낸다 — 목록에 근거가 없는 수를 얹느니
#   안 세는 편이 낫다.
#
#   서브에이전트 판정은 '실행 파일이 codex 이고 인자에 app-server 가 있다' 한
#   가지다. gen_codex 의 후보 루프도 같은 문자열(' app-server')로 거른다 — 둘이
#   어긋나면 행에서 뺀 프로세스를 배지에서도 안 세게 되어 서브에이전트가 통째로
#   사라진다.
#
#   여기서만 comm 이 아니라 args 첫 토큰으로 실행 파일을 본다. macOS ps 는 comm 을
#   args 와 함께 지정하면 16자로 잘라 버려서('/Applications/Co'), 경로가 긴
#   Codex.app 의 실행 파일이 comm 매칭에서 통째로 빠진다. 둘 다 실행 경로라 판정
#   성질은 같다.
#
#   부모는 ppid 한 칸으로 안 닿는다. 사이에 Codex.app 의 node/node_repl 이 두어
#   단계 끼어 있어서 트리를 거슬러 세션 집합에서 멈춘다 — hdls_parent_r 과 같은
#   규칙이되 사슬 타기까지 awk 안에서 끝낸다. 그쪽은 bash 파라미터 확장으로 매
#   단계 프로세스 맵 전체를 훑어서 한 번에 60ms 가 넘는다. headless 는 세션당
#   한 번이라 견디지만 서브에이전트는 자식마다라, 몇 개만 돼도 2초 폴링에
#   0.1초 단위로 얹힌다.
# ---------------------------------------------------------------------------
codex_subagent_parents() {
  local set="${1:-}"
  [[ -n "$set" ]] || return 0
  # ps 한 벌이면 자식 목록(argv0=codex + 인자에 app-server)과 ppid 사슬이 둘 다
  # 나온다. args 를 마지막 열에 두는 게 중요하다 — comm 을 args 와 같이 지정하면
  # macOS ps 가 16자로 잘라 경로가 긴 Codex.app 실행 파일이 통째로 빠진다.
  ps -axo pid=,ppid=,args= 2>/dev/null | LC_ALL=C awk -v sess=" $set " -v hop="$HDLS_HOP_MAX" '
    { par[$1] = $2 }
    $3 ~ /(^|\/)codex$/ && / app-server/ { kid[++n] = $1 }
    END {
      for (i = 1; i <= n; i++) {
        p = kid[i]
        for (h = 0; h < hop; h++) {
          p = par[p]
          if (p == "" || p + 0 <= 1) break
          if (index(sess, " " p " ") > 0) { print p; break }
        }
      }
    }'
  return 0
}

# Resolve a live PID through the rollout file it actually has open. Never guess
# from cwd/timestamps: multiple resumed sessions can share both.
codex_rollout_of() {
  local paths
  paths=$(lsof -a -p "$1" -Fn 2>/dev/null |
    sed -n '/^n.*\/rollout-.*\.jsonl$/s/^n//p' | sort -u)
  [[ -n "$paths" && "$paths" != *$'\n'* ]] || return 0
  printf '%s' "$paths"
}

# Only extract monitoring fields; prompts and tool output are never returned.
# Ignore incomplete trailing JSON while Codex is writing. Start with the tail;
# scan older records only if the current metadata or usage is missing.
codex_metrics_pick() {
  jq -Rn '
    reduce inputs as $line ({};
      ($line | try fromjson catch null) as $e |
      if $e.type == "turn_context" then
        .model = ($e.payload.model // .model) |
        .mode = ($e.payload.approval_policy // .mode) |
        .sandbox = ($e.payload.sandbox_policy.type // .sandbox)
      elif $e.type == "event_msg" and $e.payload.type == "token_count"
           and $e.payload.info != null then
        .tokens = ($e.payload.info.last_token_usage.total_tokens //
          (($e.payload.info.last_token_usage.input_tokens // 0) +
           ($e.payload.info.last_token_usage.output_tokens // 0))) |
        .cap = $e.payload.info.model_context_window
      else . end)'
}

codex_metrics_r() { # <rollout path> -> model, mode, sandbox, tokens, cap
  local file="${1:-}" data
  _r=""; _r2=""; _r3=""; _r4=""; _r5=""
  [[ -r "$file" ]] || return 0
  data=$(tail -c 1048576 "$file" 2>/dev/null | codex_metrics_pick)
  if ! printf '%s' "$data" | jq -e '.model != null and .tokens != null and .cap != null' >/dev/null; then
    data=$(codex_metrics_pick < "$file")
  fi
  IFS=$'\037' read -r _r _r2 _r3 _r4 _r5 < <(
    printf '%s' "$data" | jq -r '[.model, .mode, .sandbox, .tokens, .cap] |
      map(if . == null then "" else tostring end) | join("\u001f")')
}


# ---------------------------------------------------------------------------
# --gen-codex : 터미널에서 실행한 codex CLI 세션을 claude 와 같은 행 포맷으로.
#   cursor 와 동일하게 라이브 status 를 안 내보내므로 iTerm2 화면 텍스트를 읽어
#   판정한다. 후보는 `ps`의 comm 정확매칭이다. `pgrep -x codex`는 macOS에서
#   일부 실행 중인 Codex 프로세스를 누락시키는 경우가 있어 쓰지 않는다.
#
#   후보에는 `codex app-server` 가 두 갈래로 섞인다. GUI(Codex.app)·플러그인이
#   띄운 것은 tty 가 ??(없음)이라 tty 필터에서 빠지지만, **codex 세션이 낳은
#   서브에이전트**는 부모의 tty 를 그대로 물려받아 그 필터를 통과한다. 그대로 두면
#   같은 세션이 목록에 두 줄로 서고, 그 줄은 rollout 을 안 열어 모델도 컨텍스트도
#   빈 채로 남는다 — 화면에서 가장 눈에 걸리는 '정체불명 행' 이 이것이다.
#   그래서 args 로 갈라내 부모 세션 행의 🤖 배지로 접는다 (claude 서브에이전트와
#   같은 취급 — 세션이 아니라 그 세션의 활동이다).
#
#   sid 는 "codex:<pid>" 로 둬서 preview transcript 조회를 건너뛰고 커서 추적
#   키를 고유화한다.
# ---------------------------------------------------------------------------
gen_codex() {
  local now; now=$(date +%s)
  local pids=() ttys=() cwds=() cpus=() rsss=() starteds=()
  local pid ptty pcpu prss etime pargs tty cpu cwd
  while read -r pid; do
    [[ -z "$pid" ]] && continue
    read -r ptty pcpu prss etime pargs < <(ps -o tty=,%cpu=,rss=,etime=,args= -p "$pid" 2>/dev/null)
    tty="${ptty:-}"
    [[ -z "$tty" || "$tty" == "??" ]] && continue   # GUI·플러그인 헬퍼(tty 없음) 제외
    # 세션이 낳은 서브에이전트 — tty 를 물려받아 위 필터를 통과한다. 세션 행으로
    # 세우지 않고 건너뛴 뒤, 아래에서 부모 행의 🤖 로 접는다. 거르는 문자열은
    # codex_subagent_parents 의 awk 와 같아야 한다.
    case " $pargs " in *" app-server"*) continue ;; esac
    cpu="${pcpu%%.*}"; [[ "$cpu" =~ ^[0-9]+$ ]] || cpu=0
    cwd=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
    [[ -z "$cwd" ]] && cwd="?"
    pids+=("$pid"); ttys+=("$tty"); cwds+=("$cwd"); cpus+=("$cpu")
    rsss+=( $(( ${prss:-0} / 1024 )) )
    starteds+=( $(( (now - $(parse_etime "$etime")) * 1000 )) )
  # macOS의 pgrep은 관측 가능한 실제 `codex` 프로세스 일부를 반환하지 않을 수
  # 있다. ps의 comm 열은 실행 파일명이라 인자에 'codex'가 들어간 다른 프로세스를
  # 오탐하지 않고, 절대경로로 나올 경우도 함께 받는다.
  done < <(ps -axo pid=,comm= 2>/dev/null | awk '$2 ~ /(^|\/)codex$/ { print $1 }')
  (( ${#pids[@]} )) || return 0

  local screens; screens=$(cursor_screens "${ttys[@]}")   # 화면 캡처 헬퍼는 cursor 와 공용

  # 서브에이전트를 부모 행에 접는다 (🤖). 부모 후보는 이번 스냅샷의 세션 pid 집합
  # 뿐이라, 방금 걸러 낸 프로세스가 그대로 배지 근거가 된다.
  local nags=() pidset=" ${pids[*]} " par i
  for i in "${!pids[@]}"; do nags[$i]=0; done
  while read -r par; do
    [[ -n "$par" ]] || continue
    for i in "${!pids[@]}"; do
      [[ "${pids[$i]}" == "$par" ]] && { nags[$i]=$(( ${nags[$i]} + 1 )); break; }
    done
  done < <(codex_subagent_parents "$pidset")

  local dir lab col1 status waiting scrtail icon proj wtb ctxc model ctoks ccap
  local nag actc actw sports nsrv ecwd
  for i in "${!pids[@]}"; do
    pid="${pids[$i]}"; tty="${ttys[$i]}"; cwd="${cwds[$i]}"
    dir=$(basename "$cwd" 2>/dev/null)
    codex_metrics_r "$(codex_rollout_of "$pid")"
    model="$_r"; ctoks="$_r4"; ccap="$_r5"
    ctx_cell_cap_r "$ctoks" "$ccap"; ctxc="$_r"
    # 실효 cwd — codex 의 rollout 은 turn_context 에 cwd 를 남기지만 관측상 세션을
    # 띄운 자리에서 안 움직인다(워크트리로 들어가도 turn cwd 는 그대로다). 그래서
    # 프로세스 cwd 가 그대로 실효 cwd 다. 헤더 통계가 컨테이너 귀속에 쓰는 값이다.
    ecwd="$cwd"; [[ "$ecwd" == "?" ]] && ecwd=""
    nag=""; (( ${nags[$i]:-0} > 0 )) && nag="${nags[$i]}"
    agent_act_r "$pid" "$ecwd" "$nag"; actc="$_r"; actw="$_r2"; sports="$_r3"; nsrv="$_r4"
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
      # HITL — claude 의 대기 행과 같은 강조, ◈ 로 codex 임만 구분. 배지 폭은
      # icon(1)+공백(1)+AGENT_W — 일반 행의 앞 블록과 같아 뒤 컬럼이 안 밀린다.
      col1=$(printf '%s◈ %-*s%s %s%s %s%s%s %s%s%s%s' \
        "$HL" "$AGENT_W" "$AGENT_CODEX" "$RESET" "$actc" "$ctxc" \
        "${BOLD}${RED}" "$(dir_cell "$dir")" "$RESET" \
        "${wtb:+$wtb }" "${BOLD}${RED}" "$lab" "$RESET")
    else
      # 모양(◈)이 codex 임을, 색이 상태를 말한다 — cursor 행과 같은 규칙이다.
      case "$status" in
        busy) icon="${YELLOW}◈${RESET}"  ;;
        *)    icon="${MAGENTA}◈${RESET}" ;;
      esac
      col1=$(printf '%s %s%-*s%s %s%s %s%s%s %s%s%s%s' \
        "$icon" "$AGENT_CODEX_C" "$AGENT_W" "$AGENT_CODEX" "$RESET" "$actc" "$ctxc" \
        "$BLUE" "$(dir_cell "$dir")" "$RESET" \
        "${wtb:+$wtb }" "$MAGENTA" "$lab" "$RESET")
    fi
    # PID가 열고 있는 세션 기록의 최신 모델과 토큰 사용량을 표시한다.
    col1="$col1$VT$(meta_line "$cwd" "$model")"
    proj=$(git_root "$cwd"); proj="${proj:-$cwd}"
    # 필드 배치는 claude 행(gen)과 같다 — 14 활동폭, 15~17 🤖⚡🔭, 18 모델,
    # 19 서버 수, 20 포트 목록, 21 실효 cwd, 22~23 headless 부모(codex 엔 없다).
    # ⚡🔭 는 근거가 claude transcript 뿐이라 0 으로 둔다.
    printf '%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\0370\0370\037%s\037%s\037%s\037%s\037\037\n' \
      "$col1" "$pid" "$tty" "codex:$pid" "$cwd" "${starteds[$i]}" "$status" "$waiting" "$dir" "${cpus[$i]}" "${rsss[$i]}" "$proj" "$(git_worktree "$cwd")" \
      "$actw" "${nag:-0}" "${model:-}" "${nsrv:-0}" "${sports:-}" "$ecwd"
  done
}
