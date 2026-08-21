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
    -h|--help)   sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

case "$MODE" in
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
