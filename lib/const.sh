# const.sh — 상수 — ANSI 팔레트, 행/컬럼 폭, preview 섹션 설정, cursor/codex 화면 판정 패턴.
#   값만 있고 로직은 없다. UI 문구가 바뀌면 여기만 고치면 되는 자리.
#
# agentop 이 source 하는 모듈이다 (단독 실행 아님). 상수·헬퍼는 agentop 프로세스
# 하나 안에서 공유되므로, 여기 정의는 다른 모듈에서 그대로 보인다.
# ---------------------------------------------------------------------------
# ---- ANSI (context-bar.sh 팔레트와 통일) ----
RESET=$'\e[0m'
GRAY=$'\e[38;5;245m'
DIM=$'\e[38;5;238m'
BLUE=$'\e[38;5;74m'
YELLOW=$'\e[38;5;179m'
RED=$'\e[38;5;167m'
BOLD=$'\e[1m'
HL=$'\e[1;48;5;167;38;5;232m'   # HITL 강조 배지: 굵게 / 빨강 배경 / 어두운 글씨
CYAN=$'\e[38;5;80m'             # cursor-agent 구분색
MAGENTA=$'\e[38;5;176m'         # codex 구분색
GREENB=$'\e[38;5;114m'          # git 브랜치 표시색
WTC=$'\e[38;5;103m'             # 워크트리 배지색 (상태색·모델색과 안 겹치는 톤)
STOPC=$'\e[38;5;241m'           # 정지(ps stat=T) 세션 행 색. 살아있는 행보다 확실히 죽이되
                                #   DIM(238)보다는 읽히는 톤 — 잔재를 지우지 않고 남기는
                                #   자리라 '있다는 건 보이되 눈이 먼저 가지는 않는' 밝기다.
# 모델 배지 색 — 상태색(노랑/빨강/파랑)과 겹치지 않는 은은한 톤
M_OPUS=$'\e[38;5;140m'          # 연보라
M_SONNET=$'\e[38;5;108m'        # 세이지
M_HAIKU=$'\e[38;5;109m'         # 연청
M_FABLE=$'\e[38;5;180m'         # 탠

# ---- 2행 렌더 ----
# 세션 1개 = 2줄. 1행 = 상태/ctx%/디렉터리/워크트리, 2행 = 브랜치 · 모델 · 권한모드.
# (프로젝트 그룹의 첫 세션은 구분선이 얹혀 3줄 — gen_all 참조)
# gen 계열은 '한 세션 = 한 줄' 텍스트 포맷을 유지해야 (awk/cut 소비자들이 전부
# 줄 기반) 하므로, 2행의 줄바꿈은 레코드 안에서 VT(0x0b) 로 들고 다니다가 fzf
# 에 넣기 직전에만 `tr '\n\013' '\0\n'` 로 치환한다 (레코드 구분자는 NUL →
# --read0, 레코드 내부 VT → 진짜 개행 → fzf 멀티라인 아이템).
VT=$'\013'
META_IND='    '                 # 2행 들여쓰기
META_BR_MAX=30                  # 2행 브랜치명 최대 길이 — 넘으면 잘라서 모델/모드 자리 확보
WT_MAX=24                       # 1행 워크트리명 최대 길이
DIR_W=17                        # 1행 dir 컬럼 폭 (2단 모드). 위 셋은 2단(좌 48%)에서만 적용되는
                                #   생략 규칙 — 목록만(wide) 모드에선 전부 풀려 원문 그대로 나온다.
ACT_W=4                         # 1행 활동 배지 슬롯 최소폭 ('🤖 3' = 4칸, 이모지가 2칸).
                                #   실제 폭은 그 순간 가장 넓은 행에 맞춰 늘어난다(fit_dir).
                                #   최소폭을 두는 이유: 배지 1개짜리(대부분)에서 폭이 고정돼
                                #   붙었다 떨어질 때마다 뒤 컬럼이 흔들리지 않는다.
WIDE=0                          # 1=목록만 모드(상세 패널 숨김). gen_all 이 매 생성 시 판정해
                                #   세팅하고 wt_badge/meta_line/dir_cell 이 읽는다 (동적 스코프).

# ---- preview 서브에이전트 섹션 ----
SUB_MAX=5                       # 나열할 최대 개수 (나머지는 '외 N개' 로 접음)
SUB_LIVE=120                    # 이 초 안에 쓰기가 있었으면 활동중(●)
SUB_TYPE_W=18                   # agentType 컬럼 폭
SUB_PREFIX_W=28                 # 행 앞부분 폭: 2 + ●1 + 1 + age4 + 1 + type18 + 1
                                #   (subagents_block 의 printf 와 반드시 같이 고칠 것)

# ---- preview 백그라운드 태스크(shell/monitor) 섹션 ----
# 서브에이전트와 달리 Bash(run_in_background) 와 Monitor 는 시작/종료가 모두
# transcript 에 남는다 — 시작은 tool_result 의 backgroundTaskId / taskId,
# 종료는 <task-notification> 의 <status> — 그래서 '실행 중' 을 추정이 아니라
# 확정으로 판정할 수 있다 (서브에이전트는 mtime 추정이었다).
TASK_MAX=5                      # 나열할 최대 개수 (나머지는 '외 N개' 로 접음)
TASK_KIND_W=7                   # kind 컬럼 폭 ('monitor' 가 7)
TASK_PREFIX_W=17                # 행 앞부분 폭: 2 + 아이콘1 + 1 + age4 + 1 + kind7 + 1
                                #   (tasks_block 의 printf 와 반드시 같이 고칠 것)
SH_ICON='▶'                     # preview 행 — 실행 중 shell
MON_ICON='◉'                    # preview 행 — 실행 중 Monitor
SHC=$'\e[38;5;150m'             # shell 색 (연녹 — 모델/브랜치색과 안 겹치는 톤)
MONC=$'\e[38;5;111m'            # monitor 색 (연청보라)

# 목록 1행 배지는 이모지, preview 행은 텍스트 기호로 나눠 쓴다. 목록은 여러
# 세션을 훑어 내리며 '뭐가 돌고 있나' 를 한눈에 잡는 자리라 색·형태가 강한
# 이모지가 유리하고, preview 는 age/종류가 열로 정렬된 표라 폭 2칸짜리
# 이모지를 넣으면 열이 밀린다 (이모지는 ANSI 색도 안 먹는다 — 숫자에만 준다).
AG_EMOJI='🤖'                   # 서브에이전트
SH_EMOJI='⚡'                   # 백그라운드 shell
MON_EMOJI='🔭'                  # Monitor

# 헤더 통계(stats)용 — 목록 배지와 달리 열 정렬이 없는 자리라 폭 2칸을 써도 된다.
PROJ_EMOJI='📁'                 # 프로젝트(git 저장소)
WT_EMOJI='🌿'                   # 워크트리

# 배지 셀을 감싸는 마커 — dir 의 RS…GS 와 같은 역할이다(act_cell/fit_dir 참조).
# 흐름제어(XON/XOFF)나 대체 문자셋 전환(SO/SI)에 안 걸리는 코드포인트로 골랐다.
ACT_L=$'\001'                   # 여는 마커
ACT_R=$'\002'                   # 닫는 마커

# 태스크 스캔 캐시 — transcript 는 수십 MB 까지 커지는데 목록은 ~2초마다 세션
# 수만큼 돈다. 결과를 (크기:mtime) 서명으로 캐시해 변경된 세션만 다시 훑는다.
TASK_CACHE="${TMPDIR:-/tmp}/agentop-tasks-$(id -u 2>/dev/null || echo 0)"

# 컨텍스트 윈도우(토큰) — preview 사용률 계산용.
# 기본 1M. CC_TOP_CTX_MAX 로 오버라이드 가능. 관측 토큰이 이 값을 넘으면 자동 1M.
CTX_MAX="${CC_TOP_CTX_MAX:-1000000}"

# cursor-agent 상태 판정 문구 (iTerm2 화면 하단 텍스트 매칭, grep -E).
# cursor-agent 버전업으로 UI 문구가 바뀌면 여기만 수정하면 됨.
# 검사 범위는 화면 마지막 CUR_TAIL 줄.
#   PERM      : 권한 플로우 프롬프트 (승인 메뉴·거부 사유 입력)
#   PERM_LIVE : 승인 대기 중인 명령 옆 표시 — 처리되면 소요시간으로 교체되므로
#               잔상이 불가능한 상태 정확 마커 (화면 전체에서 매칭해도 안전)
#   ASK_LIVE  : 활성 AskQuestion 박스에만 뜨는 마커 ('Question N of M' + 키
#               안내줄). 응답/스킵되면 박스가 지워지고 'AskQuestion <제목> (N)'
#               요약 잔상으로 교체되므로 역시 잔상 불가능.
#               주의: 'AskQuestion' 문자열 자체는 잔상에만 나오므로 매칭 금지.
CUR_PAT_PERM='Run this command\?|Not in allowlist:|→ Run \(once\)|→ Reason for rejection'
CUR_PAT_PERM_LIVE='Waiting for approval\.\.\.'
CUR_PAT_ASK_LIVE='Question [0-9]+ of [0-9]+|Space select · Enter next/submit|Esc to skip'
CUR_PAT_IDLE='→ Add a follow-up'
CUR_TAIL=25

# codex CLI 상태 판정 문구 (iTerm2 화면 하단 텍스트 매칭, grep -E).
# codex 버전업으로 UI 문구가 바뀌면 여기만 수정하면 됨. 검사 범위는 화면 마지막
# CDX_TAIL 줄. cursor 와 달리 codex 는 별도 AskQuestion UI 가 없어(질문도 그냥
# 텍스트로 묻고 입력 대기=idle) PERM·BUSY 두 마커만 본다.
#   PERM : 승인 모달 — 명령/패치/메모리 실행 또는 tool call 승인. 제목('Allow
#          Codex to …', 'Approve app tool call?')은 모달에만 뜨고, 메뉴 옵션
#          ('Yes, proceed', 'tell Codex what to do differently')도 응답되면
#          사라지므로 잔상이 불가능한 상태 정확 마커 → 화면 전체 매칭 안전.
#   BUSY : 턴 진행 중 상태줄 '• Working (Ns • esc to interrupt)'. 턴이 끝나면
#          사라지므로 busy 동안만 존재. (주의: footer 의 'esc' 는 소문자 →
#          대소문자 구분 매칭이라 [Ee] 로 양쪽 다 받는다)
CDX_PAT_PERM='Allow Codex to |Approve app tool call\?|Yes, proceed|tell Codex what to do differently'
CDX_PAT_BUSY='Working \([0-9]+|[Ee]sc to interrupt|to interrupt and send'
CDX_TAIL=25

# ---- 목록 자동 갱신 (poll) ----
# 갱신 주기(초). poll 은 이 길이의 타이머를 gen 과 '겹쳐' 돌리므로, gen 이 주기
# 안에 끝나는 한 이 값이 그대로 화면 갱신 간격이 된다. 타이머를 gen 앞에 두면
# 한 바퀴가 'POLL_INT + gen' 이 되어 간격이 두 배 가까이 벌어진다 (실측: 세션
# 5개에서 gen 1.7초 → 사이클 3.7초).
POLL_INT="${CC_TOP_POLL:-2}"
# gen 이 주기를 넘겼을 때의 최소 휴식(초). 세션이 늘면 gen 이 POLL_INT 를 넘기는데,
# 그때 곧장 다음 바퀴로 가면 gen 이 쉬지 않고 이어 붙어 CPU 를 계속 문다. 갱신이
# 조금 늦는 것보다 그쪽이 나쁘다 — 다른 세션이 쓸 CPU 를 이 화면이 가져간다.
POLL_FLOOR=0.3

# ---- 화면 배치 ('p' 가 도는 세 모드) ----
# 2단은 좌우로 나누고(목록이 세로로 길다), 활동은 위아래로 나눈다 — 서버·태스크는
# 세로로 긴 표라 가로 폭보다 줄 수가 아쉽고, 위아래로 나누면 상세가 터미널 전체
# 폭을 써서 컨테이너 이름·명령 설명이 안 잘린다.
#
# 활동 모드에서 목록은 위다(preview 가 down). 세 모드를 오가도 세션 목록이 늘 화면
# 같은 자리에서 시작해야 눈이 그 줄을 다시 찾지 않는다 — 2단·목록만에서 목록이
# 위에서 내려오는데 활동에서만 아래로 밀리면, 모드를 바꿀 때마다 보던 세션을
# 눈으로 다시 더듬게 된다.
PV_WIN_SPLIT='right,52%,wrap,border-left'
PV_WIN_ACT='down,72%,wrap,border-top'

# ---- 로컬 서버 (세션이 띄운 리스닝 포트) ----
# 백그라운드 shell(⚡)과 나눠 두는 이유: 테스트·CI 대기처럼 끝나기를 기다리는
# 태스크와, dev 서버처럼 '떠 있는 것 자체가 상태' 인 것은 알고 싶은 값이 다르다.
# 전자는 '몇 개 도나', 후자는 '어느 포트로 열렸나' 다. 그래서 판정 근거도 다르게
# 둔다 — ⚡ 는 transcript(기록), 🌐 는 lsof(실물)다. 서버가 죽으면 포트가 닫혀
# 배지가 바로 사라지므로, transcript 기반 판정의 고질병(죽었는데 실행 중으로
# 남는 것)이 여기엔 없다. 대신 포그라운드로 띄운 서버도 같이 잡힌다.
SRV_EMOJI='🌐'                  # 1행 배지 — 이 세션이 물고 있는 리스닝 포트 수
SRVC=$'\e[38;5;79m'             # 서버 배지색 (청록 — shell 연녹/monitor 연청보라와 구분)
DKR_EMOJI='🐳'                  # 1행 배지 + preview — 이 세션 자리에서 뜬 compose 컨테이너
DKRC=$'\e[38;5;67m'             # 컨테이너 색 (탁한 파랑 — 로컬 포트보다 한 단계 죽인다)
DKR_ORPHC=$'\e[38;5;131m'       # 주인 없는 스택 색 (탁한 벽돌 — 컨테이너색과 hue 가 반대라
                                #   '🐳 42' 처럼 붙여 써도 두 수가 갈린다. RED(167) 보다
                                #   어둡고 탁한 톤 — 경고는 아니고 '정리해도 될 잔재' 다)
SRV_BLK_MAX=8                   # preview servers 섹션에 나열할 최대 줄 수
SRV_NAME_W=26                   # preview servers 섹션 이름 컬럼 폭
SRV_ANCESTOR_MAX=12             # 리스닝 pid 에서 세션까지 거슬러 오를 최대 단계
                                #   (zsh → npm → node 처럼 2~4 단계가 보통이고,
                                #    순환이 생겨도 여기서 멈춘다)

# compose 컨테이너 조회 캐시 — docker ps 는 0.1~1.0s 로 폭이 넓고, 데몬이 안 떠
# 있으면 몇 초를 끈다. 목록 폴링(2초)도 preview 도 그 시간을 그대로 물 수 없으므로
# 조회 결과를 짧게 캐시한다. 목록은 캐시만 읽고 갱신은 백그라운드로 돌린다
# (dkr_warm) — 배지가 최대 DKR_TTL 초 늦게 붙는 대신 폴링이 절대 안 밀린다.
# 컨테이너는 dev 서버처럼 오래 떠 있는 것이라 그 정도 지연은 읽는 데 지장이 없다.
DKR_CACHE="${TMPDIR:-/tmp}/agentop-docker-$(id -u 2>/dev/null || echo 0)"
DKR_LOCK="$DKR_CACHE.lock"          # 갱신 중복 방지 (mkdir 원자성). 아래 초 넘게 묵으면 치운다.
DKR_LOCK_STALE=60                   # 갱신 프로세스가 죽어 남은 락으로 보는 기준(초)
DKR_TTL="${CC_TOP_DOCKER_TTL:-5}"   # 캐시 수명(초). 0 이면 compose 조회를 아예 끈다.

# ---- 세션 보드 (hooks/board-*.sh 가 쌓는 편집 기록) ----
# 같은 저장소의 세션들이 어떤 파일을 만졌는지 남기는 보드. 1행에는 '다른 세션과
# 겹치는 파일 수' 만 배지로 얹고(⚠ N), 무엇이 겹치는지는 preview 섹션에서 푼다.
BOARD_EMOJI='⚠'                 # 1행 배지 — 겹치는 파일 수
BOARDC=$'\e[38;5;173m'          # 보드 배지색 (주황 — 상태 빨강/노랑과 구분되는 톤)
BOARD_BLK_MAX=6                 # preview 보드 섹션에 나열할 최대 파일 수
BOARD_BLK_PATH_W=44             # preview 보드 섹션 경로 컬럼 폭
