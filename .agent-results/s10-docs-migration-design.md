# S10 — User-facing Docs & Migration 설계

> 코드 수정 없음. 파일 편집 지점 + migration 텍스트 설계만 포함.

---

## 1. 영향받는 문서별 변경 지점

### `.claude/commands/tm.md` (가장 많이 변경)

- **Goal 섹션 (line 3–7)**: "하나의 instruction을 모든 idle 에이전트에게 **동시에** delegate" → "instruction을 N개 역할별 sub-task로 **자동 분해**하여 각 에이전트에게 **서로 다른** sub-task 위임; `--no-decompose`로 v1 동작 유지".
- **Arguments 섹션 (line 59–63)**: `--no-decompose` 플래그 추가(기본값: decompose=on); "금지 옵션" 목록에는 추가하지 않음.
- **Workflow Step 2 앞에 "Step 1.5 — Sub-task Decomposition" 삽입**: instruction → LLM(leader 자신) 분해 → board.jsonl에 N개 task 기록 → 각 task에 role-affinity 힌트 태깅. `--no-decompose`면 이 단계 스킵.
- **Examples 섹션**: 기존 2개 예제를 v1(--no-decompose) / v2(default) before-after 쌍으로 교체(아래 §2 참고).
- **Future(v2 deferred) 섹션 전체 삭제**: 구현 완료 기능이므로 제거.

### `CLAUDE.md` — "Command responsibility split" 표 + Quick CLI reference

- **표의 `/tm` 행 설명** 업데이트: "작업 디스패치 (fan-out + 3줄 합성)" → "instruction 자동 분해 → 역할별 sub-task 병렬 dispatch + 3줄 합성".
- **`/tm` 행 주요 명령 열**: `--ensure <roles>` 옆에 `--no-decompose` 병기.
- **Quick CLI reference `# Dispatch (/tm)` 블록**: `/tm --no-decompose "..."  # v1 동작 — 동일 instruction 전원 발송` 예시 한 줄 추가.

### `.claude/commands/team.md`

- **Communication 섹션 note (line ~176)**: "/tm은 아래 표의 명령들을 내부적으로 조합한다" 뒤에 "(v2부터 분해 단계가 Step 1.5로 추가됨)" 한 줄 주석 추가.
- 나머지는 영향 없음 — team.md는 low-level primitive 문서이므로 분해 전략 설명 불필요.

### `.codex/prompts/tm.md`

- **Empty input 출력 예시**: `/tm --no-decompose "instruction"` 예시 한 줄 추가.
- **Parse arguments**: `--no-decompose` 플래그 항목 추가.
- **Workflow Step 1 이후**: decomposition 처리 단계 미러 (Step 1.5).

---

## 2. Before / After 예제 (기존 Example 1 사용)

### Before (v1 — `--no-decompose` 또는 현재 동작)

```
/tm "review Sources/Auth.swift for security and performance issues"

→ Dispatch (동일 instruction → 4명):
  INSTR = "review Sources/Auth.swift for security and performance issues"
  explorer, executor, reviewer, security 모두 동일 instruction 수신

→ [결론]  Auth.swift에 force-unwrap 3곳 + 평문 token 로깅 1곳이 즉시 수정 필요.
  [충돌]  executor: token 로깅은 DEBUG guard 있어 무시 가능 / security: Release 심볼 잔존 → security 채택.
  [다음]  security에 force-unwrap 3곳 패치 위임.
```

### After (v2 — 자동 분해, default)

```
/tm "review Sources/Auth.swift for security and performance issues"

→ Step 1.5 Auto-decompose → board.jsonl에 4개 sub-task 기록:
  T1 (affinity: security) : "Find security vulnerabilities and force-unwrap patterns in Auth.swift"
  T2 (affinity: executor) : "Profile Auth.swift call paths for performance hot spots"
  T3 (affinity: reviewer) : "Check code style, naming, and API clarity in Auth.swift"
  T4 (affinity: explorer) : "Map all callers of Auth.swift public API — return path:line"

→ Dispatch (서로 다른 sub-task → 4명):
  security ← T1, executor ← T2, reviewer ← T3, explorer ← T4

→ [결론]  보안 3건(T1) + 성능 1건(T2) + 가독성 2건(T3) 발견; 전체 커버리지 완성.
  [충돌]  reviewer: token 로깅 DEBUG guard 충분 / security: Release 바이너리 심볼 잔존 → security 채택.
  [다음]  security에 T1 결과 기반 force-unwrap 3곳 패치 위임.
```

**핵심 차이**: v1에서 4명이 동일 파일을 각자 관점으로 리뷰해 overlap 많음 → v2에서 4명이 서로 다른 측면을 전담해 coverage 극대화, overlap 최소화.

---

## 3. User-facing Migration Note (1단락)

> **v2 `/tm` 업그레이드 안내 —** `/tm "instruction"`은 이제 instruction을 역할별 N개 sub-task로 자동 분해한 후, 각 idle 에이전트에게 **서로 다른** sub-task를 위임합니다. 분해 결과는 board.jsonl에 기록되며 `tm-agent task list`로 확인할 수 있습니다. 기존처럼 모든 에이전트에게 **동일한** instruction을 보내고 싶다면(예: 아키텍처 의견 수집, 다수결 투표) `/tm --no-decompose "instruction"`을 사용하세요. `--timeout` / `--ensure` 플래그와 3줄 synthesis 형식(`[결론][충돌][다음]`)은 변경되지 않습니다. 다중 라운드 분해·정제가 필요하면 `/tm-op distribute` 또는 `/tm-op refine`을 권장합니다.

---

## 4. 사용자 멘탈 모델 변화

### 기존 (v1 — "같은 답 N개")

사용자는 `/tm`을 "N명의 전문가에게 **같은 질문**을 던져 관점 차이를 모으는" 브레인스토밍·다관점 투표 도구로 인식. 에이전트마다 동일 instruction을 보내므로:
- 결과 간 **내용 overlap이 많음** (각자 같은 버그를 발견)
- [충돌] = "같은 문제를 보는 해석 차이"
- 효과적 사용: 의견 수렴, 아키텍처 trade-off 논의, 투표 기반 결정

### 목표 (v2 — "다른 답 N개")

사용자는 `/tm`을 "하나의 목표를 **N개 하위 작업으로 분해**하여 전문가에게 분산 실행하는" 프로젝트 오케스트레이터로 인식. 각 에이전트가 다른 sub-task를 완수하므로:
- 결과 간 **overlap 최소, coverage 극대화**
- [충돌] = "다른 sub-task 결과 간 우선순위·범위 겹침 해소"
- 효과적 사용: 코드 리뷰(보안/성능/가독성 분담), 대규모 버그 분석, 멀티파트 설계

### 전환 마찰 지점 & 안내 전략

| 기존 사용 패턴 | v2 동작 | 권장 대응 |
|--------------|---------|----------|
| 아키텍처 의견 수집 ("monolith vs micro") | 각자 다른 sub-task → 의견 분산 불리 | `--no-decompose` 명시 |
| 코드 전체 리뷰 | 각자 다른 측면 담당 → coverage ↑ | 기본(decompose) 유지 |
| "3명이 같은 버그 보고" 중복 확인 | 분해로 중복 제거 | 기본(decompose) 유지 |
| `/tm-op tournament` 대체 시도 | 분해 후 vote 구조 필요 | `/tm-op tournament` 그대로 사용 |

**핵심 안내문**: "분석·실행 작업은 기본(decompose), 의견·투표 수집은 `--no-decompose`"
