# Anthropic summaries are manual; Jev can run automatically when configured.
jev_python() {
  # macOS system Python uses the OS trust integration; a conda Python selected
  # by PATH can have an incompatible CA store. Never disable TLS verification.
  local interpreter="${AGENTOP_JEV_PYTHON:-/usr/bin/python3}"
  command -v "$interpreter" >/dev/null 2>&1 || { printf 'Jev: Python 경로를 AGENTOP_JEV_PYTHON으로 지정해 주세요.\n'; return 1; }
  "$interpreter" "$LIB/jev.py" "$@"
}

jev_session() {
  local action="$1" sid="$2" cwd="$3" tx
  case "$sid" in
    ''|cursor:*|codex:*) printf 'Jev 실험은 Claude Code session ID와 cwd가 필요합니다.\n'; return 1 ;;
  esac
  tx=$(tx_of "$cwd" "$sid")
  [[ -f "$tx" ]] || { printf '세션 transcript를 찾을 수 없습니다.\n'; return 1; }
  jev_python "$action" "$sid" "$tx"
}

ai_python() {
  command -v python3 >/dev/null 2>&1 || {
    printf 'AI: python3가 필요합니다 (brew install python).\n'; return 1;
  }
  python3 "$LIB/ai.py" "$@"
}

ai_analyze() {
  local sid="${1:-}" cwd="${2:-}" tx=""
  case "$sid" in
    ''|cursor:*|codex:*) ai_python notice "$sid" 'AI 분석은 현재 Claude Code 세션만 지원합니다.'; return ;;
  esac
  tx=$(tx_of "$cwd" "$sid")
  ai_python start "$sid" "$tx"
}

ai_block() {
  if [[ -f "${XDG_CONFIG_HOME:-$HOME/.config}/agentop/jev.json" ]]; then
    jev_python view "${1:-}" 2>/dev/null || true
  fi
  # No Python startup or state creation unless AI has been configured.
  [[ -f "${XDG_CONFIG_HOME:-$HOME/.config}/agentop/ai.json" ]] || {
    printf '\nAI  설정: agentop --ai-init (수동 분석 전용)\n'; return 0;
  }
  command -v python3 >/dev/null 2>&1 || return 0
  ai_python view "${1:-}" "${2:-}" 2>/dev/null || true
}
