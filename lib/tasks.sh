# tasks.sh — 백그라운드 태스크(shell/Monitor) 추적 — transcript 에서 시작/종료를 뽑아
#   실행 중인 것만 남긴다. 목록 1행 배지(gen)와 preview 섹션이 같이 쓴다.
#
# agentop 이 source 하는 모듈이다 (단독 실행 아님). 상수·헬퍼는 agentop 프로세스
# 하나 안에서 공유되므로, 여기 정의는 다른 모듈에서 그대로 보인다.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# tasks_extract <transcript> : 백그라운드 태스크(shell/monitor) 레코드 추출.
#   출력 1줄 = kind \037 state \037 시작ISO \037 설명   (시작 순서 유지)
#     kind  : sh(Bash run_in_background) | mon(Monitor)
#     state : run | completed | failed | killed
#
#   transcript 안에서 한 태스크는 세 레코드에 흩어져 있다:
#     ① assistant tool_use   — 종류(Bash+run_in_background / Monitor)와 설명.
#        아직 taskId 가 없어 tool_use_id 로 걸어둔다.
#     ② user tool_result     — 여기서 taskId 확정. Bash 는 toolUseResult.
#        backgroundTaskId, Monitor 는 toolUseResult.taskId. 시각도 여기서.
#     ③ <task-notification>  — <status> 가 있으면 그 태스크는 끝난 것.
#     ④ TaskStop tool_use   — 세션이 직접 끊은 경우. ③ 알림이 안 남으므로
#        (실측: TaskStop 으로 죽인 태스크엔 <status> 레코드가 없다) 이걸 안 보면
#        영영 '실행 중' 으로 남는다.
#   ③④ 가 모두 없으면 아직 실행 중. grep 으로 관련 줄만 걸러 awk 에 넘겨 27MB
#   짜리 transcript 도 한 번 훑는 데 ~50ms 로 끝난다.
#
#   주의: transcript 를 grep/cat 한 결과가 다시 transcript 에 실릴 수 있어(세션이
#   제 로그를 들여다본 경우) 남의 taskId 가 섞일 수 있다. 그래도 ② 로 확정된
#   id 만 출력하므로 남의 id 는 목록에 오르지 않는다.
# ---------------------------------------------------------------------------
tasks_extract() {
  LC_ALL=C grep -aE '"run_in_background":true|"name":"Monitor"|"backgroundTaskId":"|"toolUseResult":\{"taskId":"|<status>|Monitor timed out|"name":"TaskStop"|"name":"KillShell"' \
    "$1" 2>/dev/null | LC_ALL=C awk '
    function unesc(s) { gsub(/\\n/, " ", s); gsub(/\\"/, "\"", s); gsub(/\\\\/, "\\", s); return s }

    # ③ 종료 알림 — 같은 줄에 <task-id> 와 <status> 가 함께 온다. 단 타임아웃으로
    #    끊긴 Monitor 만은 <status> 없이 이벤트 문구(Monitor timed out)로 끝난다.
    /<status>|Monitor timed out/ {
      fid = ""; st = ""
      if (match($0, /<task-id>[a-z0-9]+/)) fid = substr($0, RSTART+9, RLENGTH-9)
      if (match($0, /<status>[a-z]+/))     st  = substr($0, RSTART+8, RLENGTH-8)
      else if ($0 ~ /Monitor timed out/)   st  = "timeout"
      if (fid != "" && st != "") fin[fid] = st
    }

    # ① tool_use — 한 줄에 병렬 호출이 여러 개 실릴 수 있어 tool_use 단위로 쪼갠다.
    /"type":"tool_use"/ {
      n = split($0, ch, /\{"type":"tool_use"/)
      for (i = 2; i <= n; i++) {
        c = ch[i]
        if (!match(c, /"id":"toolu_[^"]*"/)) continue
        id = substr(c, RSTART+6, RLENGTH-7)
        if (!match(c, /"name":"[^"]*"/)) continue
        nm = substr(c, RSTART+8, RLENGTH-9)
        if (nm == "TaskStop" || nm == "KillShell") {
          # ④ 세션이 직접 끊은 태스크. 에이전트 이름을 넘긴 경우도 있는데
          #    그건 어떤 taskId 와도 안 맞아 그냥 무시된다.
          if (match(c, /"task_id":"[^"]*"/))       fin[substr(c, RSTART+11, RLENGTH-12)] = "killed"
          else if (match(c, /"shell_id":"[^"]*"/)) fin[substr(c, RSTART+12, RLENGTH-13)] = "killed"
          continue
        }
        if (nm == "Monitor") k = "mon"
        else if (nm == "Bash" && c ~ /"run_in_background":true/) k = "sh"
        else continue
        d = ""
        if (match(c, /"description":"[^"]*"/)) d = substr(c, RSTART+15, RLENGTH-16)
        if (d == "" && match(c, /"command":"[^"]*"/)) d = substr(c, RSTART+11, RLENGTH-12)
        kind[id] = k; desc[id] = unesc(d)
      }
    }

    # ② tool_result — tool_use_id 로 ① 과 이어 붙이고 taskId 를 확정한다.
    /"backgroundTaskId":"|"toolUseResult":\{"taskId":"/ {
      tid = ""; bid = ""
      if (match($0, /"tool_use_id":"toolu_[^"]*"/)) tid = substr($0, RSTART+15, RLENGTH-16)
      if (match($0, /"backgroundTaskId":"[^"]*"/))  bid = substr($0, RSTART+20, RLENGTH-21)
      else if (match($0, /"toolUseResult":\{"taskId":"[^"]*"/)) bid = substr($0, RSTART+27, RLENGTH-28)
      if (bid == "" || tid == "" || !(tid in kind) || (bid in tkind)) next
      ts = ""
      if (match($0, /"timestamp":"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}/)) ts = substr($0, RSTART+13, 19)
      ord[++cnt] = bid; tkind[bid] = kind[tid]; tdesc[bid] = desc[tid]; tstamp[bid] = ts
    }

    END {
      for (i = 1; i <= cnt; i++) {
        b = ord[i]
        st = (b in fin) ? fin[b] : "run"
        printf "%s\037%s\037%s\037%s\n", tkind[b], st, tstamp[b], tdesc[b]
      }
    }'
}

# ---------------------------------------------------------------------------
# tasks_scan <transcript> : tasks_extract 결과를 (크기:mtime) 서명으로 캐시.
#   목록(gen)은 ~2초마다 세션 수만큼 도는 경로라 매번 전체를 훑으면 부담이 크다.
#   transcript 는 append-only 라 크기·mtime 이 그대로면 결과도 그대로다.
#   캐시 파일 1행 = 서명, 2행부터 = tasks_extract 출력.
# ---------------------------------------------------------------------------
tasks_scan() {
  local tx="${1:-}" sig f cached
  [[ -n "$tx" && -f "$tx" ]] || return 0
  # v1 은 캐시 포맷 버전 — tasks_extract 출력 모양을 바꾸면 올려서 옛 캐시를 버린다
  sig=$(stat -f 'v1:%z:%m' "$tx" 2>/dev/null)
  [[ -n "$sig" ]] || return 0
  f="$TASK_CACHE/${tx##*/}.tasks"
  if [[ -f "$f" ]]; then
    IFS= read -r cached < "$f"
    [[ "$cached" == "$sig" ]] && { tail -n +2 "$f" 2>/dev/null; return 0; }
  fi
  mkdir -p "$TASK_CACHE" 2>/dev/null
  # 같은 세션을 gen/preview 가 동시에 훑을 수 있어 임시파일 → mv 로 원자 교체
  { printf '%s\n' "$sig"; tasks_extract "$tx"; } > "$f.$$" 2>/dev/null \
    && mv -f "$f.$$" "$f" 2>/dev/null
  rm -f "$f.$$" 2>/dev/null
  tail -n +2 "$f" 2>/dev/null
  return 0
}

# ---------------------------------------------------------------------------
# tasks_live <transcript> [since(ISO)] : 실행 중인 shell 수 \037 monitor 수.
#   목록 1행 배지용. since 를 주면 그보다 먼저 시작한 태스크는 이전 프로세스
#   것이므로 실행 중으로 세지 않는다 (epoch_iso 주석 참고).
# ---------------------------------------------------------------------------
tasks_live() {
  local rows
  rows=$(tasks_scan "${1:-}")
  [[ -n "$rows" ]] || { printf '0\0370'; return 0; }
  printf '%s\n' "$rows" | awk -F'\037' -v since="${2:-}" '
    $2=="run" && (since=="" || $3=="" || $3>=since) {
      if ($1=="sh") s++; else if ($1=="mon") m++
    }
    END { printf "%d\037%d", s+0, m+0 }'
}

# ---------------------------------------------------------------------------
# epoch_iso <startedAt(ms)> : 세션 프로세스 시작 시각을 transcript 와 같은 UTC
#   ISO 문자열로. 태스크 시작 시각도 ISO 라 문자열 비교(ISO8601 UTC 는 사전순
#   = 시간순)만으로 '지금 이 프로세스가 띄운 것인지' 를 가릴 수 있다 — 태스크
#   마다 date 를 부르지 않으려는 장치다. resume(--continue)로 되살린 세션은
#   sessionId 가 그대로라 transcript 에 이전 프로세스의 태스크가 섞여 있는데,
#   그것들은 부모가 죽으면서 같이 끝났으므로 '실행 중' 으로 세면 안 된다.
# ---------------------------------------------------------------------------
epoch_iso() {
  local ms="${1:-0}"
  [[ "$ms" =~ ^[0-9]+$ ]] && (( ms > 0 )) || return 0
  date -u -r "$(( ms / 1000 ))" +%Y-%m-%dT%H:%M:%S 2>/dev/null
  return 0
}

# ---------------------------------------------------------------------------
# iso_epoch <ISO8601(UTC)> : '2026-08-18T07:51:00' → epoch 초. 실패하면 빈 값.
#   preview 에서 표시할 몇 줄에만 부르므로 date 프로세스 비용은 무시할 만하다.
# ---------------------------------------------------------------------------
iso_epoch() {
  local t="${1:-}"
  [[ "$t" == ????-??-??T??:??:?? ]] || return 0
  date -u -j -f '%Y-%m-%dT%H:%M:%S' "$t" +%s 2>/dev/null
  return 0
}
