#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
. lib/const.sh
. lib/core.sh
. lib/gen-agents.sh
fixture=$(mktemp)
trap 'rm -f "$fixture"' EXIT
printf '%s\n' \
  '{"type":"turn_context","payload":{"model":"test-model","approval_policy":"never","sandbox_policy":{"type":"read-only"}}}' \
  '{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":80,"output_tokens":20,"total_tokens":120},"model_context_window":1000}}}' \
  '{"incomplete":' > "$fixture"
codex_metrics_r "$fixture"
[[ "$_r|$_r2|$_r3|$_r4|$_r5" == 'test-model|never|read-only|120|1000' ]]
# A new complete event must replace the previous usage despite an incomplete line.
printf '\n%s\n' '{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":200},"model_context_window":1000}}}' >> "$fixture"
codex_metrics_r "$fixture"
[[ "$_r4|$_r5" == '200|1000' ]]
ctx_cell_cap_r "$_r4" "$_r5"
[[ "$_r" == *'20%'* ]]
codex_metrics_r /nonexistent/rollout.jsonl
[[ -z "$_r$_r2$_r3$_r4$_r5" ]]
# PID identity comes from open files, never the shared working directory.
lsof() {
  case "$4" in
    101) printf 'n/shared/rollout-a.jsonl\n' ;;
    102) printf 'n/shared/rollout-b.jsonl\n' ;;
    103) printf 'n/shared/rollout-a.jsonl\nn/shared/rollout-b.jsonl\n' ;;
  esac
}
[[ "$(codex_rollout_of 101)" == /shared/rollout-a.jsonl ]]
[[ "$(codex_rollout_of 102)" == /shared/rollout-b.jsonl ]]
[[ -z "$(codex_rollout_of 103)" ]]
# 실효 cwd — 워크트리에서 일하는 세션의 브랜치·⑂ 근거. turn_context.cwd 는 세션을
# 띄운 자리라 안 움직이므로, 마지막 CommandExecution 의 cwd 가 이겨야 한다.
cwdfix=$(mktemp)
trap 'rm -f "$fixture" "$cwdfix"' EXIT
printf '%s\n' \
  '{"type":"turn_context","payload":{"model":"m","cwd":"/repo"}}' \
  '{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"CommandExecution","cwd":"file:///repo/.claude/worktrees/wt-a"}}}' \
  '{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":1},"model_context_window":10}}}' > "$cwdfix"
codex_metrics_r "$cwdfix"
[[ "$_r6" == /repo/.claude/worktrees/wt-a ]] || { echo "실효 cwd: '$_r6'" >&2; exit 1; }

# 나중 명령이 이긴다 — 세션이 워크트리를 옮겨 다녀도 마지막 자리를 따라간다.
printf '%s\n' \
  '{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"CommandExecution","cwd":"file:///repo/.claude/worktrees/wt-b/services/api"}}}' >> "$cwdfix"
codex_metrics_r "$cwdfix"
[[ "$_r6" == /repo/.claude/worktrees/wt-b/services/api ]] || { echo "실효 cwd(최신): '$_r6'" >&2; exit 1; }

# 퍼센트 인코딩된 경로도 푼다 (file:// URI 라 공백이 %20 으로 온다).
printf '%s\n' \
  '{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"CommandExecution","cwd":"file:///repo/my%20work/dir"}}}' >> "$cwdfix"
codex_metrics_r "$cwdfix"
[[ "$_r6" == "/repo/my work/dir" ]] || { echo "퍼센트 디코딩: '$_r6'" >&2; exit 1; }

# 명령을 한 번도 안 돌린 세션은 turn_context.cwd 로 떨어진다.
printf '%s\n' '{"type":"turn_context","payload":{"model":"m","cwd":"/repo"}}' \
  '{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":1},"model_context_window":10}}}' > "$cwdfix"
codex_metrics_r "$cwdfix"
[[ "$_r6" == /repo ]] || { echo "폴백(turn_context): '$_r6'" >&2; exit 1; }

printf 'Codex regression checks passed\n'
