#!/usr/bin/env bash
# compose 스택의 '자리' 판정 회귀 — 목록 배지(dkr_count_r) · 상세(srv_docker) ·
# 헤더 통계(stats) 세 곳이 같은 자리를 고르는가.
#
# 셋이 어긋나면 행에는 🐳 가 붙어 있는데 통계에선 주인 없다고 하는 모순이 화면에
# 그대로 뜬다. 특히 `-f .claude/compose.yml` 로 띄우면 compose 가 박는
# working_dir 라벨이 세션이 앉는 자리보다 한 칸 아래가 된다 — 조상 방향으로만
# 훑던 시절엔 자기 바로 밑의 스택을 영영 못 만났다.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
for module in const core board servers tasks gen gen-agents preview ui; do
  . "lib/$module.sh"
done

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# ---- dkr_count_r : 목록 배지 -----------------------------------------------
# 자리 둘 — 워크트리 루트(3개)와 그 밑 .claude(2개), 그리고 저장소 루트(5개).
DKR_MAP=$'\036/repo\0375\036/repo/wt/.claude\0372\036/repo/wt2\0373'

chk() {  # <설명> <세션 cwd> <기대값>
  dkr_count_r "$2"
  [[ "$_r" == "$3" ]] || fail "$1: '$2' → $_r (기대 $3)"
}
chk "세션 바로 밑 .claude 자리"        /repo/wt                2
chk "하위 디렉터리에서도 그 자리"      /repo/wt/services/api   2
chk "워크트리 루트 자리(.claude 없음)" /repo/wt2               3
chk "루트는 워크트리 스택을 안 먹는다" /repo                   5
chk "자리가 아예 없으면 0"             /elsewhere              0

# .claude 와 그 부모에 둘 다 있으면 더 구체적인 .claude 가 이긴다.
DKR_MAP=$'\036/repo/wt\0379\036/repo/wt/.claude\0372'
chk "동률이면 .claude 우선"            /repo/wt                2

# ---- srv_docker : preview 상세 ---------------------------------------------
DKR_CACHE="$tmp/dkr"; DKR_TTL=999
printf '%s\n' \
  $'/repo/wt/.claude\trunning\twt-postgres-1\t0.0.0.0:5444->5432/tcp' \
  $'/repo/wt/.claude\trunning\twt-redis-1\t' \
  $'/repo\trunning\troot-api-1\t' > "$DKR_CACHE"

got=$(srv_docker /repo/wt | LC_ALL=C awk -F'\t' '{printf "%s:%s ", $1, $2}')
[[ "$got" == "up:wt-postgres-1 up:wt-redis-1 " ]] || fail "srv_docker 자리: '$got'"
got=$(srv_docker /repo/wt/services/api | LC_ALL=C awk -F'\t' '{printf "%s ", $2}')
[[ "$got" == "wt-postgres-1 wt-redis-1 " ]] || fail "srv_docker 하위에서: '$got'"
got=$(srv_docker /repo | LC_ALL=C awk -F'\t' '{printf "%s ", $2}')
[[ "$got" == "root-api-1 " ]] || fail "srv_docker 루트가 워크트리 스택을 먹었다: '$got'"

# 목록 배지와 상세가 같은 자리를 보는지 — 개수가 어긋나면 화면이 모순된다.
DKR_MAP=$(dkr_map)
dkr_count_r /repo/wt
n=$(srv_docker /repo/wt | LC_ALL=C awk -F'\t' '$1=="up"' | wc -l | tr -d ' ')
[[ "$_r" == "$n" ]] || fail "배지($_r)와 상세($n)의 개수가 다르다"

# ---- stats : 헤더 통계의 귀속/주인 없음 ------------------------------------
# 워크트리에 세션이 있으면 그 밑 .claude 스택은 귀속(2), 아무도 없는 /repo 스택은
# 주인 없음(1). 배지 형식은 '🐳 <귀속><주인없음>' 이라 숫자만 이어 붙는다.
lst="$tmp/lst"
rec() {  # <ecwd> — 필드 21 만 의미가 있고 나머지는 자리만 채운다
  printf 'row\037900\037ttys0\037sid-%s\037%s\0370\037busy\037\037d\0370\0370\037/repo\037\0370\0370\0370\0370\037m\0370\037\037%s\037\037\n' \
    "$RANDOM" "$1" "$1"
}
rec /repo/wt > "$lst"
CC_TOP_LST="$lst"
got=$(stats 200 | LC_ALL=C sed $'s/\033\\[[0-9;]*m//g')
[[ "$got" == *"🐳 21"* ]] || fail "귀속 2 · 주인 없음 1 을 기대했는데: '$got'"

# 세션이 저장소 루트에만 있으면 /repo 스택만 귀속되고 워크트리 스택은 주인 없음.
rec /repo > "$lst"
got=$(stats 200 | LC_ALL=C sed $'s/\033\\[[0-9;]*m//g')
[[ "$got" == *"🐳 12"* ]] || fail "귀속 1 · 주인 없음 2 를 기대했는데: '$got'"

# 아무 세션도 그 자리에 없으면 전부 주인 없음 — 앞 숫자를 빼고 한 덩어리로 낸다.
rec /elsewhere > "$lst"
got=$(stats 200 | LC_ALL=C sed $'s/\033\\[[0-9;]*m//g')
[[ "$got" == *"🐳 3"* ]] || fail "주인 없음 3 한 덩어리를 기대했는데: '$got'"

printf 'Docker placement checks passed\n'
