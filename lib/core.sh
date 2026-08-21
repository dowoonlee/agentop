# core.sh — 조회 헬퍼 — 세션 하나에서 model/mode/cwd/ctx/git 정보를 뽑는다.
#   gen(목록)과 preview(상세)가 공용으로 쓰는 계층이라 렌더링 코드는 두지 않는다.
#   뒤쪽 preview_shown/main_width/toggle_preview 는 2단↔목록만 모드 상태.
#
# agentop 이 source 하는 모듈이다 (단독 실행 아님). 상수·헬퍼는 agentop 프로세스
# 하나 안에서 공유되므로, 여기 정의는 다른 모듈에서 그대로 보인다.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# mode_of <transcript.jsonl> : 세션의 현재 permission mode (shift+tab 토글).
#   토글 시마다 transcript 에 permission-mode 레코드가 기록됨 → 마지막 값이 현재.
# mode_badge <mode> : 목록 행용 색 배지. default 는 노이즈라 표시 안 함.
# ---------------------------------------------------------------------------
mode_of() {
  [[ -f "${1:-}" ]] || return 0
  # model_of/ctx_of 와 같은 이유로 꼬리 256KB 만 훑는다 — 폴링마다 세션 수만큼
  # 도는데 transcript 는 수십 MB 까지 큰다. permissionMode 는 토글 때만이 아니라
  # 사용자 입력 레코드마다 실려서(실측: 12MB 파일 기준 꼬리에도 항상 존재) 대개
  # 여기서 잡히고, 없을 때만 전체를 훑는다.
  local m re='"permissionMode":"([^"]*)"'
  m=$(tail -c 262144 "$1" 2>/dev/null | grep -o '"permissionMode":"[^"]*"' | tail -1)
  [[ -z "$m" ]] && m=$(grep -o '"permissionMode":"[^"]*"' "$1" 2>/dev/null | tail -1)
  [[ "$m" =~ $re ]] && printf '%s' "${BASH_REMATCH[1]}"
  return 0
}

mode_badge() {
  case "${1:-}" in
    acceptEdits)       printf '%s⏵⏵accept%s' "$YELLOW" "$RESET" ;;
    plan)              printf '%s⏸ plan%s'    "$BLUE"   "$RESET" ;;
    bypassPermissions) printf '%s⏵⏵BYPASS%s' "$RED"    "$RESET" ;;
    # default·auto 는 사실상 모든 세션에 붙어 노이즈라 목록에선 생략한다
    # (preview 의 mode 줄에는 원래 값이 그대로 나온다)
    default|auto|'')   ;;
    *)                 printf '%s%s%s'        "$GRAY" "$1" "$RESET" ;;
  esac
}

# ---------------------------------------------------------------------------
# cwd_of <transcript.jsonl> : 세션의 '실효' 작업 디렉터리.
#   `claude agents --json` 의 cwd 는 세션을 시작한 디렉터리라, 도중에 워크트리로
#   옮겨 작업하면(EnterWorktree / cd) 실제 위치와 어긋난다. transcript 는 레코드
#   마다 그 시점의 cwd 를 싣기 때문에 마지막 값이 현재 위치다. 꼬리 우선.
# ---------------------------------------------------------------------------
cwd_of() {
  [[ -f "${1:-}" ]] || return 0
  local c re='"cwd":"([^"]*)"'
  c=$(tail -c 262144 "$1" 2>/dev/null | grep -o '"cwd":"[^"]*"' | tail -1)
  [[ -z "$c" ]] && c=$(grep -o '"cwd":"[^"]*"' "$1" 2>/dev/null | tail -1)
  [[ "$c" =~ $re ]] && printf '%s' "${BASH_REMATCH[1]}"
  return 0
}

# ---------------------------------------------------------------------------
# tx_of <cwd> <sessionId> : 세션 transcript(jsonl) 경로. 없으면 빈 문자열.
#   1차는 cwd 해시 규칙(/ . → -). 다만 세션 도중 프로세스 cwd 가 시작 디렉토리와
#   달라지면(툴에서 cd 등) 해시가 빗나가므로, 그때만 프로젝트 폴더를 sessionId
#   로 한 단계 glob 해서 찾는다 (디렉토리 수십 개 stat 이라 폴링에도 부담 없음).
# ---------------------------------------------------------------------------
tx_of() {
  local cwd="${1:-}" sid="${2:-}" p f
  [[ -z "$sid" || "$sid" == cursor:* || "$sid" == codex:* ]] && return 0
  p="$HOME/.claude/projects/$(printf '%s' "$cwd" | sed 's#[/.]#-#g')/$sid.jsonl"
  [[ -f "$p" ]] && { printf '%s' "$p"; return 0; }
  for f in "$HOME"/.claude/projects/*/"$sid.jsonl"; do
    [[ -f "$f" ]] && { printf '%s' "$f"; return 0; }
  done
  return 0
}

# ---------------------------------------------------------------------------
# model_of <transcript.jsonl> : 세션이 마지막으로 쓴 모델 id.
#   assistant 레코드마다 message.model 이 박히므로 마지막 값 = 현재 모델
#   (/model 로 바꾸면 다음 응답부터 새 값). transcript 는 수십 MB 까지 커지므로
#   꼬리 256KB 만 훑고, 거기 없을 때(응답이 적은 초기 세션)만 전체를 훑는다.
#   <synthetic> 은 로컬 생성 메시지라 모델이 아니므로 제외.
# model_pretty <id>  : claude- 접두·날짜 suffix 를 떼고 opus5 / haiku4.5 꼴로.
# model_color <pretty> : preview·2행 표시용 색.
# ---------------------------------------------------------------------------
model_of() {
  [[ -f "${1:-}" ]] || return 0
  local m
  m=$(tail -c 262144 "$1" 2>/dev/null | grep -o '"model":"[^"<]*"' | tail -1)
  [[ -z "$m" ]] && m=$(grep -o '"model":"[^"<]*"' "$1" 2>/dev/null | tail -1)
  m="${m#*:\"}"
  printf '%s' "${m%\"}"
}

model_pretty() {
  [[ -z "${1:-}" ]] && return 0
  printf '%s' "$1" | sed -E '
    s/^([a-z]+\.)?anthropic\.//
    s/^claude-//
    s/-v[0-9]+(:[0-9]+)?$//
    s/-[0-9]{8}$//
    s/^([a-z]+)-([0-9]+)-([0-9]+)$/\1\2.\3/
    s/^([0-9]+)-([0-9]+)-([a-z]+)$/\3\1.\2/
    s/^([a-z]+)-([0-9]+)$/\1\2/
  '
}

# ---------------------------------------------------------------------------
# ctx_of <transcript.jsonl> : 마지막 응답 시점의 컨텍스트 토큰 수. 없으면 빈 값.
#   assistant 레코드의 message.usage 에서 input + cache_read + cache_creation 을
#   더한 값 = 그 턴에 실제로 올라간 컨텍스트. 사이드체인(서브에이전트)·API 에러
#   레코드는 세션 컨텍스트가 아니라 제외한다.
#   폴링마다 세션 수만큼 불리므로 jq 로 전체 파싱하지 않고 꼬리 256KB 만 훑는다.
#   (tail -c 는 첫 줄이 잘려 나올 수 있어 tail -n +2 로 버린다. 파일이 256KB 보다
#    작아 진짜 첫 줄이 버려지는 경우도 그 줄은 세션 시작 레코드라 usage 가 없다.)
#   꼬리에 usage 가 없을 때만(응답이 적은 초기 세션) 전체를 훑는다.
# ctx_pct <transcript> : 사용률 정수(%). CTX_MAX 기준, 관측 토큰이 넘으면 1M 로 상향.
# ctx_cell <transcript> : 목록 1행의 4칸 셀. 90%+ 빨강 / 75%+ 노랑 (compact 사전 인지).
# ---------------------------------------------------------------------------
ctx_pick() {   # stdin=jsonl → 마지막 usage 레코드 한 줄 (바이트 모드: tx_scan 주석 참조)
  LC_ALL=C awk '/"usage":\{/ && !/"isSidechain":true/ && !/"isApiErrorMessage":true/ {l=$0} END{if (l!="") print l}'
}

ctx_of() {
  [[ -f "${1:-}" ]] || return 0
  local line it=0 cr=0 cc=0
  line=$(tail -c 262144 "$1" 2>/dev/null | tail -n +2 | ctx_pick)
  [[ -z "$line" ]] && line=$(ctx_pick < "$1" 2>/dev/null)
  [[ -z "$line" ]] && return 0
  # 숫자 추출은 bash 정규식으로 — 폴링마다 세션 수만큼 도니 서브프로세스를 안 띄운다.
  # 패턴이 여는 따옴표를 포함하므로 cache_*_input_tokens 에 오매칭되지 않는다.
  local re
  re='"input_tokens":([0-9]+)';                [[ "$line" =~ $re ]] && it="${BASH_REMATCH[1]}"
  re='"cache_read_input_tokens":([0-9]+)';     [[ "$line" =~ $re ]] && cr="${BASH_REMATCH[1]}"
  re='"cache_creation_input_tokens":([0-9]+)'; [[ "$line" =~ $re ]] && cc="${BASH_REMATCH[1]}"
  printf '%s' $(( it + cr + cc ))
}

ctx_pct_n() {   # <토큰 수> → 사용률 정수(%)
  local toks="${1:-}" cm p
  [[ "$toks" =~ ^[0-9]+$ ]] && (( toks > 0 )) || return 0
  cm=$CTX_MAX; (( toks > cm )) && cm=1000000
  p=$(( toks * 100 / cm )); (( p > 100 )) && p=100
  printf '%s' "$p"
}

ctx_pct() { ctx_pct_n "$(ctx_of "${1:-}")"; }

ctx_cell_n() {  # <토큰 수> → 목록 1행의 4칸 셀
  local p c; p=$(ctx_pct_n "${1:-}")
  [[ -z "$p" ]] && { printf '%s   -%s' "$DIM" "$RESET"; return 0; }
  c="$GRAY"
  (( p >= 75 )) && c="$YELLOW"
  (( p >= 90 )) && c="$RED"
  printf '%s%3d%%%s' "$c" "$p" "$RESET"
}

ctx_cell() { ctx_cell_n "$(ctx_of "${1:-}")"; }

model_color() {
  case "${1:-}" in
    opus*)   printf '%s' "$M_OPUS"   ;;
    sonnet*) printf '%s' "$M_SONNET" ;;
    haiku*)  printf '%s' "$M_HAIKU"  ;;
    fable*)  printf '%s' "$M_FABLE"  ;;
    *)       printf '%s' "$GRAY"     ;;
  esac
}

# ---------------------------------------------------------------------------
# git_dir <cwd> : 상위로 올라가며 찾은 .git 디렉터리 경로. 저장소가 아니면 빈 값.
#   폴링마다 세션 수만큼 불리므로 git 프로세스를 띄우지 않고 파일을 직접 본다.
#   worktree/submodule 은 .git 이 'gitdir: <경로>' 파일이라 한 단계 더 따라간다.
# git_branch <cwd> : 현재 브랜치명. detached 면 짧은 SHA. 저장소 아니면 빈 값.
# git_root <cwd>   : 프로젝트 루트. worktree/submodule 은 본 저장소(상위) 루트로
#   접히므로, 같은 저장소에서 파생된 세션들이 하나의 키로 묶인다 (목록 그룹핑용).
# git_worktree <cwd> : 링크된 워크트리에서 작업 중이면 그 워크트리 이름, 본체
#   체크아웃이면 빈 값. 같은 프로젝트 그룹 안에서 본체/워크트리를 구분하는 용도.
# ---------------------------------------------------------------------------
git_dir() {
  local d="${1:-}" gd=""
  [[ -z "$d" || "$d" == "?" ]] && return 0
  while [[ -n "$d" && "$d" != "/" ]]; do
    if [[ -d "$d/.git" ]]; then gd="$d/.git"; break; fi
    if [[ -f "$d/.git" ]]; then
      gd=$(sed -n 's/^gitdir: *//p' "$d/.git" 2>/dev/null | head -1)
      [[ -n "$gd" && "$gd" != /* ]] && gd="$d/$gd"
      break
    fi
    d="${d%/*}"
  done
  printf '%s' "$gd"
}

git_branch() {
  local gd head
  gd=$(git_dir "${1:-}")
  [[ -n "$gd" && -f "$gd/HEAD" ]] || return 0
  head=$(< "$gd/HEAD")
  if [[ "$head" == ref:* ]]; then
    head="${head#ref: }"
    printf '%s' "${head#refs/heads/}"
  else
    printf '%s' "${head:0:7}"        # detached HEAD
  fi
}

git_root() {
  local gd; gd=$(git_dir "${1:-}")
  case "$gd" in
    */.git/worktrees/*) printf '%s' "${gd%/.git/worktrees/*}" ;;  # 워크트리 → 본 저장소
    */.git/modules/*)   printf '%s' "${gd%/.git/modules/*}"   ;;  # 서브모듈 → 상위 저장소
    */.git)             printf '%s' "${gd%/.git}"             ;;
  esac
}

git_worktree() {
  local gd; gd=$(git_dir "${1:-}")
  case "$gd" in
    */.git/worktrees/*) printf '%s' "${gd##*/}" ;;
  esac
}

# ---------------------------------------------------------------------------
# preview_shown : 상세(preview) 패널이 현재 보이는지. 'p' 토글이 $lst.pv 를
#   뒤집고(1=표시, 0=목록만) 여기서 읽는다. 파일 없음 = 기본값(표시).
#   fzf 도 FZF_PREVIEW_COLUMNS 를 내보내지만 실행 시점에 따라 토글 전 값일
#   수 있어, 상태는 파일 하나로 단일화한다 (백그라운드 --poll 도 같은 파일).
# main_width <cols> : 목록(메인 영역) 가용 폭. 패널이 있으면 전체의 ~48%
#   (우측 preview 52% 제외), 없으면 전체 폭. gen_all 의 구분선 길이와
#   build_header 의 도움말 줄바꿈이 같은 값을 보게 한 곳에 모았다.
# ---------------------------------------------------------------------------
preview_shown() { [[ "$(cat "${CC_TOP_LST:-}.pv" 2>/dev/null)" != 0 ]]; }

main_width() {
  local cols="${1:-80}"
  [[ "$cols" =~ ^[0-9]+$ ]] || cols=80
  if preview_shown; then echo $(( cols * 48 / 100 )); else echo "$cols"; fi
}

# --toggle-preview : 패널 표시 상태 파일을 뒤집는다. fzf 의 toggle-preview 액션과
#   같은 바인딩 체인에서 연달아 불리므로 둘은 항상 같은 상태를 가리킨다.
toggle_preview() {
  local f="${CC_TOP_LST:-}.pv"
  [[ -n "${CC_TOP_LST:-}" ]] || return 0
  if preview_shown; then printf 0 > "$f"; else printf 1 > "$f"; fi
}
