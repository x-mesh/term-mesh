# term-mesh 활용성·차별화 전략 로드맵

작성일: 2026-07-07
상태: Proposal (Draft)
관련 문서: `PRD.md`, `TODO.md`, `PROJECTS.md`, `docs/peer-federation-impl-status.md`

이 문서는 term-mesh가 "여러 AI 에이전트를 띄울 수 있는 터미널"에서
**"AI 에이전트 함대(fleet)를 운영하는 표준 관제탑(control plane)"**으로 진화하기 위해
해야 할 일을 전략 축별로 최대한 넓게 계획·제안한다.

---

## 0. 요약 (TL;DR)

term-mesh의 방어 가능한 차별화는 단일 기능이 아니라 **네 자산의 교집합**에서 나온다:

1. **네이티브 성능** — libghostty/Metal 기반 GPU 터미널 (Electron 계열 경쟁자가 복제 불가)
2. **에이전트 오케스트레이션 프로토콜** — `tm-agent` + task board + runbook + watch (터미널 앱이 아니라 운영체계)
3. **관제/거버넌스** — 비용 추적, Budget Guard(SIGSTOP), 파일 히트맵, 알림 링 (에이전트를 "감시·통제"하는 유일한 터미널)
4. **Peer Federation** — Mac↔Mac 레이아웃 보존 릴레이 (원격 함대 운영의 물리적 기반)

제안하는 전략 우선순위 (Now → Next → Later):

| 단계 | 테마 | 핵심 산출물 |
|------|------|------------|
| **Now (0–2개월)** | 신뢰·온보딩·첫 5분 | 코드서명/공증, 첫 실행 마법사, CLI 통합 설치, 문서 사이트 |
| **Next (2–5개월)** | 오케스트레이션 심화 | 세션 영속화/resume, Mission Control 뷰, diff 리뷰·승인 큐, MCP 서버 |
| **Later (5–12개월)** | 함대 확장·생태계 | 원격 함대(peer×team), 모바일/웹 뷰어, 플러그인 API, Team/Pro 티어 |

---

## 1. 현재 자산 진단 — 무엇이 이미 있는가

전략 수립 전에, 이미 구축된 것을 정확히 인정해야 중복 투자를 피한다.

### 1.1 완성도 높은 자산 (차별화의 씨앗)

| 자산 | 상태 | 경쟁 대비 |
|------|------|----------|
| libghostty Metal 터미널 + 수직 사이드바 + 스플릿 | 성숙 (GPU 리소스 회수 v0.150 포함) | Warp/Wave 등 자체 렌더러 진영과 동급, Electron 계열(Conductor 류) 대비 압도적 |
| `tm-agent` (Rust, ~2ms) — create/delegate/broadcast/task board/claim/auto-claim/recycle/watch | 성숙, 프로토콜(TM-PROTOCOL-v1)까지 정의 | **독보적.** claude-squad·Crystal은 "세션 나란히 띄우기" 수준, term-mesh는 리더-워커 프로토콜과 work-pool까지 있음 |
| 전략 오케스트레이션 (`/tm-op` refine/tournament/debate/red-team/research…) | 동작, 문서화됨 | 시장에 대응물 없음 |
| Peer Federation (레이아웃 보존 릴레이 + SSH 터널 + Bonjour + 재접속) | Phase D 대부분 완료, 안정화 진행 중 (0.139–0.151 릴리즈 노트가 대부분 peer 버그픽스) | tmux 원격과 비교 불가한 UX. VibeTunnel류는 단일 세션 웹뷰 수준 |
| 브라우저 패널 + agent-browser 호환 자동화 API (find/frame/dialog/cookies/…) | v2 API·테스트까지 완료 | 터미널 앱 중 유일. 에이전트가 "자기 결과물을 브라우저로 검증"하는 루프 가능 |
| 비용 추적(JSONL 파싱) + Budget Guard(SIGSTOP/SIGCONT) + 파일 히트맵 + 대시보드 | 동작 | "지출 통제"까지 하는 도구는 없음 |
| Socket/HTTP API + v2 handle 기반 CLI + Python e2e 스위트(tests_v2) | 성숙 | 자동화 친화도 최상위 |
| 샌드박스 워크트리 (`--sandbox`, git-kit wt, delegate --worktree auto) | 동작 | Conductor/Sculptor와 동급 이상 |
| CLI 멀티 지원 (claude/codex/kiro/gemini + 프로파일) | 동작 | 단일 벤더 종속 도구 대비 강점 |

### 1.2 약점 (활용성을 깎는 것들)

1. **배포 신뢰**: 서명·공증 없음 → `xattr` 수동 해제. 첫인상에서 탈락하는 사용자 다수 발생 구간.
2. **첫 5분 경험 부재**: 설치 후 "그래서 뭘 하지?"에 답하는 가이드/마법사 없음. 핵심 기능(팀, watch, peer)이 CLI·슬래시 커맨드 지식 없이는 발견 불가.
3. **세션 휘발성**: 앱 재시작 시 에이전트 세션·팀·task board가 사라짐(레이아웃 복원 수준). 장시간 함대 운영의 최대 걸림돌.
4. **관제 뷰의 낮은 해상도**: 대시보드가 리소스/비용 중심. "에이전트가 지금 뭘 하고 있고, 뭘 승인해야 하는가"라는 운영자 질문에 답하는 뷰가 없음.
5. **문서/마케팅 표면 부족**: README는 훌륭하나 docs-site 콘텐츠·데모 영상·비교 페이지 부재. 기능 대비 인지도 격차 큼.
6. **macOS 단일 플랫폼**: 앱은 의도된 선택이지만, *관제 대상*까지 Mac에 갇힐 필요는 없음(§6).
7. **테스트 공백** (`TODO.md` Test Coverage Gaps): 설정·워크스페이스·포커스·팀 오케스트레이션 등 핵심 경로의 회귀 안전망 미비.

---

## 2. 포지셔닝 — 어떤 싸움을 할 것인가

### 2.1 경쟁 구도

| 진영 | 대표 | 그들의 강점 | term-mesh의 응수 |
|------|------|------------|-----------------|
| 에이전트 세션 매니저 | Conductor, Crystal, claude-squad, Sculptor | 간편함, worktree 격리 | 네이티브 성능 + 오케스트레이션 프로토콜 + 관제. "나란히 띄우기"가 아니라 "팀으로 부리기" |
| 클라우드 백그라운드 에이전트 | Claude Code web, Codex cloud, Cursor BG agents, Terragon | 로컬 자원 불필요, 모바일 접근 | 로컬 신뢰(코드가 내 머신을 떠나지 않음) + 멀티 벤더 + peer로 "내 머신들의 클라우드"화 |
| AI 터미널 | Warp, Wave | 세련된 UX, 대중성 | 단일 세션 AI 보조 vs 다중 에이전트 함대 관제라는 다른 카테고리 |
| 전통 강자 | tmux+스크립트, iTerm2, Ghostty 본체 | 무료, 익숙함 | tmux 조합의 DIY 비용 대비 통합 완제품. Ghostty 엔진을 쓰므로 "Ghostty를 버려라"가 아니라 "Ghostty 위의 관제층" |

### 2.2 포지셔닝 선언

> **"AI 에이전트 함대를 위한 macOS 네이티브 관제탑."**
> 에이전트를 *실행*하는 도구는 많다. term-mesh는 에이전트를 **조직하고(team), 감시하고(watch/cost), 통제하고(budget/approve), 어디서든 이어받는다(peer)**.

차별화 문장 세 개 (홈페이지/README 헤드라인 후보):

- "Run agents anywhere. Command them from one place."
- "The terminal that watches your agents — tokens, files, drift, and all."
- "Your Macs, your models, your fleet. No cloud required."

### 2.3 타깃 사용자 우선순위

1. **P0 — 파워 에이전트 운영자**: Claude Code/Codex를 하루 수 시간, 병렬 3+ 세션. 비용에 민감, 자동화 선호. 현재 기능이 정확히 이들을 위한 것 → 초기 전도사층.
2. **P1 — 멀티 머신 개발자**: 데스크톱+랩탑, 홈서버 Mac mini. peer federation의 직접 수혜자.
3. **P2 — 소규모 팀 리드**: 팀원/CI가 돌리는 에이전트의 비용·산출물 가시성 필요. Team 티어(§8)의 구매자.

---

## 3. 전략 축 A — 신뢰와 첫 5분 (활용성의 병목 제거)

가장 저렴하고 가장 수익률 높은 투자. 기능이 아니라 **채택 깔때기**의 문제.

### A-1. 배포 신뢰 체인 완성 (P0)
- Apple Developer ID 서명 + 공증(notarization) → `xattr` 단계 제거, Homebrew cask 단순화.
- Sparkle 업데이트 서명(EdDSA) 점검, 릴리즈 파이프라인에 공증 단계 통합.
- (검토) 오픈소스 무료 배포와 서명 비용의 균형 → §8 수익화와 연동.

### A-2. 첫 실행 온보딩 마법사 (P0)
- 설치된 CLI 자동 감지(claude/codex/kiro/gemini) → CLI 프로파일 자동 생성.
- "Install Claude Code integration" 메뉴(기존 TODO)를 마법사 스텝으로 흡수: 설정 diff 제시 → y 확인.
- 3개 체험 시나리오 버튼: ① 에이전트 1개 + 대시보드 스플릿, ② 3-agent 팀 생성 + `/tm` 데모, ③ 브라우저 스플릿 + 자동화 데모.
- 완료 시 단축키 치트시트 표시 (기존 TODO의 "question mark icon" 통합).

### A-3. 기능 발견성 (P1)
- 커맨드 팔레트(`CommandPaletteOverlay` 기반)에 **모든** 소켓 커맨드·팀 액션 노출 + 각 항목에 대응 CLI 명령 표기 → GUI가 CLI 학습 도구가 되는 구조.
- 사이드바 빈 상태(empty state)에 팀 생성/peer 연결/브라우저 열기 유도 카드.
- 메뉴바에서 `/team-up`, `/watch on` 등 슬래시 커맨드의 GUI 등가물 제공.

### A-4. 문서·데모 표면 (P0~P1)
- docs-site를 실사용 시나리오 중심으로 재편: "5분 안에 3-agent 코드 리뷰", "랩탑에서 데스크톱 함대 조종", "에이전트 예산 통제하기".
- 30–60초 데모 GIF/영상 5개 (팀 fan-out, watch drift 감지, peer 접속, 브라우저 자동화, budget guard 발동).
- 비교 페이지: vs tmux+scripts, vs Conductor/Crystal, vs 클라우드 에이전트 — 정직한 트레이드오프 표.
- README의 tm-agent/tm-op 섹션을 영문 문서로 승격 (현재 CLAUDE.md 한국어에만 존재하는 내용 다수).

### A-5. 품질 안전망 (P1, 지속)
- `TODO.md` Test Coverage Gaps 소거 캠페인: 워크스페이스 라이프사이클 → 포커스 라우팅 → 팀 오케스트레이션 순.
- 성능 기준선 CI화: 렌더링 FPS, 소켓 레이턴시, 데몬 RSS — PRD §7 지표를 자동 측정으로 전환.
- Sentry crash-free rate를 릴리즈 게이트 지표로 채택.

---

## 4. 전략 축 B — 오케스트레이션 심화 (핵심 차별화 강화)

`tm-agent`는 이미 독보적이다. 다음 병목은 **영속성·가시성·회복력**.

### B-1. 세션·팀 영속화와 Resume (P0 — 단일 최대 임팩트 기능)
- 팀 구성, task board, 에이전트별 CLI 세션 ID(`--resume` 가능한)를 데몬이 디스크에 스냅샷.
- 앱/머신 재시작 후 "Restore fleet" 한 번으로: 워크스페이스 레이아웃 + 팀 + 각 pane의 `claude --resume <id>` 재기동 + task board 복원.
- 크래시 복구: 데몬이 orphan 세션 감지 → 사이드바에 "복구 가능" 배지.
- 근거: 에이전트 컨텍스트 라이프사이클 정책(runbook digest + task capsule로 재구성 가능)이 이미 설계되어 있어, 영속화는 그 정책의 자연스러운 완성.

### B-2. Mission Control 뷰 (P0)
운영자 질문 "지금 함대가 뭘 하고 있나"에 답하는 전용 화면 (Cmd+Shift+M):
- 에이전트 × 상태(idle/working/waiting-input/blocked) 매트릭스, task board 칸반, 진행 중 heartbeat 요약.
- 각 셀 클릭 → 해당 pane으로 점프. STATUS/NEXT 헤더 파싱 결과를 구조화 표시.
- watch verdict 히스토리 + drift 알림 타임라인 통합.
- 구현 경로: 기존 WKWebView 대시보드에 탭 추가(데이터는 이미 소켓에 있음) → 빠른 출시 가능.

### B-3. Diff 리뷰·승인 큐 (P0~P1 — "관제"의 완성)
- 워크트리 에이전트가 작업 완료 시: 파일 히트맵이 아니라 **git diff 요약 카드**가 승인 큐에 적재.
- 운영자는 Mission Control에서 diff 확인 → Approve(= `finish-worktree --to parent`) / Reject / "reviewer에게 위임"(`tm-agent delegate reviewer …`) 원클릭.
- Budget Guard와 동일 철학: 에이전트는 자유롭게 일하되, **병합은 사람이 게이트**.
- 차별화 효과: "에이전트 결과물 리뷰"가 제품 안에서 닫힘 → Conductor류와의 결정적 격차.

### B-4. 알림 → 액션 딥링크 (P1)
- "Waiting for input" 알림에서 바로 응답 입력(quick reply) 또는 pane 점프.
- BLOCKED task 알림에 unblock/reassign 버튼.
- macOS 집중 모드 연동: 함대 운영 중 에이전트 알림만 통과.

### B-5. 팀 템플릿·레시피 마켓 (P1~P2)
- 팀 프리셋(이미 존재) + tm-op 전략 + runbook을 하나의 "레시피" 파일로 패키징(`.term-mesh/recipes/*.yaml`).
- 예: "PR 리뷰 삼각편대", "보안 red-team", "릴리즈 준비 파이프라인".
- 저장소에 커밋 가능 → 팀 단위 공유 → 커뮤니티 레시피 갤러리(§7)로 확장.

### B-6. 스케줄러/트리거 (P2)
- 데몬 수준 cron: "매일 09:00 `/tm-op research 'deps 취약점'`", "CI 실패 webhook → executor에게 delegate".
- GitHub webhook 수신(로컬 tunnel 또는 폴링) → PR 이벤트를 task board로.

### B-7. 헤드리스 함대 모드 (P2)
- GUI 없이 term-meshd + tm-agent만으로 팀 운영(이미 부분 지원) → 서버 Mac mini에 상주 함대.
- peer federation으로 이 헤드리스 함대에 GUI를 "나중에 붙이는" 모델 → §6과 결합 시 클라우드 에이전트 진영에 대한 로컬 응수 완성.

---

## 5. 전략 축 C — 관제·거버넌스 심화 (감시자 포지션 독점)

### C-1. 비용 관제 고도화 (P1)
- 멀티 벤더 비용 통합: Claude JSONL 외 Codex/Gemini 사용량 소스 추가(각 CLI 로그 어댑터).
- 예산 정책의 계층화: 글로벌/워크스페이스/팀/에이전트별 일·월 예산, 소진 시 정책 선택(SIGSTOP / 알림만 / 신규 task 차단).
- 비용 귀속(attribution): task_id·팀·프로젝트 단위 비용 리포트 → "이 기능 구현에 $12.40" 카드. 주간 리포트 자동 생성.

### C-2. 감사 로그와 안전 레일 (P1)
- 에이전트가 실행한 소켓 커맨드·파일 변경·브라우저 액션의 append-only 감사 로그(`~/.term-mesh/audit/`).
- 민감 파일 접근 알림: `.env`, `~/.ssh`, 키체인 경로 접근 시 히트맵이 아니라 **즉시 경고 배지**.
- 시크릿 유출 스캔: 에이전트 출력 스트림에서 API 키 패턴 감지 → 마스킹 + 알림 (git-kit push 스캔의 런타임 버전).
- 이 축은 §8 Team 티어의 핵심 판매 포인트(컴플라이언스).

### C-3. 에이전트 행동 리플레이 (P2)
- pane 출력 + task 이벤트 + 파일 이벤트를 시간축으로 정렬한 "무슨 일이 있었나" 타임라인 뷰.
- 실패한 task의 사후 분석(post-mortem)과 watch drift 판정 근거 확인에 사용.
- 스코프 주의: 전체 세션 녹화가 아니라 이벤트 로그 + 기존 결과 파일의 시간축 정렬로 시작 (저비용).

### C-4. 포트/서비스 레이더 (P2)
- 에이전트가 띄운 dev server 포트 자동 감지(기존 `ports_kick` 인프라 활용) → 사이드바 배지 + 원클릭 브라우저 스플릿.
- "에이전트가 만든 것을 즉시 눈으로 확인"하는 루프를 기본 UX로.

---

## 6. 전략 축 D — Peer Federation을 함대 인프라로 (장기 해자)

현재 peer는 "화면 릴레이"다. 이를 **분산 함대의 제어면**으로 승격한다.

### D-1. 안정화 마무리 + Native TCP (P0~P1)
- 최근 5개 릴리즈가 peer 버그픽스 집중 → 안정화 완주(끊김/재접속/IME/붙여넣기 잔여 이슈 소거)가 선행.
- D-3b(Native TCP transport) 완료로 LAN에서 SSH 없이 즉시 연결.
- 신뢰 페어링: 최초 연결 시 지문 확인(TOFU) 또는 코드 6자리 페어링 — SSH 밖 전송의 보안 기반.

### D-2. 원격 팀 제어 (P1 — peer × tm-agent 교차점, **최대 차별화 기회**)
- 릴레이 창에서 원격 호스트의 팀 상태 조회·delegate·collect 실행 (peer 프로토콜에 tm-agent RPC 포워딩 추가).
- 시나리오: 데스크톱에 8-agent 함대 상주 → 랩탑/카페에서 접속해 task 던지고 결과 회수.
- Mission Control(§B-2)에 원격 호스트 섹션 통합 → "모든 머신의 모든 에이전트" 단일 뷰.

### D-3. 웹/모바일 읽기 전용 뷰어 (P2)
- 데몬의 HTTP 대시보드를 확장: 인증 토큰 + read-only 함대 상태 + 알림 스트림.
- Tailscale/SSH 터널 문서화로 "폰에서 함대 확인" 시나리오 개방 (앱 개발 없이 웹으로 시작).
- 승인 큐(§B-3)의 모바일 승인까지 열리면 클라우드 에이전트 진영의 "모바일 접근" 강점을 상쇄.

### D-4. 세션 핸드오프 (P2~P3)
- 뷰어 릴레이를 넘어 소유권 이전: 랩탑에서 시작한 pane을 데스크톱 함대로 "이관"(PTY는 원래 호스트에 있으므로, 워크스페이스 소속과 관제 책임의 이전).
- "출근하면 랩탑 세션이 데스크톱 사이드바에 나타난다"는 마법 모먼트.

---

## 7. 전략 축 E — 생태계·통합 (네트워크 효과)

### E-1. term-mesh MCP 서버 (P0~P1 — 저비용 고효과)
- 기존 소켓 API를 MCP tool로 노출하는 어댑터: 어떤 MCP 클라이언트(Claude Desktop, 타 에이전트)든 term-mesh를 조종 가능.
- "에이전트가 term-mesh를 도구로 사용" → 팀 생성, 브라우저 검증, peer 조회까지 에이전트 자율 루프에 편입.
- 이미 handle 기반 v2 API + 테스트가 있어 어댑터 계층만 필요.

### E-2. CLI 벤더 지원 확대 (P1, 지속)
- OpenCode·Amp 등 신흥 CLI 어댑터 추가 (TODO의 Codex/OpenCode 통합 항목 승격).
- 어댑터 계약 문서화: "새 CLI 지원 = 감지 경로 + 프로파일 + 비용 로그 파서 + IME alias" 체크리스트 → 커뮤니티 기여 가능 구조.

### E-3. 이슈 트래커·협업 도구 연동 (P2)
- GitHub Issues/Linear → task board 가져오기, task 완료 → PR/코멘트 갱신.
- Slack/Discord webhook: BLOCKED·budget 초과·watch drift 알림 전달.

### E-4. 플러그인/확장 API (P2~P3)
- 1단계(저비용): 대시보드 웹뷰에 커스텀 패널 URL 등록 + 소켓 이벤트 구독 SDK(TS/Python).
- 2단계: 사이드바 배지·알림 규칙·팀 레시피의 서드파티 패키지(`plugins/` 디렉토리 활성화).
- 원칙: 앱 코어는 좁게, 확장은 소켓/웹 경계 밖에서 — 네이티브 안정성 보호.

### E-5. 오픈소스 성장 운영 (P1, 지속)
- good-first-issue 큐레이션(테스트 공백·CLI 어댑터가 적합), CONTRIBUTING에 e2e 실행 가이드 보강.
- 월간 릴리즈 노트 블로그화(이미 한국어 CHANGELOG 품질 높음 → 영문 병행).
- "번역 README 15개"라는 기존 자산을 살려 비영어권 커뮤니티(한국·일본·중국 AI 코딩 커뮤니티) 우선 공략.

---

## 8. 전략 축 F — 지속가능성 (수익화 옵션)

AGPL-3.0 기반을 유지하면서 가능한 경로. 결정은 후행해도 되지만 설계는 선행해야 한다.

| 옵션 | 내용 | 시점 |
|------|------|------|
| **Sponsor/Donation** | GitHub Sponsors + 앱 내 후원 링크. 서명 인증서 비용 충당 | Now |
| **Pro (개인 유료)** | 원격 함대 제어(§D-2), 모바일 승인(§D-3), 고급 비용 리포트(§C-1)를 유료 기능으로. 코어는 영원히 무료 | Next~Later |
| **Team 서버** | 팀 공유 감사 로그·예산 정책·레시피 저장소를 제공하는 self-hosted 데몬 확장. AGPL 듀얼 라이선스 판매 | Later |
| **지원 계약** | 에이전트 운영 컨설팅 + 우선 지원 | Later |

원칙: **로컬 우선·프라이버시가 정체성**이므로 SaaS 전환은 하지 않는다. 유료화는 "여러 머신·여러 사람" 경계에서만.

---

## 9. 실행 로드맵

### Phase 1 — "Trust & First Five Minutes" (0–2개월)
- [ ] 코드서명 + 공증 + 릴리즈 파이프라인 통합 (A-1)
- [ ] 첫 실행 온보딩 마법사 + CLI 통합 설치 (A-2)
- [ ] docs-site 시나리오 재편 + 데모 GIF 5종 + 영문 tm-agent 문서 (A-4)
- [ ] peer 안정화 완주 + Native TCP(D-3b) (D-1)
- [ ] term-mesh MCP 서버 v1 (E-1)
- [ ] 테스트 공백 캠페인 1차: 워크스페이스·포커스 (A-5)

### Phase 2 — "Fleet Operations" (2–5개월)
- [ ] 세션·팀 영속화 + Restore Fleet (B-1)
- [ ] Mission Control 뷰 v1 (B-2)
- [ ] Diff 리뷰·승인 큐 v1 (B-3)
- [ ] 알림 quick-reply/딥링크 (B-4)
- [ ] 비용 정책 계층화 + task 귀속 리포트 (C-1)
- [ ] 감사 로그 + 민감 경로 경고 (C-2)
- [ ] Codex/OpenCode 비용 어댑터 (E-2)

### Phase 3 — "Distributed Fleet & Ecosystem" (5–12개월)
- [ ] 원격 팀 제어 (peer × tm-agent) (D-2)
- [ ] 웹 read-only 뷰어 + 모바일 승인 (D-3)
- [ ] 팀 레시피 패키징 + 갤러리 (B-5)
- [ ] 스케줄러/트리거 + GitHub/Linear 연동 (B-6, E-3)
- [ ] 플러그인 API 1단계 (E-4)
- [ ] Pro 티어 실험 (F)

### 항시 트랙
- 성능 기준선 CI + crash-free 게이트 (A-5)
- peer/오케스트레이션 dogfooding: term-mesh 개발 자체를 term-mesh 함대로 수행하고 그 기록을 콘텐츠화

---

## 10. 성공 지표 (KPI)

| 축 | 지표 | 6개월 목표(안) |
|----|------|---------------|
| 채택 | 설치 → 첫 팀 생성 전환율 | ≥ 25% |
| 채택 | DAU (PostHog `term-mesh_daily_active`) | 4× 성장 |
| 활용 깊이 | 동시 3+ 에이전트 세션 사용자 비율 | ≥ 40% |
| 활용 깊이 | 주간 tm-agent delegate 실행 수 / 활성 사용자 | 상승 추세 확인 |
| 차별 기능 | peer 연결 사용 설치 비율 | ≥ 10% |
| 차별 기능 | 승인 큐 통과 diff 수 (출시 후) | 신규 계측 |
| 신뢰 | crash-free session rate | ≥ 99.5% |
| 커뮤니티 | 외부 기여 PR / 분기 | ≥ 10 |

---

## 11. 리스크와 완화

| 리스크 | 완화 |
|--------|------|
| CLI 벤더(Anthropic 등)가 공식 멀티세션 GUI를 출시 | 멀티 벤더 + 로컬 관제 + peer라는 벤더 중립 지형 선점. 단일 벤더 GUI는 자사 CLI만 관제 |
| ghostty upstream 추적 비용 | fork 동기화 절차 이미 문서화(`docs/ghostty-fork.md`). upstream 기여로 patch 부담 축소 |
| 기능 폭 대비 1인 유지보수 한계 | Phase 게이트 엄수, 테스트 공백 우선 소거, 플러그인 경계로 코어 표면 동결 |
| peer 보안 사고(원격 입력 경로) | TOFU 페어링, 기본 read-only, 원격 팀 제어는 명시적 권한 단계 도입 후 출시 |
| AGPL이 기업 채택 저해 | Team 듀얼 라이선스 옵션 설계(F). 코어 사용은 앱 실행이므로 실질 제약 낮음을 FAQ로 명시 |
| 관제 기능(감사/예산)이 UX를 무겁게 만듦 | 모든 거버넌스 기능은 opt-in, 기본값은 "빠른 터미널" |

---

## 12. 결정 요청 (다음 액션)

1. Phase 1 항목 중 **서명/공증**과 **온보딩 마법사**의 착수 승인 (외부 비용: Apple Developer Program).
2. §B-1 세션 영속화의 설계 스파이크(1주) 승인 — resume 가능 범위(CLI별 `--resume` 지원 편차) 검증 선행.
3. 수익화(§8)는 Phase 2 말 재논의로 보류하되, Pro 후보 기능(D-2, D-3, C-1 리포트)의 코드 경계를 지금부터 분리 유지할지 결정.
