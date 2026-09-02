# board-lib.sh — 세션 보드 공용 계층 — 저장 규칙·경로 판정·기록·조회.
#   같은 저장소에서 도는 세션들이 "누가 어떤 파일을 만지고 있는지" 를 서로
#   물어보지 않고 알게 하는 것이 목적이다. 각 세션은 자기 파일에만 append 하고
#   (락 불필요 — macOS 에 flock 이 없다), 읽는 쪽은 형제 파일을 훑는다.
#
#   훅 3개(board-record / board-gate / board-brief)가 source 하는 모듈이다.
#   git 헬퍼는 agentop 본체와 같은 구현을 쓴다 — 워크트리·서브모듈 판정 규칙이
#   TUI 와 훅에서 갈리면 같은 세션이 서로 다른 보드에 기록되므로 반드시 공용.
# ---------------------------------------------------------------------------
BOARD_LIB_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/core.sh
source "$BOARD_LIB_DIR/../lib/core.sh" 2>/dev/null || true

BOARD_ROOT="${CC_BOARD_ROOT:-$HOME/.claude/session-board}"
BOARD_WINDOW="${CC_BOARD_WINDOW:-900}"   # 충돌·브리핑 시간창(초). 기본 15분.
                                         #   이 창이 liveness 판정을 대신한다 — 죽은
                                         #   세션은 append 가 멈춰 자연히 창 밖으로
                                         #   밀려나므로 `claude agents --json`(~0.4s)
                                         #   을 매 편집마다 부르지 않아도 된다.
                                         #   반대로 방금 죽은 세션이 남긴 미커밋 변경은
                                         #   창 안에 있어 여전히 경고 대상이 된다.
BOARD_KEEP="${CC_BOARD_KEEP:-200}"       # 세션 파일당 유지 줄 수 (append-only 무한증식 방지)
BOARD_STALE="${CC_BOARD_STALE:-604800}"  # 이 기간(초) 손 안 댄 보드 파일은 청소. 기본 7일.

# ---------------------------------------------------------------------------
# board_slug <경로> : 경로를 파일명 안전한 슬러그로. `/` `.` → `-`.
#   ~/.claude/projects 의 규칙과 같게 맞췄다 — 보드 디렉터리와 transcript
#   디렉터리 이름이 눈으로 대응돼서 디버깅할 때 헤매지 않는다.
# ---------------------------------------------------------------------------
board_slug() { printf '%s' "${1:-}" | sed 's#[/.]#-#g'; }

# ---------------------------------------------------------------------------
# board_checkout_root <디렉터리> : 위로 올라가며 만난 첫 체크아웃 루트(.git 이
#   있는 디렉터리). 링크된 워크트리에서는 그 워크트리의 루트가 나온다.
#   git_root 는 워크트리를 본 저장소로 접어 버리므로(보드 키로는 그게 맞다)
#   파일의 저장소 상대 경로를 구하려면 접히지 않은 이 값이 따로 필요하다.
# ---------------------------------------------------------------------------
board_checkout_root() {
  local d="${1:-}"
  [[ -z "$d" ]] && return 0
  while [[ -n "$d" && "$d" != "/" ]]; do
    [[ -e "$d/.git" ]] && { printf '%s' "$d"; return 0; }
    d="${d%/*}"
  done
  return 0
}

# ---------------------------------------------------------------------------
# board_dir <파일 절대경로> : 이 파일이 속한 저장소의 보드 디렉터리. 저장소
#   밖이면 빈 값(= 기록·검사 대상 아님).
#   판정 기준을 세션 cwd 가 아니라 '파일 경로' 로 둔 이유: 한 세션이 여러
#   저장소를 건드릴 때 cwd 기준으로 잡으면 남의 저장소 보드에 기록이 섞인다.
#   워크트리는 git_root 가 본 저장소로 접으므로, 같은 저장소에서 파생된
#   본체·워크트리 세션들이 하나의 보드에 모인다 (서로를 보게 하는 것이 목적).
# ---------------------------------------------------------------------------
board_dir() {
  local p="${1:-}" root
  [[ "$p" == /* ]] || return 0
  root=$(git_root "${p%/*}")
  [[ -n "$root" ]] || return 0
  printf '%s/%s' "$BOARD_ROOT" "$(board_slug "$root")"
}

# ---------------------------------------------------------------------------
# board_rel <파일 절대경로> : 체크아웃 루트 기준 상대 경로. 루트 밖이면 빈 값.
#   워크트리가 달라도 같은 값이 나오는 것이 핵심 — 서로 다른 워크트리에서 같은
#   파일을 고치는 상황(머지 충돌 예고)을 이 값으로 잡는다.
# ---------------------------------------------------------------------------
board_rel() {
  local p="${1:-}" co
  co=$(board_checkout_root "${p%/*}")
  [[ -n "$co" ]] || return 0
  case "$p" in "$co"/*) printf '%s' "${p#"$co"/}" ;; esac
}

# ---------------------------------------------------------------------------
# board_record <세션id> <툴명> <파일 절대경로> : 편집 1건을 자기 파일에 append.
#   레코드: <epoch> \t <툴> \t <워크트리> \t <저장소상대경로> \t <절대경로>
#   epoch 정수로 두면 읽는 쪽이 bash 산술만으로 시간창을 자른다(date 호출 없음).
#   워크트리 칸은 본체 체크아웃이면 '-' — 빈 칸을 두면 read 가 필드를 밀어 먹는다.
#   자기 파일에만 쓰므로 세션이 몇 개든 경합이 없다.
# ---------------------------------------------------------------------------
board_record() {
  local sid="${1:-}" tool="${2:-}" p="${3:-}" bd rel wt
  [[ -n "$sid" && -n "$p" ]] || return 0
  bd=$(board_dir "$p"); [[ -n "$bd" ]] || return 0   # 저장소 밖(임시·scratchpad) 은 노이즈라 안 남긴다
  rel=$(board_rel "$p"); [[ -n "$rel" ]] || return 0
  wt=$(git_worktree "${p%/*}")
  mkdir -p "$bd" 2>/dev/null || return 0
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$(date +%s)" "$tool" "${wt:--}" "$rel" "$p" >> "$bd/$sid.tsv" 2>/dev/null
  # 줄 수 상한은 여기서 보지 않는다 — 편집마다 wc 를 띄우는 값이 아니고, 길어진
  # 파일도 스캔에는 부담이 없다. 자르는 일은 board_sweep(세션 시작 1회)이 맡는다.
  return 0
}

# ---------------------------------------------------------------------------
# board_scan <보드디렉터리> <제외할 세션id> [시간창초] : 시간창 안의 이웃 레코드.
#   출력: <세션id> \t <경과초> \t <툴> \t <워크트리> \t <상대경로> \t <절대경로>
#   세션 id 는 자르지 않고 원본을 낸다 — 표시용 축약은 부르는 쪽에서 하고, 이름
#   조회(claude agents --json 의 sessionId)에는 전체 값이 필요하다.
#   자기 파일과 창 밖 레코드는 뺀다. 같은 (세션,상대경로) 는 가장 최근 1건만 —
#   한 파일을 열 번 고친 세션이 목록을 다 먹는 것을 막는다.
#
#   board-gate 가 편집마다 부르는 자리라 프로세스 수를 셋(date·stat·awk)으로
#   묶었다: mtime 은 파일 목록 전체를 stat 한 번으로 받고, 창 안에 든 파일만
#   모아 awk 한 번에 넘긴다. 세션 id 는 FILENAME 에서 뽑는다.
#   (파일마다 stat·awk 를 띄우면 세션 열 개짜리 저장소에서 프로세스 20개가 된다.)
# ---------------------------------------------------------------------------
board_scan() {
  local bd="${1:-}" self="${2:-}" win="${3:-$BOARD_WINDOW}" now mt p sid
  [[ -d "$bd" ]] || return 0
  now=$(date +%s)
  local files=()
  while read -r mt p; do
    [[ -n "${p:-}" ]] || continue
    (( now - ${mt:-0} > win )) && continue      # 창보다 오래 멈춘 세션은 열지도 않는다
    sid="${p##*/}"; sid="${sid%.tsv}"
    [[ "$sid" == "$self" ]] && continue
    files[${#files[@]}]="$p"
  done < <(stat -f '%m %N' "$bd"/*.tsv 2>/dev/null)
  (( ${#files[@]} )) || return 0
  LC_ALL=C awk -F'\t' -v now="$now" -v win="$win" '
    FNR == 1 { sid = FILENAME; sub(/.*\//, "", sid); sub(/\.tsv$/, "", sid) }
    $1 ~ /^[0-9]+$/ && now - $1 <= win {
      age = now - $1; k = sid "\t" $4
      if (!(k in seen) || age < seen[k]) { seen[k] = age; tool[k] = $2; wt[k] = $3; abs[k] = $5 } }
    END { for (k in seen) { split(k, a, "\t")
            printf "%s\t%d\t%s\t%s\t%s\t%s\n", a[1], seen[k], tool[k], wt[k], a[2], abs[k] } }
  ' "${files[@]}" 2>/dev/null
  return 0
}

# ---------------------------------------------------------------------------
# board_sweep : 방치된 보드 파일 수거 + 길어진 파일 트림. SessionStart 에서만
#   부른다 (세션 시작 1회라 비용을 신경 쓸 자리가 아니다 — 그래서 편집 경로인
#   board_record 에서 줄 수 검사를 떼어 여기로 모았다). 빈 디렉터리는 같이 지운다.
#   SessionEnd 훅을 따로 두지 않는 이유 — 종료 시점에 지울 것이 없다.
#   기록은 시간창으로 자연 만료되고, 파일 자체는 여기서 수거된다.
# ---------------------------------------------------------------------------
board_sweep() {
  [[ -d "$BOARD_ROOT" ]] || return 0
  local mins=$(( BOARD_STALE / 60 )) f n
  find "$BOARD_ROOT" -type f -name '*.tsv' -mmin "+$mins" -delete 2>/dev/null
  for f in "$BOARD_ROOT"/*/*.tsv; do
    [[ -f "$f" ]] || continue
    n=$(wc -l < "$f" 2>/dev/null | tr -d ' ')
    [[ "$n" =~ ^[0-9]+$ ]] && (( n > BOARD_KEEP * 2 )) || continue
    tail -n "$BOARD_KEEP" "$f" > "$f.tmp" 2>/dev/null && mv -f "$f.tmp" "$f" 2>/dev/null
  done
  find "$BOARD_ROOT" -type d -empty -delete 2>/dev/null
  return 0
}
