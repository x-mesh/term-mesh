---
description: "term-mesh team primitive — route Codex leader operations through tm-agent"
---

# /team — term-mesh Team Management for Codex

User provided: $ARGUMENTS

You are running as a Codex leader inside term-mesh. All team operations must use `tm-agent`.

Do not use Codex sub-agents, native delegation, or any disconnected team state for term-mesh teams. The source of truth is the term-mesh daemon and `tm-agent`.

## Empty input

If `$ARGUMENTS` is empty, run `tm-agent status`, render a formatted table (NAME / STATE / CLI / MODEL / TASK), then print:

```text
자주 쓰는 명령:

  /team status              지금 팀 상태 (테이블)
  /team add reviewer        reviewer 추가 (claude/sonnet 기본)
  /team add executor --model opus  opus 모델로 executor 추가
  /team add reviewer --cli codex   codex-backed reviewer 추가
  /team remove writer       writer 제거
  /team recycle reviewer    idle/stopped worker context 비우기
  /team swap executor opus  executor 모델 교체
  /team ensure reviewer security  없는 role만 추가
  /team destroy             2단계 확인 후 팀 종료
  /team task list           진행 중 작업

한 줄로 모두 동원하려면: /tm "instruction"
역할 자동 보충: /tm --ensure reviewer,security "instruction"
전략 오케스트레이션: /tm-op refine|review|debate|...
```

Do not run additional `tm-agent` commands for empty input unless the user explicitly asks for status.

## Subcommand routing

Parse the first token of `$ARGUMENTS`:

### `add <role> [--cli X] [--model Y] [--name Z]`

Valid roles: `architect` `executor` `explorer` `frontend` `backend` `tester` `reviewer` `security` `writer` `planner`

Defaults: `--cli claude`, `--model sonnet`. Works for headless and GUI teams. Rejects duplicate name within the team. Run:

```bash
tm-agent add <role> [--cli X] [--model Y] [--name Z]
```

### `remove <name> [--force]`

Team-name–scoped remove (does NOT require TERMMESH_WORKSPACE_ID/PANEL_ID). This is distinct from `tm-agent detach` which is workspace-adopt scoped. `--force` defaults to true.

Check `tm-agent status`. If working and no `--force`, print:

```
Warning: <name> is currently working. Use --force to remove anyway.
```

Otherwise run:

```bash
tm-agent remove <name> [--force]
```

### `recycle <name> [--force]`

Recycle an agent pane after its task state has been captured. This is a guarded
hard restart for context hygiene: the pane transcript is discarded, while durable
state remains in the task board and `~/.term-mesh/results/`.

Run:

```bash
tm-agent recycle <name> [--force]
```

Without `--force`, this rejects agents with active non-terminal tasks. For long
active work, ask the agent to checkpoint first with `tm-agent heartbeat`,
`tm-agent task block`, `tm-agent task review`, or `tm-agent reply`. Use
`tm-agent restart <name> --hard` only as the lower-level recovery escape hatch.

### `swap <name> <new-model> [--force]`

Read `cli` and `agent_type` from `tm-agent status`. If working and no `--force`, warn and stop. Otherwise:

```bash
tm-agent detach <name>
tm-agent attach <agent_type> --name <name> --cli <stored-cli> --model <new-model>
```

### `ensure <role1> [role2] ...`

For each role, check `tm-agent status`. Skip if already present; attach otherwise. Print one line per role:

```
ENSURED: <role> (added)
ENSURED: <role> (already present)
```

### `destroy`

Two-step confirm: (1) "Are you sure? This will close all agent panes." (2) "Type DESTROY to confirm." Only if exactly `DESTROY`:

```bash
tm-agent destroy
```

### `status`

```bash
tm-agent status
```

Render as a human-readable table: `NAME (state, cli, model) — active_task_title or "idle"` per agent.

### `edit` or no args (interactive)

Show the formatted status table, then ask the user which action to take: Add / Remove / Swap / Ensure roles / Refresh / Destroy. Execute per the subcommand logic above. After each action, reprint the table and ask "Another action?".

For **Ensure roles**: prompt the user for a comma-separated list of roles (or present the 10 valid roles as a multi-select). For each role, check `tm-agent status`; if missing run `tm-agent attach <role>`; else skip. Print `ENSURED: <role> (added)` or `ENSURED: <role> (already present)` per entry.

### Any other first token → passthrough

```bash
tm-agent $ARGUMENTS
```

If `tm-agent` is unavailable in PATH:

```bash
./daemon/target/release/tm-agent $ARGUMENTS
```

## Codex leader defaults

- To create a team where the current Codex pane is the leader, prefer:
  ```bash
  tm-agent create <N> --adopt
  ```
- To add agents into the current workspace without creating a separate team workspace:
  ```bash
  tm-agent attach <role> [--cli claude|codex|kiro|gemini] [--model <model>]
  ```
- To create Codex-backed worker panes, use CLI mix count flags (see CLAUDE.md):
  ```bash
  tm-agent create 3 --adopt  # add --kiro N / CLI-count flags to mix CLI types
  ```

Use `--claude-leader` only when the leader pane should be Claude Code, not Codex.

## Low-level reference

```bash
tm-agent status
tm-agent list
tm-agent create 3 --adopt
tm-agent add reviewer                       # team-scoped; works for GUI + headless teams
tm-agent remove reviewer                    # team-scoped counterpart of add
tm-agent recycle reviewer                   # guarded hard restart; drops accumulated worker context
tm-agent attach executor --cli codex        # workspace-adopt scoped (creates ws-* team)
tm-agent detach executor                    # workspace-adopt scoped
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
