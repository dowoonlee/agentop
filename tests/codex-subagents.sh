#!/usr/bin/env bash
# codex 서브에이전트(app-server) 회귀 — 세션 행에서 빠지고 부모의 🤖 로 접히는가.
#
# 이 자식은 부모 세션의 tty 를 그대로 물려받아 gen_codex 의 tty 필터를 통과한다.
# 걸러 내지 않으면 같은 세션이 목록에 두 줄로 서고, 그 줄은 rollout 을 안 열어
# 모델·컨텍스트가 빈 채로 남는다 (화면에서 가장 눈에 걸리던 '정체불명 행').
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
for module in const core board servers tasks gen gen-agents preview; do
  . "lib/$module.sh"
done

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# 트리:  920001 codex --yolo (세션)
#          └ 920010 node_repl
#              └ 920100 codex app-server   ← 서브에이전트 (세 단계 위가 세션)
#          └ 920300 codex app-server       ← 서브에이전트 (한 단계 위가 세션)
#        920200 플러그인 app-server (부모가 세션이 아님 — 세면 안 된다)
#        920400 codex --yolo (세션, 자식 없음)
ps() {
  [[ "${1:-}" == -axo && "${2:-}" == "pid=,ppid=,args=" ]] || return 0
  printf '%s\n' \
    '920001 1 codex --yolo' \
    '920400 1 codex --yolo' \
    '920010 920001 /App/Codex.app/Contents/Resources/cua_node/bin/node_repl' \
    '920100 920010 /App/Codex.app/Contents/Resources/codex app-server --listen stdio://' \
    '920300 920001 /App/Codex.app/Contents/Resources/codex app-server --listen stdio://' \
    '920200 1 /Users/x/.codex/plugins/.plugin-appserver/codex app-server --analytics-default-enabled'
}

got=$(codex_subagent_parents " 920001 920400 " | sort | tr '\n' ',')
[[ "$got" == "920001,920001," ]] || fail "부모 귀속: 920001 두 번을 기대했는데 '$got'"

# 부모가 세션 집합에 없으면 아무 줄도 안 낸다 — 근거 없는 수를 배지에 얹지 않는다.
got=$(codex_subagent_parents " 920400 " | tr '\n' ',')
[[ -z "$got" ]] || fail "세션 집합 밖 부모까지 셌다: '$got'"

got=$(codex_subagent_parents "" | tr '\n' ',')
[[ -z "$got" ]] || fail "빈 세션 집합에서 무언가를 냈다: '$got'"

# 세션이 아닌 프로세스는 app-server 여도 자식으로 안 센다 (argv0 이 codex 여야 한다).
ps() {
  [[ "${1:-}" == -axo && "${2:-}" == "pid=,ppid=,args=" ]] || return 0
  printf '%s\n' '921001 1 codex --yolo' \
                '921100 921001 /usr/local/bin/some-other-tool app-server --listen stdio://'
}
got=$(codex_subagent_parents " 921001 " | tr '\n' ',')
[[ -z "$got" ]] || fail "codex 가 아닌 app-server 를 셌다: '$got'"

# ps 가 comm 을 args 와 함께 지정하면 16자로 자른다 — 그래서 판정은 args 로 한다.
# 경로가 긴 Codex.app 실행 파일이 빠지지 않는지 못을 박아 둔다.
ps() {
  [[ "${1:-}" == -axo && "${2:-}" == "pid=,ppid=,args=" ]] || return 0
  printf '%s\n' '930001 1 codex --yolo' \
    '930100 930001 /Applications/Codex.app/Contents/Resources/codex app-server --listen stdio://'
}
got=$(codex_subagent_parents " 930001 " | tr '\n' ',')
[[ "$got" == "930001," ]] || fail "긴 경로의 app-server 를 놓쳤다: '$got'"

# 사슬이 상한(HDLS_HOP_MAX)보다 길면 포기한다 — 순환이 생겨도 여기서 멈춘다.
ps() {
  [[ "${1:-}" == -axo && "${2:-}" == "pid=,ppid=,args=" ]] || return 0
  printf '%s\n' '940001 1 codex --yolo' \
    '940100 940002 /App/Codex.app/Contents/Resources/codex app-server --listen stdio://'
  local i
  for (( i = 2; i <= HDLS_HOP_MAX + 3; i++ )); do
    printf '%s %s /bin/node\n' "$(( 940000 + i ))" "$(( 940000 + i + 1 ))"
  done
  printf '%s 940001 /bin/node\n' "$(( 940000 + HDLS_HOP_MAX + 4 ))"
}
got=$(codex_subagent_parents " 940001 " | tr '\n' ',')
[[ -z "$got" ]] || fail "상한을 넘겨 거슬러 올랐다: '$got'"

printf 'Codex subagent checks passed\n'

# ---------------------------------------------------------------------------
# 레코드 필드 — claude 행(gen)과 같은 23 필드여야 한다.
#   18(모델)이 비면 헤더 통계의 모델 분포에서 codex 세션이 통째로 빠지고,
#   21(실효 cwd)이 비면 통계가 그 세션 자리를 못 봐서 그 자리 컨테이너가 전부
#   '주인 없는 스택' 으로 세어진다. 예전 레코드는 20 필드였다.
# ---------------------------------------------------------------------------
ps() {
  case "${1:-}" in
    -axo)
      case "${2:-}" in
        "pid=,comm=")      printf '%s\n' '950001 codex' '950100 /App/Codex.app/Contents/Resources/codex' ;;
        "pid=,ppid=,args=") printf '%s\n' '950001 1 codex --yolo' \
                                          '950100 950001 /App/Codex.app/Contents/Resources/codex app-server --listen stdio://' ;;
      esac ;;
    -o)  # ps -o tty=,%cpu=,rss=,etime=,args= -p <pid>  →  $4 가 pid
         case "${4:-}" in
           950001) printf 'ttys900 1.5 204800 01:23:45 codex --yolo\n' ;;
           950100) printf 'ttys900 0.5 102400 01:20:00 /App/Codex.app/Contents/Resources/codex app-server --listen stdio://\n' ;;
         esac ;;
  esac
}
lsof() { printf 'n/fixture/repo\n'; }        # cwd 조회 — rollout 은 안 잡히게 둔다
cursor_screens() { printf '@@TTY:ttys900\nidle screen\n'; }
git_root() { printf '/fixture/repo'; }
git_worktree() { :; }
srv_map() { printf ' '; }
dkr_map() { :; }
SRV_MAP=" "; DKR_MAP=""

row=$(gen_codex)
[[ $(printf '%s\n' "$row" | grep -c .) == 1 ]] || fail "세션 행이 1개가 아니다 (app-server 가 섞였다):\n$row"
nf=$(printf '%s' "$row" | LC_ALL=C awk -F'\037' '{print NF}')
[[ "$nf" == 23 ]] || fail "레코드가 $nf 필드다 (23 이어야 한다)"
f21=$(printf '%s' "$row" | LC_ALL=C awk -F'\037' '{print $21}')
[[ "$f21" == /fixture/repo ]] || fail "21(실효 cwd)이 '$f21'"
f15=$(printf '%s' "$row" | LC_ALL=C awk -F'\037' '{print $15}')
[[ "$f15" == 1 ]] || fail "15(서브에이전트 수)가 '$f15' (1 이어야 한다)"

printf 'Codex record-field checks passed\n'

# ---------------------------------------------------------------------------
# 헬퍼 프로세스 걸러내기 — `codex sandbox`(명령 실행 헬퍼)가 세션 행으로 서면
#   같은 세션이 목록에 두세 줄로 선다. 부모의 tty 를 물려받아 tty 필터를 통과하고
#   comm 도 codex 라, 여기서 안 거르면 화면에 그대로 중복돼 나온다.
#   판정은 서브커맨드 한 자리로만 한다 — codex 는 프롬프트를 인자로 받으므로
#   argv 전체를 부분 문자열로 훑으면 프롬프트에 그 단어가 든 세션까지 사라진다.
# ---------------------------------------------------------------------------
chkhelper() {  # <argv> <helper|session>
  local want="$2" got=session
  codex_helper_argv "$1" && got=helper
  [[ "$got" == "$want" ]] || fail "헬퍼 판정: '$1' → $got (기대 $want)"
}
chkhelper 'codex sandbox -c shell_environment_policy.inherit=all -- /bin/zsh -lc make' helper
chkhelper '/App/Codex.app/Contents/Resources/codex app-server --listen stdio://'       helper
chkhelper 'codex -c features.code_mode_host=true app-server --analytics-default-enabled' helper
chkhelper 'codex --yolo resume'             session
chkhelper 'codex resume'                    session
chkhelper 'codex --yolo'                    session
chkhelper 'codex'                           session
chkhelper 'codex exec 프롬프트 안의 sandbox 라는 단어'  session
# 옵션 값이 서브커맨드로 오독되면 진짜 세션이 목록에서 통째로 사라진다.
chkhelper 'codex --sandbox workspace-write' session
chkhelper 'codex -m gpt-6-astra --sandbox danger-full-access' session

# gen_codex 도 같은 판정을 쓰는가 — 세션 하나 + 헬퍼 둘이 있는 tty 에서 한 줄만.
ps() {
  case "${1:-}" in
    -axo)
      case "${2:-}" in
        "pid=,comm=")       printf '%s\n' '970001 codex' '970100 /App/Codex.app/Contents/Resources/codex' \
                                          '970101 /App/Codex.app/Contents/Resources/codex' ;;
        "pid=,ppid=,args=") printf '%s\n' '970001 1 codex resume' \
                                          '970010 970001 /App/Codex.app/Contents/Resources/cua_node/bin/node_repl' \
                                          '970100 970010 /App/Codex.app/Contents/Resources/codex app-server --listen stdio://' \
                                          '970101 970010 /App/Codex.app/Contents/Resources/codex sandbox -c x=y -- make' ;;
      esac ;;
    -o)
      case "${4:-}" in
        970001) printf 'ttys900 1.0 204800 01:00:00 codex resume\n' ;;
        970100) printf 'ttys900 0.1 102400 00:50:00 /App/Codex.app/Contents/Resources/codex app-server --listen stdio://\n' ;;
        970101) printf 'ttys900 0.1 102400 00:01:00 /App/Codex.app/Contents/Resources/codex sandbox -c x=y -- make\n' ;;
      esac ;;
  esac
}
rows=$(gen_codex)
n=$(printf '%s\n' "$rows" | grep -c .)
[[ "$n" == 1 ]] || fail "세션 행이 $n 개다 (sandbox/app-server 헬퍼가 섞였다):\n$rows"
pid=$(printf '%s' "$rows" | LC_ALL=C awk -F'\037' '{print $2}')
[[ "$pid" == 970001 ]] || fail "세션이 아닌 pid($pid)가 행으로 섰다"
# app-server 만 🤖 로 접힌다 — sandbox 는 서브에이전트가 아니라 세션이 돌리는 명령.
nag=$(printf '%s' "$rows" | LC_ALL=C awk -F'\037' '{print $15}')
[[ "$nag" == 1 ]] || fail "15(서브에이전트 수)가 '$nag' (app-server 1개만 세야 한다)"

printf 'Codex helper-process filter checks passed\n'
