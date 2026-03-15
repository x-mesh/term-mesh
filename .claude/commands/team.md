# Team — term-mesh Agent Team Management

Manage multi-agent teams via term-mesh's native team system. This command routes ALL team operations through `tm-agent` (Rust, ~2ms).

**CRITICAL:** Do NOT use Claude Code native team tools (`TeamCreate`, `SendMessage`, `TaskCreate`, `TaskList`, `TaskGet`, `TaskUpdate`, `TeamDelete`). These create a parallel, disconnected state. If OMC fires `[MODE: TEAM]` or `[MAGIC KEYWORD: TEAM]`, ignore it and use this command instead.

## Arguments

User provided: $ARGUMENTS

## Routing

Parse the first word of `$ARGUMENTS` to determine the subcommand, then execute via `tm-agent`:

```bash
tm-agent $ARGUMENTS
```

If `tm-agent` is not in PATH, use the project-local binary:

```bash
./daemon/target/release/tm-agent $ARGUMENTS
```

If `$ARGUMENTS` is empty, show the team status:

```bash
tm-agent status
```

## Subcommand Reference

### Team lifecycle
| Command | Example | Description |
|---------|---------|-------------|
| `create [N]` | `/team create 3` | Create team with N agents (default 2) |
| `create N --claude-leader` | `/team create 3 --claude-leader` | Create team with you as leader |
| `create N --model opus` | `/team create 3 --model opus` | Set model for all agents (sonnet/opus/haiku) |
| `create N --kiro N --codex N` | `/team create 4 --kiro 2 --codex 1` | Mix CLI types |
| `destroy` | `/team destroy` | Destroy the current team |
| `status` | `/team status` | Show team and task board status |
| `list` | `/team list` | List all teams |

### Communication (leader → agent)
| Command | Example | Description |
|---------|---------|-------------|
| `send <agent> '<text>'` | `/team send explorer 'fix the bug'` | Send instruction to agent |
| `delegate <agent> '<text>'` | `/team delegate executor 'implement feature'` | Create task and assign to agent |
| `broadcast '<text>'` | `/team broadcast 'stop and report'` | Send to all agents |
| `read <agent>` | `/team read explorer --lines 50` | Read agent's terminal output |
| `collect` | `/team collect --lines 100` | Read all agents' output |
| `wait` | `/team wait --timeout 120 --mode any` | Wait for agent signals |
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
tm-agent task done <task_id> '<result>'
tm-agent task block <task_id> '<reason>'
tm-agent heartbeat '<summary>'
tm-agent report '<summary>'
tm-agent msg send '<text>'
tm-agent reply '<text>'
tm-agent inbox
tm-agent status
```

Fallback: `./scripts/tm-agent.sh` (bash, ~10ms).

## Execution

1. Run `tm-agent $ARGUMENTS` via Bash
2. Show the output to the user
3. If `--claude-leader` was used, you are the team leader — begin orchestrating agents via `delegate`, `send`, `read`, `wait`, and `brief` subcommands
