# ADR: No-Commit Policy — 전 역할 영구 적용 설계

**Status:** PROPOSED  
**Date:** 2026-05-20  
**Scope:** Agent runbook 계층 구조, digest 생성, 정책 전파

---

## Context

### 현재 상태

1. **executor.md** Operating Rules에 no-commit 정책 명시됨 (2026-05-20)
   - "명시 지시가 없으면 git 상태 변경 금지"
   - "변경은 working tree에 남기고 leader가 커밋 시점 결정"
   - executor 역할만 digest에 노출

2. **_common.md** P0 섹션에 공통 규칙 추가됨
   - "모든 역할에 적용되는 universal invariant"
   - P0. Task lifecycle (reply 강제)
   - P0. Git 상태 변경 금지 (모든 역할 공통)
   - 각 역할 runbook보다 우선 (line 50)
   - **문제:** compact digest 생성기에 미포함 → 다른 역할의 digest 출력 시 no-commit 누락

3. **계층 구조의 불일치**
   - executor.md: Operating Rules에 명시 (영구, visible in digest)
   - reviewer/frontend/backend/etc: 명시 없음 (일관성 부족)
   - _common.md: 모든 역할을 위해 작성되었으나, digest 생성기가 이를 포함하지 않음

4. **파일 관리 취약성**
   - `tm-agent runbook install --tool all`이 역할 .md를 템플릿으로 리셋하는 메커니즘
   - 수동 수정이 설치 시 덮어씌워질 가능성

---

## Decision

### 선택 옵션: 3-계층 hybrid 접근

**No-commit 정책을 3개 계층에서 다음과 같이 분담한다:**

| 계층 | 책임 | 내용 |
|------|------|------|
| **L1: _common.md (Universal)** | 모든 역할이 준수할 명령적 규칙 | P0. Git 상태 변경 금지: "명시 지시 없으면 git add/commit/push 금지. 예외: task에 'commit'/'커밋하라' 명시" |
| **L2: 역할별 .md Operating Rules** | 역할이 해당 규칙을 "인식"하고 요약 | "이 역할은 working tree 변경만 수행; git 관리는 leader 책임 (자세히는 _common.md P0 참조)" |
| **L3: digest 생성기 (tm-agent runbook digest)** | L1 + L2 축약판을 MUST 섹션에 노출 | _common.md P0 항목들을 `MUST: ...` 라인으로 변환하여 모든 역할 digest 앞에 자동 출력 |

### 각 계층의 역할

#### L1: _common.md 확장 (현재 완료된 상태 유지)
- 현재 이미 P0 섹션 2개 (Task lifecycle, Git 상태 변경)가 있음
- **유지:** "명시 지시가 없으면 git 상태 바꾸지 않는다" + 예외 명시

#### L2: 역할별 .md Operating Rules (일관성 개선)

모든 역할 (executor, reviewer, frontend, backend, architect, security, watcher, etc.)의 Operating Rules 첫 항목으로 다음을 추가:

```markdown
## Operating Rules

- 이 역할은 working tree에만 변경을 기록하며, git 커밋·푸시·상태 변경은 수행하지 않는다.
  예외: task에 "commit", "커밋하라", "git add <files>" 등 명시가 있을 때만 지시된 파일을 add + commit.
  자세한 규칙은 _common.md P0 참조.
- [기존 규칙들...]
```

**대상 파일 (모든 역할 runbook):**
- executor.md (이미 있음 — 검증 및 일관성 다듬기)
- reviewer.md, frontend.md, backend.md, architect.md, security.md, watcher.md
- 기타 모든 역할 (총 26개 .md)

#### L3: digest 생성기 수정 (tm-agent runbook digest command)

`tm-agent runbook digest [--agent <role>]` 명령이 각 역할 digest 생성 시:

**전:** executor digest 출력 예시
```
# Executor Digest
When to use: ...
Operating Rules:
- Own the files...
- Do not revert...
```

**후:** 모든 역할 digest 헤더에 MUST 섹션 추가
```
# <Role> Digest

## MUST (mandatory for all agents)
- **No git changes without explicit task directive.** If task says "commit", "커밋하라", or names git commands, then `git add <files>` + `git commit` only for those files (no `git add -A`, `--amend`, force-push, `--no-verify`). Otherwise leave changes in working tree; leader decides commit timing.
- **Always close with `tm-agent reply`** in the prescribed header format (STATUS / FILES / VERIFY / NEXT / FULL_REPORT).
- Details: see _common.md P0.

When to use: ...
Operating Rules:
- [Role-specific rules...]
```

**구현:**
- daemon 이진리 또는 Go/Rust 코드 추가: _common.md P0 섹션 파싱 → MUST 라인 렌더링
- 모든 역할 digest 생성 시 자동 prepend
- _common.md 수정하면 모든 digest가 자동 반영 (DRY)

---

## Rationale

### 왜 3계층 hybrid인가?

| 옵션 | 장점 | 단점 | 선택 |
|------|------|------|------|
| **역할별 .md Operating Rules만** | 각 역할이 독립적으로 완전 | 26개 파일 동기화 필요, 중복, 파일 수정 취약 | ❌ |
| **_common.md P0만** | DRY, 중앙 관리, 수정 1곳 | digest 생성기가 P0를 읽지 않으면 에이전트가 모른다 | ❌ (현재 상황) |
| **tmesh managed 템플릿 (바이너리)** | 가장 안전, 설치 후 덮어쓰기 불가 | 매번 binary 업데이트 필요, 오프라인/로컬 git 환경에서 제약 | ❌ |
| **L1(_common) + L2(역할별 요약) + L3(digest prepend)** | 중앙 source(_common), 역할별 인식, 모든 agent가 digest로 노출 | 3곳 동기화이지만 각 계층의 역할 명확, digest 생성기가 자동화 | ✅ |

### 왜 예외를 "명시 지시"로 정의하는가?

**"명시 지시"의 정의:**
- Task에 "commit", "커밋하라", "git add <files>" 명시
- Task GOAL 섹션에 "commit with message: ..." 기재
- 또는 사용자가 reply 이후 message로 "commit the above changes"

**이것이 필요한 이유:**
- leader/사용자가 절차를 제어할 수 있다 (squash/amend/rebase 시점을 leader가 선택)
- 과도한 auto-commit 방지 (executor.md 과거 버그: runway 지시로 무단 commit)
- 긴급 상황 (merge 직전, release 직전)에 leader가 개입 가능

---

## Consequences

### 즉효 (Immediate, 임시 조치)

1. **executor.md 검증 + 모든 역할 .md 추가** (~1시간)
   - executor.md 현재 텍스트 검증 (P0와 일관성)
   - reviewer.md, frontend.md, backend.md, architect.md, security.md, watcher.md부터 순차 추가 (Operating Rules 첫 항목)
   - 나머지 18개 역할 .md 추가 (자동화 스크립트 고려)
   - **효과:** 에이전트가 각 runbook을 읽을 때 no-commit이 명시됨

2. **digest 생성기 임시 수정** (~30분, Go/Rust)
   - _common.md P0 첫 2개 섹션 → MUST 3라인으로 축약
   - digest 출력 헤더 앞에 자동 prepend
   - **효과:** `tm-agent runbook digest executor` 실행 시 no-commit과 reply 강제가 digest 맨 앞에 표시됨

**즉효 후 상태:**
- ✅ executor.md, reviewer.md, ..., writer.md 모두 Operating Rules에 no-commit 명시
- ✅ digest 출력이 MUST 섹션 포함 → 에이전트가 초기화 시 no-commit 인식
- ✅ _common.md 수정하면 digest가 자동 반영

### 영구 (Durable, 정책 안정화)

3. **파일 관리 정책 문서화** (~30분)
   - `.agent-runbooks/README.md` 확장: "계층 구조" 섹션 추가
     ```
     # 계층 구조 (Layer Structure)
     
     ## L1: _common.md (Universal)
     모든 역할이 준수할 P0 규칙. 수정 시 모든 digest 자동 반영.
     
     ## L2: 역할별 .md Operating Rules
     각 역할이 _common.md 규칙을 "인식"하는 인트로. 
     "자세히는 _common.md 참조" 스타일로 동기화 유지.
     
     ## L3: tm-agent runbook digest
     L1 + L2를 에이전트에게 노출하는 compact 형식.
     ```
   
   - `tm-agent runbook install --tool all` 보호 (선택적)
     - 문서: "역할 .md의 Operating Rules 처음 3라인은 템플릿; 이후 라인은 역할별 커스텀"
     - 또는: install 시 `--preserve-rules` 옵션 추가 (기존 Operating Rules 유지)

4. **정책 회귀 방지** (~자동)
   - CI: `.agent-runbooks/*/Operating Rules` 섹션에 "git" 키워드 포함 검증
     ```bash
     for f in .agent-runbooks/*.md; do
       grep -q "^## Operating Rules" "$f" && \
       grep -q -E "(git|working tree)" "$f" || \
       echo "❌ Missing no-commit in $f"
     done
     ```

**영구 후 상태:**
- ✅ 정책이 계층별로 명확히 문서화됨
- ✅ 실수로 no-commit을 빠뜨린 역할 .md가 있으면 CI가 탐지
- ✅ _common.md가 유일한 source of truth
- ✅ executor 무단 auto-commit 같은 회귀 방지

---

## Implementation Plan

### Phase 1: 즉효 (Today, ~1.5시간)

```bash
# Step 1: 모든 역할 .md 의 Operating Rules 수정
# (26개 파일 중 executor.md 제외하고 25개 추가)

# Step 2: digest 생성기 수정 (Go/Rust)
# _common.md P0 → MUST 항목 자동 변환

# Step 3: 검증
tm-agent runbook digest executor    # MUST 섹션 포함 확인
tm-agent runbook digest reviewer    # MUST 섹션 포함 확인
tm-agent runbook digest frontend    # MUST 섹션 포함 확인
```

**최소 변경 commit:**
- `.agent-runbooks/*.md` — Operating Rules 첫 항목 추가 (모든 파일)
- `cmd/tm-agent/runbook_digest.go` (또는 해당 binary source) — MUST 항목 prepend 로직

### Phase 2: 영구 (Tomorrow, ~1시간)

```bash
# Step 1: README.md 계층 구조 섹션 추가
# Step 2: CI 회귀 검증 추가 (.github/workflows/lint.yml)
# Step 3: CLAUDE.md 또는 docs 업데이트 (정책 문서화)
```

---

## Backwards Compatibility

- ✅ _common.md P0는 이미 모든 기존 runbook보다 우선 (문서 명시)
- ✅ digest 수정은 read-only (기존 task 동작 변경 없음)
- ✅ 역할 .md Operating Rules 추가는 역할별 runbook 로직 변경 없음 (인식만 향상)
- ⚠️ 과거에 "reply 전 commit" 지시를 받은 agent: 이번 정책으로 무효화, 명시적 "commit" 지시 필요

---

## Summary

| 항목 | 결정 |
|------|------|
| **정책 위치** | L1: _common.md (source) + L2: 역할별 .md (인식) + L3: digest (노출) |
| **예외 정의** | Task에 "commit", "커밋하라" 명시가 있을 때만 |
| **즉효 조치** | 역할별 .md Operating Rules + digest MUST 항목 (~1.5시간) |
| **영구 조치** | 계층 구조 문서화 + CI 회귀 검증 (~1시간) |
| **호환성** | ✅ _common.md P0가 기존 규칙을 무효화하므로 일관성 확보 |

**결과:**
- 임시: executor.md 수정된 즉시 적용 (완료 상태)
- 영구: 모든 역할 26개 .md + digest 생성기 정비로 재발 방지
- 예외: "명시 지시" 규칙으로 leader 개입 가능성 유지
