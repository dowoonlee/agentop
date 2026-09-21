#!/usr/bin/env bash
# 🌐 귀속 회귀 — 리스닝 포트가 claude 뿐 아니라 codex · cursor-agent 세션에도 닿는가.
#
# srv_map 의 조상 탐색이 `claude` 에서만 멈추던 때는 codex 세션이 띄운 vite 가
# 어느 행에도 안 붙었다 (README 는 codex·cursor 행에도 🌐 가 선다고 적혀 있었다).
# codex 는 헬퍼(`codex sandbox`)도 comm 이 codex 라 첫 codex 에서 끊으면 안 된다.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
for module in const core servers; do
  . "lib/$module.sh"
done

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# 트리:  930001 claude ← 930010 zsh ← 930011 node(:5173)
#        930100 codex  ← 930110 pnpm ← 930111 node(:60552)
#        930200 codex(세션) ← 930210 /App/Codex.app/.../codex (sandbox 헬퍼) ← 930211 node(:8080)
#        930300 cursor-agent ← 930310 node(:3000)
#        930400 zsh ← 930410 node(:9999)   ← 세션 조상 없음 — 아무 데도 안 붙어야 한다
ps() {
  [[ "${1:-}" == -eo && "${2:-}" == "pid=,ppid=,comm=" ]] || return 0
  printf '%s\n' \
    '930001 1 claude' \
    '930010 930001 zsh' \
    '930011 930010 node' \
    '930100 1 codex' \
    '930110 930100 pnpm' \
    '930111 930110 node' \
    '930200 1 codex' \
    '930210 930200 /App/Codex.app/Contents/Resources/codex' \
    '930211 930210 node' \
    '930300 1 /Users/x/.local/bin/cursor-agent' \
    '930310 930300 node' \
    '930400 1 zsh' \
    '930410 930400 node'
}
lsof() {
  printf 'COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\n'
  printf 'node %s a11706 17u IPv4 0x1 0t0 TCP 127.0.0.1:%s (LISTEN)\n' \
    930011 5173  930111 60552  930211 8080  930310 3000  930410 9999
}

SRV_MAP=$(srv_map)

srv_ports_r 930001; [[ "$_r" == "5173/930011" ]]  || fail "claude 세션에 5173 을 기대했는데 '$_r'"
srv_ports_r 930100; [[ "$_r" == "60552/930111" ]] || fail "codex 세션에 60552 를 기대했는데 '$_r'"
srv_ports_r 930200; [[ "$_r" == "8080/930211" ]]  || fail "codex 헬퍼 너머의 세션에 8080 을 기대했는데 '$_r'"
srv_ports_r 930300; [[ "$_r" == "3000/930310" ]]  || fail "cursor-agent 세션에 3000 을 기대했는데 '$_r'"
srv_ports_r 930400; [[ -z "$_r" ]]                || fail "세션이 아닌 zsh 에 포트가 붙었다: '$_r'"
srv_ports_r 930010; [[ -z "$_r" ]]                || fail "중간 zsh 에 포트가 붙었다: '$_r'"

echo "ok: servers-agents"
