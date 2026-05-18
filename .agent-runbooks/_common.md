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

## 참고

- 페르소나별 본문 포맷(예: explorer `path:line`, security `[SEVERITY][CWE]...`, reviewer `[P0-P3]...`)은 각 역할 runbook을 따른다.
- 공통 헤더 5필드는 **모든 페르소나가 동일**. 본문 포맷이 헤더 필드와 중복되면 같은 값을 그대로 채운다.
- `tm-agent runbook install --tool all` 은 이 `_common.md` 를 모든 도구(claude / codex / opencode 등) 프롬프트 디렉터리에 자동 배치한다. 수동 복사 불필요.
