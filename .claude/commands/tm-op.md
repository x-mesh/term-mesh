# tm-op — 전략 오케스트레이션 커맨드

에이전트 팀에게 구조화된 전략(발산·수렴·경쟁·파이프라인·리뷰·토론·공격방어·브레인스토밍)을 지시한다.
리더 Claude(너)가 오케스트레이터 겸 LLM 합성 역할을 수행하며, tm-agent 프리미티브로 에이전트를 제어한다.

## Arguments

User provided: $ARGUMENTS

## Routing

Parse `$ARGUMENTS`의 첫 단어로 전략을 결정한다:
- `list` → [Subcommand: list] 섹션 실행
- `refine` → [Strategy: refine] 섹션 실행
- `tournament` → [Strategy: tournament] 섹션 실행
- `chain` → [Strategy: chain] 섹션 실행
- `review` → [Strategy: review] 섹션 실행
- `debate` → [Strategy: debate] 섹션 실행
- `red-team` → [Strategy: red-team] 섹션 실행
- `brainstorm` → [Strategy: brainstorm] 섹션 실행
- `distribute` → [Strategy: distribute] 섹션 실행
- `council` → [Strategy: council] 섹션 실행
- 빈 입력 → 사용자에게 전략 선택 질문

## Options

`$ARGUMENTS`에서 다음 옵션을 파싱한다:
- `--rounds N` — refine 라운드 수 (기본 4)
- `--preset quick|thorough|deep` — 프리셋 (quick: rounds=2/timeout=60, thorough: rounds=4/timeout=120, deep: rounds=6/timeout=180)
- `--steps "agent:task,agent:task"` — chain 단계 수동 지정
- `--target <file|dir>` — review 대상 파일
- `--pr <number>` — review 대상 PR
- `--judge <agent>` — tournament 심판 에이전트
- `--timeout N` — base_timeout 초 (기본 120). 실제 wait 타임아웃은 Shared Setup의 Timeout Floor 규칙에 따라 자동 조정됨
- `--pro "agent,agent"` — debate 찬성팀 수동 지정
- `--con "agent,agent"` — debate 반대팀 수동 지정
- `--attackers "agent,agent"` — red-team 공격팀 수동 지정
- `--defenders "agent,agent"` — red-team 방어팀 수동 지정
- `--vote` — brainstorm에서 도트 투표 활성화
- `--splits "agent:task,agent:task"` — distribute 분할 수동 지정
- `--no-merge` — distribute 결과 병합 비활성화
- `--conflict-check` — distribute 파일 충돌 검사 (기본 활성)
- `--agenda "item1,item2,item3"` — council 다중 안건 지정
- `--context` — 대화 맥락을 강제로 에이전트에게 주입 (자동 판단 무시)
- `--no-context` — 대화 맥락 주입을 강제로 비활성화 (자동 판단 무시)

## Shared Setup

모든 전략 실행 전에 반드시 수행:

1. 팀 상태 확인:
```bash
tm-agent status
```

2. idle 에이전트 목록을 파악한다. working/blocked 에이전트는 제외한다.

3. 전략별 최소 에이전트 수를 확인한다:
   - chain, review, brainstorm: 최소 1명
   - refine, tournament, red-team, distribute, council: 최소 2명 (council은 3명 이상 권장)
   - debate: 최소 3명 (PRO 1+, CON 1+, JUDGE 1+)
   미달이면 경고를 출력하고 사용자에게 계속 진행할지 확인한다.
   tournament에서 에이전트가 1명뿐이면 "경쟁 불가 — chain 전략을 권장합니다" 안내.

4. 참여할 에이전트 이름 목록을 기억한다 (이후 모든 라운드에서 사용).

5. **Timeout Floor** — `--timeout` (또는 preset의 timeout)을 `base_timeout`이라 한다. 실제 `wait` 타임아웃은 아래 규칙에 따라 자동 조정한다:

   | 상황 | 실제 timeout |
   |------|-------------|
   | fan-out / delegate (기본) | `base_timeout` |
   | broadcast → wait (전원 응답 필요) | `max(base_timeout * 1.5, 90)` |
   | red-team attack / defend | `max(base_timeout, 90)` (코드 분석 필요) |
   | council cross-examine | `max(base_timeout, 90)` (다른 에이전트 입장 읽기 필요) |
   | chain 전체 | `단계수 * base_timeout` (단계별은 `base_timeout`) |

   예: `--preset quick` (base_timeout=60) → red-team attack wait = 90초, broadcast wait = 90초.

6. **자율 실행 모드 (Autonomous Mode)** — 에이전트가 파일을 직접 수정해야 하는 전략에서는 `tm-agent delegate --autonomous`를 사용한다. 이 모드는 임시 `claude -p` 서브프로세스를 spawn하여 리더 승인 없이 파일 편집이 가능하다.

   **호출 규칙**:
   - autonomous delegate는 반드시 **background로 실행**한다: `tm-agent delegate <agent> '...' --autonomous &`
   - `tm-agent`는 claude 서브프로세스 완료까지 대기하며 task를 자동 완료한다 (thread join).
   - 결과 파일: `~/.term-mesh/results/<team>/<task_id>.md` 및 `<agent>-reply.md`에 자동 기록된다.
   - 병렬 실행 시 여러 `&` 명령을 동시에 실행하고, `tm-agent task list`로 completion을 폴링한다.

   **자율 실행이 필요한 경우** (파일 수정):
   - `distribute`: 모든 에이전트 → `--autonomous`
   - `chain`: executor, backend, frontend 역할 에이전트 → `--autonomous`
   - `red-team`: defenders (수정안 구현) → `--autonomous`

   **감독 실행이 충분한 경우** (읽기/분석):
   - `refine`, `tournament`, `brainstorm`, `council`: 모든 에이전트 → 기본 모드
   - `review`, `red-team` attackers: 모든 에이전트 → 기본 모드
   - `chain`: explorer, reviewer, architect 역할 → 기본 모드

## Context Injection

모든 전략 실행 전, 에이전트에게 사전 맥락을 주입할지 결정한다.

### 결정 우선순위
1. `--no-context` 옵션 → **주입하지 않는다** (자동 판단 무시)
2. `--context` 옵션 → **반드시 주입한다** (자동 판단 무시)
3. 옵션 없음 → 아래 자동 판단 기준에 따라 결정

### 자동 판단 기준 (하나라도 해당하면 주입)
- 사용자가 이전 시도의 실패를 언급했다
- 대화에 에러 메시지, 빌드 실패, 스택 트레이스가 있었다
- 이전 tm-op 전략의 결과가 있다

### 자동 판단 결과 안내
옵션이 명시되지 않았을 때, 자동 판단 결과를 사용자에게 알린다:
- 주입 시: `📋 Context detected — 이전 대화 맥락을 에이전트에게 전달합니다. (--no-context로 비활성화 가능)`
- 미주입 시: `💡 No prior context detected. (--context로 강제 주입 가능)`

### 컨텍스트 작성 규칙
1. 3000자 이내
2. 구조: `## What was tried` → `## What failed` → `## Error details` → `## Constraints`
3. 에러 메시지는 핵심 부분만 발췌 (전체 스택 트레이스 금지)
4. 관련 없는 대화 내용은 제외

### 주입 방법
`tm-agent delegate`/`tm-agent fan-out` 호출 시 `--context` 플래그를 추가한다:

```bash
tm-agent fan-out '<instruction>' --context '## What was tried
- Approach A: XYZ — failed due to ABC
## Error details
Error: specific error message
## Constraints
- Must maintain backward compat'
```

주입하지 않을 때는 `--context` 플래그를 생략한다 (기존 동작 유지).

## Error Handling

**모든** `tm-agent` Bash 호출 후:
- exit code ≠ 0 **또는** JSON 응답에 `"ok": false` 포함 → STOP하고 에러를 사용자에게 보고
- `tm-agent collect` 결과가 빈 배열(응답 에이전트 0명) → 전략 중단, 사용자에게 보고
- 에이전트가 타임아웃 내에 응답하지 않으면 해당 에이전트를 제외하고 나머지로 계속 진행
- 전원 미응답 시 전략을 중단하고 수집된 부분 결과를 출력
- refine/tournament에서 투표 라운드 결과가 빈 경우 → 이전 라운드 결과로 best-effort 채택

에이전트에게 보내는 **모든** 메시지 끝에 다음을 추가:
`[IMPORTANT] When done, run: tm-agent reply '<your result>' to report.`

## Result Collection

각 `fan-out`/`delegate` 실행 시 반환되는 **task ID를 반드시 기록**한다.

결과 수집 우선순위:
1. **Task ID 파일** (가장 신뢰적 — 태스크별 유니크, 이전 전략에 오염되지 않음):
```bash
cat ~/.term-mesh/results/my-team/<task_id>.md
```
2. **Agent reply 파일** (task ID 파일이 비어있을 때 fallback):
```bash
cat ~/.term-mesh/results/my-team/<agent>-reply.md
```
3. **tm-agent collect** (요약 수집 — 잘릴 수 있음, 위 파일로 보완)

---

## Subcommand: list

사용 가능한 전략과 서브커맨드 목록을 출력한다. 아래 표를 **그대로** 사용자에게 출력하라:

```
tm-op — 전략 오케스트레이션 커맨드

서브커맨드:
  list                    사용 가능한 전략/서브커맨드 목록 출력

전략 (Strategies):
  refine <topic>          발산→수렴→검증 라운드 기반 정제. 전원 독립 답변 후 종합·투표·검증 반복
  tournament <topic>      전원 동시 경쟁 후 익명 투표로 최고 결과 채택
  chain <topic>           A→B→C 순차 파이프라인. 이전 단계 결과가 다음 입력
  review <--target file>  버그·보안·성능 관점 자동 배정 후 이슈 종합·심각도 정렬 리포트
  debate <topic>          찬반 토론 후 판정. 설계 트레이드오프 분석에 적합
  red-team <--target f>   공격팀이 결함 발견→방어팀이 수정. 보안·견고성 강화
  brainstorm <topic>      수렴 없이 아이디어 발산→분류→투표
  distribute <topic>      대규모 태스크를 독립 서브태스크로 분할하여 병렬 실행·병합
  council <topic>         N명 자유 토의 → 교차 질의 → 심화 → 합의 도출. 다자간 숙의 회의

옵션 (Options):
  --rounds N              refine 라운드 수 (기본 4)
  --preset <p>            quick | thorough | deep
  --steps "a:t,b:t"       chain 단계 수동 지정
  --splits "a:t,b:t"      distribute 분할 수동 지정
  --target <file|dir>     review/red-team 대상
  --pr <number>           review 대상 PR
  --judge <agent>         tournament 심판 에이전트
  --timeout N             라운드별 타임아웃 초 (기본 120)
  --pro "a,b"             debate 찬성팀
  --con "a,b"             debate 반대팀
  --attackers "a,b"       red-team 공격팀
  --defenders "a,b"       red-team 방어팀
  --vote                  brainstorm 도트 투표 활성화
  --no-merge              distribute 결과 병합 비활성화
  --conflict-check        distribute 파일 충돌 검사 (기본 활성)
  --agenda "a,b,c"        council 다중 안건
  --context               대화 맥락을 강제로 에이전트에게 주입
  --no-context            대화 맥락 주입을 강제로 비활성화

예시:
  /tm-op refine "결제 API 설계" --rounds 4
  /tm-op tournament "로그인 구현"
  /tm-op chain "보안 점검" --steps "explorer:분석,security:식별,reviewer:종합"
  /tm-op review --target src/pay.ts
  /tm-op debate "모놀리스 vs 마이크로서비스"
  /tm-op red-team --target src/auth.ts
  /tm-op brainstorm "v2 기능 아이디어" --vote
  /tm-op distribute "6개 Sentry 이슈 분석" --splits "explorer:MESH-1,security:MESH-2,executor:MESH-3"
  /tm-op council "ECS vs K8s 마이그레이션" --rounds 4
  /tm-op council "스프린트 계획" --agenda "API 설계,인증 방식,배포 전략"
```

출력 후 즉시 종료. 전략을 실행하지 않는다.

---

## Strategy: refine

발산→수렴→검증 라운드 기반 정제.

### Round 1: DIVERGE (발산)

사용자에게 진행 상황을 알린다:
> 🔄 [refine] Round 1/{max_rounds}: Diverge — 전원 독립 해결책 생성

```bash
tm-agent fan-out '<TASK>. 이 태스크에 대해 독립적으로 해결책을 제시하라. 400단어 이내. 다른 에이전트의 답변을 고려하지 말고 자기만의 접근법을 제안해라. [IMPORTANT] When done, run: tm-agent reply "<your solution>" to report.'
```

태스크 텍스트는 사용자가 입력한 원본 그대로 전달한다.

```bash
tm-agent wait --timeout {timeout} --mode report
```

전원 결과를 수집한다:
```bash
tm-agent collect --lines 100
```

잘린 결과가 있으면 개별 reply 파일을 읽는다.

### Round 2: CONVERGE (수렴)

> 🔄 [refine] Round 2/{max_rounds}: Converge — 결과 종합 및 투표

너(Claude, 리더)가 직접 전원 결과를 읽고 종합한다:
- 공통점과 차이점을 파악
- 각 해결책의 강점을 추출
- 종합 해결책을 작성

종합 결과를 에이전트에게 공유하고 투표를 요청:
```bash
tm-agent broadcast '## 전원 결과 종합

{여기에 너가 작성한 종합 결과를 넣는다}

위 종합 결과를 검토하고:
1. 가장 좋은 접근법 번호를 선택
2. 선택 이유를 2-3줄로 설명
3. 추가 개선 제안이 있으면 포함

[IMPORTANT] When done, run: tm-agent reply "<your vote and reasoning>" to report.'
```

```bash
tm-agent wait --timeout {timeout} --mode report
tm-agent collect --lines 100
```

너(Claude)가 투표를 집계한다:
- 각 접근법별 득표 수 계산
- 가장 많은 지지를 받은 안을 채택
- 동점 시 너(Claude)가 tiebreaker로 판단

채택안을 정리한다.

### Round 3+: VERIFY (검증)

> 🔄 [refine] Round {n}/{max_rounds}: Verify — 채택안 검증

```bash
tm-agent broadcast '## 채택안 검증

{채택된 해결책 전문}

위 채택안을 자신의 전문 분야 관점에서 검증하라:
- 문제가 있으면: 구체적으로 지적하고 수정안 제시
- 문제가 없으면: "OK" 라고만 답변

[IMPORTANT] When done, run: tm-agent reply "<your feedback>" to report.'
```

```bash
tm-agent wait --timeout {timeout} --mode report
tm-agent collect --lines 100
```

결과를 분석:
- **전원 OK** → DONE (조기 종료)
- **지적 있음** → 너(Claude)가 지적을 반영하여 채택안 수정 → 다음 검증 라운드
- **max_rounds 도달** → best-effort로 현재 채택안 출력 + 미해결 지적 목록

### Refine 최종 출력

```
🔄 [refine] Complete — {실제 라운드 수}/{max_rounds} rounds

## 채택된 해결책
{최종 채택안}

## 라운드 요약
| Round | Phase    | 참여 | 결과 |
|-------|----------|------|------|
| 1     | Diverge  | {N}명 | {N}개 독립 해결책 |
| 2     | Converge | {N}명 | {채택안} 채택 (득표 {M}/{N}) |
| 3     | Verify   | {N}명 | {OK수}/{N} OK |
```

---

## Strategy: tournament

전원 동시 경쟁 → 익명 투표 → 채택.

### Phase 1: COMPETE

> 🏆 [tournament] Phase 1: Compete — 전원 동시 경쟁

```bash
tm-agent fan-out '<TASK>. 최선의 결과를 제출하라. 이것은 경쟁이다 — 가장 뛰어난 결과가 채택된다. 400단어 이내. [IMPORTANT] When done, run: tm-agent reply "<your submission>" to report.'
```

```bash
tm-agent wait --timeout {timeout} --mode report
tm-agent collect --lines 100
```

### Phase 2: ANONYMIZE

> 🏆 [tournament] Phase 2: Anonymize — 익명화

너(Claude)가 수집된 결과를 익명화한다:
1. 에이전트 이름을 제거
2. 순서를 무작위로 셔플
3. "Solution A", "Solution B", "Solution C" ... 로 라벨링
4. 포맷을 통일하여 스타일로 작성자를 식별하기 어렵게 만든다

에이전트-솔루션 매핑을 내부적으로 기억한다 (최종 발표용).

### Phase 3: VOTE

> 🏆 [tournament] Phase 3: Vote — 익명 순위 투표

```bash
tm-agent broadcast '## 토너먼트 투표

아래 {N}개 솔루션을 1위부터 {N}위까지 순위를 매겨라.
자기가 제출한 것이라고 생각되는 솔루션에는 높은 순위를 주지 마라 (공정성).

{익명화된 솔루션 목록}

형식: 1위: [A|B|C|...], 2위: [...], ... 이유: [한 줄 설명]
[IMPORTANT] When done, run: tm-agent reply "<your ranking>" to report.'
```

```bash
tm-agent wait --timeout {timeout} --mode report
tm-agent collect --lines 100
```

### Phase 4: TALLY

> 🏆 [tournament] Phase 4: Tally — 집계

Borda count 방식으로 집계:
- 1위 = N점, 2위 = N-1점, ... N위 = 1점
- 총점이 가장 높은 솔루션 채택

동점 시:
1. 1위 득표 수 비교
2. 여전히 동점이면 `--judge` 에이전트에게 판정 요청 (미지정시 너(Claude)가 판정)

### Tournament 최종 출력

```
🏆 [tournament] Winner: Solution {X} ({원래 에이전트 이름})

| Rank | Solution | Score | Agent |
|------|----------|-------|-------|
| 1st  |    {X}   |  {S}  | {agent} |
| 2nd  |    {Y}   |  {S}  | {agent} |
| ...  |   ...    |  ...  | ...   |

## 우승 솔루션
{솔루션 전문}
```

---

## Strategy: chain

A→B→C 순차 파이프라인.

### Step Parsing

`--steps` 옵션이 있으면 파싱:
```
--steps "explorer:코드분석,architect:설계,executor:구현"
→ [(explorer, "코드분석"), (architect, "설계"), (executor, "구현")]
```

`--steps` 없으면 너(Claude)가 태스크를 분석하여 적절한 파이프라인을 자동 구성한다.
에이전트 역할을 고려하여 순서를 결정한다.

### Execution Loop

각 단계마다:

> ⛓️ [chain] Step {n}/{total}: {agent} → {step_task}

```bash
tm-agent delegate {agent} '## Chain Step {n}/{total}: {step_task}

태스크: {원본 태스크}
이전 단계 결과: {이전 결과 또는 "없음 (첫 단계)"}

위 맥락을 바탕으로 "{step_task}"를 수행하라. 400단어 이내.
[IMPORTANT] When done, run: tm-agent reply "<your result>" to report.'
```

```bash
tm-agent wait --timeout {timeout} --mode report
```

delegate 반환 JSON에서 task_id를 기억하고, 결과를 읽는다:
```bash
# delegate 응답의 JSON에서 task_id 추출 (예: "id": "417a1043")
# 우선순위 1: task_id 파일 (이전 전략에 오염되지 않음)
cat ~/.term-mesh/results/my-team/{task_id}.md
# 우선순위 2: agent reply 파일 (task_id 파일이 비어있을 때)
cat ~/.term-mesh/results/my-team/{agent}-reply.md
```

이 결과를 다음 단계의 "이전 단계 결과"로 전달한다.

에이전트가 실패(timeout/error)하면:
- **첫 단계 실패**: 이전 결과가 없으므로 "이전 결과 없음"이 후속 단계를 오염시킨다. 전략을 중단하고 사용자에게 보고한다.
- **중간 단계 실패**: 사용자에게 알리고 계속 진행할지 확인. 계속하면 **직전 성공 단계의 결과**를 다음 단계에 전달한다 (실패 단계 결과가 아닌 그 전 단계 결과).

### Chain 최종 출력

```
⛓️ [chain] Complete — {total} steps

| Step | Agent     | Task     | Status |
|------|-----------|----------|--------|
| 1    | explorer  | 코드분석  | ✅     |
| 2    | architect | 설계     | ✅     |
| 3    | executor  | 구현     | ✅     |

## 최종 결과
{마지막 단계의 결과}
```

---

## Strategy: review

전원이 현재 코드를 다각도 리뷰.

### Phase 1: COLLECT TARGET

리뷰 대상을 수집:
- `--target <file>` → 해당 파일 읽기
- `--pr <number>` → `gh pr diff {number}` 실행
- 둘 다 없으면 → `git diff HEAD` (staged + unstaged)

**보안 필터**: .env, credentials, secret, key 패턴이 포함된 파일은 제외하고 경고.

### Phase 2: ASSIGN PERSPECTIVES

에이전트 역할 기반으로 관점을 자동 배정:
- security → 보안 취약점 (인젝션, 인증, 권한)
- reviewer → 로직 오류, 가독성, 패턴 일관성
- tester → 테스트 커버리지, 에지 케이스
- architect → 아키텍처 적합성, 설계 원칙
- explorer → 코드 구조, 중복, 불필요 코드
- backend → 성능, DB 쿼리, 에러 핸들링
- frontend → UI/UX, 접근성, 상태 관리
- planner → 요구사항 충족, 누락 기능

idle 에이전트만 참여시킨다.

### Phase 3: PARALLEL REVIEW

> 🔍 [review] Reviewing with {N} agents...

각 에이전트에게 병렬로 리뷰 요청:

```bash
tm-agent delegate {agent} '## Code Review: {perspective} 관점

아래 코드를 {perspective} 관점에서 리뷰하라.

{코드 diff 또는 파일 내용}

발견한 이슈를 아래 형식으로 보고:
- [Critical|High|Medium|Low] 파일:라인 — 설명
- 이슈가 없으면 "No issues found" 라고만

[IMPORTANT] When done, run: tm-agent reply "<your review>" to report.'
```

모든 에이전트를 동시에 delegate한 후:
```bash
tm-agent wait --timeout {timeout} --mode report
tm-agent collect --lines 200
```

### Phase 4: SYNTHESIZE

너(Claude)가 전원 리뷰를 종합한다:
1. 중복 이슈 제거 (같은 문제를 여러 에이전트가 지적한 경우)
2. 심각도별 정렬: Critical > High > Medium > Low
3. 발견 에이전트 수 표시 (2명 이상이 지적한 이슈는 신뢰도 높음)

### Review 최종 출력

```
🔍 [review] Complete — {N} agents, {M} issues found

| # | Severity | Location      | Issue              | Found by |
|---|----------|---------------|--------------------|----------|
| 1 | Critical | file.ts:42    | SQL injection risk | security, reviewer |
| 2 | High     | api.ts:128    | Missing auth check | security |
| 3 | Medium   | util.ts:15    | Unused import      | explorer |

## 상세 리뷰
### Critical Issues
{상세 설명 및 수정 제안}

### High Issues
{상세 설명 및 수정 제안}
```

---

## Strategy: debate

정반합 토론. 찬성팀(PRO)과 반대팀(CON)이 구조화된 논쟁을 벌인 뒤 판정단이 평가.

### Phase 1: POSITION (팀 분배)

> ⚖️ [debate] Phase 1: Position — 팀 분배

`--pro`/`--con` 옵션이 있으면 해당 에이전트를 배정한다.
없으면 자동 분배:
- idle 에이전트 리스트를 3등분: PRO(전반), CON(후반), JUDGES(나머지)
- 최소 PRO 1명, CON 1명, JUDGE 1명 필요
- JUDGE가 없으면 리더(Claude)가 판정

사용자에게 팀 구성을 알린다:
> PRO: {agent1, agent2} | CON: {agent3, agent4} | JUDGE: {agent5}

### Phase 2: OPENING (입론)

> ⚖️ [debate] Phase 2: Opening — 양측 입론

PRO팀과 CON팀에게 동시에 입론을 요청한다:

PRO팀 각 에이전트에게:
```bash
tm-agent delegate {pro_agent} '## Debate: PRO 입론
논제: {TASK}
당신은 찬성(PRO) 측이다. 이 제안/접근법을 지지하는 논거를 제시하라.
- 핵심 장점 3가지
- 구체적 근거와 예시
- 300단어 이내
[IMPORTANT] When done, run: tm-agent reply "<your argument>" to report.'
```

CON팀 각 에이전트에게 (동시에):
```bash
tm-agent delegate {con_agent} '## Debate: CON 입론
논제: {TASK}
당신은 반대(CON) 측이다. 이 제안/접근법의 문제점과 대안을 제시하라.
- 핵심 위험/단점 3가지
- 구체적 근거와 대안
- 300단어 이내
[IMPORTANT] When done, run: tm-agent reply "<your argument>" to report.'
```

```bash
tm-agent wait --timeout {timeout} --mode report
```

양측 입론을 수집한다. 같은 팀의 복수 에이전트 입론은 리더가 팀별로 종합한다.

### Phase 3: REBUTTAL (반박)

> ⚖️ [debate] Phase 3: Rebuttal — 교차 반박 (Round {n})

`--rounds N`으로 반박 라운드 수를 조절한다 (기본 1).

PRO팀에게 CON 입론을 전달하고 반박 요청:
```bash
tm-agent delegate {pro_agent} '## Debate: PRO 반박 (Round {n})
상대(CON)의 주장:
{con_arguments}

위 주장에 반박하라. 200단어 이내.
[IMPORTANT] When done, run: tm-agent reply "<your rebuttal>" to report.'
```

CON팀에게 PRO 입론을 전달하고 반박 요청 (동시에):
```bash
tm-agent delegate {con_agent} '## Debate: CON 반박 (Round {n})
상대(PRO)의 주장:
{pro_arguments}

위 주장에 반박하라. 200단어 이내.
[IMPORTANT] When done, run: tm-agent reply "<your rebuttal>" to report.'
```

```bash
tm-agent wait --timeout {timeout} --mode report
```

라운드 2 이상이면 이전 반박 결과를 포함하여 반복한다:
- PRO 에이전트에게: CON의 최신 반박 결과 + 이전 라운드 PRO 반박 결과를 함께 전달
- CON 에이전트에게: PRO의 최신 반박 결과 + 이전 라운드 CON 반박 결과를 함께 전달
- 라운드 간 결과는 `cat ~/.term-mesh/results/my-team/{task_id}.md` 로 정확히 수집 (이전 라운드 reply 파일이 새 라운드에서 덮어쓰여지므로 task_id 기반 수집 필수)

### Phase 4: VERDICT (판정)

> ⚖️ [debate] Phase 4: Verdict — 판정

판정단 에이전트에게 전체 논쟁 기록을 전달:
```bash
tm-agent delegate {judge} '## Debate: 판정
논제: {TASK}

PRO 입론: {pro_opening}
CON 입론: {con_opening}
PRO 반박: {pro_rebuttal}
CON 반박: {con_rebuttal}

양측 논거를 평가하고 판정하라:
1. 어느 쪽이 더 설득력 있는가? (PRO/CON)
2. 각 측의 가장 강한 논거 1개
3. 최종 권고 (200단어 이내)
[IMPORTANT] When done, run: tm-agent reply "<your verdict>" to report.'
```

```bash
tm-agent wait --timeout {timeout} --mode report
```

리더(Claude)가 판정단 결과를 종합하여 최종 결론을 내린다.
판정단이 없는 경우(에이전트 3명 미만) 리더가 직접 판정한다.

### Debate 최종 출력

```
⚖️ [debate] Complete — {topic}

| Team | Agents | Key Argument |
|------|--------|-------------|
| PRO  | {agents} | {strongest point} |
| CON  | {agents} | {strongest point} |

## Verdict: {PRO|CON} — {한 줄 요약}
{최종 판정 근거}

## 논쟁 요약
| Phase | PRO | CON |
|-------|-----|-----|
| Opening | {핵심 주장} | {핵심 주장} |
| Rebuttal | {핵심 반박} | {핵심 반박} |
```

---

## Strategy: council

다자간 숙의 회의. N명의 에이전트가 자유롭게 의견을 개진하고, 서로의 주장에 교차 질의하며, 핵심 쟁점을 심화 토의한 뒤 합의 또는 쟁점 정리 문서를 도출한다.

debate와의 차이: debate는 2개 고정 진영(PRO/CON)이 승패를 겨루지만, council은 N개 유동 포지션이 합의를 추구한다.

### Prerequisites

- 최소 에이전트 수: **2명** (3명 이상 권장)
- 2명일 경우 경고: "council은 3명 이상에서 최적화됩니다. 2명이면 debate를 권장합니다. 계속할까요?"
- `--rounds N` — 총 라운드 수 (기본 4, 최소 2). Round 1(개진) + Round 2(교차 질의) + Round 3~N-1(심화) + Final(수렴).
- `--agenda "item1,item2,item3"` — 다중 안건. 각 안건마다 전체 council 사이클을 반복한다.

### Agenda Handling

`--agenda` 제공 시:
1. 안건 목록을 파싱: `"API 설계,인증 방식,배포 전략"` → `["API 설계", "인증 방식", "배포 전략"]`
2. 사용자에게 안건 목록을 보여준다:
```
🏛️ [council] 안건 목록:
  1. API 설계
  2. 인증 방식
  3. 배포 전략
총 {N}개 안건, 에이전트 {M}명 참여
```
3. 각 안건마다 Round 1~Final을 순차 실행한다.
4. 안건별 결과를 누적하여 최종 출력에 통합한다.

`--agenda` 없으면 사용자가 제공한 토픽 하나를 단일 안건으로 처리한다.

### Round 1: OPENING (개진)

> 🏛️ [council] Round 1/{max_rounds}: Opening — 각자 입장 개진

각 에이전트가 독립적으로 주제에 대한 자신의 입장을 밝힌다.

```bash
tm-agent fan-out '## Council: 입장 개진
논제: {TASK}

이 주제에 대해 당신의 입장과 근거를 밝혀라.
- 핵심 주장 (명확한 포지션)
- 근거 2-3가지 (구체적 사례/데이터)
- 예상되는 반론과 그에 대한 사전 답변 1가지
- 300단어 이내

당신은 어떤 포지션이든 자유롭게 취할 수 있다. 다른 에이전트와 같은 입장이어도 무방하다.
[IMPORTANT] When done, run: tm-agent reply "<your position>" to report.'
```

```bash
tm-agent wait --timeout {timeout} --mode report
tm-agent collect --lines 200
```

잘린 결과가 있으면 개별 reply 파일을 읽는다.

리더(Claude)가 전원 입장을 수집하고 내부적으로 **포지션 맵**을 구축한다:
- 각 에이전트의 핵심 주장 요약 (1줄)
- 유사 포지션끼리 그룹핑
- 초기 합의 지점과 분기점 파악

사용자에게 중간 상황을 보고한다:
```
🏛️ [council] Round 1 완료 — {N}명 입장 개진
포지션 분포: {group_summary}
핵심 분기점: {divergence_points}
```

### Round 2: CROSS-EXAMINE (교차 질의)

> 🏛️ [council] Round 2/{max_rounds}: Cross-Examine — 교차 질의

이 라운드가 council의 핵심 차별점이다. 각 에이전트가 다른 에이전트들의 **구체적 주장**을 읽고 직접 질문하거나 반론한다.

각 에이전트에게 **본인 제외** 다른 모든 에이전트의 입장을 전달하고 교차 질의를 요청한다:

```bash
tm-agent delegate {agent} '## Council: 교차 질의
논제: {TASK}

다른 참여자들의 입장:
{other_agents_positions — 본인 제외}

위 입장을 읽고 아래를 수행하라:
1. 가장 동의하는 주장 1개를 골라 그 이유를 밝혀라
2. 가장 의문이 드는 주장 1-2개를 골라 구체적 질문 또는 반론을 제기하라
   - "{agent_name}의 주장 중 ~~ 부분에 대해..." 형식으로 특정 에이전트를 지명하라
3. 다른 에이전트의 주장을 통해 자신의 입장이 변화했다면 어떻게 변했는지 밝혀라
- 300단어 이내
[IMPORTANT] When done, run: tm-agent reply "<your cross-examination>" to report.'
```

(위 delegate를 모든 에이전트에 대해 **병렬로** 실행한다. broadcast가 아닌 개별 delegate — 에이전트마다 {other_agents_positions} 내용이 다르기 때문이다.)

```bash
tm-agent wait --timeout {timeout} --mode report
tm-agent collect --lines 200
```

잘린 결과가 있으면 개별 reply 파일을 읽는다.

결과를 수집하고 리더(Claude)가 분석한다:
1. **합의 수렴 감지**: 복수 에이전트가 특정 포지션에 동의를 표명했는지 확인
2. **핵심 쟁점 추출**: 교차 질의에서 반복적으로 제기된 의문/반론을 쟁점(dispute)으로 정리
3. **입장 변화 추적**: 에이전트가 입장을 수정한 경우 기록

사용자에게 중간 상황을 보고한다:
```
🏛️ [council] Round 2 완료 — 교차 질의 결과
합의 수렴: {converging_points}
핵심 쟁점: {dispute_list}
입장 변화: {agent_name}: {old_position} → {new_position}
```

**조기 종료 체크**: 전원이 동일 포지션에 합의를 표명했다면 → Round 3~N-1을 건너뛰고 Final Round로 직행.

### Round 3 ~ N-1: DEEP DIVE (심화)

> 🏛️ [council] Round {n}/{max_rounds}: Deep Dive — 핵심 쟁점 심화 토의

리더(Claude)가 교차 질의에서 추출한 핵심 쟁점(최대 3개)을 선정하고, 전 에이전트에게 해당 쟁점에 집중한 심화 토의를 요청한다.

```bash
tm-agent broadcast '## Council: 심화 토의 (Round {n})
논제: {TASK}

지금까지의 논의에서 다음 핵심 쟁점이 도출되었다:

### 쟁점 1: {dispute_1_title}
{dispute_1_description}
관련 입장: {agent_a} — {position_a} vs {agent_b} — {position_b}

### 쟁점 2: {dispute_2_title}
{dispute_2_description}

### 현재 합의 사항
- {agreed_point_1}
- {agreed_point_2}

위 쟁점 중 자신의 전문 분야와 가장 관련 깊은 것에 집중하여:
1. 추가 근거나 데이터를 제시하라
2. 다른 에이전트의 교차 질의에 직접 답변하라 ("{agent}의 질문에 대해...")
3. 타협안(compromise)이 있다면 제안하라
4. 자신의 입장이 변했다면 명시적으로 밝혀라: "입장 변경: {이전} → {이후}"
- 300단어 이내
[IMPORTANT] When done, run: tm-agent reply "<your deep dive>" to report.'
```

```bash
tm-agent wait --timeout {timeout} --mode report
tm-agent collect --lines 200
```

리더(Claude)가 결과를 분석한다:
1. 각 쟁점별로 합의가 이루어졌는지 판단
2. 새로운 쟁점이 등장했는지 확인
3. 에이전트별 입장 변화를 누적 추적

**조기 종료 체크**: 모든 핵심 쟁점에서 합의가 이루어졌다면 → 다음 심화 라운드를 건너뛰고 Final Round로 직행.

심화 라운드를 max_rounds가 허용하는 한 반복한다. 각 라운드에서:
- 해결된 쟁점은 "합의 사항"으로 이동
- 미해결 쟁점은 다음 라운드에서 재논의
- 새 쟁점이 등장하면 추가

### Final Round: CONVERGE (수렴)

> 🏛️ [council] Round {max_rounds}/{max_rounds}: Converge — 합의 시도

리더(Claude)가 전체 논의를 종합하여 **합의안 초안(draft consensus)**을 작성한다. 리더가 작성하되, 에이전트들의 실제 논의 내용만을 반영한다 (리더 자신의 의견을 넣지 않는다).

```bash
tm-agent broadcast '## Council: 합의 수렴
논제: {TASK}

전체 논의를 종합한 합의안 초안:

### 합의 사항
{consensus_items}

### 미해결 쟁점
{remaining_disputes_with_both_positions}

위 초안에 대해 다음 중 하나로 응답하라:
1. **AGREE** — 합의안에 동의한다. (부분 수정 제안이 있으면 함께 기술)
2. **OBJECT** — 합의안에 동의하지 않는다. 반대 이유와 수정 요구를 구체적으로 밝혀라.

또한 최종 입장을 한 줄로 요약하라: "최종 입장: {summary}"
[IMPORTANT] When done, run: tm-agent reply "<AGREE or OBJECT + reasoning>" to report.'
```

```bash
tm-agent wait --timeout {timeout} --mode report
tm-agent collect --lines 200
```

리더(Claude)가 결과를 분석한다:
- **전원 AGREE** → consensus_status = "FULL CONSENSUS"
- **과반 AGREE** (OBJECT 에이전트의 수정 제안이 minor) → 수정 반영 후 consensus_status = "CONSENSUS WITH RESERVATIONS"
- **과반 미달** 또는 **핵심 OBJECT** → consensus_status = "NO CONSENSUS — DISPUTE SUMMARY"

### Council 최종 출력

```
🏛️ [council] Complete — {actual_rounds}/{max_rounds} rounds, {N} agents
Status: {FULL CONSENSUS | CONSENSUS WITH RESERVATIONS | NO CONSENSUS}

## Consensus Statement (합의문)
{consensus_statement — 전원 합의 시 확정안, 부분 합의 시 조건부 합의안}

## Key Disputes (핵심 쟁점)
| # | Dispute | Position A | Position B | Status |
|---|---------|-----------|-----------|--------|
| 1 | {쟁점} | {입장A} ({agents}) | {입장B} ({agents}) | ✅ Resolved / ❌ Open |

## Stance Evolution (입장 변천)
| Agent | Round 1 | Final | Changed? |
|-------|---------|-------|----------|
| {agent1} | {initial_position} | {final_position} | ✅ / — |
| {agent2} | {initial_position} | {final_position} | ✅ / — |

## Unresolved Items (미해결 항목)
| # | Item | Blocking Positions | What Would Resolve It |
|---|------|--------------------|----------------------|
| 1 | {item} | {agent}: {reason} | {데이터/실험/추가 분석 필요} |

## Round Summary
| Round | Phase | Key Outcome |
|-------|-------|-------------|
| 1 | Opening | {N}명 입장 개진, {G}개 포지션 그룹 |
| 2 | Cross-Examine | {쟁점 수}개 핵심 쟁점 도출, {변화 수}명 입장 변화 |
| 3 | Deep Dive | 쟁점 {해결수}/{총수} 해결 |
| 4 | Converge | {consensus_status} |
```

`--agenda` 사용 시:
```
🏛️ [council] Complete — {agenda_count} agendas, {total_rounds} total rounds

## Agenda 1: {topic_1}
{위와 동일한 출력 구조}

## Agenda 2: {topic_2}
{위와 동일한 출력 구조}

## Cross-Agenda Summary
{안건 간 연관성이나 상충점이 있으면 리더가 정리}
```

---

## Strategy: red-team

적대적 공격/방어. 공격팀이 취약점·결함을 발견하고 방어팀이 수정안을 제시.

### Phase 1: TARGET (대상 수집)

> 🔴 [red-team] Phase 1: Target — 공격 대상 수집

리뷰 대상을 수집한다 (review 전략과 동일):
- `--target <file>` → 해당 파일 읽기
- `--pr <number>` → `gh pr diff {number}` 실행
- 둘 다 없으면 → `git diff HEAD` (staged + unstaged)

**보안 필터**: .env, credentials, secret, key 패턴이 포함된 파일은 제외하고 경고.

### Phase 2: ASSIGN TEAMS (팀 분배)

> 🔴 [red-team] Phase 2: Assign — 공격/방어팀 분배

`--attackers`/`--defenders` 옵션이 있으면 해당 에이전트를 배정한다.
없으면 역할 기반 자동 분배:
- **공격팀 (ATTACKERS)**: security, tester, explorer, reviewer (취약점 발견에 적합)
- **방어팀 (DEFENDERS)**: executor, backend, frontend, architect (수정/설계에 적합)
- planner, writer → idle면 방어팀에 배정

### Phase 3: ATTACK (공격)

> 🔴 [red-team] Phase 3: Attack — 취약점/결함 탐색

공격팀 에이전트에게 병렬로 공격 요청:
```bash
tm-agent delegate {attacker} '## Red Team: ATTACK
대상 코드/설계:
{target_content}

적대적 관점에서 최대한 많은 취약점/결함/에지케이스를 찾아라.
각 발견 항목을 아래 형식으로:
- [Critical|High|Medium] 위치 — 공격 벡터 — 증명 시나리오
공격적으로 사고하라. 방어 가능성은 고려하지 마라.
[IMPORTANT] When done, run: tm-agent reply "<your attacks>" to report.'
```

```bash
tm-agent wait --timeout {timeout} --mode report
```

리더가 공격 결과를 수집하고 중복을 제거한다.

**빈 공격 가드**: 중복 제거 후 공격 목록이 비어있으면 (전원 타임아웃 또는 무효 결과):
- "⚠️ 유효한 공격이 발견되지 않았습니다. 공격팀 전원이 타임아웃되었거나 유효 공격 없음." 을 사용자에게 보고한다.
- Phase 4(DEFEND)로 진행하지 않고 전략을 종료한다. 빈 공격을 방어팀에게 전달하면 연쇄 공백 전파가 발생한다.
- 일부 공격팀만 타임아웃된 경우: 수집된 공격 수를 명시하고 ("📋 {N}/{M}명 응답, {K}개 공격 발견") 계속 진행한다.

### Phase 4: DEFEND (방어)

> 🔴 [red-team] Phase 4: Defend — 수정안 제시

방어팀 에이전트에게 중복 제거된 공격 목록을 전달:
```bash
tm-agent delegate {defender} '## Red Team: DEFEND
다음 공격이 보고되었다:
{deduplicated_attacks}

각 공격에 대해:
1. 유효한 공격이면: 구체적 수정안 코드/설계 제시
2. 무효한 공격이면: 반박 근거 제시 (왜 실제로는 문제가 아닌지)
[IMPORTANT] When done, run: tm-agent reply "<your defenses>" to report.'
```

```bash
tm-agent wait --timeout {timeout} --mode report
```

### Phase 5: REATTACK (재공격, 선택)

`--rounds 2` 이상일 때만 실행.

> 🔴 [red-team] Phase 5: Reattack — 수정안 재공격 (Round {n})

방어팀의 수정안을 공격팀에게 전달하여 재공격:
```bash
tm-agent delegate {attacker} '## Red Team: REATTACK (Round {n})
이전 공격에 대한 방어팀 수정안:
{defense_results}

수정안이 충분한지 검증하라. 여전히 취약한 부분이 있으면 새 공격 벡터를 제시.
[IMPORTANT] When done, run: tm-agent reply "<your reattack>" to report.'
```

```bash
tm-agent wait --timeout {timeout} --mode report
```

재공격 결과가 있으면 Phase 4(방어)를 반복한다. `--rounds` 횟수까지 반복.

### Phase 6: REPORT (종합)

리더(Claude)가 모든 공격/방어 결과를 종합한다:
1. 각 공격 항목의 최종 상태 결정: Fixed(🟢), Partial(🟡), Open(🔴)
2. 심각도별 정렬: Critical > High > Medium
3. 수정안이 유효한지 리더가 최종 판단

### Red-team 최종 출력

```
🔴 [red-team] Complete — {rounds} rounds, {total} vulnerabilities

| # | Severity | Attack | Status | Defender |
|---|----------|--------|--------|----------|
| 1 | Critical | {attack description} | 🟢 Fixed | {agent} |
| 2 | High     | {attack description} | 🟡 Partial | {agent} |
| 3 | Medium   | {attack description} | 🔴 Open | — |

## Fixed Issues (🟢)
{수정안 상세}

## Partial Fixes (🟡)
{부분 수정 + 남은 위험}

## Open Issues (🔴)
{미해결 취약점 + 권장 조치}
```

---

## Strategy: brainstorm

자유 발산. 수렴 압력 없이 아이디어를 최대한 모은 뒤 분류·우선순위 매기기.

### Phase 1: SEED (주제 제시)

> 💡 [brainstorm] Phase 1: Seed — 주제 설정

사용자에게 진행 상황을 알린다:
> 💡 [brainstorm] "{TASK}" — {N}명 에이전트 참여, 발산 시작

### Phase 2: GENERATE (아이디어 생성)

> 💡 [brainstorm] Phase 2: Generate — 전원 아이디어 발산

```bash
tm-agent fan-out '## Brainstorm: {TASK}
이 주제에 대해 아이디어를 최대한 많이 제시하라.
규칙:
- 비판 금지 — 실현 가능성은 나중에 판단
- 기존 아이디어에 편승(build-on) OK
- 각 아이디어는 제목 + 1-2줄 설명
- 최소 5개 이상
[IMPORTANT] When done, run: tm-agent reply "<your ideas>" to report.'
```

```bash
tm-agent wait --timeout {timeout} --mode report
tm-agent collect --lines 200
```

잘린 결과가 있으면 개별 reply 파일을 읽는다.

### Phase 3: CLUSTER (분류)

> 💡 [brainstorm] Phase 3: Cluster — 테마별 분류

리더(Claude)가 전원 아이디어를 수집하고:
1. 중복 제거 (같은 아이디어를 여러 에이전트가 제안한 경우 병합, 제안자 모두 표시)
2. 테마별 그룹핑 (예: "성능", "UX", "아키텍처", "파격적 아이디어")
3. 총 아이디어 수와 테마 수 카운트
4. 각 아이디어에 번호 부여

### Phase 4: VOTE (도트 투표, 선택)

`--vote` 옵션이 있을 때만 실행.

> 💡 [brainstorm] Phase 4: Vote — 도트 투표

```bash
tm-agent broadcast '## Brainstorm: 도트 투표
아래 아이디어 목록에서 가장 가치 있다고 생각하는 3개를 선택하라.

{clustered_ideas_with_numbers}

형식: 1. [아이디어 번호], 2. [번호], 3. [번호] — 이유: [한 줄]
[IMPORTANT] When done, run: tm-agent reply "<your votes>" to report.'
```

```bash
tm-agent wait --timeout {timeout} --mode report
tm-agent collect --lines 100
```

리더(Claude)가 투표를 집계한다:
- 각 아이디어별 득표 수 계산
- 득표 순으로 정렬
- Top 5 선정

### Brainstorm 최종 출력

`--vote` 없을 때:
```
💡 [brainstorm] Complete — {N} ideas from {M} agents, {T} themes

## 테마: {theme_1} ({count}개)
- {idea_1} — {agent}
- {idea_2} — {agent1, agent2}

## 테마: {theme_2} ({count}개)
- {idea_3} — {agent}
...
```

`--vote` 있을 때:
```
💡 [brainstorm] Complete — {N} ideas from {M} agents, {T} themes

## Top 5
| Rank | Idea | Votes | By |
|------|------|-------|----|
| 1 | {idea} | {N}표 | {agents} |
| 2 | {idea} | {N}표 | {agents} |
...

## 전체 아이디어 (테마별)
### {theme_1} ({count}개)
| # | Idea | By | Votes |
|---|------|----|-------|
| 1 | ... | architect | ⭐⭐⭐ |
| 2 | ... | frontend | ⭐⭐ |
...
```

---

## Strategy: distribute

대규모 태스크를 독립 서브태스크로 분할하여 각 에이전트에게 할당, 병렬 실행 후 병합.
`refine`(같은 태스크를 다르게)이나 `fan-out`(동일 지시)과 달리, 각 에이전트가 **서로 다른 서브태스크**를 수행한다.

### Phase 1: SPLIT (분할)

> 📦 [distribute] Phase 1: Split — 태스크를 독립 서브태스크로 분할

**Case A: `--splits` 제공 시** — 파싱:
```
--splits "explorer:src/auth 분석,security:src/api 분석,executor:tests/ 작성"
→ [(explorer, "src/auth 분석"), (security, "src/api 분석"), (executor, "tests/ 작성")]
```

지정된 에이전트가 존재하고 idle인지 확인한다. working/blocked이면 경고 후 사용자에게 계속할지 확인.

**Case B: 자동 분할 (기본)** — 리더(Claude)가 태스크를 분석하여 idle 에이전트 수만큼 서브태스크로 분할:

1. 태스크 설명을 읽고 자연스러운 분할 경계를 파악 (파일별, 모듈별, 이슈별, 테스트별 등)
2. 서브태스크 간 **독립성** 보장 — 어떤 서브태스크도 다른 서브태스크의 결과에 의존하지 않아야 한다
3. 에이전트 역할에 맞게 배정 (security → 보안 관련, frontend → UI 관련 등)

리더가 분할 계획을 사용자에게 보여주고 확인받는다:
```
📦 분할 계획:
| # | Agent     | Subtask              | Target Files    |
|---|-----------|----------------------|-----------------|
| 1 | explorer  | src/auth/ 분석       | src/auth/*.ts   |
| 2 | security  | src/api/ 보안 점검    | src/api/*.ts    |
| 3 | executor  | tests/ 작성          | tests/*.ts      |

진행할까요? (Y/n)
```

사용자가 거부하면 AskUserQuestion으로 수정 사항을 받는다.

서브태스크 수 > idle 에이전트 수인 경우 **순차 할당 알고리즘**을 적용한다:

1. **첫 배치**: idle 에이전트 수만큼 서브태스크를 동시 dispatch한다.
2. **대기 큐**: 나머지 서브태스크를 큐에 넣는다.
3. **완료 감지**: `tm-agent wait --timeout {timeout} --mode report` 후 `tm-agent status`로 완료된 에이전트를 파악한다.
4. **재할당**: 완료된 에이전트에게 큐의 다음 서브태스크를 즉시 `tm-agent delegate`한다.
5. **한도**: 에이전트당 최대 2개 서브태스크까지 (컨텍스트 오염 방지). 3번째부터는 다른 에이전트가 완료될 때까지 대기한다.
6. **반복**: 큐가 빌 때까지 3-5를 반복한다.

예: 2명 idle, 4개 서브태스크 → 첫 배치(2개) → 완료 후 나머지(2개) 순차 할당.
모든 에이전트가 한도에 도달하고 큐가 남으면 사용자에게 범위 축소를 제안한다.

### Phase 2: CONFLICT CHECK (충돌 검사)

> 📦 [distribute] Phase 2: Conflict Check — 파일 충돌 사전 검증

`--conflict-check` 활성 시 (기본 활성) 그리고 태스크가 파일 수정을 포함할 때:

1. 각 서브태스크의 대상 파일/디렉토리를 파악
2. 두 에이전트 이상의 범위에 같은 파일이 포함되면 경고:
```
⚠️ 충돌 감지: src/utils/helper.ts 가 explorer와 executor의 작업 범위에 포함됩니다.
```
3. 해결 옵션: 해당 파일을 한 에이전트에게만 재할당, 또는 경고를 인지하고 진행
4. 분석 전용 태스크(읽기만)이면 이 단계를 스킵한다

### Phase 3: DISPATCH (병렬 배포)

> 📦 [distribute] Phase 3: Dispatch — {N}개 서브태스크 병렬 실행

각 에이전트에게 고유한 서브태스크를 `tm-agent delegate`로 전송:

```bash
tm-agent delegate {agent} '## Distributed Task: Subtask {n}/{total}

전체 태스크: {original_task}
당신의 담당: {subtask_description}
작업 범위: {target_files_or_scope}

다른 에이전트가 나머지 부분을 병렬로 작업 중이다. 아래 파일/범위만 수정/분석하라:
{scope_boundary}

⚠️ 범위 밖 파일을 수정하지 마라 — 다른 에이전트와 충돌할 수 있다.

[IMPORTANT] When done, run: tm-agent reply "<your result>" to report.'
```

컨텍스트 주입이 활성이면 각 delegate 호출에 `--context` 플래그를 추가한다.

모든 에이전트를 동시에 dispatch한 후:

```bash
tm-agent wait --timeout {timeout} --mode report
```

### Phase 4: COLLECT (수집)

> 📦 [distribute] Phase 4: Collect — 결과 수집

표준 Result Collection 우선순위로 수집:
1. Task ID 파일: `cat ~/.term-mesh/results/{team}/{task_id}.md`
2. Agent reply 파일: `cat ~/.term-mesh/results/{team}/{agent}-reply.md`
3. `tm-agent collect --lines 200` (요약, 잘릴 수 있음)

에이전트별 완료 상태를 추적:

| Agent | Status | Duration |
|-------|--------|----------|
| explorer | completed | 45s |
| security | completed | 62s |
| executor | timeout | 120s |

에이전트가 타임아웃이면:
- 해당 에이전트를 "timeout"으로 표시
- 나머지 에이전트 결과로 계속 진행
- 최종 출력에 경고 포함

전원 타임아웃이면 전략을 중단하고 수집된 부분 결과를 출력.

### Phase 5: MERGE (병합)

> 📦 [distribute] Phase 5: Merge — 결과 병합

`--no-merge` 시 이 단계를 스킵하고 Phase 6으로 이동.

리더(Claude)가 전원 결과를 병합한다:
1. **코드 수정 태스크**: 충돌하는 편집이 없는지 검증. 충돌 감지 시 양쪽 버전을 보여주고 사용자 선택 요청.
2. **분석 태스크**: 발견 사항을 테마/심각도별로 종합, 중복 제거.
3. **혼합 태스크**: 유형별(코드 변경, 분석, 문서)로 그룹화하여 통합 제시.

### Phase 6: VERIFY (교차 검증, 선택)

`--rounds 2` 이상일 때만 실행.

> 📦 [distribute] Phase 6: Verify — 교차 검증 (Round {n})

```bash
tm-agent broadcast '## Distribute: 교차 검증
다른 에이전트들의 작업 결과를 검토하라:

{merged_results_summary}

자신의 담당 범위와 인접한 부분에서 일관성 문제나 누락을 확인하라.
- 문제 있으면: 구체적으로 지적
- 문제 없으면: "OK"

[IMPORTANT] When done, run: tm-agent reply "<your verification>" to report.'
```

```bash
tm-agent wait --timeout {timeout} --mode report
tm-agent collect --lines 100
```

결과를 분석:
- **전원 OK** → 완료
- **지적 있음** → 리더가 반영하여 결과 수정, 또는 해당 에이전트에게 수정 재요청

### Distribute 최종 출력

`--merge` 활성 시 (기본):
```
📦 [distribute] Complete — {N} subtasks, {completed}/{N} succeeded

| # | Agent     | Subtask           | Status    | Duration |
|---|-----------|-------------------|-----------|----------|
| 1 | explorer  | src/auth/ 분석     | ✅ Done   | 45s      |
| 2 | security  | src/api/ 보안 점검  | ✅ Done   | 62s      |
| 3 | executor  | tests/ 작성        | ⏰ Timeout | 120s     |

## 병합된 결과
{merged_result}

## 서브태스크별 상세
### Subtask 1: {subtask_description} (explorer)
{individual_result}

### Subtask 2: {subtask_description} (security)
{individual_result}

### Subtask 3: {subtask_description} (executor)
⏰ Timeout — 결과 없음
```

`--no-merge` 시:
```
📦 [distribute] Complete — {N} subtasks, {completed}/{N} succeeded

| # | Agent     | Subtask           | Status    | Duration |
|---|-----------|-------------------|-----------|----------|

## Subtask 1: {subtask_description} (explorer)
{individual_result}

## Subtask 2: {subtask_description} (security)
{individual_result}
```

---

## Interactive Mode

`$ARGUMENTS`가 빈 경우, AskUserQuestion 도구를 사용하여 전략을 선택받는다.

**AskUserQuestion은 옵션 최대 4개 제한이 있으므로**, 두 단계로 질문한다:

**1단계 — 카테고리 선택:**
- Question: "어떤 유형의 전략을 사용할까요?"
- Options:
  1. "협력 (refine / brainstorm)" — 전원이 협력하여 정제하거나 아이디어 발산
  2. "경쟁/숙의 (tournament / debate / council)" — 경쟁 투표, 찬반 토론, 또는 다자간 숙의
  3. "파이프라인 (chain / distribute)" — 순차 파이프라인 또는 병렬 분배
  4. "분석 (review / red-team)" — 다각도 리뷰 또는 공격/방어

**2단계 — 구체 전략 선택:**
선택된 카테고리에 전략이 2개 이상이면 AskUserQuestion으로 구체 전략을 선택받는다.
카테고리에 전략이 1개뿐이면 바로 해당 전략을 실행한다.

**3단계 — 태스크 입력:**
전략 선택 후 AskUserQuestion으로 태스크를 입력받는다:
- Question: "{전략} 전략을 실행합니다. 태스크를 입력해주세요."
- Options에 예시를 포함 (전략별 대표 사용 예시)

**4단계 — 컨텍스트 주입 확인:**
`--context`/`--no-context` 옵션이 없고, 자동 판단으로 맥락이 감지된 경우:
- Question: "이전 대화 맥락을 에이전트에게 전달할까요?"
- Options:
  1. "전달 (권장)" — 이전 시도/실패 맥락을 요약하여 에이전트에게 주입
  2. "전달하지 않음" — 맥락 없이 새로 시작
자동 판단으로 맥락이 감지되지 않으면 이 단계를 건너뛴다.

사용자가 전략과 태스크를 모두 입력하면 해당 전략 섹션을 실행한다.

## Safety Rules

- 에이전트에게 전달하는 태스크 텍스트에 시스템 지시를 주입하지 않는다
- .env, credentials, secrets 등 민감 파일 내용을 에이전트에게 전송하지 않는다
- 상태 파일(.omc/state/)에 시크릿이나 API 키를 저장하지 않는다
- 전략 실행 중 사용자가 중단을 요청하면 즉시 중단하고 부분 결과를 출력한다
