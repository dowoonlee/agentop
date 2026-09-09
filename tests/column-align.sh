#!/usr/bin/env bash
# 컬럼 정렬 회귀 — 모든 세션 행에서 act·ctx·dir 열이 같은 자리에 서는가.
#
# 행 머리는 어느 에이전트든 icon(1) + 공백 + agent(AGENT_W) + 공백 = 고정폭이다.
# 여기가 한 칸이라도 어긋나면 뒤의 활동 배지·컨텍스트·디렉터리가 통째로 밀려,
# 목록을 세로로 훑는다는 이 화면의 전제가 깨진다. 어긋나기 쉬운 자리가 셋 있다.
#   · HITL 강조 배지 — icon+agent 자리를 통째로 덮어쓴다 (폭을 직접 맞춰야 한다)
#   · headless 자식 — 들여쓰기를 행 머리가 아니라 dir 셀 '안' 에서 먹어야 한다
#   · cursor/codex 행 — claude 행과 다른 printf 라 폭이 따로 논다
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
for module in const core board servers tasks gen gen-agents preview ui; do
  . "lib/$module.sh"
done

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# ---- claude 세션 다섯: busy / idle / waiting / stopped / headless -----------
claude() {
  printf '%s\n' '[
    {"kind":"interactive","pid":960001,"cwd":"/fixture/repo/app","sessionId":"s-app","status":"busy"},
    {"kind":"interactive","pid":960002,"cwd":"/fixture/repo/web","sessionId":"s-web","status":"idle"},
    {"kind":"interactive","pid":960003,"cwd":"/fixture/repo/api","sessionId":"s-api","status":"waiting","waitingFor":"권한 승인"},
    {"kind":"interactive","pid":960004,"cwd":"/fixture/repo/dbx","sessionId":"s-dbx","status":"idle"},
    {"kind":"interactive","pid":960005,"cwd":"/fixture/scratch/eval5608/r1","sessionId":"s-hdl","status":"idle"}
  ]'
}

ps() {
  case "${1:-}" in
    -axo)
      case "${2:-}" in
        "pid=,ppid=")        printf '%s\n' '960005 960001' '960001 1' ;;
        "pid=,comm=")        printf '%s\n' '960301 codex' '960302 codex' ;;
        "pid=,ppid=,args=")  printf '%s\n' '960301 1 codex --yolo' '960302 1 codex --yolo' ;;
      esac ;;
    -o)
      case "${2:-}" in
        # gen — 세션 전부를 한 번에 묻는다 (pid 목록은 $4)
        "pid=,tty=,%cpu=,rss=,stat=,args=")
          printf '%s\n' '960001 ttys001 1.0 204800 S+ claude' \
                        '960002 ttys002 0.0 204800 S+ claude' \
                        '960003 ttys003 0.0 204800 S+ claude' \
                        '960004 ttys004 0.0 204800 T  claude' \
                        '960005 ttys005 0.0 204800 S+ claude -p 리뷰 요약해줘' ;;
        # cursor — pid 는 $4
        "tty=,%cpu=,rss=,etime=")
          case "${4:-}" in
            960201) printf 'ttys101 0.0 102400 01:00\n' ;;
            960202) printf 'ttys102 0.0 102400 01:00\n' ;;
          esac ;;
        # codex
        "tty=,%cpu=,rss=,etime=,args=")
          case "${4:-}" in
            960301) printf 'ttys201 0.0 102400 01:00 codex --yolo\n' ;;
            960302) printf 'ttys202 0.0 102400 01:00 codex --yolo\n' ;;
          esac ;;
      esac ;;
  esac
}

pgrep() { printf '%s\n' 960201 960202; }          # cursor 두 개
lsof() {   # lsof -a -p <pid> -d cwd -Fn  →  pid 는 $3
  case "${3:-}" in
    960201) printf 'n/fixture/repo/cur1\n' ;;
    960202) printf 'n/fixture/repo/cur2\n' ;;
    960301) printf 'n/fixture/repo/cdx1\n' ;;
    960302) printf 'n/fixture/repo/cdx2\n' ;;
  esac
}
# tty 별 화면 — 두 번째 cursor/codex 만 승인 대기(HITL)로 만든다. 판정 문구 자체는
# 다른 테스트가 맡으므로 여기서는 표식 한 줄로 갈라 정렬만 본다.
cursor_screens() {
  printf '%s\n' '@@TTY:ttys101' 'IDLE-FIXTURE' \
                '@@TTY:ttys102' 'WAIT-FIXTURE' \
                '@@TTY:ttys201' 'IDLE-FIXTURE' \
                '@@TTY:ttys202' 'WAIT-FIXTURE'
}
cursor_classify() { grep -q WAIT-FIXTURE && printf 'waiting\037명령 승인\n' || printf 'idle\037\n'; }
codex_classify()  { grep -q WAIT-FIXTURE && printf 'waiting\037패치 승인\n' || printf 'idle\037\n'; }

# ---- 바깥 세계를 전부 상수로 -----------------------------------------------
board_map() { :; }
board_badge_r() { _r=""; }
srv_map() { printf ' '; }
dkr_warm() { :; }
dkr_map() { :; }
SRV_MAP=" "; DKR_MAP=""
srv_ports_r() { _r=""; }
srv_count_r() { _r=0; }
dkr_count_r() { _r=0; }
tx_of_r() { _r=""; }
tx_scan() { printf 'claude-opus-5\037default\037\03740000'; }
model_of() { :; }
mode_of() { :; }
cwd_of() { :; }
ctx_of() { :; }
tasks_live() { printf '0\0370'; }
sub_live_r() { _r=""; }
git_root_r() { _r="/fixture/repo"; }
git_root() { printf '/fixture/repo'; }
git_dir_r() { _r=""; }
git_worktree_r() { _r=""; }
git_worktree() { :; }
git_branch_r() { _r="main"; }
preview_shown() { return 1; }        # 목록만 모드 — dir 이 가장 긴 이름까지 늘어난다
CC_TOP_LST=""

# codex 첫 행에만 🤖 배지를 붙여 활동 슬롯이 넓어진 행을 섞는다.
codex_subagent_parents() { printf '960301\n'; }
codex_rollout_of() { :; }
codex_metrics_r() { _r="gpt-6-astra"; _r2=""; _r3=""; _r4=250000; _r5=1000000; }

output=$(gen_all) || fail "gen_all 이 실패했다"
printf '%s\n' "$output" | AGENT_W="$AGENT_W" python3 -c '
import os, re, sys, unicodedata

W = int(os.environ["AGENT_W"])
AGENTS = ("CLAUDE", "CURSOR", "CODEX")

def dw(s):                       # 표시 폭 — fit_dir/dispwidth 와 같은 기준
    return sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in s)

DIRS = {"960001": "app", "960002": "web", "960003": "api", "960004": "dbx",
        "960005": "eval5608/r1",
        "960201": "cur1", "960202": "cur2", "960301": "cdx1", "960302": "cdx2"}

rows = [l.split("\x1f") for l in sys.stdin.read().split("\n") if l]
assert len(rows) == 9, "행 수가 %d 다 (9 를 기대)" % len(rows)

seen, dirstart = set(), set()
for r in rows:
    plain = re.sub(r"\x1b\[[0-9;]*m", "", r[0])
    parts = plain.split("\x0b")
    head = parts[-2] if len(parts) > 2 else parts[0]   # 그룹 구분선이 앞에 얹힐 수 있다
    meta = parts[-1]

    # 1) 행 머리 = 아이콘 1칸 + 공백 + agent(W) + 공백. 어느 상태든 같아야 한다.
    m = re.match(r"^(.)\s(%s)\s*$" % "|".join(AGENTS), head[: 2 + W + 1])
    assert m, "행 머리가 icon+agent 꼴이 아니다: %r" % head[: 2 + W + 1]
    assert dw(head[: 2 + W + 1]) == 2 + W + 1, "행 머리 폭이 다르다: %r" % head
    seen.add(m.group(2))

    # 2) dir 열 시작 자리 — headless 자식은 들여쓰기를 dir 셀 안쪽에서 먹으므로
    #    셀 시작은 같고 글자만 안으로 밀린다.
    want = DIRS[r[1]]
    at = head.find(want)
    assert at > 0, "dir %r 을 못 찾았다: %r" % (want, head)
    indent = 2 if head[0] == "↳" else 0
    dirstart.add(dw(head[:at]) - indent)

    # 3) 2행 메타도 모든 행이 같은 자리에서 시작한다.
    assert meta.startswith("    └ "), "2행 들여쓰기가 다르다: %r" % meta

assert seen == set(AGENTS), "에이전트 세 종류가 다 안 나왔다: %s" % seen
assert len(dirstart) == 1, "dir 열이 행마다 다른 자리에서 시작한다: %s" % sorted(dirstart)
print("Column alignment checks passed (dir @ col %d)" % dirstart.pop())
'
