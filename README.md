# agentop

여러 터미널 탭에 흩어진 **AI 코딩 에이전트 세션을 한 화면에서 보고, 바로 그 탭으로 점프**하는 macOS용 TUI입니다.

Claude Code · cursor-agent · codex 세션을 함께 잡아 상태·컨텍스트 사용률·브랜치·워크트리·모델을 한 줄에 모으고, 입력 대기(HITL)에 걸린 세션이 생기면 벨과 macOS 알림으로 알려 줍니다. 읽기 전용 모니터가 아니라 `⏎` 한 번으로 해당 iTerm2 탭에 포커스가 넘어갑니다.

```
🤖2 ⚡1 🔭3  │  📁3 🌿5/8  │  opus5 6 · sonnet5 2
↑↓ 선택   ⏎ 탭 점프   p 목록만   k 강제종료   r 새로고침   q 종료
  state act  ctx dir               worktree
━━ my-service ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
● busy  🔭1  23% api               ⑂ feat-search
    └ ⎇ feat/search-ranking · opus5 · plan
◐ WAIT      41% web                ← 권한 승인
    └ ⎇ main · sonnet5
○ idle       8% worker
    └ ⎇ develop · opus5
━━ infra ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
● busy  🤖2  67% terraform
    └ ⎇ main · opus5
────────────────────────────────────────────────────────────
8 sessions  busy 5 · wait 1 · idle 2   │  cpu 12%  mem 4.2GB
```

## 무엇이 보이나

세션 하나가 두 줄입니다.

- **1행** — 상태(`● busy` / `◐ WAIT` / `○ idle`), 활동 배지, 컨텍스트 사용률, 디렉터리, 워크트리(`⑂`), 상태 사유
- **2행** — 브랜치(`⎇`), 모델, 권한 모드

프로젝트(git 루트)별로 묶여 `━━ 이름 ━━` 구분선이 붙고, 그룹 순서는 세션이 늘고 줄어도 흔들리지 않습니다.

**활동 배지**는 `state` 바로 뒤 고정 슬롯에 섭니다 — 🤖 서브에이전트, ⚡ 백그라운드 shell, 🔭 Monitor. 앞 컬럼이 모두 고정폭이라 세로로 훑으면 지금 뭔가 돌고 있는 세션만 한 열에서 바로 잡힙니다.

**맨 윗줄 통계**는 전체 활동 합계, 📁 프로젝트 수, 🌿 워크트리 비율(전체 세션 중 워크트리에서 도는 수), 모델 분포입니다. 아래 footer는 세션 수와 cpu/mem을 맡아 위아래가 겹치지 않습니다.

**입력 대기 세션**은 `◐ WAIT` 빨강 배지로 강조되고, 새로 발생하면 벨 + macOS 알림이 뜹니다(`CC_TOP_NOTIFY=0`으로 끕니다). 목록 맨 위로 끌어올리지는 않습니다 — 자기 프로젝트 자리를 지킵니다.

## 키

| 키 | 동작 |
|---|---|
| `↑` `↓` | 세션 선택 |
| `⏎` | 해당 iTerm2 탭으로 포커스 점프 |
| `p` | 상세 패널 토글 (2단 ⇄ 목록만) |
| `k` | 선택 세션 강제 종료 (SIGTERM → 잔존 시 SIGKILL, 확인받음) |
| `r` | 즉시 새로고침 (목록은 ~2초마다 자동 갱신) |
| `q` `ESC` | 종료 |

`p`로 상세 패널을 끄면 목록이 전체 폭을 쓰면서 디렉터리·워크트리·브랜치가 잘리지 않고 전부 나옵니다.

## 요구사항

**macOS 전용입니다.** `stat -f`(BSD), `osascript`, `pgrep`을 씁니다.

| | 비고 |
|---|---|
| `fzf` | `brew install fzf` |
| `claude` CLI | `claude agents --json`이 목록의 원천 |
| `jq` | 최신 macOS는 `/usr/bin/jq` 기본 탑재 |
| iTerm2 | `⏎` 탭 점프와 cursor/codex 상태 감지에 필요. 없으면 경고 후 목록만 동작 |

`perl` `awk` `sed` `ps` `stat` `stty` `osascript` `pgrep`은 macOS 기본 탑재라 따로 설치할 게 없습니다. **bash 3.2**(macOS 기본 `/bin/bash`)에서 동작하므로 최신 bash도 필요 없습니다.

`git` 바이너리는 **필요 없습니다.** 브랜치·워크트리·저장소 루트를 `.git` 파일에서 직접 읽습니다 — 폴링이 2초마다 세션 수만큼 도는데 매번 git 프로세스를 띄우지 않기 위해서입니다.

`cursor-agent`와 `codex`는 선택입니다. 떠 있으면 목록에 합류하고, 없으면 그냥 빠집니다.

## 설치

**어디에 clone해도 됩니다.** 본체가 자기 위치를 스스로 찾아 `lib/`를 읽으므로 정해진 경로가 없습니다.

```bash
git clone https://github.com/dowoonlee/agentop.git
cd agentop
./install.sh
```

`install.sh`는 파일을 어디로 복사하지 않고, **clone한 그 자리**를 가리키는 심볼릭 링크만 PATH에 걸어 줍니다. 먼저 요구사항(macOS · fzf · claude · jq · iTerm2)을 점검해 빠진 게 있으면 알려 줍니다.

| 옵션 | 동작 |
|---|---|
| (없음) | PATH 안의 쓰기 가능한 곳에 링크 (없으면 `~/.local/bin`) |
| `--prefix DIR` | 링크를 걸 디렉터리 지정 |
| `--alias` | 링크 대신 셸 설정(`.zshrc` 등)에 alias 추가 |
| `--name NAME` | 실행 이름 변경 (기본 `agentop`) |
| `--uninstall` | 설치한 링크 제거 |

저장소를 다른 곳으로 옮겼다면 디렉터리째 옮긴 뒤 `./install.sh`를 다시 돌리면 링크가 새 위치를 가리킵니다.

설치 스크립트를 쓰지 않아도 됩니다. 직접 실행하거나, 원하는 방식으로 걸어 두면 그만입니다.

```bash
/path/to/agentop/agentop                      # 그냥 실행
alias agentop='/path/to/agentop/agentop'      # alias
ln -s /path/to/agentop/agentop ~/.local/bin/  # 심볼릭 링크 (이중 링크도 따라갑니다)
```

## 환경변수

| 변수 | 기본 | 용도 |
|---|---|---|
| `CC_TOP_NOTIFY` | (켜짐) | `0`이면 HITL 벨·알림을 끕니다 |
| `CC_TOP_CTX_MAX` | `1000000` | 컨텍스트 윈도우 토큰 수. 관측값이 넘으면 자동으로 1M |

## 어디서 읽나

- `claude agents --json` — 세션 목록·상태
- `~/.claude/sessions/<pid>.json` — `waitingFor` 폴백
- `~/.claude/projects/…/<sid>.jsonl` — 모델, 권한 모드, 컨텍스트 토큰, 서브에이전트, 백그라운드 태스크
- iTerm2 화면 텍스트(AppleScript) — cursor-agent / codex 상태 판정

transcript는 수십 MB까지 커지므로 꼬리 256KB만 훑고, 백그라운드 태스크 스캔은 `(크기:mtime)` 서명으로 캐시해 변경된 세션만 다시 읽습니다.

## 구조

```
agentop        진입점 — fzf 구성, 서브커맨드 디스패치
install.sh     설치 — clone 위치를 가리키는 링크 생성
lib/const.sh   상수 — 팔레트, 컬럼 폭, 화면 판정 패턴
lib/core.sh    git/transcript/모델 헬퍼
lib/tasks.sh   백그라운드 shell·Monitor 스캔 + 캐시
lib/gen.sh     claude 행 생성 + 최종 조립·폭 맞춤
lib/gen-agents.sh  cursor / codex 행 생성
lib/preview.sh 상세 패널
lib/ui.sh      헤더·통계·footer·폴링·알림
lib/actions.sh 탭 점프, 강제 종료
```

서브커맨드는 fzf 바인딩이 자기 자신을 재실행하는 용도입니다 — `--gen` `--poll` `--preview` `--header` `--summary` `--jump` `--kill` 등. 디버깅에는 `--classify`(cursor 화면 판정)와 `--classify-codex`가 쓸 만합니다.

## 라이선스

MIT
