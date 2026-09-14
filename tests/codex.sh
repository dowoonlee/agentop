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
# 띄운 자리라 안 움직이므로 CommandExecution 의 cwd 에서 골라야 한다. 워크트리
# 판정은 git_dir_r 이 파일시스템만 보므로(.git 파일의 gitdir: 포인터) 실제 git 없이
# 디렉토리 나무만 세운다. 지워진 자리를 건너뛰는 규칙도 이 나무로 검증한다.
cwdfix=$(mktemp); tree=$(mktemp -d)
trap 'rm -rf "$fixture" "$cwdfix" "$tree"' EXIT
repo="$tree/repo"
mkdir -p "$repo/.git" "$repo/services/api" "$repo/my work/dir" \
  "$repo/.claude/worktrees/wt-a" "$repo/.claude/worktrees/wt-b/services/api"
printf 'gitdir: %s\n' "$repo/.git/worktrees/wt-a" > "$repo/.claude/worktrees/wt-a/.git"
printf 'gitdir: %s\n' "$repo/.git/worktrees/wt-b" > "$repo/.claude/worktrees/wt-b/.git"
tc() { printf '{"type":"turn_context","payload":{"model":"m","cwd":"%s"}}\n' "$repo"; }
ce() { printf '{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"CommandExecution","cwd":"file://%s"}}}\n' "$1"; }
tk='{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":1},"model_context_window":10}}}'
{ tc; ce "$repo/.claude/worktrees/wt-a"; printf '%s\n' "$tk"; } > "$cwdfix"
codex_metrics_r "$cwdfix"
[[ "$_r6" == "$repo/.claude/worktrees/wt-a" ]] || { echo "실효 cwd: '$_r6'" >&2; exit 1; }
[[ "$_r" == m ]] || { echo "모델이 지워짐: '$_r'" >&2; exit 1; }

# 나중 명령이 이긴다 — 세션이 워크트리를 옮겨 다녀도 마지막 자리를 따라간다.
ce "$repo/.claude/worktrees/wt-b/services/api" >> "$cwdfix"
codex_metrics_r "$cwdfix"
[[ "$_r6" == "$repo/.claude/worktrees/wt-b/services/api" ]] || { echo "실효 cwd(최신): '$_r6'" >&2; exit 1; }

# 본체 체크아웃에서 돌린 살림 명령(gh 조회·git worktree list)은 워크트리를 못 이긴다 —
# 마지막 한 건이 본체여도 같은 턴에 워크트리 명령이 있으면 그 자리가 실효 cwd 다.
ce "$repo" >> "$cwdfix"; ce "$repo/services/api" >> "$cwdfix"
codex_metrics_r "$cwdfix"
[[ "$_r6" == "$repo/.claude/worktrees/wt-b/services/api" ]] || { echo "살림 명령이 이김: '$_r6'" >&2; exit 1; }

# 퍼센트 인코딩된 경로도 푼다 (file:// URI 라 공백이 %20 으로 온다). 워크트리가 아닌
# 자리들만 있으면 그중 가장 최근 것이다.
{ tc; ce "$repo"; ce "$repo/my%20work/dir"; } >> "$cwdfix"
codex_metrics_r "$cwdfix"
[[ "$_r6" == "$repo/my work/dir" ]] || { echo "퍼센트 디코딩: '$_r6'" >&2; exit 1; }

# 새 턴이 시작되면 지난 턴의 워크트리는 잊는다 — 본체로 돌아온 세션이 옛 워크트리를
# 계속 달고 있으면 안 된다. 다만 아직 명령을 안 돌린 턴은 직전 목록으로 떨어진다.
{ tc; ce "$repo/.claude/worktrees/wt-a"; tc; } > "$cwdfix"
codex_metrics_r "$cwdfix"
[[ "$_r6" == "$repo/.claude/worktrees/wt-a" ]] || { echo "빈 턴 폴백: '$_r6'" >&2; exit 1; }
ce "$repo" >> "$cwdfix"
codex_metrics_r "$cwdfix"
[[ "$_r6" == "$repo" ]] || { echo "새 턴에서 옛 워크트리 잔존: '$_r6'" >&2; exit 1; }

# 지워진 디렉토리는 건너뛴다 — 머지 후 정리된 워크트리가 아니라 남아 있는 자리를 본다.
{ tc; ce "$repo/.claude/worktrees/wt-a"; ce "$repo/.claude/worktrees/gone"; } > "$cwdfix"
codex_metrics_r "$cwdfix"
[[ "$_r6" == "$repo/.claude/worktrees/wt-a" ]] || { echo "지워진 자리: '$_r6'" >&2; exit 1; }

# 명령을 한 번도 안 돌린 세션은 turn_context.cwd 로 떨어진다.
{ tc; printf '%s\n' "$tk"; } > "$cwdfix"
codex_metrics_r "$cwdfix"
[[ "$_r6" == "$repo" ]] || { echo "폴백(turn_context): '$_r6'" >&2; exit 1; }

printf 'Codex regression checks passed\n'
