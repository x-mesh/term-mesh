# 공통 부록 — 모든 에이전트 (universal addendum)

이 파일은 모든 역할 runbook 위에 자동으로 얹히는 공통 규칙이다.
`tm-agent runbook install --tool all` 실행 시 자동 배포된다.

---

## P0. Task lifecycle invariant — 절대 위반 금지

조사·분석·코드 변경·검증, 어떤 형태의 작업이든 **종료는 반드시 `tm-agent reply`** 로 한다.
leader가 작업의 종료를 알 수 있는 유일한 신호이기 때문이다.

### 종료 순서 (이 순서 고정)

1. **`tm-agent reply '<5-line header + summary>'`**
   - TM-PROTOCOL-v1: `STATUS / FILES / VERIFY / NEXT / FULL_REPORT` 헤더 5필드 의무.
   - reply 호출이 동시에 active task를 자동 완료 처리한다 (`Warning: no active task ...`이 떠도 reply alias는 정상 기록됨).
2. **(옵션) `tm-agent task done <task_id>`**
   - 명시적 task ID로 완료 보고가 필요할 때만. 일반적으로 1번이 대체한다.
3. **`tm-agent inbox` / `tm-agent msg list`**
   - 받은 후속 지시 확인은 **reply 이후**. reply 전에 inbox 작업을 하지 않는다.

### 금지 패턴 (anti-pattern)

- ❌ `tm-agent msg send` 한 줄만 보내고 종료 — leader 입장에서 task는 여전히 assigned/in-progress.
- ❌ 본문 출력만 하고 reply 누락 — agent terminal에 결과가 남아도 leader에는 전달 안 됨.
- ❌ `tm-agent reply` 전에 `inbox` 폴링 루프 — 새 task가 들어와도 이전 task가 종료되지 않은 채로 컨텍스트가 누적됨.

### 응답이 1000자 초과인 경우

`FULL_REPORT: ~/.term-mesh/results/<team>/<agent>-reply.md` 경로를 헤더에 명시.
소켓 전송은 1500자 truncate 되므로 풀 내용은 파일로만 보존된다.

---

## P0. Git 상태 변경 금지 — 절대 위반 금지 (모든 역할 공통)

**위임 task에 명시적 지시가 없으면 git 상태를 바꾸지 않는다.** 코드/문서 변경은 working tree에 그대로 두고, 커밋 시점·메시지·squash는 **leader/사용자가 결정**한다.

### 금지 (명시 요청이 없는 한)
- ❌ `git commit` / `git add -A` / `git add .` / `git push` / `git reset` / `git checkout -- <file>` / `git stash` 등 git 상태·인덱스·히스토리 변경
- ❌ "작업을 끝냈으니 커밋해 두자"는 자체 판단 — task가 "커밋하라"고 명시하지 않았으면 커밋하지 않는다
- ❌ 다른 에이전트/사용자의 변경 revert·overwrite

### 허용
- ✅ 변경을 working tree에 남기고 `tm-agent reply`의 FILES 필드에 경로만 보고 (uncommitted가 정상 — 위반 아님)
- ✅ task에 "커밋하라"/"commit" 명시가 있을 때만: 지시된 파일만 `git add <files>` 후 `git commit` (`git add -A` 금지, `--amend`/force-push/`--no-verify` 금지)
- ✅ 읽기 전용 git 조회(`git status`, `git diff`, `git log`)

> 이 규칙은 각 역할 runbook보다 우선한다. 과거 일부 runbook이 "reply 전 commit"을 요구했더라도 이 P0가 무효화한다.

---

## 참고

- 페르소나별 본문 포맷(예: explorer `path:line`, security `[SEVERITY][CWE]...`, reviewer `[P0-P3]...`)은 각 역할 runbook을 따른다.
- 공통 헤더 5필드는 **모든 페르소나가 동일**. 본문 포맷이 헤더 필드와 중복되면 같은 값을 그대로 채운다.
- `tm-agent runbook install --tool all` 은 이 `_common.md` 를 모든 도구(claude / codex / opencode 등) 프롬프트 디렉터리에 자동 배치한다. 수동 복사 불필요.
