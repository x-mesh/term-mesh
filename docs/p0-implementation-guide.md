# P0 Implementation Guide

**Date:** March 14, 2026
**Status:** P0 core features implemented, dashboard refinements in progress

## Quick Reference: tm-agent Commands

### Task Lifecycle
```bash
# Create a task
tm-agent task create "Feature title" --assign executor --priority 3

# Start working on a task
tm-agent task start <task_id>

# Send periodic heartbeats while working
tm-agent heartbeat "Making progress on X"

# Mark task as blocked (waiting for external input)
tm-agent task block <task_id> "Waiting for API response"

# Mark as ready for leader review
tm-agent task review <task_id> "Implementation complete, ready for validation"

# Mark as done
tm-agent task done <task_id> "Finished with result"

# Get task details
tm-agent task get <task_id>

# List all tasks
tm-agent task list

# Reassign a task
tm-agent task reassign <task_id> <new_agent>

# Unblock a blocked task
tm-agent task unblock <task_id>

# Split a task into subtasks
tm-agent task split <task_id> "Subtask title" --assign agent_name
```

### Messaging
```bash
# Send message to leader
tm-agent msg send "Status update"

# Send message to another agent
tm-agent msg send "Request for info" --to agent_name

# List messages
tm-agent msg list

# List messages from specific agent
tm-agent msg list --from-agent explorer

# Clear message queue
tm-agent msg clear
```

### Team Operations
```bash
# Check your inbox (prioritized attention items)
tm-agent inbox

# Check team status
tm-agent status

# Send heartbeat
tm-agent heartbeat "Working on task X"

# Report results to leader
tm-agent report "Task complete with findings"

# Reply to leader (combines msg send + report)
tm-agent reply "One-paragraph summary of result"
```

## Task States and When to Use Them

| State | Usage | Who Sets It |
|-------|-------|-----------|
| `queued` | Task created, awaiting assignment | Leader |
| `assigned` | Task assigned to agent, not started | Leader |
| `in_progress` | Agent actively working on task | Agent via `task start` |
| `blocked` | Agent blocked on external input | Agent via `task block` |
| `review_ready` | Implementation ready for validation | Agent via `task review` |
| `completed` | Task accepted as done | Leader or Agent via `task done` |
| `failed` | Task ended unsuccessfully | Either party via `task update` |

## Dashboard Features

### Main Components
1. **Needs Attention** card - shows blocked, review_ready, failed, and stale tasks
2. **Task Board** - kanban-style with columns for each status
3. **Agent List** - shows active agents, their current task, and heartbeat status
4. **Message Panel** - filtered view of team communications

### Task Board Columns
- **Queued** - new tasks awaiting assignment
- **Assigned** - assigned but not started
- **In Progress** - actively being worked
- **Blocked** - waiting on external input (shows blocker reason)
- **Review Ready** - waiting for leader validation
- **Completed** - finished tasks

## Recommended Workflows

### Single Agent, Multiple Tasks
1. Leader creates task with `tm-agent task create`
2. Leader assigns to agent
3. Agent marks `in_progress` with `tm-agent task start`
4. Agent sends heartbeats with `tm-agent heartbeat`
5. Agent marks `review_ready` or `blocked` as needed
6. Agent marks `completed` with `tm-agent task done`
7. Leader validates in dashboard

### Multi-Agent Parallel Work
1. Leader creates multiple independent tasks
2. Leader assigns to different agents
3. All agents work in parallel, sending heartbeats
4. Leader checks `inbox` for attention items
5. Leader unblocks agents or reviews ready items as needed

### Dependent Tasks (P1 Feature)
1. Leader creates main task
2. Leader creates subtasks with `depends_on: [main_task_id]`
3. Subtasks appear blocked until dependencies complete
4. System unblocks subtasks automatically when dependencies resolve

## Common Patterns

### Asking for Help
```bash
# Agent marks task as blocked
tm-agent task block <task_id> "Need clarification on API endpoint behavior"

# Leader checks inbox
tm-agent inbox

# Leader reads the blocked reason and responds
tm-agent msg send "The endpoint is at /api/v2/endpoint" --to agent_name

# Agent unblocks
tm-agent task unblock <task_id>
```

### Code Review Workflow
```bash
# Agent marks implementation ready
tm-agent task review <task_id> "PR #123 ready for review"

# Leader sees review_ready in dashboard
tm-agent inbox

# Leader provides feedback or approves
tm-agent msg send "Changes look good, approved" --to agent_name

# Agent marks complete
tm-agent task done <task_id> "PR merged"
```

## Architecture Notes

### Socket Communication
- All commands communicate via Unix domain socket
- Default sockets: `/tmp/term-mesh-debug.sock`, `/tmp/term-mesh.sock`, `/tmp/term-mesh.sock`
- Socket detected automatically or via `TERMMESH_SOCKET` env var

### RPC Protocol
- JSON-RPC 2.0 over Unix socket
- Single-line request/response format
- ~2ms per call (Rust implementation)
- ~10ms fallback (bash wrapper)

### State Storage
- Task state stored in TeamOrchestrator
- Persisted to disk for team recovery
- Dashboard fetches state via RPC

## Integration with Claude Code

### Agent Initialization
When agents are spawned by the leader, they receive:
- Task ID in the task instruction
- TeamOrchestrator socket information
- Working directory
- Agent name and role

### Lifecycle Expectations
1. Agent calls `tm-agent task start` immediately
2. Agent sends `tm-agent heartbeat` periodically
3. Agent calls `tm-agent task block` if stuck
4. Agent calls `tm-agent task review` when ready for validation
5. Agent calls `tm-agent reply` with final summary

## Next Steps (P1)

- [ ] Heartbeat-based stale detection on dashboard
- [ ] Active task display per agent with heartbeat age
- [ ] Workflow presets for common team setups
- [ ] Task dependency automation and visualization
- [ ] Brief command with terminal tail integration

## Troubleshooting

### Socket Connection Failed
- Ensure term-mesh app is running
- Check socket exists: `ls /tmp/term-mesh*.sock`
- Verify TERMMESH_SOCKET env var if set

### Task Not Appearing
- Check task was created: `tm-agent task list`
- Verify assignee matches agent name exactly
- Check team status: `tm-agent status`

### Messages Not Received
- Check inbox: `tm-agent inbox`
- List messages: `tm-agent msg list`
- Verify agent name and socket connection

