# Team Up — On-the-fly 팀 생성

현재 터미널을 리더로 승격하고 에이전트 팀을 즉시 생성합니다. 기존 대화 컨텍스트를 100% 유지하면서 팀을 구성할 수 있습니다.

## Arguments

User provided: $ARGUMENTS

## Usage

```
/team-up [COUNT] [OPTIONS]
/team-up 3
/team-up 4 --model opus
/team-up 3 --preset code-review
/team-up 2 --kiro 1 --codex 1
```

- **COUNT** — 에이전트 수 (기본: 2)
- **--model MODEL** — 에이전트 모델 (sonnet/opus/haiku, 기본: sonnet)
- **--preset NAME** — 팀 프리셋 사용 (e.g. code-review, debug, full-stack)
- **--kiro N / --codex N / --gemini N** — CLI 타입 혼합 구성
- **--roles 'role1,role2,...'** — 에이전트 역할 지정

## Execution

### Step 1: 팀 생성

Parse `$ARGUMENTS` to extract count and options. Default count is 2 if not specified.

```bash
tm-agent create $ARGUMENTS --adopt
```

If `tm-agent` is not in PATH, use the project-local binary:

```bash
./daemon/target/release/tm-agent create $ARGUMENTS --adopt
```

The `--adopt` flag tells term-mesh to:
- Skip creating a new leader pane (reuse the current terminal)
- Register this terminal as the leader
- Create agent panes in a separate workspace

### Step 2: 팀 상태 확인

```bash
tm-agent status
```

Verify that agents are spawned and ready.

### Step 3: 리더로서 팀 지휘 시작

You are now the **team leader**. Your current conversation context is fully preserved. Use the following commands to orchestrate your agents:

**CRITICAL:** Do NOT use Claude Code native team tools (`TeamCreate`, `SendMessage`, `TaskCreate`, etc.). Use `tm-agent` exclusively.

#### Task management
| Command | Description |
|---------|-------------|
| `tm-agent delegate <agent> '<instruction>'` | Create task and assign to agent |
| `tm-agent task create '<title>' --assign <agent>` | Create task with assignment |
| `tm-agent task list` | View all tasks |
| `tm-agent task get <id>` | Get task details |

#### Communication
| Command | Description |
|---------|-------------|
| `tm-agent send <agent> '<text>'` | Send instruction to agent |
| `tm-agent broadcast '<text>'` | Send to all agents |
| `tm-agent read <agent> --lines 50` | Read agent's terminal output |
| `tm-agent collect --lines 100` | Read all agents' output |
| `tm-agent wait --timeout 120 --mode any` | Wait for agent signals |
| `tm-agent inbox` | Check priority-sorted attention queue |
| `tm-agent brief <agent>` | Get concise agent status |

#### Lifecycle
| Command | Description |
|---------|-------------|
| `tm-agent status` | Show team and task board |
| `tm-agent destroy` | Destroy the team |

### Leader workflow

1. **Analyze** the task at hand using your existing conversation context
2. **Decompose** the work into subtasks appropriate for each agent
3. **Delegate** subtasks using `tm-agent delegate <agent> '<instruction>'`
4. **Monitor** progress with `tm-agent inbox` and `tm-agent collect`
5. **Coordinate** by sending follow-up instructions or unblocking agents
6. **Verify** results by reading agent output and checking the codebase
7. **Destroy** the team when all work is complete: `tm-agent destroy`

### Reading full agent reports

Agent replies are truncated to 1500 chars over the socket. Full reports are saved to files:

```bash
# Read full report for a specific task
cat ~/.term-mesh/results/$(tm-agent status 2>/dev/null | grep -o '"team_name":"[^"]*"' | head -1 | cut -d'"' -f4)/<task_id>.md

# Read an agent's latest reply
cat ~/.term-mesh/results/<team>/<agent>-reply.md
```
