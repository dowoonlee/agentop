# core.sh — 조회 헬퍼 — 세션 하나에서 model/mode/cwd/ctx/git 정보를 뽑는다.
#   gen(목록)과 preview(상세)가 공용으로 쓰는 계층이라 렌더링 코드는 두지 않는다.
#   뒤쪽 preview_shown/main_width/toggle_preview 는 2단↔목록만 모드 상태.
#
# agentop 이 source 하는 모듈이다 (단독 실행 아님). 상수·헬퍼는 agentop 프로세스
# 하나 안에서 공유되므로, 여기 정의는 다른 모듈에서 그대로 보인다.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# _r 반환 규약
#   2초 폴링 경로(gen)는 세션 하나를 그릴 때마다 이 헬퍼들을 열몇 번 부른다.
#   `x=$(f ...)` 는 값 하나 받자고 서브셸을 띄운다. 서브셸 자체는 이 환경에서
#   0.7ms 로 싸지만, 그 안에서 외부 명령을 부르면 단가가 6~7ms 로 뛰고(sed·
#   basename·date·ps) jq 는 21ms 다. 세션 수만큼 곱해지는 자리라 값 하나 받자고
#   프로세스를 띄우는 습관이 폴링 한 바퀴를 통째로 밀어낸다.
#
#   그래서 계산 본체는 결과를 전역 `_r` 에 담는 `*_r` 함수로 두고, 기존 이름은
#   그것을 찍어 주는 한 줄 래퍼로 남긴다. 서브셸을 아끼는 것 자체보다, 이 형태여야
#   함수 안에서 sed·basename 같은 것을 걷어낼 자리가 보인다는 쪽이 크다.
#   preview 처럼 세션 하나만 그리는 자리는 가독성이 나은 기존 이름을 그대로 쓴다.
#
#   규약: `_r` 은 다음 `*_r` 호출이 덮어쓴다 — 부른 직후에 읽어 제 변수로 옮길 것.
#   값을 둘 내는 함수만 `_r2` 를 함께 쓴다 (act_cell_r).
_r=""; _r2=""

# ---------------------------------------------------------------------------
# mode_of <transcript.jsonl> : 세션의 현재 permission mode (shift+tab 토글).
#   토글 시마다 transcript 에 permission-mode 레코드가 기록됨 → 마지막 값이 현재.
# mode_badge <mode> [muted] : 목록 행용 색 배지. default 는 노이즈라 표시 안 함.
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

mode_badge_r() {   # <mode> [muted — 비어 있지 않으면 톤을 낮춘다]
  # muted 는 headless(-p) 행이 쓴다. 사람이 승인할 수 없는 세션이라 bypass 가
  # 기본값에 가까운데, 빨강으로 두면 그 줄에서 가장 시끄러운 것이 가장 뜻이 없는
  # 자리가 된다. 지운다는 선택도 있지만 '무엇이든 할 수 있는 세션' 인 건 여전히
  # 사실이라, 없애지 않고 회색으로 낮춰 둔다.
  case "${1:-}" in
    acceptEdits)       _r="${YELLOW}⏵⏵accept${RESET}" ;;
    plan)              _r="${BLUE}⏸ plan${RESET}"     ;;
    bypassPermissions)
      if [[ -n "${2:-}" ]]; then _r="${GRAY}⏵⏵bypass${RESET}"
      else                       _r="${RED}⏵⏵BYPASS${RESET}"; fi ;;
    # default·auto 는 사실상 모든 세션에 붙어 노이즈라 목록에선 생략한다
    # (preview 의 mode 줄에는 원래 값이 그대로 나온다)
    default|auto|'')   _r=""                          ;;
    *)                 _r="${GRAY}${1}${RESET}"       ;;
  esac
}
mode_badge() { mode_badge_r "${1:-}" "${2:-}"; printf '%s' "$_r"; }

# ---------------------------------------------------------------------------
# hdls_argv_r <ps args 한 줄> : headless(-p) 세션인지 + 그 세션에 던져진 프롬프트.
#   판정 근거를 tty/status 가 아니라 argv 로 두는 이유 — 없는 tty 도 없는 status 도
#   증상이지 원인이 아니다. 터미널을 잃은 대화형 세션이나 아직 등록 전인 세션도
#   같은 증상을 내므로, 세션을 headless 로 만드는 그 플래그(-p/--print)를 직접 본다.
#   프롬프트는 -p 다음부터 다음 '--플래그' 직전까지 — claude 는 프롬프트를 따옴표로
#   묶지 않아도 받으므로 여러 단어로 쪼개져 들어온다.
#   결과: _r = 1(headless) / 빈 값,  _r2 = 프롬프트 (없으면 빈 값)
# ---------------------------------------------------------------------------
hdls_argv_r() {   # <argv>
  local a=" ${1:-} " rest w
  _r=""; _r2=""
  case "$a" in
    *" -p "*|*" --print "*|*" -p"|*" --print") ;;
    *) return 0 ;;
  esac
  _r=1
  # -p 뒤를 프롬프트로 본다. --print 는 값을 안 받는 형태로도 쓰여(stdin 입력)
  # 뒤가 곧장 플래그면 빈 프롬프트가 나오는데, 그건 그대로 빈 값이 맞다.
  case "$a" in
    *" -p "*)      rest="${a#* -p }" ;;
    *" --print "*) rest="${a#* --print }" ;;
    *)             return 0 ;;
  esac
  for w in $rest; do
    case "$w" in --*) break ;; esac
    _r2="${_r2:+$_r2 }$w"
  done
  return 0
}
hdls_argv() { hdls_argv_r "${1:-}"; printf '%s' "$_r2"; }

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
tx_of_r() {
  local cwd="${1:-}" sid="${2:-}" p f
  _r=""
  [[ -z "$sid" || "$sid" == cursor:* || "$sid" == codex:* ]] && return 0
  # 프로젝트 폴더명은 cwd 의 '/' 와 '.' 을 '-' 로 바꾼 것. sed 파이프를 쓰던
  # 자리인데 세션마다 프로세스 둘이 떠서 파라미터 확장으로 옮겼다 (같은 결과).
  p="$HOME/.claude/projects/${cwd//[\/.]/-}/$sid.jsonl"
  [[ -f "$p" ]] && { _r="$p"; return 0; }
  for f in "$HOME"/.claude/projects/*/"$sid.jsonl"; do
    [[ -f "$f" ]] && { _r="$f"; return 0; }
  done
  return 0
}
tx_of() { tx_of_r "${1:-}" "${2:-}"; printf '%s' "$_r"; }

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

model_pretty_r() {
  local m="${1:-}" re
  _r=""
  [[ -z "$m" ]] && return 0
  # 아래는 sed -E 스크립트를 그대로 옮긴 것이다 — 순서가 뜻을 갖는다(앞 치환의
  # 결과에 뒤 치환이 걸린다). sed 파이프는 세션마다 프로세스 둘을 띄우는데
  # 모델 id 한 줄 다듬자고 낼 비용이 아니라 bash 정규식으로 내렸다.
  re='^([a-z]+\.)?anthropic\.(.*)$'; [[ "$m" =~ $re ]] && m="${BASH_REMATCH[2]}"
  m="${m#claude-}"
  re='^(.*)-v[0-9]+(:[0-9]+)?$';       [[ "$m" =~ $re ]] && m="${BASH_REMATCH[1]}"
  re='^(.*)-[0-9]{8}$';                [[ "$m" =~ $re ]] && m="${BASH_REMATCH[1]}"
  re='^([a-z]+)-([0-9]+)-([0-9]+)$';   [[ "$m" =~ $re ]] && m="${BASH_REMATCH[1]}${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"
  re='^([0-9]+)-([0-9]+)-([a-z]+)$';   [[ "$m" =~ $re ]] && m="${BASH_REMATCH[3]}${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
  re='^([a-z]+)-([0-9]+)$';            [[ "$m" =~ $re ]] && m="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
  _r="$m"
}
model_pretty() { model_pretty_r "${1:-}"; printf '%s' "$_r"; }

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

ctx_pct_n_r() {   # <토큰 수> → 사용률 정수(%)
  local toks="${1:-}" cm p
  _r=""
  [[ "$toks" =~ ^[0-9]+$ ]] && (( toks > 0 )) || return 0
  cm=$CTX_MAX; (( toks > cm )) && cm=1000000
  p=$(( toks * 100 / cm )); (( p > 100 )) && p=100
  _r="$p"
}
ctx_pct_n() { ctx_pct_n_r "${1:-}"; printf '%s' "$_r"; }

ctx_pct() { ctx_pct_n "$(ctx_of "${1:-}")"; }

ctx_cell_n_r() {  # <토큰 수> → 목록 1행의 4칸 셀
  local p c
  ctx_pct_n_r "${1:-}"; p="$_r"
  [[ -z "$p" ]] && { _r="${DIM}   -${RESET}"; return 0; }
  c="$GRAY"
  (( p >= 75 )) && c="$YELLOW"
  (( p >= 90 )) && c="$RED"
  printf -v _r '%s%3d%%%s' "$c" "$p" "$RESET"
}
ctx_cell_n() { ctx_cell_n_r "${1:-}"; printf '%s' "$_r"; }

ctx_cell() { ctx_cell_n "$(ctx_of "${1:-}")"; }

model_color_r() {
  case "${1:-}" in
    opus*)   _r="$M_OPUS"   ;;
    sonnet*) _r="$M_SONNET" ;;
    haiku*)  _r="$M_HAIKU"  ;;
    fable*)  _r="$M_FABLE"  ;;
    *)       _r="$GRAY"     ;;
  esac
}
model_color() { model_color_r "${1:-}"; printf '%s' "$_r"; }

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
git_dir_r() {
  local d="${1:-}" gd="" ln
  _r=""
  [[ -z "$d" || "$d" == "?" ]] && return 0
  while [[ -n "$d" && "$d" != "/" ]]; do
    if [[ -d "$d/.git" ]]; then gd="$d/.git"; break; fi
    if [[ -f "$d/.git" ]]; then
      # 'gitdir: <경로>' 를 읽는다. sed|head 를 쓰던 자리인데 워크트리 세션마다
      # 프로세스 둘이 떠서 셸 읽기로 옮겼다 — 규칙은 같다(첫 매칭 줄, 콜론 뒤
      # 공백은 몇 개든 뗀다).
      while IFS= read -r ln || [[ -n "$ln" ]]; do
        case "$ln" in gitdir:*)
          gd="${ln#gitdir:}"
          while [[ "$gd" == " "* ]]; do gd="${gd# }"; done
          break ;;
        esac
      done < "$d/.git"
      [[ -n "$gd" && "$gd" != /* ]] && gd="$d/$gd"
      break
    fi
    d="${d%/*}"
  done
  _r="$gd"
}
git_dir() { git_dir_r "${1:-}"; printf '%s' "$_r"; }

git_branch_r() {   # <cwd> [이미 구해 둔 git_dir — 있으면 그걸 쓴다]
  local gd="${2:-}" head
  _r=""
  [[ -n "$gd" ]] || { git_dir_r "${1:-}"; gd="$_r"; _r=""; }
  [[ -n "$gd" && -f "$gd/HEAD" ]] || return 0
  head=$(< "$gd/HEAD")
  if [[ "$head" == ref:* ]]; then
    head="${head#ref: }"
    _r="${head#refs/heads/}"
  else
    _r="${head:0:7}"                 # detached HEAD
  fi
}
git_branch() { git_branch_r "${1:-}" "${2:-}"; printf '%s' "$_r"; }

git_root_r() {   # <cwd> [이미 구해 둔 git_dir]
  local gd="${2:-}"
  [[ -n "$gd" ]] || { git_dir_r "${1:-}"; gd="$_r"; }
  case "$gd" in
    */.git/worktrees/*) _r="${gd%/.git/worktrees/*}" ;;  # 워크트리 → 본 저장소
    */.git/modules/*)   _r="${gd%/.git/modules/*}"   ;;  # 서브모듈 → 상위 저장소
    */.git)             _r="${gd%/.git}"             ;;
    *)                  _r=""                        ;;
  esac
}
git_root() { git_root_r "${1:-}" "${2:-}"; printf '%s' "$_r"; }

git_worktree_r() {   # <cwd> [이미 구해 둔 git_dir]
  local gd="${2:-}"
  [[ -n "$gd" ]] || { git_dir_r "${1:-}"; gd="$_r"; }
  case "$gd" in
    */.git/worktrees/*) _r="${gd##*/}" ;;
    *)                  _r=""          ;;
  esac
}
git_worktree() { git_worktree_r "${1:-}" "${2:-}"; printf '%s' "$_r"; }

# ---------------------------------------------------------------------------
# preview_mode : 화면 배치 상태. 'p' 가 $lst.pv 를 돌리고 여기서 읽는다.
#     1 = 2단   (좌 목록 / 우 상세)          — 기본값
#     0 = 목록만 (전체 폭)
#     2 = 활동   (위 상세 전체폭 / 아래 목록) — 서버·태스크를 상한 없이 편다
#   fzf 도 FZF_PREVIEW_COLUMNS 를 내보내지만 실행 시점에 따라 토글 전 값일
#   수 있어, 상태는 파일 하나로 단일화한다 (백그라운드 --poll 도 같은 파일).
#
# preview_shown : 패널이 보이는지 (1·2 는 보임, 0 은 숨김).
#
# main_width <cols> : 목록(메인 영역) 가용 폭. 2단일 때만 전체의 ~48% 고,
#   목록만과 활동은 전체 폭이다 — 활동은 위아래로 나누므로 목록이 가로를 다 쓴다.
#   gen_all 의 구분선 길이와 build_header 의 도움말 줄바꿈이 같은 값을 보게
#   한 곳에 모았다.
# ---------------------------------------------------------------------------
preview_mode() {
  local m; m=$(cat "${CC_TOP_LST:-}.pv" 2>/dev/null)
  case "$m" in 0|1|2) printf '%s' "$m" ;; *) printf 1 ;; esac
}

preview_shown() { [[ "$(preview_mode)" != 0 ]]; }

main_width() {
  local cols="${1:-80}"
  [[ "$cols" =~ ^[0-9]+$ ]] || cols=80
  case "$(preview_mode)" in
    1) echo $(( cols * 48 / 100 )) ;;
    *) echo "$cols" ;;
  esac
}

# --toggle-preview : 'p' — 배치를 2단 → 목록만 → 활동 → 2단 으로 돌린다.
#   fzf 쪽 창 조작은 --pvaction 이 따로 낸다 (액션 문자열은 상태를 바꾼 뒤에
#   읽어야 하므로 바인딩에서 이 함수보다 뒤에 온다).
toggle_preview() {
  local f="${CC_TOP_LST:-}.pv"
  [[ -n "${CC_TOP_LST:-}" ]] || return 0
  case "$(preview_mode)" in
    1) printf 0 > "$f" ;;
    0) printf 2 > "$f" ;;
    *) printf 1 > "$f" ;;
  esac
}

# --pvaction : 지금 상태에 맞는 fzf 창 액션 문자열. transform 바인딩이 이걸
#   그대로 실행한다. reload·헤더 갱신까지 여기서 만들지 않는 이유 — 그쪽은
#   따옴표가 겹겹이라 문자열로 조립하면 깨지기 쉽고, 바인딩에 고정으로 두면
#   모드와 무관하게 늘 같은 일이라 나눠 두는 편이 안전하다.
pvaction() {
  case "$(preview_mode)" in
    0) printf 'hide-preview' ;;
    1) printf 'show-preview+change-preview-window(%s)' "$PV_WIN_SPLIT" ;;
    2) printf 'show-preview+change-preview-window(%s)' "$PV_WIN_ACT" ;;
  esac
}
