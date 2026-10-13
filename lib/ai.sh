# AI is opt-in and manual. Polling/gen never calls this module's worker.
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
  # No Python startup or state creation unless AI has been configured.
  [[ -f "${XDG_CONFIG_HOME:-$HOME/.config}/agentop/ai.json" ]] || {
    printf '\nAI  설정: agentop --ai-init (수동 분석 전용)\n'; return 0;
  }
  command -v python3 >/dev/null 2>&1 || return 0
  ai_python view "${1:-}" "${2:-}" 2>/dev/null || true
}
