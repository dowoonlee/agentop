#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
for module in const core board servers tasks gen gen-agents preview; do
  . "lib/$module.sh"
done

# 백그라운드로 보낸 세션은 kind=="background" 로 온다 — 원래의 interactive 프로세스는
# --json 에서 빠지므로, 이쪽을 안 받으면 그 작업이 목록에서 통째로 사라진다.
# 끝난 job 의 기록(pid 없음)은 행이 아니고, state=="blocked" 는 HITL 이다.
HOME=$(mktemp -d); export HOME
trap 'rm -rf "$HOME"' EXIT
mkdir -p "$HOME/.claude/jobs/bgblock01"
printf '%s' '{"state":"blocked","needs":"confirm whether to reopen the issue"}' \
  > "$HOME/.claude/jobs/bgblock01/state.json"

claude() {
  printf '%s\n' '[
    {"kind":"interactive","pid":920001,"cwd":"/fixture/project","sessionId":"fx-int","status":"idle"},
    {"kind":"background","pid":920002,"id":"bgblock01","cwd":"/fixture/project","sessionId":"fx-blocked","status":"busy","state":"blocked"},
    {"kind":"background","pid":920003,"id":"bgwork01","cwd":"/fixture/project","sessionId":"fx-working","status":"busy","state":"working"},
    {"kind":"background","id":"bgdone01","cwd":"/fixture/project","sessionId":"fx-done","state":"done"}
  ]'
}
ps() {
  if [[ "$1" == -axo ]]; then
    printf '%s\n' '920001 1' '920002 1' '920003 1'
  else
    printf '%s\n' '920001 ttys001 0.0 1024 S claude' \
      '920002 ttys005 0.0 1024 S claude bg-spare --bg-spare /tmp/x.claim.sock' \
      '920003 ?? 0.0 1024 S claude bg-spare --bg-spare /tmp/y.claim.sock'
  fi
}
board_map() { :; }
srv_map() { :; }
dkr_warm() { :; }
dkr_map() { :; }
tx_of_r() { _r=""; }
tx_scan() { printf '\037\037\037'; }
model_of() { :; }
mode_of() { :; }
cwd_of() { :; }
ctx_of() { :; }
tasks_live() { printf '0\0370'; }
preview_shown() { return 1; }
gen_codex() { :; }
gen_cursor() { :; }

output=$(gen_all) || exit 1
printf '%s\n' "$output" | python3 -c '
import re, sys
rows = [line.split("\x1f") for line in sys.stdin.read().split("\n") if line]
by_pid = {r[1]: re.sub(r"\x1b\[[0-9;]*m", "", r[0]) for r in rows if r[1].isdigit()}
assert set(by_pid) == {"920001", "920002", "920003"}, sorted(by_pid)
blocked = by_pid["920002"].partition("\x0b")[0]
assert blocked.startswith("◐ CLAUDE "), repr(blocked)
assert "← confirm whether to reopen the issue (bg)" in blocked, repr(blocked)
working = by_pid["920003"].partition("\x0b")[0]
assert working.startswith("● CLAUDE "), repr(working)
# tty 가 없어도 background 는 (detached) 가 아니다.
assert "(bg)" in working and "(detached)" not in working, repr(working)
assert "(bg)" not in by_pid["920001"], repr(by_pid["920001"])
print("Background session checks passed")
'
