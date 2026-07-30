# 공통 부록 — 모든 에이전트 (universal addendum)

이 파일은 모든 역할 runbook 위에 자동으로 얹히는 공통 규칙이다.
`tm-agent runbook install --tool all` 실행 시 자동 배포된다.

---

## P0. Task lifecycle invariant — 절대 위반 금지

조사·분석·코드 변경·검증, 어떤 형태의 작업이든 **종료는 반드시 `tm-agent reply`** 로 한다.
leader가 작업의 종료를 알 수 있는 유일한 신호이기 때문이다.

### 종료 순서 (이 순서 고정)

1. **본문 전체를 하나의 따옴표 positional argument로 넘긴다** (heredoc 아님):

   ```text
   tm-agent reply 'STATUS: DONE
   FILES: none
   VERIFY: n/a
   NEXT: NONE
   FULL_REPORT: n/a

   <요약/본문>'
   ```

   - 첫 줄은 반드시 `STATUS: DONE`(또는 BLOCKED / NEEDS_REVIEW). TM-PROTOCOL-v1: `STATUS / FILES / VERIFY / NEXT / FULL_REPORT` 헤더 5필드 의무.
   - heredoc(`<<'EOF'`)·파이프도 동작하지만(stdin fallback), 위 arg 형식이 가장 안전하다.
   - reply 호출이 동시에 active task를 자동 완료 처리한다. stateless watcher(`watcher` role)는 닫을 task가 없으므로 `--task-id` 없이 호출하면 "no active task" 경고 없이 정상 종료한다(verdict는 alias 파일로 전달). 그 외 역할은 active task가 자동 선택되며, 후보가 여럿이라는 경고가 뜨면 `--task-id <id>`로 지정한다.
2. **(옵션) `tm-agent task done <task_id>`**
   - 명시적 task ID로 완료 보고가 필요할 때만. 일반적으로 1번이 대체한다.
3. **`tm-agent inbox` / `tm-agent msg list`**
   - 받은 후속 지시 확인은 **reply 이후**. reply 전에 inbox 작업을 하지 않는다.

### 메시지·inbox 호출이 실패할 때

`tm-agent reply`가 **유일하게 보장된 전달 경로**다. `msg send` / `inbox` / `task *`는
`no_app`·connection reset·non-zero exit로 실패할 수 있다 — **피어 호스트에서 실행 중인
에이전트에는 앱으로 되돌아오는 인가된 경로가 없다.**

실패하면:

- ❌ 재시도 루프를 돌지 않는다. 몇 번을 불러도 결과는 같다.
- ❌ BLOCKED로 보고하지 않는다. 작업이 막힌 게 아니다.
- ✅ 전하려던 내용을 **reply 본문에 담고** 하던 일을 계속한다.

### 금지 패턴 (anti-pattern)

- ❌ `tm-agent msg send` 한 줄만 보내고 종료 — leader 입장에서 task는 여전히 assigned/in-progress.
- ❌ 본문 출력만 하고 reply 누락 — agent terminal에 결과가 남아도 leader에는 전달 안 됨.
- ❌ `tm-agent reply` 전에 `inbox` 폴링 루프 — 새 task가 들어와도 이전 task가 종료되지 않은 채로 컨텍스트가 누적됨.

### 응답이 1000자 초과인 경우

소켓 전송은 1500자 truncate 되므로 상세는 파일로 남긴다. **먼저 고유 파일을 직접 쓰고**,
그 경로를 헤더에 명시한다:

```
~/.term-mesh/results/<team>/<task_id>-full.md   # 권장 이름
FULL_REPORT: <위에서 쓴 그 경로>
```

- ❌ `<agent>-reply.md` / `<agent>-<instance>-reply.md` / `<task_id>.md` 를 FULL_REPORT로 쓰지 말 것.
  이 셋은 `tm-agent reply`가 **제출 내용으로 통째 덮어쓰는 envelope 보존본**이다(append 아님).
  여기에 상세를 먼저 써 두면 뒤이은 reply가 그대로 지운다 — 실제로 ADR 본문이 이렇게 유실됐다.
- 상세 파일이 따로 없으면 `FULL_REPORT: n/a`.

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
