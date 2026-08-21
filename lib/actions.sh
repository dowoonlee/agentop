# actions.sh — 세션에 실제로 손대는 동작 — iTerm2 탭 점프, 강제종료(확인 → TERM → KILL).
#
# agentop 이 source 하는 모듈이다 (단독 실행 아님). 상수·헬퍼는 agentop 프로세스
# 하나 안에서 공유되므로, 여기 정의는 다른 모듈에서 그대로 보인다.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# --jump <tty> : 해당 tty 의 iTerm2 세션으로 포커스 이동
# ---------------------------------------------------------------------------
jump() {
  local tty="${1:-}"
  [[ -z "$tty" || "$tty" == "-" ]] && exit 0
  osascript - "$tty" >/dev/null 2>&1 <<'OSA'
on run argv
  set targetTTY to "/dev/" & (item 1 of argv)
  tell application "iTerm2"
    repeat with w in windows
      repeat with t in tabs of w
        repeat with s in sessions of t
          if (tty of s) is targetTTY then
            select s
            tell t to select
            activate
            return
          end if
        end repeat
      end repeat
    end repeat
  end tell
end run
OSA
}

# ---------------------------------------------------------------------------
# --kill <pid> <cwd> <name> : 선택 세션 강제종료.
#   확인 → SIGTERM → 최대 ~3초 종료 대기 → 잔존 시 SIGKILL(재확인).
#   execute(silent 아님) 바인딩으로 호출되어 터미널을 점유하므로 read 가능.
# ---------------------------------------------------------------------------
kill_session() {
  local pid="${1:-}" cwd="${2:-}" name="${3:-}"
  local label="${name:-$(basename "$cwd" 2>/dev/null)}"
  local ans i

  [[ "$pid" =~ ^[0-9]+$ ]] || { printf '잘못된 pid: %s\n' "$pid"; sleep 1; return 0; }
  kill -0 "$pid" 2>/dev/null || { printf 'pid %s 는 이미 종료되었습니다.\n' "$pid"; sleep 1; return 0; }

  local tty; tty=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
  printf '\n%s세션 강제종료%s  pid=%s  tty=%s  %s%s%s\n' \
    "$RED" "$RESET" "$pid" "${tty:--}" "$BLUE" "$label" "$RESET"
  # 현재 agentop 을 띄운 터미널과 같은 tty 면 자기 자신을 죽이는 셈 → 경고
  if [[ -n "$tty" && "$tty" != "-" && "/dev/$tty" == "$(tty 2>/dev/null)" ]]; then
    printf '%s⚠ 지금 이 화면(agentop)을 띄운 세션입니다. 종료하면 agentop 도 닫힙니다.%s\n' "$YELLOW" "$RESET"
  fi
  printf 'SIGTERM 을 보낼까요? [y/N] '
  read -r ans
  [[ "$ans" =~ ^[Yy]$ ]] || { printf '취소했습니다.\n'; sleep 0.4; return 0; }

  kill -TERM "$pid" 2>/dev/null
  for ((i=0; i<6; i++)); do
    kill -0 "$pid" 2>/dev/null || { printf '%s종료됨%s (SIGTERM)\n' "$GRAY" "$RESET"; sleep 0.4; return 0; }
    sleep 0.5
  done

  printf '%sSIGTERM 으로 안 죽었습니다.%s SIGKILL(-9) 보낼까요? [y/N] ' "$YELLOW" "$RESET"
  read -r ans
  [[ "$ans" =~ ^[Yy]$ ]] || { printf 'SIGKILL 취소 — pid %s 아직 살아있음.\n' "$pid"; sleep 1; return 0; }
  kill -KILL "$pid" 2>/dev/null
  sleep 0.4
  if kill -0 "$pid" 2>/dev/null; then
    printf '%s여전히 살아있습니다%s (권한 문제일 수 있음): pid %s\n' "$RED" "$RESET" "$pid"; sleep 1.2
  else
    printf '%s강제 종료됨%s (SIGKILL)\n' "$GRAY" "$RESET"; sleep 0.4
  fi
}
