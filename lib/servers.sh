# servers.sh — 세션이 띄운 로컬 서버 — 리스닝 포트를 실물로 조회해 목록 1행
#   배지(🌐N)와 preview 상세 섹션으로 만든다.
#
#   백그라운드 shell(⚡)과 왜 나누나 — 알고 싶은 값이 다르다. 테스트·CI 대기는
#   '끝났나' 가, dev 서버는 '어느 포트로 열렸나' 가 궁금하다. 그래서 판정 근거도
#   나눴다: ⚡ 는 transcript(기록), 🌐 는 lsof(실물)다.
#
#   실물 조회의 이점이 둘 있다. 서버가 죽으면 포트가 닫혀 배지가 바로 사라진다
#   (transcript 판정은 종료 알림이 안 실리면 영영 '실행 중' 으로 남는다). 그리고
#   포그라운드로 띄운 서버도 잡힌다 — 백그라운드 태스크가 아니라서 ⚡ 로는 안
#   보이던 것들이다.
#
#   귀속은 프로세스 조상으로 판정한다: 리스닝 pid 에서 부모를 거슬러 올라가다
#   `claude` 를 만나면 그 세션의 서버다. 실측한 체인은 이렇다 —
#     node(vite) → npm exec vite → /bin/zsh -c → claude   (2~4 단계)
#   포트 번호로 추측하거나 명령 문자열을 패턴 매칭하지 않는 이유: 실제 명령이
#   `docker compose up --build` 인데 그 안에서 vite 가 뜨는 식이라 문자열로는
#   못 잡는다. 조상 추적은 무엇을 어떻게 띄웠든 결과(열린 포트)만 본다.
#
#   Docker 컨테이너는 여기서 안 잡힌다 — 컨테이너 포트는 Docker 데몬이 물고
#   있어 세션의 자손이 아니다. compose 스택은 근거도 조회 방법도 달라서 아래
#   dkr_* 계열이 따로 맡는다 (라벨 귀속 + docker ps 캐시). 목록 배지도 🌐 과
#   합치지 않고 🐳 로 따로 세운다 — 자세한 이유는 srv_block 주석 참조.
#
# agentop 이 source 하는 모듈이다 (단독 실행 아님). 상수·헬퍼는 agentop 프로세스
# 하나 안에서 공유되므로, 여기 정의는 다른 모듈에서 그대로 보인다.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# srv_map : 모든 리스닝 포트를 한 번 훑어 만든 '세션 pid 별 포트' 맵.
#   형식은 " <세션pid>:<포트/리스닝pid,…> " — gen 의 세션 루프가 프로세스를
#   하나도 더 띄우지 않고 파라미터 확장만으로 조회할 수 있게 문자열 하나로 낸다
#   (board_map 과 같은 방침 — 2초 폴링에서 세션마다 lsof 를 띄우면 그게 다 프로세스다).
#
#   포트에 리스닝 pid 를 붙여 두는 이유: preview 가 '무슨 서버인지' 이름을 뽑을 때
#   그 pid 가 필요한데, 여기서 이미 알고 있는 값이라 안 실어 보내면 패널에서
#   포트마다 lsof 를 다시 불러야 한다 (포트 2개면 그것만 0.1초다).
#
#   lsof 와 ps 를 각각 한 번씩만 부르고 파싱은 awk 하나로 끝낸다. 실측 ~0.15초.
#   (세션마다 따로 돌리면 세션 열 개짜리 화면에서 lsof 가 열 번이다.)
#
#   같은 포트를 여러 프로세스가 물고 있을 수 있어(IPv4/IPv6 이중 바인딩) 중복은
#   접는다. 포트는 오름차순 — 훑을 때 자리가 튀지 않게.
# ---------------------------------------------------------------------------
srv_map() {
  command -v lsof >/dev/null 2>&1 || return 0
  printf ' '
  { ps -eo pid=,ppid=,comm= 2>/dev/null | sed 's/^ *//' | awk '{ print "P", $1, $2, $3 }'
    # NAME 은 '127.0.0.1:5173' 처럼 오고 뒤에 '(LISTEN)' 이 따라붙어 필드가 갈린다.
    lsof -iTCP -sTCP:LISTEN -P -n 2>/dev/null | awk '
      NR > 1 && $NF == "(LISTEN)" {
        n = $(NF-1); sub(/.*:/, "", n)
        if (n ~ /^[0-9]+$/) print "L", $2, n }'
  } | LC_ALL=C awk -v MAXUP="${SRV_ANCESTOR_MAX:-12}" '
    $1 == "P" { ppid[$2] = $3; comm[$2] = $4; next }
    $1 == "L" {
      lp = $2; p = lp                       # lp = 실제로 포트를 물고 있는 프로세스
      for (i = 0; i < MAXUP && p != "" && p != "0" && p != "1"; i++) {
        if (comm[p] == "claude") { if (!((p, $3) in seen)) { seen[p, $3] = 1; port[p] = port[p] " " $3 "/" lp } ; break }
        p = ppid[p]
      }
    }
    END {
      for (s in port) {
        n = split(port[s], a, " ")
        # 포트 몇 개짜리라 단순 선택정렬로 충분하다 (수치 비교 — 문자열이면 9000>19111.
        # 항목이 "18899/22524" 라도 awk 의 수치 변환은 앞의 포트만 읽는다)
        for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++)
          if (a[j] + 0 < a[i] + 0) { t = a[i]; a[i] = a[j]; a[j] = t }
        out = ""
        for (i = 1; i <= n; i++) out = out (i > 1 ? "," : "") a[i]
        printf "%s:%s ", s, out
      }
    }'
  return 0
}

# ---------------------------------------------------------------------------
# srv_badge <세션pid> : 1행 배지 '🌐N'. 서버가 없으면 빈 값.
#   맵은 SRV_MAP 에 담겨 있다고 본다 (gen 이 루프 전에 한 번 채운다).
#   프로세스를 띄우지 않는다 — 파라미터 확장만 쓴다 (board_badge 와 같은 방침).
# ---------------------------------------------------------------------------
srv_ports() {   # <세션pid> → "19111,5173" (없으면 빈 값)
  local pid="${1:-}" rest
  [[ -n "$pid" && -n "${SRV_MAP:-}" ]] || return 0
  case "$SRV_MAP" in *" $pid:"*) ;; *) return 0 ;; esac
  rest="${SRV_MAP##* "$pid":}"
  printf '%s' "${rest%% *}"
}

srv_count() {   # <포트목록> → 개수. 콤마 개수 + 1 (프로세스 없이 센다)
  local ports="${1:-}" rest n
  [[ -n "$ports" ]] || { printf '0'; return 0; }
  n=1; rest="$ports"
  while [[ "$rest" == *,* ]]; do rest="${rest#*,}"; n=$(( n + 1 )); done
  printf '%s' "$n"
}

srv_badge() {
  local pid="${1:-}" ports n
  ports=$(srv_ports "$pid"); [[ -n "$ports" ]] || return 0
  n=$(srv_count "$ports")
  printf '%s%s%s%s' "$SRV_EMOJI" "$SRVC" "$n" "$RESET"
}

# ---------------------------------------------------------------------------
# srv_snap_ports <세션pid> : 목록 스냅샷(필드 20)에서 포트를 읽는다.
#   preview 는 목록과 별개 프로세스라 SRV_MAP 을 못 물려받는데, gen 이 이미 구해
#   실어 보낸 값이 스냅샷에 있다. 이걸 읽으면 패널마다 lsof+ps 를 다시 도는
#   0.15초가 빠진다 (↑↓ 로 훑을 때 그 차이가 그대로 체감된다).
#   종료 코드로 '행을 찾았는지' 를 알린다 — 서버가 없는 세션도 유효한 답(빈 값)
#   이라, 빈 문자열만으로는 '없음' 과 '못 읽음' 을 못 가른다.
# ---------------------------------------------------------------------------
srv_snap_ports() {
  local pid="${1:-}" f="${CC_TOP_LST:-}"
  [[ -n "$pid" && -n "$f" && -s "$f" ]] || return 1
  LC_ALL=C awk -F'\037' -v p="$pid" '
    $2 == p { print $20; hit = 1; exit } END { exit !hit }' "$f" 2>/dev/null
}

# ---------------------------------------------------------------------------
# srv_name <리스닝pid> : 그 포트를 물고 있는 것이 무엇인지 짧은 이름으로.
#   lsof 의 COMMAND 는 'node' · 'python3.1' 이라 무슨 서버인지 안 알려 준다.
#   실제로 알고 싶은 건 vite / uvicorn / http.server 쪽이라 명령줄에서 뽑는다:
#     node …/node_modules/.bin/vite      → vite
#     python3 -m uvicorn app:api         → uvicorn
#     npm exec vite --port 19111         → vite
#   못 뽑으면 실행파일 basename 으로 떨어진다 (최소한 종류는 알려 준다).
#   조상도 한 단계 본다 — npm/uv 처럼 실행기가 한 겹 씌워진 경우가 흔하다.
# ---------------------------------------------------------------------------
srv_name() {
  local pid="${1:-}" cmd par pcmd
  [[ -n "$pid" ]] || return 0
  cmd=$(ps -o command= -p "$pid" 2>/dev/null)
  [[ -n "$cmd" ]] || return 0
  par=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  [[ -n "$par" ]] && pcmd=$(ps -o command= -p "$par" 2>/dev/null)
  LC_ALL=C awk -v c="$cmd" -v pc="${pcmd:-}" '
    function base(s) { sub(/.*\//, "", s); return s }
    # pick <명령줄> : 그 명령줄에서 "무슨 서버인지" 로 읽히는 토큰 하나.
    function pick(s,   n, a, i, t) {
      n = split(s, a, /[ \t]+/)
      for (i = 1; i <= n; i++) {
        t = a[i]
        if (t == "-m" && i < n) return a[i+1]          # python3 -m uvicorn
        if (t == "exec" && i < n) return base(a[i+1])  # npm exec vite
        if (t == "run" && i < n && a[i+1] !~ /^-/) return base(a[i+1])
        if (t ~ /node_modules\/\.bin\//) return base(t)
        if (t ~ /\/(vite|uvicorn|gunicorn|hypercorn|daphne|next|nuxt|webpack|rollup|esbuild|serve|http-server|flask|django-admin|manage\.py|rails|puma|air)([.-][a-z]*)?(\.js|\.py)?$/) return base(t)
      }
      return ""
    }
    BEGIN {
      v = pick(c)
      if (v == "" && pc != "") v = pick(pc)
      if (v == "") { split(c, a, /[ \t]+/); v = base(a[1]); sub(/[0-9.]+$/, "", v) }
      sub(/\.(js|py|rb|ts)$/, "", v)
      print v
    }'
  return 0
}

# ---------------------------------------------------------------------------
# compose 컨테이너 캐시 — docker ps 한 벌을 파일에 받아 두고 목록·preview 가
#   같이 읽는다. 조회를 부르는 자리가 둘이라(2초 폴링 + 패널 갱신) 각자 부르면
#   docker 데몬을 초당 몇 번씩 두드리게 된다.
#
#   dkr_fresh : 캐시가 TTL 안인가 (파일 mtime 만 본다 — 프로세스를 안 띄운다)
#   dkr_pull  : 동기 갱신. 락(mkdir)으로 중복 실행을 막는다 — 2초 폴링이 도는
#               동안 갱신이 아직 안 끝났으면 그 사이클은 그냥 건너뛴다.
#   dkr_warm  : 목록용. 낡았으면 백그라운드로 갱신만 걸고 즉시 돌아온다.
#
#   캐시가 없는 첫 사이클엔 배지가 안 붙고 다음 폴링(2초 뒤)에 붙는다. 컨테이너를
#   '지금 막' 띄운 순간을 다투는 값이 아니라 그 편이 폴링을 미루는 것보다 낫다.
# ---------------------------------------------------------------------------
dkr_fresh() {
  local mt now
  (( ${DKR_TTL:-5} > 0 )) || return 1
  mt=$(stat -f '%m' "$DKR_CACHE" 2>/dev/null)
  [[ "$mt" =~ ^[0-9]+$ ]] || return 1
  now=$(date +%s)
  (( now - mt <= DKR_TTL ))
}

dkr_pull() {
  local now mt
  (( ${DKR_TTL:-5} > 0 )) || return 1
  command -v docker >/dev/null 2>&1 || return 1
  if ! mkdir "$DKR_LOCK" 2>/dev/null; then
    # 락이 잡혀 있다 — 보통은 다른 프로세스가 지금 긁는 중이라 그냥 넘긴다.
    # 다만 docker 가 매달려 갱신 프로세스가 죽어 버린 경우엔 락이 영영 남아
    # 캐시가 다시는 안 갱신되므로, 오래 묵은 락은 치우고 다음 호출에 맡긴다.
    now=$(date +%s); mt=$(stat -f '%m' "$DKR_LOCK" 2>/dev/null)
    [[ "$mt" =~ ^[0-9]+$ ]] && (( now - mt > DKR_LOCK_STALE )) && rmdir "$DKR_LOCK" 2>/dev/null
    return 1
  fi
  # 데몬이 안 떠 있으면 docker ps 가 몇 초를 끌 수 있다 — 빈 캐시라도 남겨 두면
  # TTL 동안은 다시 안 부른다 (그만큼 멈추는 것을 막는다).
  docker ps -a --no-trunc \
    --format '{{.Label "com.docker.compose.project.working_dir"}}\t{{.State}}\t{{.Names}}\t{{.Ports}}' \
    > "$DKR_CACHE.$$" 2>/dev/null
  mv -f "$DKR_CACHE.$$" "$DKR_CACHE" 2>/dev/null || rm -f "$DKR_CACHE.$$" 2>/dev/null
  rmdir "$DKR_LOCK" 2>/dev/null
  return 0
}

dkr_warm() {
  (( ${DKR_TTL:-5} > 0 )) || return 0
  command -v docker >/dev/null 2>&1 || return 0
  dkr_fresh && return 0
  # 부모(gen)가 끝나도 갱신은 남아 캐시를 채우고 죽는다. 출력은 전부 버린다 —
  # gen 의 stdout 은 목록 레코드 전용이라 한 글자라도 새면 행이 깨진다.
  ( dkr_pull >/dev/null 2>&1 & ) >/dev/null 2>&1
  return 0
}

# ---------------------------------------------------------------------------
# dkr_map : 캐시를 한 번 훑어 만든 '작업 디렉터리별 실행 중 컨테이너 수' 맵.
#   srv_map·board_map 과 같은 방침 — gen 의 세션 루프가 프로세스를 더 띄우지 않고
#   파라미터 확장만으로 조회하도록 문자열 하나로 낸다.
#
#   다만 키가 경로다. srv_map 의 ' <pid>:<값> ' 형식은 공백이 든 경로에서 깨지므로
#   구분자를 RS(0x1e)/US(0x1f) 로 둔다 — 경로에 들어갈 수 없는 바이트다.
#   형식: <RS><디렉터리><US><실행 중 개수>  (항목이 이어서 붙는다)
#
#   세는 것은 running 뿐이다. 목록 배지는 '지금 떠 있는 것' 을 세는 자리라(🌐 도
#   실제 리스닝 포트만 센다), 중지된 컨테이너는 preview 에서 '(중지 N)' 으로 푼다.
# ---------------------------------------------------------------------------
dkr_map() {
  [[ -f "$DKR_CACHE" ]] || return 0
  LC_ALL=C awk -F'\t' '
    $1 != "" && $2 == "running" { n[$1]++ }
    END { for (d in n) printf "\036%s\037%s", d, n[d] }' "$DKR_CACHE" 2>/dev/null
  return 0
}

# ---------------------------------------------------------------------------
# dkr_count <디렉터리> : 맵에서 그 자리의 실행 중 컨테이너 수. 없으면 0.
#   맵은 DKR_MAP 에 담겨 있다고 본다 (gen 이 루프 전에 한 번 채운다).
#   프로세스를 띄우지 않는다 — 파라미터 확장만 쓴다.
# ---------------------------------------------------------------------------
dkr_count() {
  local dir="${1:-}" rest n
  [[ -n "$dir" && -n "${DKR_MAP:-}" ]] || { printf '0'; return 0; }
  case "$DKR_MAP" in *$'\036'"$dir"$'\037'*) ;; *) printf '0'; return 0 ;; esac
  rest="${DKR_MAP##*$'\036'"$dir"$'\037'}"
  n="${rest%%$'\036'*}"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  printf '%s' "$n"
}

# ---------------------------------------------------------------------------
# srv_docker <디렉터리> : 그 디렉터리에서 띄운 compose 컨테이너.
#   출력: <상태:up|down> \t <이름> \t <포트매핑>
#
#   귀속은 compose 가 컨테이너에 박아 두는 project.working_dir 라벨로 한다 —
#   `docker compose -p c2p5317 …` 처럼 프로젝트 이름을 바꿔 띄워도 라벨은 compose
#   파일이 있던 자리를 가리키므로, 세션의 실효 cwd 와 그대로 대응된다.
#
#   docker ps 는 0.4~1.0s 라 목록 폴링(2초)에 못 넣는다. preview 에서만 부르되
#   ↑↓ 로 훑을 때 매번 1초를 물면 못 쓰므로 짧게(DKR_TTL) 캐시한다. 캐시는 전체
#   목록 1벌이고 필터는 읽는 쪽에서 한다 — 세션마다 캐시를 나누면 훑는 동안
#   세션 수만큼 docker ps 가 돈다.
#   중지된 컨테이너도 낸다 — 'compose 로 띄웠는데 그중 하나가 죽어서 로컬로
#   대신 띄운' 상황이 실제로 흔하고, 그때 죽은 쪽이 안 보이면 이유를 못 찾는다.
# ---------------------------------------------------------------------------
srv_docker() {
  local dir="${1:-}"
  [[ -n "$dir" ]] || return 0
  # preview 는 목록과 달리 '지금 이 세션 하나' 를 그리는 자리라, 캐시가 낡았으면
  # 여기서 기다려서라도 채운다 (dkr_pull 은 동기다). 목록 쪽은 절대 안 기다린다
  # — dkr_warm 이 백그라운드로만 갱신한다.
  dkr_fresh || dkr_pull
  [[ -f "$DKR_CACHE" ]] || return 0

  LC_ALL=C awk -F'\t' -v dir="$dir" '
    $1 != dir { next }
    {
      # "0.0.0.0:19116->8000/tcp, [::]:19116->8000/tcp" → "19116→8000"
      # IPv4/IPv6 이 같은 매핑을 두 번 실으므로 접는다. 공개 안 된 포트(8001/tcp)는 뺀다.
      n = split($4, a, /, */); out = ""
      for (i = 1; i <= n; i++) {
        if (a[i] !~ /->/) continue
        host = a[i]; sub(/->.*/, "", host); sub(/.*:/, "", host)
        cont = a[i]; sub(/.*->/, "", cont); sub(/\/.*/, "", cont)
        if (host == "" || (host SUBSEP cont) in seen) continue
        seen[host, cont] = 1
        out = out (out == "" ? "" : " ") host (host == cont ? "" : "\342\206\222" cont)
      }
      delete seen
      printf "%s\t%s\t%s\n", ($2 == "running" ? "up" : "down"), $3, out
    }' "$DKR_CACHE"
  return 0
}

# ---------------------------------------------------------------------------
# srv_block <세션pid> <실효cwd> : preview 하단 'servers' 섹션.
#   로컬 리스닝 포트(🌐)를 먼저, 그 세션의 compose 컨테이너(🐳)를 뒤에 붙인다.
#   둘 다 없으면 아무것도 그리지 않는다 (조용한 기본값 — board_block 과 같다).
#
#   목록 1행에도 둘 다 나가지만 배지는 끝까지 나눠 둔다(🌐N 🐳N). '내가 띄운
#   프로세스' 와 '데몬이 들고 있는 컨테이너' 는 죽이는 손버릇도(k 로 세션을
#   접으면 앞의 것만 같이 죽는다) 살아 있는 근거도 달라서, 같은 숫자로 합치면
#   그 차이가 지워진다. 여기 상세는 그 위에 이름·포트 매핑과 중지된 것까지 편다.
# ---------------------------------------------------------------------------
srv_block() {
  local pid="${1:-}" cwd="${2:-}" ports dk rows=0 nloc=0 nup=0 ndown=0
  [[ -n "$pid" ]] || return 0

  # 포트는 스냅샷에서 먼저 찾는다 (gen 이 실어 보낸 필드 20). 스냅샷이 없는
  # 단독 실행·디버깅에서만 직접 훑는다.
  ports=$(srv_snap_ports "$pid") || {
    [[ -n "${SRV_MAP:-}" ]] || SRV_MAP=$(srv_map)
    ports=$(srv_ports "$pid")
  }
  dk=$(srv_docker "$cwd")
  [[ -n "$ports" || -n "$dk" ]] || return 0

  [[ -n "$ports" ]] && nloc=$(srv_count "$ports")
  if [[ -n "$dk" ]]; then
    nup=$(printf '%s\n' "$dk" | LC_ALL=C awk -F'\t' '$1=="up"{n++} END{print n+0}')
    ndown=$(printf '%s\n' "$dk" | LC_ALL=C awk -F'\t' '$1=="down"{n++} END{print n+0}')
  fi

  printf '\n%sservers%s' "$GRAY" "$RESET"
  (( nloc > 0 )) && printf ' %s%s개%s' "$SRVC" "$nloc" "$RESET"
  # 구분자는 앞에 실제로 뭔가 찍혔을 때만 — 로컬이 0 이면 'servers · 컨테이너' 가 된다.
  (( nup  > 0 )) && { (( nloc > 0 )) && printf '%s · %s' "$GRAY" "$RESET"
                      printf ' %s컨테이너 %s개%s' "$DKRC" "$nup" "$RESET"; }
  (( ndown > 0 )) && printf ' %s(중지 %s)%s' "$DIM" "$ndown" "$RESET"
  printf '\n'

  # 로컬 포트 — 항목은 "포트/리스닝pid" 다. pid 가 딸려 오므로 여기서 lsof 를
  # 다시 부르지 않고 이름만 뽑으면 된다 (srv_map 주석 참조).
  local ent p nm lpid
  local IFS=,
  for ent in $ports; do
    (( rows >= SRV_BLK_MAX )) && break
    rows=$(( rows + 1 ))
    p="${ent%%/*}"; lpid="${ent#*/}"
    [[ "$lpid" == "$ent" ]] && lpid=""     # 옛 포맷(pid 없음) 방어
    nm=$(srv_name "$lpid")
    printf '  %s%s%s %s%-5s%s %s\n' \
      "$SRVC" "$SRV_EMOJI" "$RESET" "$SRVC" "$p" "$RESET" \
      "$(trunc_disp "${nm:-?}" "$SRV_NAME_W")"
  done
  unset IFS

  # compose 컨테이너 — 중지된 것을 먼저 낸다. 스택이 열 몇 개면 상한에 걸려 뒤가
  # 잘리는데, 그때 잘려서 안 될 것은 '떠 있는 아홉 개' 가 아니라 '죽은 하나' 다
  # (sort 는 'down' < 'up' 이라 기본 오름차순이 그대로 이 순서다).
  local st nmc pm
  while IFS=$'\t' read -r st nmc pm; do
    [[ -n "$nmc" ]] || continue
    (( rows >= SRV_BLK_MAX )) && { printf '  %s… 외 더 있음%s\n' "$DIM" "$RESET"; break; }
    rows=$(( rows + 1 ))
    # 이름 컬럼은 폭을 고정한다 — 포트 매핑이 이름 길이만큼 들쭉날쭉하면 세로로
    # 훑을 때 어느 포트가 어디로 가는지 눈이 못 따라간다. 컨테이너 이름은 사실상
    # ASCII 라 trunc_disp(표시폭)로 자른 뒤 %-*s(바이트) 로 채워도 어긋나지 않는다.
    if [[ "$st" == up ]]; then
      printf '  %s%s%s %s%-*s%s %s\n' "$DKRC" "$DKR_EMOJI" "$RESET" \
        "$DKRC" "$SRV_NAME_W" "$(trunc_disp "$nmc" "$SRV_NAME_W")" "$RESET" "${pm:-$DIM-$RESET}"
    else
      printf '  %s✗%s %s%-*s%s %s\n' "$DIM" "$RESET" \
        "$DIM" "$SRV_NAME_W" "$(trunc_disp "$nmc" "$SRV_NAME_W")" "$RESET" "${DIM}중지${RESET}"
    fi
  done < <(printf '%s\n' "$dk" | LC_ALL=C sort -t$'\t' -k1,1 -k2,2)
  return 0
}
