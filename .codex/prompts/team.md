---
description: "term-mesh team primitive — route Codex leader operations through tm-agent"
---

# /team — term-mesh Team Management for Codex

User provided: $ARGUMENTS

You are running as a Codex leader inside term-mesh. All team operations must use `tm-agent`.

Do not use Codex sub-agents, native delegation, or any disconnected team state for term-mesh teams. The source of truth is the term-mesh daemon and `tm-agent`.

## Empty input

If `$ARGUMENTS` is empty, print this cheat sheet and stop:

```text
자주 쓰는 명령:

  /team status              지금 팀 상태
  /team task list           진행 중 작업
  /team task clear          끝난 태스크 정리
  /team create 4 --adopt    현재 Codex pane을 리더로 팀 생성
  /team attach reviewer     현재 workspace에 에이전트 추가
  /team delegate <a> "..."  1명에게 추적 가능한 일감 위임
  /team destroy             팀 종료

한 줄로 모두 동원하려면: /tm "instruction"
전략 오케스트레이션: /tm-op refine|review|debate|...
```

Do not run `tm-agent status` for empty input unless the user explicitly asks for status.

## Execution

For non-empty `$ARGUMENTS`, run:

```bash
tm-agent $ARGUMENTS
```

If `tm-agent` is unavailable in PATH, run:

```bash
./daemon/target/release/tm-agent $ARGUMENTS
```

Show the meaningful output to the user.

## Codex leader defaults

- To create a team where the current Codex pane is the leader, prefer:
  ```bash
  tm-agent create <N> --adopt
  ```
- To add agents into the current workspace without creating a separate team workspace:
  ```bash
  tm-agent attach <role> [--cli claude|codex|kiro|gemini] [--model <model>]
  ```
- To create Codex-backed worker panes:
  ```bash
  tm-agent create 3 --adopt --codex all
  ```

Use `--claude-leader` only when the leader pane should be Claude Code, not Codex.

## Low-level reference

```bash
tm-agent status
tm-agent list
tm-agent create 3 --adopt
tm-agent attach executor --cli codex
tm-agent detach executor
tm-agent delegate executor '<instruction>'
tm-agent send reviewer '<message>'
tm-agent broadcast '<message>'
tm-agent wait --timeout 120 --mode any
tm-agent collect --headers
tm-agent reports --summary
tm-agent task list
tm-agent task clear
tm-agent inbox
```

When delegating work, prefer `delegate` over `send` because it creates a trackable task and lets the leader wait, collect, and synthesize results.
