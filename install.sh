#!/usr/bin/env bash
# install.sh — agentop 설치.
#
#   파일을 어디로 복사하지 않는다. clone 한 위치를 그대로 쓰고, 실행할 이름만
#   PATH 에 심볼릭 링크로 걸어 준다 (본체가 자기 위치를 스스로 찾으므로 lib/ 도
#   따라온다). 그래서 저장소를 어디에 두든 상관없고, 옮기고 싶으면 디렉터리째
#   옮긴 뒤 다시 이 스크립트를 돌리면 된다.
#
#   사용법
#     ./install.sh                 PATH 안의 쓰기 가능한 곳에 링크 (없으면 ~/.local/bin)
#     ./install.sh --prefix DIR    링크를 걸 디렉터리 지정
#     ./install.sh --alias         링크 대신 셸 설정에 alias 추가
#     ./install.sh --uninstall     설치한 링크 제거
#     ./install.sh --name NAME     실행 이름 변경 (기본 agentop)
#     ./install.sh --hooks         세션 보드 훅을 ~/.claude/settings.json 에 등록
#     ./install.sh --unhooks       등록한 세션 보드 훅만 제거
set -uo pipefail

ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$ROOT/agentop"
NAME="agentop"
PREFIX=""
MODE="link"

B=$'\e[1m'; G=$'\e[38;5;245m'; Y=$'\e[38;5;179m'; R=$'\e[38;5;167m'; OK=$'\e[38;5;114m'; Z=$'\e[0m'
say()  { printf '%s\n' "$*"; }
info() { printf '  %s\n' "$*"; }
good() { printf '  %s✓%s %s\n' "$OK" "$Z" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$Z" "$*"; }
die()  { printf '  %s✗%s %s\n' "$R" "$Z" "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix)    PREFIX="${2:-}"; shift 2 ;;
    --name)      NAME="${2:-agentop}"; shift 2 ;;
    --alias)     MODE="alias"; shift ;;
    --uninstall) MODE="uninstall"; shift ;;
    --hooks)     MODE="hooks"; shift ;;
    --unhooks)   MODE="unhooks"; shift ;;
    -h|--help)   sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           die "모르는 옵션: $1  (--help 로 사용법)" ;;
  esac
done

[[ -f "$BIN" ]] || die "agentop 본체를 찾을 수 없습니다: $BIN"
chmod +x "$BIN" 2>/dev/null

# ---------------------------------------------------------------------------
# 요구사항 — 없으면 설치는 되지만 실행이 안 되므로 먼저 알려 준다.
# ---------------------------------------------------------------------------
check_deps() {
  local missing=0
  say "${B}요구사항${Z}"
  [[ "$(uname -s)" == "Darwin" ]] \
    && good "macOS" \
    || { warn "macOS 전용입니다 (stat -f · osascript · pgrep 사용) — 현재: $(uname -s)"; missing=1; }
  for c in fzf claude jq; do
    if command -v "$c" >/dev/null 2>&1; then good "$c  ${G}$(command -v "$c")${Z}"
    else
      missing=1
      case "$c" in
        fzf)    warn "fzf 없음 — brew install fzf" ;;
        claude) warn "claude CLI 없음 — https://claude.com/claude-code" ;;
        jq)     warn "jq 없음 — brew install jq" ;;
      esac
    fi
  done
  if [[ -d "/Applications/iTerm.app" ]]; then good "iTerm2"
  else warn "iTerm2 없음 — 목록은 동작하지만 ⏎ 탭 점프와 cursor/codex 상태 감지가 빠집니다"; fi
  say ""
  return $missing
}

# PATH 안에서 쓰기 가능한 디렉터리를 고른다. 없으면 ~/.local/bin 을 만든다.
pick_prefix() {
  local d
  for d in "$HOME/.local/bin" "/usr/local/bin" "$HOME/bin"; do
    case ":$PATH:" in
      *":$d:"*) [[ -d "$d" && -w "$d" ]] && { printf '%s' "$d"; return 0; } ;;
    esac
  done
  printf '%s' "$HOME/.local/bin"
}

# 셸 설정 파일 — 로그인 셸 기준.
rc_file() {
  case "$(basename "${SHELL:-/bin/zsh}")" in
    zsh)  printf '%s' "$HOME/.zshrc" ;;
    bash) [[ -f "$HOME/.bash_profile" ]] && printf '%s' "$HOME/.bash_profile" || printf '%s' "$HOME/.bashrc" ;;
    *)    printf '%s' "$HOME/.profile" ;;
  esac
}


# ---------------------------------------------------------------------------
# 세션 보드 훅 — ~/.claude/settings.json 등록/제거.
#
#   멱등하게 만든다: 먼저 이 저장소를 가리키는 board-* 항목을 전부 걷어낸 뒤
#   필요하면 새로 넣는다. 그래서 재실행·경로 이동·업그레이드에서 중복이 쌓이지
#   않고, --unhooks 는 '걷어내기' 만 하면 된다.
#
#   남의 훅은 건드리지 않는다 — 판정 기준은 command 가 이 저장소의 hooks/board-
#   로 시작하는지 하나뿐이다. 사용자가 직접 넣은 SessionStart 훅 등은 같은
#   이벤트 배열에 그대로 남는다.
#
#   PostToolUse(기록)만 async 로 등록한다. 기록은 결과를 기다릴 이유가 없어서
#   편집 흐름에서 빼는 것이 맞고, PreToolUse(확인)는 당연히 동기라야 한다.
# ---------------------------------------------------------------------------
BOARD_MATCHER='Edit|Write|MultiEdit|NotebookEdit'
SETTINGS="${AGENTOP_SETTINGS:-$HOME/.claude/settings.json}"   # 테스트·비표준 경로용 오버라이드

board_hooks() {   # <add|remove>
  local act="${1:-add}" tmp
  command -v jq >/dev/null 2>&1 || die "jq 가 필요합니다 — brew install jq"

  if [[ ! -f "$SETTINGS" ]]; then
    [[ "$act" == remove ]] && { info "settings.json 이 없습니다 — 지울 것이 없습니다."; return 0; }
    mkdir -p "$(dirname "$SETTINGS")" 2>/dev/null
    printf '{}\n' > "$SETTINGS" || die "settings.json 을 만들 수 없습니다: $SETTINGS"
    good "settings.json 생성: $SETTINGS"
  fi
  jq -e . "$SETTINGS" >/dev/null 2>&1 || die "settings.json 이 올바른 JSON 이 아닙니다: $SETTINGS"

  # 백업 — 남의 설정이 들어 있는 파일을 고치므로 되돌릴 수단을 먼저 만든다.
  local bak="$SETTINGS.agentop-bak-$(date +%Y%m%d%H%M%S)"
  cp "$SETTINGS" "$bak" || die "백업 실패: $bak"

  tmp=$(mktemp) || die "임시 파일을 만들 수 없습니다"
  jq --arg pfx "$ROOT/hooks/board-" \
     --arg brief  "$ROOT/hooks/board-brief.sh" \
     --arg gate   "$ROOT/hooks/board-gate.sh" \
     --arg record "$ROOT/hooks/board-record.sh" \
     --arg m "$BOARD_MATCHER" --arg act "$act" '
    # 1) 이 저장소의 board-* 훅을 전부 걷어낸다 (빈 항목·빈 이벤트도 정리)
      .hooks = ( (.hooks // {})
        | with_entries( .value |= ( (. // [])
            | map( .hooks = ((.hooks // []) | map(select((.command // "") | startswith($pfx) | not))) )
            | map(select((.hooks | length) > 0)) ) )
        | with_entries(select((.value | length) > 0)) )
    # 2) add 면 세 훅을 넣는다
    | if $act == "add" then
        .hooks.SessionStart = ((.hooks.SessionStart // []) + [{
          hooks: [{ type: "command", command: $brief, timeout: 20,
                    statusMessage: "세션 보드 브리핑" }] }])
      | .hooks.PreToolUse = ((.hooks.PreToolUse // []) + [{
          matcher: $m,
          hooks: [{ type: "command", command: $gate, timeout: 10,
                    statusMessage: "세션 보드 충돌 확인" }] }])
      | .hooks.PostToolUse = ((.hooks.PostToolUse // []) + [{
          matcher: $m,
          hooks: [{ type: "command", command: $record, timeout: 10, async: true }] }])
      else . end
  ' "$SETTINGS" > "$tmp" || { rm -f "$tmp"; die "settings.json 갱신 실패 (백업: $bak)"; }

  jq -e . "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; die "생성된 JSON 이 깨졌습니다 (백업: $bak)"; }
  mv -f "$tmp" "$SETTINGS" || { rm -f "$tmp"; die "settings.json 쓰기 실패 (백업: $bak)"; }
  good "백업: ${G}$bak${Z}"
  return 0
}

case "$MODE" in
# ---------------------------------------------------------------------------
hooks)
  check_deps
  say "${B}세션 보드 훅 등록${Z}"
  for f in board-lib.sh board-brief.sh board-gate.sh board-record.sh; do
    [[ -f "$ROOT/hooks/$f" ]] || die "훅 파일이 없습니다: $ROOT/hooks/$f"
  done
  chmod +x "$ROOT"/hooks/board-*.sh 2>/dev/null
  board_hooks add
  good "SessionStart  ${G}board-brief.sh${Z}   — 같은 저장소의 다른 세션 브리핑"
  good "PreToolUse    ${G}board-gate.sh${Z}    — 편집 직전 충돌 알림 ($BOARD_MATCHER)"
  good "PostToolUse   ${G}board-record.sh${Z}  — 편집 기록 (async)"
  say ""
  info "새로 시작하는 세션부터 적용됩니다 (이미 열려 있는 세션은 재시작 필요)."
  info "보드 위치: ${B}${CC_BOARD_ROOT:-$HOME/.claude/session-board}${Z}"
  ;;

# ---------------------------------------------------------------------------
unhooks)
  say "${B}세션 보드 훅 제거${Z}"
  board_hooks remove
  good "settings.json 에서 board-* 훅을 걷어냈습니다."
  info "보드 데이터는 남아 있습니다 — 지우려면: rm -rf ${CC_BOARD_ROOT:-$HOME/.claude/session-board}"
  ;;

# ---------------------------------------------------------------------------
uninstall)
  say "${B}제거${Z}"
  found=0
  # PATH 전체를 훑어 이 저장소를 가리키는 링크만 지운다 (남의 파일은 건드리지 않음)
  IFS=: read -r -a dirs <<< "$PATH"
  # --prefix 로 설치했으면 그 자리는 PATH 에 없을 수 있으므로 먼저 본다.
  for d in ${PREFIX:+"$PREFIX"} "${dirs[@]}" "$HOME/.local/bin" "/usr/local/bin" "$HOME/bin"; do
    [[ -L "$d/$NAME" ]] || continue
    tgt=$(readlink "$d/$NAME")
    case "$tgt" in "$BIN"|"$ROOT"/*) rm -f "$d/$NAME" && good "링크 제거: $d/$NAME"; found=1 ;; esac
  done
  rc=$(rc_file)
  # 조건과 상세 출력이 같은 패턴이어야 한다 — rc 에는 ~/... 로 적혀 있을 수 있어
  # 절대경로($ROOT)만으로는 안 잡힌다.
  rcpat="agentop/agentop|$ROOT"
  if [[ -f "$rc" ]] && grep -qE "$rcpat" "$rc" 2>/dev/null; then
    warn "$rc 에 alias 가 남아 있습니다 — 직접 지워 주세요:"
    grep -nE "$rcpat" "$rc" | sed 's/^/      /'
    found=1
  fi
  # settings.json 에 남은 board-* 훅도 같이 걷어낸다 — 저장소를 지운 뒤에도
  # 훅만 남으면 없는 경로를 실행하려 해서 매 편집마다 조용히 실패한다.
  if [[ -f "$SETTINGS" ]] && grep -q "$ROOT/hooks/board-" "$SETTINGS" 2>/dev/null; then
    board_hooks remove && good "세션 보드 훅 제거 (settings.json)"
    found=1
  fi
  (( found )) || info "설치된 흔적을 찾지 못했습니다."
  ;;

# ---------------------------------------------------------------------------
alias)
  check_deps
  rc=$(rc_file)
  line="alias $NAME='$BIN'"
  if grep -qF "$line" "$rc" 2>/dev/null; then
    good "이미 설정돼 있습니다: $rc"
  else
    printf '\n# agentop — %s\n%s\n' "https://github.com/dowoonlee/agentop" "$line" >> "$rc"
    good "alias 추가: $rc"
  fi
  say ""
  info "새 셸을 열거나 ${B}source $rc${Z} 후 ${B}$NAME${Z} 으로 실행하세요."
  ;;

# ---------------------------------------------------------------------------
link)
  check_deps
  dest="${PREFIX:-$(pick_prefix)}"
  mkdir -p "$dest" 2>/dev/null || die "디렉터리를 만들 수 없습니다: $dest"
  [[ -w "$dest" ]] || die "쓰기 권한이 없습니다: $dest  (--prefix 로 다른 곳을 지정하거나 --alias 를 쓰세요)"

  if [[ -e "$dest/$NAME" && ! -L "$dest/$NAME" ]]; then
    die "이미 파일이 있습니다: $dest/$NAME  (--name 으로 다른 이름을 쓰세요)"
  fi
  ln -sfn "$BIN" "$dest/$NAME" || die "링크를 만들지 못했습니다: $dest/$NAME"

  say "${B}설치 완료${Z}"
  good "$dest/$NAME  ${G}→  $BIN${Z}"
  say ""
  case ":$PATH:" in
    *":$dest:"*) info "${B}$NAME${Z} 으로 실행하세요." ;;
    *)
      warn "$dest 가 PATH 에 없습니다. 아래를 셸 설정에 추가하세요:"
      say ""
      info "  export PATH=\"$dest:\$PATH\""
      ;;
  esac
  ;;
esac
