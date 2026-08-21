# ui.sh — fzf 화면 요소 — 헤더(명령 도움말+컬럼 이름), footer 요약, 커서 위치 복원,
#   목록 폴링(변경 감지 + HITL 알림).
#
# agentop 이 source 하는 모듈이다 (단독 실행 아님). 상수·헬퍼는 agentop 프로세스
# 하나 안에서 공유되므로, 여기 정의는 다른 모듈에서 그대로 보인다.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# main : fzf 라이브 뷰
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# --posof : result 이벤트마다 호출. 마지막으로 사용자가 둔 커서의 sessionId 를
#   현재 목록(lst)에서 찾아 pos(N) 액션을 출력 → reload 후에도 같은 세션 추적.
#   (fzf --track 은 '행 문자열' 기준이라 status/정렬 변동에 깨짐 → sid 기준으로 대체)
# ---------------------------------------------------------------------------
posof() {
  local cur="${CC_TOP_CUR:-}" lst="${CC_TOP_LST:-}"
  [[ -s "$cur" && -s "$lst" ]] || exit 0
  local sid n
  sid=$(cat "$cur" 2>/dev/null)
  [[ -z "$sid" ]] && exit 0
  # sid 는 4번째 필드(\037 구분). col1 만 ANSI 라 매칭에 영향 없음.
  n=$(awk -F'\037' -v s="$sid" '$4==s{print NR; exit}' "$lst" 2>/dev/null)
  [[ -n "$n" ]] && printf 'pos(%s)' "$n"
}

# ---------------------------------------------------------------------------
# --poll : 목록이 실제로 바뀔 때까지 2초 간격으로 블로킹 폴링하다, 바뀐 순간에만
#   새 목록을 stdout 으로 내보낸다. 변경 없는 사이클엔 아무것도 출력하지 않아
#   fzf 가 화면을 다시 그리지 않음 → htop 처럼 깜빡임 없이 상태 변화 때만 1회 갱신.
#   서명에서 제외하는 필드: started(6, age 용 매초 변동), cpu/rss raw(10·11,
#   미세 변동). cpu 는 col1(1)에 정수%로 녹아 있어 busy 변동 시엔 갱신되지만
#   idle(0%) 은 안정 → 깜빡임 없음.
# ---------------------------------------------------------------------------
poll() {
  # CC_TOP_LST 는 main 이 잡아 준다. 서브커맨드를 직접 실행하면 비어 있는데,
  # 그때 ".sig" 같은 상대경로가 되면 실행한 디렉터리에 파일이 떨어진다 —
  # 남의 작업 디렉터리를 더럽히지 않도록 $TMPDIR 로 보낸다.
  local base="${CC_TOP_LST:-${TMPDIR:-/tmp}/agentop-lst}"
  local lst="$base" sigf="$base.sig" waitf="$base.wait"
  local out sig
  while :; do
    sleep 2
    out=$("$SELF" --gen)
    sig=$(printf '%s' "$out" | cut -d$'\037' -f1-5,7-9)
    if [[ "$sig" != "$(cat "$sigf" 2>/dev/null)" ]]; then
      # 신규 waiting(HITL) 세션 감지 → 직전 스냅샷에 없던 pid 만 알림
      local nowwait prevwait newp
      nowwait=$(printf '%s\n' "$out" | awk -F'\037' '$7=="waiting"{print $2}' | sort)
      prevwait=$(cat "$waitf" 2>/dev/null)
      printf '%s' "$nowwait" > "$waitf"
      newp=$(comm -23 <(printf '%s\n' "$nowwait") <(printf '%s\n' "$prevwait") 2>/dev/null)
      [[ -n "${newp//[$' \t\n']/}" ]] && notify_hitl "$out" "$newp"

      printf '%s' "$sig" > "$sigf"
      printf '%s\n' "$out" > "$lst"   # posof 용 스냅샷
      printf '%s\n' "$out"            # fzf 목록 교체
      return 0
    fi
  done
}

# ---------------------------------------------------------------------------
# notify_hitl <gen출력> <신규 waiting pid 목록> : 입력 대기 세션 발생 알림.
#   터미널 벨 + macOS 알림. CC_TOP_NOTIFY=0 으로 끌 수 있음.
# ---------------------------------------------------------------------------
notify_hitl() {
  [[ "${CC_TOP_NOTIFY:-1}" == 0 ]] && return 0
  local out="$1" pids="$2" msg="" p line dir wfor
  while read -r p; do
    [[ -z "$p" ]] && continue
    line=$(printf '%s\n' "$out" | awk -F'\037' -v x="$p" '$2==x{print; exit}')
    dir=$(basename "$(printf '%s' "$line" | cut -d$'\037' -f5)" 2>/dev/null)
    wfor=$(printf '%s' "$line" | cut -d$'\037' -f8)
    msg+="${msg:+, }${dir}${wfor:+ (${wfor})}"
  done <<< "$pids"
  msg="${msg//\"/}"   # osascript 문자열 깨짐 방지
  [[ -z "$msg" ]] && return 0
  printf '\a' > /dev/tty 2>/dev/null
  osascript -e "display notification \"$msg\" with title \"agentop · 입력 대기\" sound name \"Glass\"" \
    >/dev/null 2>&1 &
}

# ---------------------------------------------------------------------------
# --summary : 현재 목록(lst) 집계 한 줄. footer(transform-footer)용.
# ---------------------------------------------------------------------------
summary() {
  local lst="${CC_TOP_LST:-/dev/null}"
  [[ -s "$lst" ]] || { printf ''; return 0; }
  awk -F'\037' -v B="$YELLOW" -v R="$RED" -v G="$GRAY" -v Z="$RESET" -v BL="$BLUE" '
    { n++; s=$7
      if ($4 ~ /^cursor:/)   cur++        # cursor 세션은 별도 표기 + 상태 집계에도 합산
      if ($4 ~ /^codex:/)    cdx++        # codex 세션도 동일 (오버레이 카운트)
      if      (s=="busy")    busy++
      else if (s=="waiting") wait++
      else if (s=="idle")    idle++
      else if (s=="cursor")  { }          # 화면 못 읽어 상태 미상 — cur 에만 카운트
      else if (s=="codex")   { }          #   "          "        — cdx 에만 카운트
      else                   other++
      cpu += $10+0; rss += $11+0 }
    END {
      if (n==0) { printf ""; exit }
      wcol = (wait>0) ? R : G
      printf "%s%d sessions%s  %sbusy %d%s · %swait %d%s · %sidle %d%s",
        BL, n, Z, B, busy+0, Z, wcol, wait+0, Z, G, idle+0, Z
      if (cur>0)   printf " · %scursor %d%s", G, cur+0, Z
      if (cdx>0)   printf " · %scodex %d%s",  G, cdx+0, Z
      if (other>0) printf " · %s? %d%s",      G, other+0, Z
      printf "   %s│%s  cpu %d%%  mem %.1fGB", G, Z, cpu+0, rss/1024
    }
  ' "$lst"
}

# ---------------------------------------------------------------------------
# stats <avail> : 목록 바로 위에 얹는 전체 통계 한 줄.
#   '지금 무슨 일이 벌어지고 있나' 를 맡는다 — 활동(🤖⚡🔭 합계) · 📁프로젝트 수 ·
#   🌿워크트리 비율 · 모델 분포. 세션 수와 cpu/mem 은 footer(summary) 몫이라 여기서
#   빼서 위아래가 겹치지 않게 나눴다.
#
#   이모지는 ANSI 색을 안 먹으므로 숫자에만 색을 준다 (목록 배지와 같은 규칙).
#
#   원자료는 gen 이 실어 보낸 필드 15~18 이다 — 배지 개수와 모델은 col1 에 렌더만
#   돼 있어 목록에서 다시 못 뽑는다.
#
#   폭이 모자라면 뒤 세그먼트부터 버린다 (활동 > 프로젝트 > 모델 순으로 지킨다).
#   줄바꿈은 하지 않는다 — 헤더가 한 줄 늘 때마다 목록이 그만큼 줄고, 세션 1개가
#   2줄이라 체감이 크다.
# ---------------------------------------------------------------------------
stats() {
  local lst="${CC_TOP_LST:-/dev/null}" avail="${1:-80}"
  [[ -s "$lst" ]] || { printf ''; return 0; }
  awk -F'\037' -v AV="$avail" \
      -v AGE="$AG_EMOJI" -v SHE="$SH_EMOJI" -v MONE="$MON_EMOJI" \
      -v AGC="$YELLOW" -v SHCL="$SHC" -v MONCL="$MONC" \
      -v G="$GRAY" -v Z="$RESET" -v BL="$BLUE" -v WTCL="$WTC" \
      -v PRE="$PROJ_EMOJI" -v WTE="$WT_EMOJI" \
      -v MO="$M_OPUS" -v MS="$M_SONNET" -v MH="$M_HAIKU" -v MF="$M_FABLE" '
    function mcol(m) {
      if (m ~ /^opus/)   return MO
      if (m ~ /^sonnet/) return MS
      if (m ~ /^haiku/)  return MH
      if (m ~ /^fable/)  return MF
      return G
    }
    # add <세그먼트> <표시폭> : 남은 폭 안에서만 잇는다. 구분자는 5칸.
    function add(seg, w,   sepw) {
      sepw = (out == "") ? 0 : 5
      if (used + sepw + w > AV) return
      out = out (out == "" ? "" : G "  │  " Z) seg
      used += sepw + w
    }
    { ag += $15; sh += $16; mon += $17
      if ($12 != "") proj[$12] = 1
      if ($13 != "") wt++
      if ($18 != "") mdl[$18]++ }
    END {
      if (NR == 0) { printf ""; exit }

      # 활동 — 돌고 있는 종류만. 이모지는 ANSI 를 안 먹어 숫자에만 색을 준다(배지와 동일).
      seg = ""; w = 0
      if (ag > 0)  { seg = seg (seg == "" ? "" : " ") AGE  AGC   ag  Z; w += (w ? 1 : 0) + 2 + length(ag)  }
      if (sh > 0)  { seg = seg (seg == "" ? "" : " ") SHE  SHCL  sh  Z; w += (w ? 1 : 0) + 2 + length(sh)  }
      if (mon > 0) { seg = seg (seg == "" ? "" : " ") MONE MONCL mon Z; w += (w ? 1 : 0) + 2 + length(mon) }
      if (seg != "") add(seg, w)
      else           add(G "활동 없음" Z, 7)

      # 프로젝트는 고유 개수, 워크트리는 전체 세션 중 몇 개가 워크트리에서 도는지의
      # 비율이다 — 분모가 세션 수라 나머지(본체 체크아웃)가 몇 개인지 바로 읽힌다.
      # (이 awk 도 bash 작은따옴표 안이라 주석에 작은따옴표를 쓰면 거기서 끊긴다.)
      np = length(proj)
      seg = PRE BL np Z; w = 2 + length(np)
      if (wt > 0) { seg = seg " " WTE WTCL wt Z G "/" NR Z; w += 1 + 2 + length(wt) + 1 + length(NR) }
      add(seg, w)

      # 모델 분포 — 많은 순 3종까지, 나머지는 +N 으로 접는다.
      n = 0
      for (m in mdl) { n++; mk[n] = m }
      for (i = 1; i <= n; i++)          # 종류가 몇 개 안 돼 단순 선택정렬로 충분
        for (j = i + 1; j <= n; j++)
          if (mdl[mk[j]] > mdl[mk[i]]) { t = mk[i]; mk[i] = mk[j]; mk[j] = t }
      seg = ""; w = 0; rest = 0
      for (i = 1; i <= n; i++) {
        if (i <= 3) {
          seg = seg (seg == "" ? "" : G " · " Z) mcol(mk[i]) mk[i] Z " " G mdl[mk[i]] Z
          w += (w ? 3 : 0) + length(mk[i]) + 1 + length(mdl[mk[i]])
        } else rest += mdl[mk[i]]
      }
      if (rest > 0) { seg = seg G " +" rest Z; w += 2 + length(rest) }
      if (seg != "") add(seg, w)

      printf "%s", out
    }
  ' "$lst"
}

# ---------------------------------------------------------------------------
# dispwidth <str>... : 터미널 표시 폭 계산 — 인자당 한 줄. 한글 등 East-Asian
#   Wide/Fullwidth=2, ↑↓⏎ 같은 Ambiguous 및 ASCII=1 (iTerm2 기본 렌더와 일치).
#   여러 개를 한 번에 받는 이유: 헤더는 목록이 바뀔 때마다 다시 그려져서
#   항목마다 perl 을 띄우면 그 비용이 폴링 주기마다 쌓인다.
# ---------------------------------------------------------------------------
dispwidth() {
  perl -CSA -e '
    for my $s (@ARGV) {
      my $w = 0;
      $w += ($_ =~ /\p{Ea=W}|\p{Ea=F}/) ? 2 : 1 for split //, $s;
      print "$w\n";
    }
  ' -- "$@" 2>/dev/null
}

# ---------------------------------------------------------------------------
# dir_width : 현재 목록 스냅샷($lst)의 '가장 긴 dir' 표시 폭 (최소 DIR_W).
#   목록만 모드에서 fit_dir 이 쓰는 폭과 같은 값을 헤더도 알아야 컬럼 이름이
#   행과 같은 자리에 선다. 폭을 파일로 주고받지 않고 스냅샷에서 바로 계산하는
#   이유: 종료 직후 뒤늦게 끝난 --gen 이 그 파일을 되살려 남기는 일이 없게.
# ---------------------------------------------------------------------------
dir_width() {
  local f="${CC_TOP_LST:-}"
  [[ -s "$f" ]] || { printf '%s' "$DIR_W"; return 0; }
  cut -d$'\037' -f5 "$f" 2>/dev/null | perl -CSA -ne '
    chomp; s{.*/}{};
    my $w = 0;
    $w += ($_ =~ /\p{Ea=W}|\p{Ea=F}/) ? 2 : 1 for split //, $_;
    $m = $w if $w > $m;
    END { print $m+0 }
  ' 2>/dev/null
}

# ---------------------------------------------------------------------------
# act_width : 헤더가 쓸 활동 배지 슬롯 폭 — 스냅샷의 폭 필드(14) 최댓값.
#   fit_dir 이 행에 적용하는 규칙(ACT_W 하한)과 같은 값을 헤더도 알아야 뒤의
#   ctx/dir 컬럼 이름이 행과 같은 자리에 선다. dir_width 와 같은 이유로 파일을
#   따로 두지 않고 스냅샷에서 바로 구한다.
# ---------------------------------------------------------------------------
act_width() {
  local f="${CC_TOP_LST:-}"
  [[ -s "$f" ]] || { printf '%s' "$ACT_W"; return 0; }
  cut -d$'\037' -f14 "$f" 2>/dev/null \
    | awk -v m="$ACT_W" '$1 ~ /^[0-9]+$/ && $1 > m { m = $1 } END { print m + 0 }'
}

# ---------------------------------------------------------------------------
# build_header <cols> : fzf 헤더 문자열 생성. 화면 폭에 맞춰 '명령 항목 경계'
#   에서만 줄바꿈 → 항목 중간이 잘리지 않음. fzf 는 \n 포함 헤더를 멀티라인
#   으로 렌더한다. 가용 폭은 메인 영역(main_width — 상세 패널이 있으면 전체의
#   ~48%, 목록만 모드면 전체 폭). 'p' 항목은 현재 모드에서 누르면 되는 쪽을
#   보여 준다 (패널 표시 중 → 'p 목록만', 목록만 모드 → 'p 상세').
#   맨 윗줄은 전체 통계(stats), 마지막 2줄은 컬럼 이름 — 목록 바로 위에 붙도록
#   --header-first 는 쓰지 않는다.
# ---------------------------------------------------------------------------
build_header() {
  local cols="${1:-80}"
  local pv_item
  if preview_shown; then pv_item="p 목록만"; else pv_item="p 상세"; fi
  local items=( "↑↓ 선택" "⏎ 탭 점프" "$pv_item" "k 강제종료" "r 새로고침" "q 종료" )
  local sep="   " sepw=3
  local avail=$(( $(main_width "$cols") - 2 ))
  (( avail < 10 )) && avail=10
  # 개행은 변수로 — ${out:+$'\n'} 처럼 expansion word 안에선 $'\n' 가
  # ANSI-C 확장되지 않아 리터럴이 새어나간다.
  local nl=$'\n' out="" line="" linew=0 text w i=0
  # 전체 통계는 맨 윗줄 — 명령 항목보다 위다. 아래 루프가 ${out:+$nl} 로 잇는다.
  out=$(stats "$avail")
  local ws=(); IFS=$'\n' read -r -d '' -a ws < <(dispwidth "${items[@]}"; printf '\0')
  for text in "${items[@]}"; do
    w="${ws[i]:-}"; (( i++ ))
    [[ "$w" =~ ^[0-9]+$ ]] || w=${#text}
    if [[ -z "$line" ]]; then
      line="$text"; linew=$w
    elif (( linew + sepw + w <= avail )); then
      line+="$sep$text"; linew=$(( linew + sepw + w ))
    else
      out+="${out:+$nl}$line"
      line="$text"; linew=$w
    fi
  done
  out+="${out:+$nl}$line"

  # 컬럼 이름 — gen 의 행 포맷과 자릿수를 그대로 맞춘다.
  #   1행 icon(1) st(5) act(act_width + 구분1) ctx(3+%) dir(2단은 DIR_W 고정,
  #   목록만은 dir_width) → 그 뒤는 워크트리 배지·상태 사유 자리
  #   2행 META_IND + '└ ' + 브랜치 · 모델 · 권한모드
  # fzf 는 헤더도 포인터 폭(2칸)만큼 들여쓰므로 별도 패딩 없이 그대로 정렬된다.
  local c1 c2 dw="$DIR_W" aw ac=''
  if ! preview_shown; then
    dw=$(dir_width)
    [[ "$dw" =~ ^[0-9]+$ ]] && (( dw >= DIR_W )) || dw="$DIR_W"
  fi
  aw=$(act_width); [[ "$aw" =~ ^[0-9]+$ ]] || aw="$ACT_W"
  # 슬롯이 'act' 3글자보다 좁으면(ACT_W 를 낮춘 경우) 이름 없이 자리만 비운다.
  if   (( aw >= 3 )); then ac=$(printf '%-*s ' "$aw" 'act')
  elif (( aw >  0 )); then ac=$(printf '%*s ' "$aw" '')
  fi
  c1=$(printf '%s %-5s %s%4s %-*s %s' ' ' 'state' "$ac" 'ctx' "$dw" 'dir' 'worktree')
  c2=$(printf '%s└ ⎇ branch · model · mode' "$META_IND")
  out+="$nl${GRAY}${c1}${RESET}$nl${DIM}${c2}${RESET}"

  printf '%s' "$out"
}
