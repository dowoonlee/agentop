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
printf 'Codex regression checks passed\n'
