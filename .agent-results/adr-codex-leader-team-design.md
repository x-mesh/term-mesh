# ADR: Codex 리더 팀 에이전트 활용 설계 — 비대칭 완화

**Status:** PROPOSED  
**Date:** 2026-05-20  
**Scope:** Agent context (AGENTS.md / CLAUDE.md), Codex prompt shims (.codex/prompts), leader adoption flow

---

## Context

### 문제 1: 리더 컨텍스트 비대칭

**Claude 리더가 받는 지침:**
- CLAUDE.md: 프로젝트 레벨 system prompt
  - "DELEGATE-FIRST PRINCIPLE" 명시
  - Agent Trigger Routing 테이블 (특정 작업 → 특정 에이전트 위임 규칙)
  - no-commit 정책, focus policy, threading policy
  - `/team`, `/tm`, `/tm-op` 커맨드 상세 설명
- `.claude/commands/team.md`: 슬래시 커맨드 구현 (강제 실행)
- `.claude/commands/tm.md`: delegation 패턴 상세 (decompose, --ensure, etc.)
- 결과: Claude 리더는 "언제 누구에게 위임하는지" 명확함

**Codex 리더가 받는 지침:**
- AGENTS.md: 프로젝트 일반 notes (모든 agent 대상)
  - Team agent system 섹션 있음 (tm-agent 사용 강제)
  - `.codex/prompts` 참조 언급
  - 그 이상: Codex-specific 위임 프로토콜 없음
- `.codex/prompts/team.md`: 프롬프트 shim (IME alias로 확장)
- `.codex/prompts/tm.md`: delegation 프롬프트 (IME alias로 확장)
- 결과: **Codex 리더가 "언제 누구에게 위임하는지" 배울 곳이 없음**
  - AGENTS.md는 team lifecycle만 다룸
  - delegation protocol (위임 시점, 역할 선택, --ensure, decompose) 미명시
  - Agent Trigger Routing 테이블 없음 (Claude만 있음)

### 문제 2: IME alias 확장 의존의 취약점

**Current flow (Codex leader 기준):**
1. 사용자가 IME box에 `/tm "review this PR"` 입력
2. IME alias가 expand → "read `.codex/prompts/tm.md` and execute with ARGUMENTS='review this PR'"
3. Codex가 프롬프트를 읽고 tm-agent delegate 실행

**취약점:**
- IME alias 메커니즘이 정상 작동해야만 Codex가 위임 프로토콜을 수행
- 만약 alias가:
  - 설정 누락 (새로운 Codex pane에 alias 미전파)
  - 구문 오류 (IME 입력 파싱 실패)
  - 프롬프트 수정 불가 (`.codex/prompts` 읽음 실패)
- → Codex는 "일반 메시지"로 해석, 선택적 처리 가능 (무시, 약식, 재해석)

**비교: Claude는 강제**
- `/tm "..."` → `.claude/commands/tm.md` 슬래시 커맨드 강제 호출
- alias 없이도 동작 (slash command 자체가 execution mechanism)
- 프롬프트 미설정이어도 실패, 우회 불가

### 문제 3: Agent context 설계 자체 불일치

**현재:**
- AGENTS.md: "이것은 generic agent context이고, Codex leader도 읽는다"
- CLAUDE.md: "이것은 Claude-specific 규칙"
- 하지만 **AGENTS.md에는 Codex-specific 지침이 없음**
  - Team agent system 섹션이 "both should use tm-agent"라고 했지만
  - Codex 리더의 구체적 위임 프로토콜 (DELEGATE-FIRST 언제 쓸지, trigger routing, --ensure언제 쓸지)은 누락

---

## Decision

### 선택 옵션: 계층 재설계 + IME 보강 + onboarding flow

**3계층 + Codex adoption flow:**

| 계층 | 책임 | 내용 |
|------|------|------|
| **L1: _common.md + AGENTS.md (Universal)** | 모든 leader (Claude/Codex)가 준수할 규칙 | P0 no-commit, P0 reply 강제, team override (tm-agent 필수) |
| **L2a: CLAUDE.md (Claude leader)** | Claude-specific 위임 및 설정 | DELEGATE-FIRST, trigger routing table, `/team`/`/tm`/`/tm-op` 커맨드, decompose 패턴 |
| **L2b: AGENTS.md-codex section (NEW, Codex leader)** | Codex-specific 위임 프로토콜 | IME alias 의존성, `/team`/`/tm`/`/tm-op` 프롬프트 flow, 프롬프트 재시작 안내 |
| **L3: adoption onboarding (NEW)** | Codex 리더 도입 시 가이드 생성 | README, cheat-sheet, alias 검증 |

### L1 확장: AGENTS.md Universal 섹션 (모든 leader)

**기존 Team agent system 섹션 직후에 추가:**

```markdown
## Universal Team Operations Protocol (All Leaders)

Claude 또는 Codex leader 모두가 따르는 에이전트 위임 규칙.

### 1. DELEGATE-FIRST Principle

특정 작업은 leader가 직접 처리하지 말고, **해당 에이전트에 위임**한다:

| 작업 신호 | → 에이전트 | 이유 |
|----------|-----------|------|
| "X is defined where", "find all callers of Y" | explorer | 심볼 탐색 전문 |
| UI/SwiftUI/AppKit 컴포넌트 경계 변경 | frontend | 컴포넌트 설계 |
| daemon/, JSON-RPC schema 변경 | backend | Rust 프로토콜 |
| 신규 IPC 설계, module boundary | architect | 구조 결정 (ADR 필요) |
| security-critical input parsing, auth | security | 취약점 탐지 의무 |
| [이 표는 CLAUDE.md Agent Trigger Routing과 동일] | | |

### 2. Delegation Protocol (both Claude & Codex)

#### 2a. Team composition: `tm-agent create N --adopt`
- N = idle agent 수 (보통 3–6)
- `--adopt`: 현재 pane을 leader로 입양

#### 2b. One-shot fan-out: `/tm "instruction"`
- 모든 idle agent에 동시 위임
- `--ensure <roles>`: 없는 role 자동 추가
- `--decompose`: 이종 sub-task 분배 (opt-in)
- 대기: `tm-agent wait --timeout 300 --mode report`

#### 2c. Lifecycle: 항상 `tm-agent reply`로 종료
- 모든 agent task는 `tm-agent reply` 호출로만 종료
- Standard Header 5필드 의무 (STATUS / FILES / VERIFY / NEXT / FULL_REPORT)
- leader는 이 signal을 감지해야만 task 완료를 알 수 있음
```

### L2a: CLAUDE.md (기존 유지)

- DELEGATE-FIRST, Agent Trigger Routing 테이블: 유지 (이미 상세)
- no-commit P0, focus/threading policy: 유지

### L2b (NEW): AGENTS.md에 "## Codex Leader Protocol" 섹션 추가

```markdown
## Codex Leader Protocol

Codex leader가 term-mesh 팀을 운영할 때의 구체적 지침.

### 1. 프롬프트 shim 의존성

- IME alias가 구조적 메커니즘 (Claude의 slash command 같은 위치)
- `/team`, `/tm`, `/tm-op` 입력 → `.codex/prompts/*.md` 읽음 → 실행
- **alias 실패 시 fallback:** IME alias 안 되면 직접 `tm-agent` 명령으로:
  ```bash
  tm-agent add reviewer
  tm-agent delegate executor "instruction"
  ```

### 2. Delegation Heuristics (CLAUDE.md Agent Trigger Routing과 동일)

Codex leader도 AGENTS.md "Universal Team Operations Protocol" 섹션의 **2. Delegation Protocol** 규칙과
trigger routing을 따른다. 차이는 "**delivery mechanism**"만:
- Claude: `/tm "<instruction>"` 슬래시 커맨드
- Codex: `/tm "<instruction>"` IME alias → `.codex/prompts/tm.md` → tm-agent

### 3. `/tm` Decompose Mode (Codex specific)

`.codex/prompts/tm.md`의 `--decompose` 옵션:
- `--decompose` 없음 (기본): 동일 instruction 모든 agent에 fan-out
- `--decompose` 명시: 이종 sub-task 분해 (매칭되면), 아니면 fallback

Codex leader는 `/tm --ensure reviewer,security "..."` 처럼 사용.

### 4. IME alias 재시작 (필요 시)

만약 `tm-agent` 명령이 작동하지 않으면:
1. `tm-agent status` 확인 (팀 존재 여부)
2. alias expansion 확인: IME box에 `/team` 입력 → 도움말 출력 확인
3. 프롬프트 문제: `.codex/prompts/{team,tm,tm-op}.md` 가독성 확인
4. 직접 실행: `tm-agent delegate executor "instruction"`

### 5. Codex Leader Adoption Checklist

새로운 Codex leader pane을 adopt할 때:
- [ ] AGENTS.md "Universal Team Operations Protocol" 읽음
- [ ] AGENTS.md "Codex Leader Protocol" 읽음 (이 섹션)
- [ ] IME alias 테스트: `/team status` 입력 → "자주 쓰는 명령" 출력 확인
- [ ] 팀 생성: `tm-agent create 3 --adopt`
- [ ] delegation 테스트: `/tm "review src/auth.ts"`
```

### L3 (NEW): Codex adoption onboarding

**파일: `.agent-results/codex-leader-onboarding.md` (생성 및 배포)**

```markdown
# Codex Leader Onboarding — term-mesh Team Adoption

이 가이드는 새로운 Codex leader pane이 term-mesh 팀을 처음 운영할 때의 단계별 안내입니다.

## Step 1: Codex leader context 읽기

AGENTS.md의 다음 섹션을 순서대로 읽으세요:

1. "Team agent system (OMC override)" — why tm-agent
2. "Universal Team Operations Protocol" — when/how to delegate
3. "Codex Leader Protocol" — Codex-specific mechanism

시간: ~5분

## Step 2: 팀 생성

```bash
tm-agent create 3 --adopt
```

- 3 = idle agent 수 (추천)
- --adopt: 현재 Codex pane을 leader로 입양

확인: `tm-agent status` → 4줄 테이블 (leader + 3 agents)

## Step 3: IME alias 검증

IME box에 다음을 입력하세요:

```
/team status
```

예상 출력: "자주 쓰는 명령" 도움말 + 팀 테이블

만약 alias 전개가 안 되면:
- IME 드라이버 재시작 또는
- 직접 실행: `tm-agent status`

## Step 4: Delegation 테스트

```bash
/tm "review the error handling in src/socket.rs"
```

또는 직접:

```bash
tm-agent delegate reviewer "review the error handling in src/socket.rs"
tm-agent wait --timeout 60 --mode any
tm-agent read reviewer --lines 50
```

결과: reviewer agent의 코드 리뷰 피드백

## Step 5: Codex leader로서 주의사항

### Delegation Protocol (Must-Follow)
- `tm-agent reply`로 모든 task 종료 (leader가 이를 감지해야 함)
- `tm-agent wait` 반드시 사용 (sleep + poll 금지)
- `tm-agent broadcast` = 모든 agent에 메시지 (duplicates 포함)

### IME alias 의존성 (Know the Limits)
- alias 실패 시 직접 `tm-agent` 명령으로 fallback
- `.codex/prompts/*.md` 프롬프트가 핵심 (수정하거나 삭제하지 말 것)
- 새로운 `/team` alias가 추가되면 IME 재시작 필요할 수 있음

## Step 6: Troubleshooting

| 증상 | 진단 | 해결 |
|------|------|------|
| `/tm` 입력 후 아무것도 안 됨 | IME alias expand 실패 | `tm-agent status` 직접 실행 |
| `/team add reviewer` 후 agent 미추가 | 명령 미실행 (alias 미전개) | IME 드라이버 재시작 또는 `tm-agent add reviewer` 직접 실행 |
| `tm-agent delegate` 후 agent 응답 안 함 | agent 과부하 또는 task 미할당 | `tm-agent task list` 확인 |
| 프롬프트 error (`.codex/prompts` 파일 손상) | git status 확인 | 손상된 파일 복구 또는 지원 요청 |

---

## Claude Leader와의 차이

| 항목 | Claude | Codex |
|------|--------|-------|
| 위임 메커니즘 | `/tm` 슬래시 커맨드 (강제) | `/tm` IME alias (조건부) |
| 프롬프트 소스 | `.claude/commands/tm.md` | `.codex/prompts/tm.md` |
| 실패 시 fallback | 없음 (slash 자체가 enforcement) | 직접 `tm-agent` 명령 |
| Trigger routing 테이블 | CLAUDE.md + AGENTS.md | AGENTS.md Universal section |
```

### L3 배포: adoption flow

Codex pane이 leader로 adopted될 때:
- `tm-agent adopt --cli codex` 실행 시 자동으로 onboarding 가이드 print/email
- 또는 `.agent-results/codex-leader-onboarding.md` 자동 생성 + readme link

---

## Consequences

### Immediate (즉효, 1주)

1. **AGENTS.md 확장** (~2시간)
   - "Universal Team Operations Protocol" 섹션 추가 (trigger routing table 포함)
   - "Codex Leader Protocol" 섹션 추가 (4-5 subsections)
   - Codex adoption checklist 추가

2. **onboarding guide 생성** (~1시간)
   - `.agent-results/codex-leader-onboarding.md` (위 Step 1-6 내용)
   - `tm-agent adopt --cli codex` 시 자동 배포 또는 수동 링크

3. **검증** (~30분)
   - Codex pane 새로 생성 → AGENTS.md 읽기 → 팀 create → delegation 테스트
   - onboarding guide 완독 → 실행 가능성 확인

### Durability (영구, 2주)

4. **CI 회귀 검증** (~30분)
   - AGENTS.md Codex Leader Protocol 섹션 존재 여부 체크
   - `.codex/prompts/{team,tm,tm-op}.md` 기본 구조 intact 여부

5. **IME alias 자동 검증** (~1시간, optional)
   - `tm-agent adopt` 시 alias expand test 자동 실행
   - 실패 시 warning + fallback 가이드 print

6. **Documentation** (~1시간)
   - CLAUDE.md에 "Codex와의 비교" 섹션 추가 (context 이해용)
   - 또는 onboarding guide를 README에 링크

---

## Backwards Compatibility

✅ 기존 Claude leader 동작 변경 없음
✅ 기존 Codex leader 동작 변경 없음 (AGENTS.md 추가만)
✅ IME alias 메커니즘 유지 (취약점은 "recognize + fallback" 패턴으로 완화)
✅ `.codex/prompts/*` 파일 구조 유지

---

## Rationale

### 왜 L2a (Claude) / L2b (Codex) 분리가 필요한가?

- **Claude는 slash command 기반** → 강제 실행 → 확인 가능
- **Codex는 IME alias 기반** → 선택적 처리 → 확인 어려움
- 같은 프로토콜이지만 전달 메커니즘이 다름
- Codex 리더가 "내가 지금 trigger routing 규칙을 쓸 수 있는가?"를 판단할 수 있어야 함

### 왜 Universal section이 필요한가?

- Claude/Codex 모두 "**언제** 누구에게 위임하는가?"는 동일
- 차이는 "**어떻게** 위임하는가?" (mechanism)
- trigger routing table을 AGENTS.md에 놓으면 DRY (Codex가 CLAUDE.md 못 읽더라도 규칙 학습 가능)

### 왜 onboarding guide인가?

- 새로운 Codex pane이 leader adopt 시 "이제 뭘 해야 하는가?"를 빠르게 배우도록
- IME alias 검증 포함 (alias 실패 시 직접 명령이라는 fallback 이해)
- "우리는 Claude와 다른 방식이지만, 규칙은 같다"는 맥락 제공

---

## Summary

| 항목 | 결정 |
|------|------|
| **계층 설계** | L1 (Universal) + L2a (Claude) + L2b (Codex) + L3 (onboarding) |
| **비대칭 원인** | Claude: CLAUDE.md system prompt, Codex: AGENTS.md만 (제한적) |
| **IME alias 취약점** | alias 실패 시 fallback = 직접 tm-agent 명령 |
| **즉효** | AGENTS.md 확장 + onboarding guide (~3시간) |
| **영구** | CI 검증 + 문서 링크 (~2시간) |
| **호환성** | ✅ 기존 모든 flow 유지, 추가만 |

**결과:**
- Codex 리더도 Claude와 동일한 위임 규칙을 배울 수 있음
- IME alias 의존성을 "인식"하고 fallback 가능
- "Codex leader adoption" 첫 steps 명확함
