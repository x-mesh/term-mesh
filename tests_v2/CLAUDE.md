# term-mesh socket E2E tests (v2)

이 디렉터리는 **신규 socket e2e 테스트의 작성 위치**다(v2 JSON 프로토콜, UUID handle).

작성·실행·판단 기준은 단일 소스인 **[`../tests/CLAUDE.md`](../tests/CLAUDE.md)** 를 따른다.
요약:
- 새 테스트는 여기(`tests_v2/`)에, v2 클라이언트(`tests_v2/termmesh.py`)로.
- VM에서만 실행: `ssh term-mesh-vm '... ./scripts/run-tests-v2.sh'` (호스트 실행 금지).
- 표준 구조·검증 규약·flaky 처리·`cmux` 잔재 금지는 `../tests/CLAUDE.md` 참조.
