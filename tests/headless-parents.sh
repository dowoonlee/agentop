#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
for module in const core board servers tasks gen gen-agents preview; do
  . "lib/$module.sh"
done

# Exercise real row generation and grouping with a Codex/Cursor -> Python ->
# Claude chain, a nested Claude child, and an unrelated orphan.
claude() {
  printf '%s\n' '[
    {"kind":"interactive","pid":910001,"cwd":"/fixture/eval-a/r1","sessionId":"fixture-a"},
    {"kind":"interactive","pid":910002,"cwd":"/fixture/eval-b/r1","sessionId":"fixture-b"},
    {"kind":"interactive","pid":910003,"cwd":"/fixture/nested/r1","sessionId":"fixture-nested"},
    {"kind":"interactive","pid":910004,"cwd":"/fixture/orphan/r1","sessionId":"fixture-orphan"}
  ]'
}
ps() {
  if [[ "$1" == -axo ]]; then
    printf '%s\n' '910001 910010' '910010 910100' '910100 1' \
      '910002 910020' '910020 910200' '910200 1' '910003 910001' '910004 1'
  else
    local p
    for p in 910001 910002 910003 910004; do
      printf '%s ?? 0.0 1024 S claude -p evaluate\n' "$p"
    done
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

parent_row() {
  printf 'parent\037%s\037ttys001\037%s:%s\037/fixture/project\0370\037idle\037\037%s\0370\0370\037/fixture/project\n' "$1" "$2" "$1" "$2"
}
gen_codex() { parent_row 910100 codex; }
gen_cursor() { parent_row 910200 cursor; }

output=$(gen_all) || exit 1
printf '%s\n' "$output" | python3 -c '
import re, sys
rows = [line.split("\x1f") for line in sys.stdin.read().split("\n") if line]
by_pid = {r[1]: r for r in rows}
assert len(rows) == 6, "A session disappeared or was duplicated"
order = [r[1] for r in rows]
for child, parent, depth, label in [
    ("910001", "910100", 1, "codex"),
    ("910002", "910200", 1, "cursor"),
    ("910003", "910001", 2, ""),
]:
    r = by_pid[child]
    assert r[21] == parent, (child, r[21])
    assert order.index(child) == order.index(parent) + 1, order
    display = re.sub(r"\x1b\[[0-9;]*m", "", r[0])
    assert display.startswith(" " * (2 * depth) + "↳"), repr(display)
    if label:
        assert r[11] == "/fixture/project", r[11]
        assert r[22] == label, r[22]
        assert "↳ " + label in display, display
orphan = by_pid["910004"]
assert not orphan[21], orphan[21]
assert orphan[11] == "/fixture/orphan/r1"
text = re.sub(r"\x1b\[[0-9;]*m", "", "\n".join(r[0] for r in rows))
assert text.count("━━ project ") == 1, text
assert text.count("━━ r1 ") == 1, text  # only the orphan owns a separate group
print("Headless parent grouping checks passed")
'
