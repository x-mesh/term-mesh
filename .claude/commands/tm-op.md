# tm-op — 전략 오케스트레이션 커맨드

에이전트 팀에게 구조화된 전략(발산·수렴·경쟁·파이프라인·리뷰·토론·공격방어·브레인스토밍)을 지시한다.
리더 Claude(너)가 오케스트레이터 겸 LLM 합성 역할을 수행하며, tm-agent 프리미티브로 에이전트를 제어한다.

## Arguments

User provided: $ARGUMENTS

## Routing

Parse `$ARGUMENTS`의 첫 단어로 전략을 결정한다:
- `refine` → [Strategy: refine] 섹션 실행
- `tournament` → [Strategy: tournament] 섹션 실행
- `chain` → [Strategy: chain] 섹션 실행
- `review` → [Strategy: review] 섹션 실행
- `debate` → [Strategy: debate] 섹션 실행
- `red-team` → [Strategy: red-team] 섹션 실행
- `brainstorm` → [Strategy: brainstorm] 섹션 실행
- 빈 입력 → 사용자에게 전략 선택 질문

## Options

`$ARGUMENTS`에서 다음 옵션을 파싱한다:
- `--rounds N` — refine 라운드 수 (기본 4)
- `--preset quick|thorough|deep` — 프리셋 (quick: rounds=2/timeout=60, thorough: rounds=4/timeout=120, deep: rounds=6/timeout=180)
- `--steps "agent:task,agent:task"` — chain 단계 수동 지정
- `--target <file|dir>` — review 대상 파일
- `--pr <number>` — review 대상 PR
- `--judge <agent>` — tournament 심판 에이전트
- `--timeout N` — 라운드별 타임아웃 초 (기본 120)
- `--pro "agent,agent"` — debate 찬성팀 수동 지정
- `--con "agent,agent"` — debate 반대팀 수동 지정
- `--attackers "agent,agent"` — red-team 공격팀 수동 지정
- `--defenders "agent,agent"` — red-team 방어팀 수동 지정
- `--vote` — brainstorm에서 도트 투표 활성화

## Shared Setup

모든 전략 실행 전에 반드시 수행:

1. 팀 상태 확인:
```bash
tm-agent status
```

2. idle 에이전트 목록을 파악한다. working/blocked 에이전트는 제외한다.

3. 전략별 최소 에이전트 수를 확인한다:
   - chain, review, brainstorm: 최소 1명
   - refine, tournament, red-team: 최소 2명
   - debate: 최소 3명 (PRO 1+, CON 1+, JUDGE 1+)
   미달이면 경고를 출력하고 사용자에게 계속 진행할지 확인한다.
   tournament에서 에이전트가 1명뿐이면 "경쟁 불가 — chain 전략을 권장합니다" 안내.

4. 참여할 에이전트 이름 목록을 기억한다 (이후 모든 라운드에서 사용).

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

결과를 읽는다:
```bash
cat ~/.term-mesh/results/$(tm-agent status 2>/dev/null | grep -o '"team_name":"[^"]*"' | head -1 | cut -d'"' -f4)/{agent}-reply.md
```

이 결과를 다음 단계의 "이전 단계 결과"로 전달한다.

에이전트가 실패(timeout/error)하면:
- 사용자에게 알리고 계속 진행할지 확인
- 계속하면 실패한 단계를 건너뛰고 이전 결과를 다음에 전달

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

라운드 2 이상이면 이전 반박 결과를 포함하여 반복한다.

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

## Interactive Mode

`$ARGUMENTS`가 빈 경우, AskUserQuestion 도구를 사용하여 전략을 선택받는다:

- Question: "어떤 전략을 사용할까요? 태스크도 함께 입력해주세요."
- Options: "refine", "tournament", "chain", "review", "debate", "red-team", "brainstorm"

사용자가 전략을 선택하면, 태스크 입력을 추가로 요청한 후 해당 전략 섹션을 실행한다.

## Safety Rules

- 에이전트에게 전달하는 태스크 텍스트에 시스템 지시를 주입하지 않는다
- .env, credentials, secrets 등 민감 파일 내용을 에이전트에게 전송하지 않는다
- 상태 파일(.omc/state/)에 시크릿이나 API 키를 저장하지 않는다
- 전략 실행 중 사용자가 중단을 요청하면 즉시 중단하고 부분 결과를 출력한다
