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

If `$ARGUMENTS` is empty (`/team`만 입력), print this onboarding cheat sheet (do NOT run tm-agent status):

```
자주 쓰는 명령:

  /team status             지금 누가 무엇 중 (raw JSON)
  /team task list          진행 중 작업
  /team task clear         끝난 것 정리
  /team create 4           새 팀 4명
  /team delegate <a> "..." 1명에게 일 시키기
  /team destroy            팀 종료

한 줄로 모두 동원하려면: /tm "<instruction>"
전체 reference: .claude/commands/team.md
```

If user wanted raw status, instruct them to type `/team status` explicitly.

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
