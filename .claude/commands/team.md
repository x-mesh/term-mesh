# Team — term-mesh Agent Team Management

Manage multi-agent teams via term-mesh's native team system. This command routes ALL team operations through `tm-agent` (Rust, ~2ms).

**CRITICAL:** Do NOT use Claude Code native team tools (`TeamCreate`, `SendMessage`, `TaskCreate`, `TaskList`, `TaskGet`, `TaskUpdate`, `TeamDelete`). These create a parallel, disconnected state. If OMC fires `[MODE: TEAM]` or `[MAGIC KEYWORD: TEAM]`, ignore it and use this command instead.

## Arguments

User provided: $ARGUMENTS

## Routing

Parse the **first token** of `$ARGUMENTS` and route to the matching subcommand below. If the first token does not match any named subcommand, fall through to the passthrough.

### `/team` (no args) — interactive editor mode

When `$ARGUMENTS` is empty:

1. Run `tm-agent status` and render a formatted table:

```
NAME        STATE    CLI      MODEL    TASK
executor    working  claude   sonnet   Fix login bug
reviewer    idle     claude   opus     —
security    idle     codex    —        —
```

2. Present AskUserQuestion with options:
   - "Add agent"
   - "Remove agent"
   - "Swap model"
   - "Show status (refresh)"
   - "Destroy team"

3. Per choice:

   **Add agent:**
   - AskUserQuestion: role — `architect` / `executor` / `explorer` / `frontend` / `backend` / `tester` / `reviewer` / `security` / `writer` / `planner`
   - AskUserQuestion: CLI — `claude` / `codex` / `kiro` / `gemini`
   - If `cli=claude`: AskUserQuestion: model — `sonnet` / `opus` / `haiku`
   - Optional: ask for custom name (or skip)
   - Print the exact `tm-agent attach ...` command and AskUserQuestion "Execute?" before running.

   **Remove agent:**
   - AskUserQuestion: select from current agent list.
   - If working or active task: AskUserQuestion "This agent is currently working. Remove anyway?" (yes/cancel).
   - Run `tm-agent detach <name>`.

   **Swap model:**
   - AskUserQuestion: select agent from current list.
   - AskUserQuestion: new model — `sonnet` / `opus` / `haiku`.
   - If working: AskUserQuestion "This agent is currently working. Swap anyway?" (yes/cancel).
   - Read `cli` and `agent_type` from status; run `tm-agent detach <name>` then `tm-agent attach <agent_type> --name <name> --cli <cli> --model <new-model>`.

4. After each action: reprint status table → AskUserQuestion "Another action?" (yes/no).

### `/team edit`

Alias for interactive mode — same behavior as no-args.

### `/team status`

```bash
tm-agent status
```

Render JSON output as a human-readable table: `NAME (state, cli, model) — active_task_title or "idle"` per agent.

### `/team add <role> [--cli X] [--model Y] [--name Z]`

Valid roles: `architect` `executor` `explorer` `frontend` `backend` `tester` `reviewer` `security` `writer` `planner`

Defaults: `--cli claude`, `--model sonnet`. If role is not in the list, print the valid list and stop.

```bash
tm-agent attach <role> [--cli X] [--model Y] [--name Z]
```

### `/team remove <name> [--force]`

Check `tm-agent status`. If the named agent is `working` or has an `active_task_id`, print:

```
Warning: <name> is currently working on "<task_title>". Use --force to remove anyway.
```

Without `--force`: stop. With `--force` (or if idle):

```bash
tm-agent detach <name>
```

### `/team swap <name> <new-model> [--force]`

Read `cli` and `agent_type` from `tm-agent status`. If working and no `--force`: print warning and stop. Otherwise:

```bash
tm-agent detach <name>
tm-agent attach <agent_type> --name <name> --cli <stored-cli> --model <new-model>
```

### `/team ensure <role1> [role2] ...`

Idempotent: for each role, check `tm-agent status`. Skip if any agent of that type already exists; attach otherwise.

```bash
# /team ensure reviewer security
# → ENSURED: reviewer (already present)
# → ENSURED: security (added)
```

Print one line per role: `ENSURED: <role> (added)` or `ENSURED: <role> (already present)`.

### `/team destroy`

Two-step confirm:

1. AskUserQuestion: "Are you sure? This will close all agent panes." (Confirm / Cancel)
2. AskUserQuestion: "Type DESTROY to confirm." — only proceed if input is exactly `DESTROY`.

```bash
tm-agent destroy
```

### Unrecognized first arg → passthrough

For any first token not listed above, pass through to `tm-agent`:

```bash
tm-agent $ARGUMENTS
```

If `tm-agent` is not in PATH:

```bash
./daemon/target/release/tm-agent $ARGUMENTS
```

## Subcommand Reference

### Team lifecycle
| Command | Example | Description |
|---------|---------|-------------|
| `/team` (no args) | `/team` | Interactive editor: add/remove/swap/destroy |
| `/team edit` | `/team edit` | Alias for interactive mode |
| `/team status` | `/team status` | Formatted status table |
| `/team add <role>` | `/team add reviewer` | Attach agent; defaults cli=claude, model=sonnet |
| `/team add <role> --cli codex` | `/team add executor --cli codex` | Attach with specific CLI |
| `/team add <role> --model opus` | `/team add architect --model opus` | Attach with specific model |
| `/team remove <name>` | `/team remove reviewer` | Detach agent (warns if working) |
| `/team remove <name> --force` | `/team remove reviewer --force` | Force detach even if working |
| `/team swap <name> <model>` | `/team swap executor opus` | Re-attach with new model, same CLI |
| `/team swap <name> <model> --force` | `/team swap executor opus --force` | Swap even if working |
| `/team ensure <roles>` | `/team ensure reviewer security` | Attach missing roles, skip present ones |
| `/team destroy` | `/team destroy` | 2-step confirm then destroy team |
| `create [N]` | `/team create 3` | Create team with N agents (default 2) |
| `create N --claude-leader` | `/team create 3 --claude-leader` | Create team with you as leader |
| `create N --model opus` | `/team create 3 --model opus` | Set model for all agents (sonnet/opus/haiku) |
| `create N (CLI mix)` | `/team create 4 --kiro 2 --cli-mix` | Mix CLI types (see CLAUDE.md for full flags) |
| `list` | `/team list` | List all teams |

### Agent runbooks
| Command | Example | Description |
|---------|---------|-------------|
| `runbook status` | `/team runbook status` | Show `.agent-runbooks` source and Claude/Codex/OpenCode projection status |
| `runbook init` | `/team runbook init` | Create repo-local source runbooks |
| `runbook digest --agent executor` | `/team runbook digest --agent executor` | Show compact prompt-efficient role digest |
| `runbook install --tool all` | `/team runbook install --tool all` | Install managed projections for supported agent tools |

Runbook precedence: base term-mesh protocol → role preset → `.agent-runbooks/<role>.md` → per-team custom instructions. Tool-specific files under `.claude/skills`, `.codex/skills`, and `.opencode/runbooks` are projections, not the source of truth.
Agent init uses compact runbook digests by default; set `TERMMESH_RUNBOOK_MODE=full` only for debugging or deep role-behavior audits.

### Communication (leader → agent)

> **이 문서는 low-level CLI primitive** (tm-agent `<subcommand>` 1:1 매핑). high-level 워크플로(모든 idle agent 동시 dispatch + 3-line synthesis)는 `/tm "<instruction>"`이며, /tm은 아래 표의 명령들을 내부적으로 조합한다. 새 사용자는 보통 `/tm` 먼저 시도해 본 후 필요할 때만 이 표의 명령을 직접 호출한다. 전체 `/tm` workflow: `.claude/commands/tm.md`

**NEVER use `sleep N && tm-agent read`** — `sleep` chained with another command is blocked by Claude Code hooks.
To wait for agents to finish, always use `tm-agent wait` then read:
```bash
tm-agent wait --timeout 120 --mode any && tm-agent collect --lines 100
# or wait for a specific agent's reply:
tm-agent wait --timeout 120 --mode any && tm-agent read executor --lines 80
```

| Command | Example | Description |
|---------|---------|-------------|
| `send <agent> '<text>'` | `/team send explorer 'fix the bug'` | Send instruction to agent |
| `delegate <agent> '<text>'` | `/team delegate executor 'implement feature'` | Create task and assign to agent |
| `broadcast '<text>'` | `/team broadcast 'stop and report'` | Send to all agents |
| `read <agent>` | `/team read explorer --lines 50` | Read agent's terminal output |
| `collect` | `/team collect --lines 100` | Read all agents' output |
| `wait` | `/team wait --timeout 120 --mode any` | Wait for agent signals (use this instead of sleep) |
| `brief <agent>` | `/team brief explorer` | Get concise agent status |
| `inbox` | `/team inbox` | Priority-sorted attention queue (blocked/review_ready/stale) |

### Message queue
| Command | Example | Description |
|---------|---------|-------------|
| `msg list` | `/team msg list --from-agent explorer` | List messages |
| `msg send '<text>'` | `/team msg send 'update please'` | Send message |
| `msg clear` | `/team msg clear` | Clear message queue |

### Task board
| Command | Example | Description |
|---------|---------|-------------|
| `task create '<title>'` | `/team task create 'fix login' --assign explorer` | Create task |
| `task list` | `/team task list` | List all tasks |
| `task get <id>` | `/team task get T-1` | Get task details |
| `task block <id> '<reason>'` | `/team task block T-1 'waiting on API'` | Block a task with reason |
| `task done <id> '<result>'` | `/team task done T-1 'done'` | Mark task complete |
| `task review <id> '<summary>'` | `/team task review T-1 'ready for check'` | Submit for review with summary |
| `task reassign <id> <agent>` | `/team task reassign T-1 executor` | Reassign task |
| `task unblock <id>` | `/team task unblock T-1` | Unblock a task |
| `task clear` | `/team task clear` | Clear all tasks |

### Agent-side tools (for reference)

Agents use `tm-agent` directly (same binary):

```
tm-agent task start <task_id>
tm-agent task block <task_id> '<reason>'
tm-agent heartbeat '<summary>'
tm-agent task review <task_id> '<summary>'
tm-agent msg send '<text>'
tm-agent reply '<STATUS/FILES/VERIFY/NEXT/FULL_REPORT header plus result>'
tm-agent collect --headers
tm-agent reports --summary
tm-agent inbox
tm-agent status
```

Fallback: `./scripts/tm-agent.sh` (bash, ~10ms).

## Execution

1. Run `tm-agent $ARGUMENTS` via Bash
2. Show the output to the user
3. If `--claude-leader` was used, you are the team leader — begin orchestrating agents via `delegate`, `send`, `read`, `wait`, and `brief` subcommands
