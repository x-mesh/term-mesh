#!/usr/bin/env python3
"""term-mesh Team Agent CLI

Usage:
    ./scripts/team.py create [N] [--claude-leader] [--kiro agent1,agent2] [--codex agent1] [--gemini agent2]
    ./scripts/team.py send <agent> <text>
    ./scripts/team.py delegate <agent> <text> [--title text] [--priority N] [--accept text ...] [--deps id ...]
    ./scripts/team.py broadcast <text>
    ./scripts/team.py status
    ./scripts/team.py inbox
    ./scripts/team.py list
    ./scripts/team.py destroy
    ./scripts/team.py read <agent> [--lines N]
    ./scripts/team.py collect [--lines N]
    ./scripts/team.py wait [--timeout N] [--mode report|msg|any|blocked|review_ready|idle] [--task id]
    ./scripts/team.py brief <agent> [--lines N]
    ./scripts/team.py agent ping <summary>
    ./scripts/team.py report <text>
    ./scripts/team.py msg send [--to X] [--from X] [--type X] [--report] <text>
    ./scripts/team.py msg post [--report] <from> <text>
    ./scripts/team.py msg list [--from X] [--limit N]
    ./scripts/team.py msg clear
    ./scripts/team.py task get <id>
    ./scripts/team.py task create <title> [--assign agent] [--desc text] [--accept text ...] [--priority N] [--deps id ...]
    ./scripts/team.py task update <id> <status> [result]
    ./scripts/team.py task start <id>
    ./scripts/team.py task block <id> <reason>
    ./scripts/team.py task review <id> <summary>
    ./scripts/team.py task done <id> [result]
    ./scripts/team.py task reassign <id> <agent>
    ./scripts/team.py task unblock <id>
    ./scripts/team.py task split <id> <title> [--assign agent]
    ./scripts/team.py task list [--status X] [--assign X] [--attention] [--priority N] [--stale] [--depends-on id]
    ./scripts/team.py task clear

Environment:
    TERMMESH_SOCKET  — socket path (default: auto-detect)
    TERMMESH_TEAM    — team name (default: live-team)
    TERMMESH_WORKDIR — working directory
    TERMMESH_AGENT_NAME — agent name (for report/msg send)
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import socket
import sys
import time
from pathlib import Path

# ── Defaults ──────────────────────────────────────────────────────────

TEAM = os.environ.get("TERMMESH_TEAM", os.environ.get("CMUX_TEAM", "live-team"))
WORKDIR = os.environ.get("TERMMESH_WORKDIR", os.environ.get("CMUX_WORKDIR", str(Path.home() / "work/project/term-mesh")))
AGENT_NAME = os.environ.get("TERMMESH_AGENT_NAME", os.environ.get("CMUX_AGENT_NAME", ""))

DEFAULT_AGENT_NAMES = ["explorer", "executor", "reviewer", "debugger", "writer", "tester"]
DEFAULT_AGENT_COLORS = ["green", "blue", "yellow", "magenta", "cyan", "red"]

REPORT_SUFFIX = (
    '\n\n[IMPORTANT] Use the team task lifecycle while you work:\n'
    '1. If you are starting assigned work, run `./scripts/team.py task start <task_id>`.\n'
    '2. While you are actively working, periodically run `./scripts/team.py agent ping \'<short progress summary>\'`.\n'
    '3. If you are blocked, run `./scripts/team.py task block <task_id> \'<reason>\'`.\n'
    '4. If you are ready for leader validation, run `./scripts/team.py task review <task_id> \'<summary>\'`.\n'
    '5. When the task is actually done, run `./scripts/team.py task done <task_id> \'<result>\'`.\n'
    'If the leader did not give you a task id, report that and ask for one.\n'
    '\n'
    '[IMPORTANT] When you finish this task, you MUST use your bash/execute tool to run this exact shell command:\n'
    '```\n'
    './scripts/team.py report \'<one-paragraph summary of your result>\'\n'
    '```\n'
    'Do NOT just describe the result in text. Actually execute the shell command above using your tool.'
)

AGENT_INIT_PROMPT = (
    'You are a team agent named "{agent}" in a term-mesh multi-agent team. '
    'Operational rules:\n'
    '1. Work should be tracked with task ids.\n'
    '2. When you begin a task, run `./scripts/team.py task start <task_id>`.\n'
    '3. While actively working, periodically run `./scripts/team.py agent ping \'<short progress summary>\'`.\n'
    '4. If blocked, run `./scripts/team.py task block <task_id> \'<reason>\'`.\n'
    '5. If ready for validation, run `./scripts/team.py task review <task_id> \'<summary>\'`.\n'
    '6. When accepted as done, run `./scripts/team.py task done <task_id> \'<result>\'`.\n'
    'When you complete any task assigned by the leader, you MUST use your bash/execute tool to run:\n'
    './scripts/team.py report \'<summary of your result>\'\n'
    'Do NOT just write the result as text — actually execute the shell command using your tool. '
    'This allows the leader to detect task completion automatically. '
    'Respond with "Agent {agent} ready." to confirm.'
)


# ── Socket helpers ────────────────────────────────────────────────────

def socket_ok(path: str) -> bool:
    """Check if a Unix socket accepts connections."""
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(1)
        s.connect(path)
        s.close()
        return True
    except (OSError, socket.error):
        return False


def detect_socket() -> str:
    """Auto-detect a connectable term-mesh socket."""
    env_socket = os.environ.get("TERMMESH_SOCKET", os.environ.get("CMUX_SOCKET", ""))
    if env_socket and socket_ok(env_socket):
        return env_socket

    candidates = sorted(
        glob.glob("/tmp/term-mesh.sock")
        + glob.glob("/tmp/term-mesh-debug.sock")
        + glob.glob("/tmp/term-mesh-debug-*.sock")
        + glob.glob("/tmp/cmux.sock")
        + glob.glob("/tmp/cmux-debug.sock")
        + glob.glob("/tmp/cmux-debug-*.sock")
    )
    for c in candidates:
        if os.path.exists(c) and socket_ok(c):
            return c

    print("Error: No connectable term-mesh socket found.", file=sys.stderr)
    print("Start the app first or set TERMMESH_SOCKET.", file=sys.stderr)
    print("", file=sys.stderr)
    print("Available sockets:", file=sys.stderr)
    avail = glob.glob("/tmp/term-mesh*.sock") + glob.glob("/tmp/cmux*.sock")
    if avail:
        for a in avail:
            print(f"  {a}", file=sys.stderr)
    else:
        print("  (none)", file=sys.stderr)
    sys.exit(1)


def rpc(sock_path: str, method: str, params: dict, req_id: int = 1, timeout: float = 5.0) -> dict:
    """Send a JSON-RPC request and return the parsed response."""
    req = {"jsonrpc": "2.0", "id": req_id, "method": method, "params": params}
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.connect(sock_path)
        s.sendall((json.dumps(req) + "\n").encode())
        s.settimeout(timeout)
        buf = b""
        while b"\n" not in buf:
            chunk = s.recv(4096)
            if not chunk:
                break
            buf += chunk
    except socket.timeout:
        pass
    finally:
        s.close()
    text = buf.decode().strip() if buf else "{}"
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return {"raw": text}


def pretty(data: dict) -> str:
    """Pretty-print a dict as JSON."""
    return json.dumps(data, indent=4, ensure_ascii=False)


# ── Commands ──────────────────────────────────────────────────────────

def cmd_create(sock: str, args: argparse.Namespace) -> None:
    count = args.count or 2
    if args.claude_leader:
        leader_mode = "claude"
    elif getattr(args, "kiro_leader", False):
        leader_mode = "kiro"
    elif getattr(args, "codex_leader", False):
        leader_mode = "codex"
    elif getattr(args, "gemini_leader", False):
        leader_mode = "gemini"
    else:
        leader_mode = "repl"

    # Parse CLI assignment flags: comma-separated agent names (or "all")
    def _parse_cli_flag(flag_value: str) -> set[str]:
        result: set[str] = set()
        if flag_value:
            for item in flag_value.split(","):
                item = item.strip()
                if item:
                    result.add(item)
        return result

    kiro_agents = _parse_cli_flag(args.kiro)
    codex_agents = _parse_cli_flag(getattr(args, "codex", ""))
    gemini_agents = _parse_cli_flag(getattr(args, "gemini", ""))

    agents = []
    for i in range(count):
        name = DEFAULT_AGENT_NAMES[i] if i < len(DEFAULT_AGENT_NAMES) else f"agent-{i}"
        color = DEFAULT_AGENT_COLORS[i % len(DEFAULT_AGENT_COLORS)]
        # Determine CLI: check each flag in priority order
        if name in codex_agents or "all" in codex_agents:
            cli = "codex"
        elif name in gemini_agents or "all" in gemini_agents:
            cli = "gemini"
        elif name in kiro_agents or "all" in kiro_agents:
            cli = "kiro"
        else:
            cli = "claude"
        agents.append({"name": name, "cli": cli, "model": "sonnet", "agent_type": name, "color": color})

    # Clean up existing team first
    rpc(sock, "team.destroy", {"team_name": TEAM}, req_id=0, timeout=2)
    time.sleep(0.5)

    print(f"Creating team '{TEAM}' with {count} agent(s) [leader: {leader_mode}]...")
    print(f"Socket: {sock}")

    r = rpc(sock, "team.create", {
        "team_name": TEAM,
        "working_directory": WORKDIR,
        "leader_session_id": f"leader-{os.getpid()}",
        "leader_mode": leader_mode,
        "agents": agents,
    })
    print(pretty(r))
    print()
    print("Commands:")
    print("  ./scripts/team.py send <agent> 'your message'")
    print("  ./scripts/team.py broadcast 'message to all'")
    print("  ./scripts/team.py status")
    print("  ./scripts/team.py destroy")

    # Option 3: Send init prompt to each agent so they know to report results
    if r.get("ok"):
        print("\nSending init prompts to agents...")
        time.sleep(3)  # Wait for agent CLI to initialize
        for agent in agents:
            name = agent["name"]
            init_text = AGENT_INIT_PROMPT.format(agent=name)
            rpc(sock, "team.send", {
                "team_name": TEAM,
                "agent_name": name,
                "text": init_text + "\n",
            }, timeout=3)
            print(f"  ✓ {name}: init prompt sent")
            time.sleep(1)  # Stagger sends to avoid race conditions


def _append_report_suffix(text: str, agent: str, no_report: bool = False) -> str:
    """Append report instruction suffix unless --no-report is set."""
    if no_report:
        return text
    return text + REPORT_SUFFIX.format(agent=agent)


def _task_title_from_text(text: str) -> str:
    compact = " ".join(text.strip().split())
    return compact[:80] if compact else "Untitled task"


def _format_task_instruction(task: dict, instruction: str, no_report: bool = False) -> str:
    lines = [
        f"[TASK_ID] {task['id']}",
        f"[TASK_TITLE] {task['title']}",
        f"[TASK_STATUS] {task.get('status', 'assigned')}",
    ]
    if task.get("priority") is not None:
        lines.append(f"[TASK_PRIORITY] {task['priority']}")
    acceptance = task.get("acceptance_criteria") or []
    if acceptance:
        lines.append("[ACCEPTANCE]")
        for item in acceptance:
            lines.append(f"- {item}")
    deps = task.get("depends_on") or []
    if deps:
        lines.append(f"[DEPS] {', '.join(deps)}")
    description = task.get("description")
    if description:
        lines.append(f"[TASK_DESCRIPTION] {description}")
    lines.extend([
        "",
        instruction.strip(),
        "",
        "Use the task lifecycle commands with this task id:",
        f"- ./scripts/team.py task start {task['id']}",
        "- ./scripts/team.py agent ping '<short progress summary>'",
        f"- ./scripts/team.py task block {task['id']} '<reason>'",
        f"- ./scripts/team.py task review {task['id']} '<summary>'",
        f"- ./scripts/team.py task done {task['id']} '<result>'",
    ])
    return _append_report_suffix("\n".join(lines).strip(), task.get("assignee", "") or "agent", no_report=no_report)


def _format_task_resume_instruction(task: dict, no_report: bool = False) -> str:
    lines = [
        f"[TASK_ID] {task['id']}",
        f"[TASK_TITLE] {task['title']}",
        f"[TASK_STATUS] {task.get('status', 'assigned')}",
    ]
    if task.get("priority") is not None:
        lines.append(f"[TASK_PRIORITY] {task['priority']}")
    acceptance = task.get("acceptance_criteria") or []
    if acceptance:
        lines.append("[ACCEPTANCE]")
        for item in acceptance:
            lines.append(f"- {item}")
    deps = task.get("depends_on") or []
    if deps:
        lines.append(f"[DEPS] {', '.join(deps)}")
    description = task.get("description")
    if description:
        lines.append(f"[TASK_DESCRIPTION] {description}")
    lines.extend([
        "",
        "Resume or start this assigned task now.",
        "",
        "Use the task lifecycle commands with this task id:",
        f"- ./scripts/team.py task start {task['id']}",
        "- ./scripts/team.py agent ping '<short progress summary>'",
        f"- ./scripts/team.py task block {task['id']} '<reason>'",
        f"- ./scripts/team.py task review {task['id']} '<summary>'",
        f"- ./scripts/team.py task done {task['id']} '<result>'",
    ])
    return _append_report_suffix("\n".join(lines).strip(), task.get("assignee", "") or "agent", no_report=no_report)


def cmd_send(sock: str, args: argparse.Namespace) -> None:
    text = _append_report_suffix(args.text, args.agent, getattr(args, "no_report", False))
    r = rpc(sock, "team.send", {
        "team_name": TEAM,
        "agent_name": args.agent,
        "text": text + "\n",
    })
    print(pretty(r))


def cmd_delegate(sock: str, args: argparse.Namespace) -> None:
    create_params: dict = {
        "team_name": TEAM,
        "title": args.title or _task_title_from_text(args.text),
        "assignee": args.agent,
        "priority": args.priority if args.priority is not None else 2,
    }
    if args.desc:
        create_params["description"] = args.desc
    if args.accept:
        create_params["acceptance_criteria"] = args.accept
    if args.deps:
        create_params["depends_on"] = args.deps

    created = rpc(sock, "team.task.create", create_params)
    task = created.get("result", {})
    task_id = task.get("id")
    if not created.get("ok") or not task_id:
        print(pretty(created))
        if not created.get("ok"):
            sys.exit(1)
        return

    instruction = _format_task_instruction(task, args.text, no_report=getattr(args, "no_report", False))
    sent = rpc(sock, "team.send", {
        "team_name": TEAM,
        "agent_name": args.agent,
        "text": instruction + "\n",
    })
    payload = {"task": task, "send": sent}
    print(pretty(payload))
    if not sent.get("ok"):
        sys.exit(1)


def cmd_broadcast(sock: str, args: argparse.Namespace) -> None:
    no_report = getattr(args, "no_report", False)
    # For broadcast, use a generic agent placeholder — each agent will see their own name in env
    text = args.text
    if not no_report:
        text += (
            '\n\n[IMPORTANT] When you finish this task, you MUST run this command to report your result:\n'
            './scripts/team.py report \'<one-paragraph summary of your result>\'\n'
            '(Make sure CMUX_AGENT_NAME is set to your agent name)'
        )
    r = rpc(sock, "team.broadcast", {
        "team_name": TEAM,
        "text": text + "\n",
    })
    print(pretty(r))


def cmd_status(sock: str, _args: argparse.Namespace) -> None:
    r = rpc(sock, "team.status", {"team_name": TEAM})
    print(pretty(r))


def cmd_inbox(sock: str, _args: argparse.Namespace) -> None:
    r = rpc(sock, "team.inbox", {"team_name": TEAM})
    print(pretty(r))


def cmd_list(sock: str, _args: argparse.Namespace) -> None:
    r = rpc(sock, "team.list", {})
    print(pretty(r))


def cmd_destroy(sock: str, _args: argparse.Namespace) -> None:
    print(f"Destroying team '{TEAM}'...")
    r = rpc(sock, "team.destroy", {"team_name": TEAM})
    print(pretty(r))


def cmd_read(sock: str, args: argparse.Namespace) -> None:
    params: dict = {"team_name": TEAM, "agent_name": args.agent}
    if args.lines:
        params["lines"] = args.lines
    r = rpc(sock, "team.read", params)
    result = r.get("result", {})
    if "text" in result:
        print(result["text"])
    elif "error" in r:
        msg = r["error"].get("message", str(r["error"])) if isinstance(r["error"], dict) else str(r["error"])
        print(f"Error: {msg}", file=sys.stderr)
        sys.exit(1)
    else:
        print(pretty(r))


def cmd_collect(sock: str, args: argparse.Namespace) -> None:
    params: dict = {"team_name": TEAM}
    if args.lines:
        params["lines"] = args.lines
    r = rpc(sock, "team.collect", params)
    print(pretty(r))


def cmd_wait(sock: str, args: argparse.Namespace) -> None:
    timeout = args.timeout or 120
    interval = args.interval or 3
    mode = args.mode or "report"
    task_id = getattr(args, "task_id", None)

    print(f"Waiting for agents in team '{TEAM}' (timeout: {timeout}s, mode: {mode})...")

    # Get agent list for msg-based detection
    agent_names: list[str] = []
    if mode in ("msg", "any"):
        r = rpc(sock, "team.status", {"team_name": TEAM})
        agents = r.get("result", {}).get("agents", [])
        agent_names = [a["name"] for a in agents]

    elapsed = 0
    while elapsed < timeout:
        report_done = False
        report_progress = "0/0"
        msg_done = False
        msg_progress = "0/0"
        inbox_blocked = []
        inbox_review = []

        # Check report-based completion
        if mode in ("report", "any"):
            r = rpc(sock, "team.result.status", {"team_name": TEAM})
            res = r.get("result", {})
            done = res.get("completed", 0)
            total = res.get("total", 0)
            report_done = res.get("all_done", False)
            report_progress = f"{done}/{total}"

        # Check message-based completion
        if mode in ("msg", "any"):
            r = rpc(sock, "team.message.list", {"team_name": TEAM})
            messages = r.get("result", {}).get("messages", [])
            senders = {m.get("from", "") for m in messages}
            reported = sum(1 for a in agent_names if a in senders)
            total = len(agent_names)
            msg_done = reported >= total > 0
            msg_progress = f"{reported}/{total}"

        if mode in ("blocked", "review_ready", "idle") or task_id:
            r = rpc(sock, "team.inbox", {"team_name": TEAM})
            items = r.get("result", {}).get("items", [])
            inbox_blocked = [item for item in items if item.get("kind") == "task" and item.get("status") == "blocked"]
            inbox_review = [item for item in items if item.get("kind") == "task" and item.get("status") == "review_ready"]
            if task_id:
                task_res = rpc(sock, "team.task.get", {"team_name": TEAM, "task_id": task_id})
                task = task_res.get("result", {}) if task_res.get("ok") else {}
                task_status = task.get("status")
            else:
                task = {}
                task_status = None
            if mode == "idle":
                status_res = rpc(sock, "team.status", {"team_name": TEAM})
                agents = status_res.get("result", {}).get("agents", [])
                idle_agents = [a for a in agents if a.get("agent_state") == "idle"]
                running_agents = [a for a in agents if a.get("agent_state") in ("running", "blocked", "review_ready")]

        # Display and check
        if task_id:
            print(f"  [{elapsed}/{timeout}s] task={task_id} status={task_status or 'unknown'}")
            if task_status in ("blocked", "review_ready", "completed", "failed", "abandoned"):
                print(pretty({"result": {"team_name": TEAM, "task": task}}))
                return
        if mode == "report":
            print(f"  [{elapsed}/{timeout}s] {report_progress} agents reported (report)")
            if report_done:
                print("All agents have reported results.")
                r = rpc(sock, "team.result.collect", {"team_name": TEAM})
                print(pretty(r))
                return
        elif mode == "msg":
            print(f"  [{elapsed}/{timeout}s] {msg_progress} agents messaged (msg)")
            if msg_done:
                print("All agents have posted messages.")
                r = rpc(sock, "team.message.list", {"team_name": TEAM})
                print(pretty(r))
                return
        elif mode == "any":
            print(f"  [{elapsed}/{timeout}s] report={report_progress} msg={msg_progress} (any)")
            if report_done:
                print("All agents have reported results.")
                r = rpc(sock, "team.result.collect", {"team_name": TEAM})
                print(pretty(r))
                return
            if msg_done:
                print("All agents have posted messages.")
                r = rpc(sock, "team.message.list", {"team_name": TEAM})
                print(pretty(r))
                return
        elif mode == "blocked":
            print(f"  [{elapsed}/{timeout}s] blocked={len(inbox_blocked)}")
            if inbox_blocked:
                print("A task is blocked.")
                print(pretty({"result": {"team_name": TEAM, "items": inbox_blocked, "count": len(inbox_blocked)}}))
                return
        elif mode == "review_ready":
            print(f"  [{elapsed}/{timeout}s] review_ready={len(inbox_review)}")
            if inbox_review:
                print("A task is ready for review.")
                print(pretty({"result": {"team_name": TEAM, "items": inbox_review, "count": len(inbox_review)}}))
                return
        elif mode == "idle":
            total = len(idle_agents) + len(running_agents)
            print(f"  [{elapsed}/{timeout}s] idle={len(idle_agents)}/{total}")
            if total > 0 and len(idle_agents) == total:
                print(pretty({"result": {"team_name": TEAM, "agents": idle_agents, "count": len(idle_agents)}}))
                return

        time.sleep(interval)
        elapsed += interval

    print(f"Timeout: not all agents reported within {timeout}s")
    r = rpc(sock, "team.result.status", {"team_name": TEAM})
    print(pretty(r))
    sys.exit(1)


def cmd_brief(sock: str, args: argparse.Namespace) -> None:
    status = rpc(sock, "team.status", {"team_name": TEAM})
    agents = status.get("result", {}).get("agents", [])
    agent = next((item for item in agents if item.get("name") == args.agent), None)
    if not agent:
        print(f"Error: agent '{args.agent}' not found in team '{TEAM}'", file=sys.stderr)
        sys.exit(1)

    active_task = None
    task_id = agent.get("active_task_id")
    if task_id:
        task_res = rpc(sock, "team.task.get", {"team_name": TEAM, "task_id": task_id})
        if task_res.get("ok"):
            active_task = task_res.get("result")

    msg_res = rpc(sock, "team.message.list", {"team_name": TEAM, "from": args.agent, "limit": 5})
    messages = msg_res.get("result", {}).get("messages", []) if msg_res.get("ok") else []

    read_res = rpc(sock, "team.read", {"team_name": TEAM, "agent_name": args.agent, "lines": args.lines})
    terminal_tail = read_res.get("result", {}).get("text", "") if read_res.get("ok") else ""

    payload = {
        "team_name": TEAM,
        "agent": {
            "name": agent.get("name"),
            "status": agent.get("status"),
            "agent_type": agent.get("agent_type"),
            "panel_id": agent.get("panel_id"),
            "active_task_id": task_id,
            "active_task_status": agent.get("active_task_status"),
            "active_task_title": agent.get("active_task_title"),
            "attention_reason": agent.get("attention_reason"),
        },
        "active_task": active_task,
        "recent_messages": messages,
        "terminal_tail": terminal_tail,
    }
    print(pretty(payload))


def cmd_agent_ping(sock: str, args: argparse.Namespace) -> None:
    agent = AGENT_NAME
    if not agent:
        print("Error: TERMMESH_AGENT_NAME not set.", file=sys.stderr)
        sys.exit(1)
    r = rpc(sock, "team.agent.heartbeat", {
        "team_name": TEAM,
        "agent_name": agent,
        "summary": args.summary,
    })
    print(pretty(r))


def cmd_report(sock: str, args: argparse.Namespace) -> None:
    agent = AGENT_NAME
    if not agent:
        print("Error: TERMMESH_AGENT_NAME not set.", file=sys.stderr)
        print("Use: TERMMESH_AGENT_NAME=explorer team.py report ...", file=sys.stderr)
        sys.exit(1)
    r = rpc(sock, "team.report", {
        "team_name": TEAM,
        "agent_name": agent,
        "content": args.text,
    })
    print(pretty(r))


# ── msg subcommands ───────────────────────────────────────────────────

def cmd_msg_send(sock: str, args: argparse.Namespace) -> None:
    sender = args.sender or AGENT_NAME or "anonymous"
    params: dict = {
        "team_name": TEAM,
        "from": sender,
        "content": args.text,
        "type": args.type or "report",
    }
    if args.to:
        params["to"] = args.to
    r = rpc(sock, "team.message.post", params)
    print(pretty(r))

    # Also submit report for wait detection
    if args.report and (args.sender or AGENT_NAME):
        rpc(sock, "team.report", {
            "team_name": TEAM,
            "agent_name": args.sender or AGENT_NAME,
            "content": args.text,
        }, req_id=2)


def cmd_msg_post(sock: str, args: argparse.Namespace) -> None:
    r = rpc(sock, "team.message.post", {
        "team_name": TEAM,
        "from": args.sender,
        "content": args.text,
        "type": args.type or "report",
    })
    print(pretty(r))

    # Also submit report for wait detection
    if args.report:
        rpc(sock, "team.report", {
            "team_name": TEAM,
            "agent_name": args.sender,
            "content": args.text,
        }, req_id=2)


def cmd_msg_list(sock: str, args: argparse.Namespace) -> None:
    params: dict = {"team_name": TEAM}
    if args.sender:
        params["from"] = args.sender
    if args.limit:
        params["limit"] = args.limit
    r = rpc(sock, "team.message.list", params)
    print(pretty(r))


def cmd_msg_clear(sock: str, _args: argparse.Namespace) -> None:
    r = rpc(sock, "team.message.clear", {"team_name": TEAM})
    print(pretty(r))


# ── task subcommands ──────────────────────────────────────────────────

def cmd_task_get(sock: str, args: argparse.Namespace) -> None:
    r = rpc(sock, "team.task.get", {"team_name": TEAM, "task_id": args.task_id})
    print(pretty(r))

def cmd_task_create(sock: str, args: argparse.Namespace) -> None:
    params: dict = {"team_name": TEAM, "title": args.title}
    if args.assign:
        params["assignee"] = args.assign
    if args.desc:
        params["description"] = args.desc
    if args.accept:
        params["acceptance_criteria"] = args.accept
    if args.priority is not None:
        params["priority"] = args.priority
    if args.deps:
        params["depends_on"] = args.deps
    r = rpc(sock, "team.task.create", params)
    print(pretty(r))


def cmd_task_update(sock: str, args: argparse.Namespace) -> None:
    params: dict = {"team_name": TEAM, "task_id": args.task_id, "status": args.status}
    if args.result:
        params["result"] = args.result
    if getattr(args, "assign", None):
        params["assignee"] = args.assign
    if getattr(args, "blocked_reason", None):
        params["blocked_reason"] = args.blocked_reason
    if getattr(args, "review_summary", None):
        params["review_summary"] = args.review_summary
    if getattr(args, "progress_note", None):
        params["progress_note"] = args.progress_note
    r = rpc(sock, "team.task.update", params)
    print(pretty(r))


def cmd_task_start(sock: str, args: argparse.Namespace) -> None:
    existing = rpc(sock, "team.task.get", {"team_name": TEAM, "task_id": args.task_id})
    task = existing.get("result", {})
    if not existing.get("ok") or not task.get("id"):
        print(pretty(existing))
        if not existing.get("ok"):
            sys.exit(1)
        return

    params = {"team_name": TEAM, "task_id": args.task_id, "status": "in_progress"}
    if args.assign:
        params["assignee"] = args.assign
    if args.progress_note:
        params["progress_note"] = args.progress_note
    r = rpc(sock, "team.task.update", params)
    assignee = args.assign or task.get("assignee")
    dispatched = None
    should_dispatch = not args.no_dispatch and assignee and assignee != AGENT_NAME
    if should_dispatch:
        task["assignee"] = assignee
        task["status"] = "in_progress"
        instruction = _format_task_resume_instruction(task, no_report=getattr(args, "no_report", False))
        dispatched = rpc(sock, "team.send", {
            "team_name": TEAM,
            "agent_name": assignee,
            "text": instruction + "\n",
        })
    print(pretty({"update": r, "dispatch": dispatched}))


def cmd_task_block(sock: str, args: argparse.Namespace) -> None:
    r = rpc(sock, "team.task.block", {
        "team_name": TEAM,
        "task_id": args.task_id,
        "blocked_reason": args.reason,
    })
    print(pretty(r))


def cmd_task_review(sock: str, args: argparse.Namespace) -> None:
    r = rpc(sock, "team.task.review", {
        "team_name": TEAM,
        "task_id": args.task_id,
        "review_summary": args.summary,
    })
    print(pretty(r))


def cmd_task_done(sock: str, args: argparse.Namespace) -> None:
    params = {
        "team_name": TEAM,
        "task_id": args.task_id,
    }
    if args.result:
        params["result"] = args.result
    r = rpc(sock, "team.task.done", params)
    print(pretty(r))


def cmd_task_reassign(sock: str, args: argparse.Namespace) -> None:
    r = rpc(sock, "team.task.reassign", {
        "team_name": TEAM,
        "task_id": args.task_id,
        "assignee": args.agent,
    })
    print(pretty(r))


def cmd_task_unblock(sock: str, args: argparse.Namespace) -> None:
    r = rpc(sock, "team.task.unblock", {
        "team_name": TEAM,
        "task_id": args.task_id,
    })
    print(pretty(r))


def cmd_task_split(sock: str, args: argparse.Namespace) -> None:
    params = {
        "team_name": TEAM,
        "task_id": args.task_id,
        "title": args.title,
    }
    if args.assign:
        params["assignee"] = args.assign
    r = rpc(sock, "team.task.split", params)
    print(pretty(r))


def cmd_task_list(sock: str, args: argparse.Namespace) -> None:
    params: dict = {"team_name": TEAM}
    if args.status:
        params["status"] = args.status
    if args.assign:
        params["assignee"] = args.assign
    if args.attention:
        params["needs_attention"] = True
    if args.priority is not None:
        params["priority"] = args.priority
    if args.stale:
        params["stale"] = True
    if args.depends_on:
        params["depends_on"] = args.depends_on
    r = rpc(sock, "team.task.list", params)
    print(pretty(r))


def cmd_task_clear(sock: str, _args: argparse.Namespace) -> None:
    r = rpc(sock, "team.task.clear", {"team_name": TEAM})
    print(pretty(r))


# ── CLI parser ────────────────────────────────────────────────────────

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="team.py", description="term-mesh Team Agent CLI")
    sub = p.add_subparsers(dest="command", help="command")

    # create
    sp = sub.add_parser("create", help="Create team with N agents")
    sp.add_argument("count", nargs="?", type=int, default=2)
    sp.add_argument("--claude-leader", action="store_true")
    sp.add_argument("--kiro-leader", action="store_true", help="Use kiro-cli as team leader")
    sp.add_argument("--codex-leader", action="store_true", help="Use Codex CLI as team leader")
    sp.add_argument("--gemini-leader", action="store_true", help="Use Gemini CLI as team leader")
    sp.add_argument("--kiro", type=str, default="",
                    help="Comma-separated agent names to run with kiro-cli (or 'all')")
    sp.add_argument("--codex", type=str, default="",
                    help="Comma-separated agent names to run with Codex CLI (or 'all')")
    sp.add_argument("--gemini", type=str, default="",
                    help="Comma-separated agent names to run with Gemini CLI (or 'all')")

    # send
    sp = sub.add_parser("send", help="Send text to a specific agent")
    sp.add_argument("agent")
    sp.add_argument("text")
    sp.add_argument("--no-report", action="store_true",
                    help="Don't append report instruction suffix")

    sp = sub.add_parser("delegate", help="Create a task and send task-aware instructions to an agent")
    sp.add_argument("agent")
    sp.add_argument("text")
    sp.add_argument("--title")
    sp.add_argument("--desc")
    sp.add_argument("--accept", nargs="*")
    sp.add_argument("--priority", type=int, choices=[1, 2, 3])
    sp.add_argument("--deps", nargs="*")
    sp.add_argument("--no-report", action="store_true",
                    help="Don't append report instruction suffix")

    # broadcast
    sp = sub.add_parser("broadcast", help="Send text to all agents")
    sp.add_argument("text")
    sp.add_argument("--no-report", action="store_true",
                    help="Don't append report instruction suffix")

    # status / list / destroy
    sub.add_parser("status", help="Show team status")
    sub.add_parser("inbox", help="Show attention-required inbox items")
    sub.add_parser("list", help="List all teams")
    sub.add_parser("destroy", help="Destroy the team")

    # read
    sp = sub.add_parser("read", help="Read agent's terminal screen")
    sp.add_argument("agent")
    sp.add_argument("--lines", type=int)

    # collect
    sp = sub.add_parser("collect", help="Read all agents' terminal screens")
    sp.add_argument("--lines", type=int)

    sp = sub.add_parser("brief", help="Summarize an agent's active context")
    sp.add_argument("agent")
    sp.add_argument("--lines", type=int, default=40)

    # wait
    sp = sub.add_parser("wait", help="Wait for all agents to complete")
    sp.add_argument("--timeout", type=int, default=120)
    sp.add_argument("--interval", type=int, default=3)
    sp.add_argument("--mode", choices=["report", "msg", "any", "blocked", "review_ready", "idle"], default="report")
    sp.add_argument("--task", dest="task_id")

    # report
    sp = sub.add_parser("report", help="Agent posts result (needs CMUX_AGENT_NAME)")
    sp.add_argument("text")

    agent_p = sub.add_parser("agent", help="Agent runtime commands")
    agent_sub = agent_p.add_subparsers(dest="agent_command", help="agent subcommand")

    sp = agent_sub.add_parser("ping", help="Send a heartbeat summary for the current agent")
    sp.add_argument("summary")

    # msg
    msg_p = sub.add_parser("msg", help="Message commands")
    msg_sub = msg_p.add_subparsers(dest="msg_command", help="msg subcommand")

    sp = msg_sub.add_parser("send", help="Send message (auto-detects sender)")
    sp.add_argument("text")
    sp.add_argument("--to", dest="to")
    sp.add_argument("--from", dest="sender")
    sp.add_argument("--type", choices=["note", "progress", "blocked", "review_ready", "error", "report"])
    sp.add_argument("--report", action="store_true")

    sp = msg_sub.add_parser("post", help="Post message with explicit sender")
    sp.add_argument("sender", metavar="from")
    sp.add_argument("text")
    sp.add_argument("--type", choices=["note", "progress", "blocked", "review_ready", "error", "report"])
    sp.add_argument("--report", action="store_true")

    sp = msg_sub.add_parser("list", help="List messages")
    sp.add_argument("--from", dest="sender")
    sp.add_argument("--limit", type=int)

    msg_sub.add_parser("clear", help="Clear all messages")

    # task
    task_p = sub.add_parser("task", help="Task board commands")
    task_sub = task_p.add_subparsers(dest="task_command", help="task subcommand")

    sp = task_sub.add_parser("get", help="Get task details")
    sp.add_argument("task_id")

    sp = task_sub.add_parser("create", help="Create a task")
    sp.add_argument("title")
    sp.add_argument("--assign")
    sp.add_argument("--desc")
    sp.add_argument("--accept", nargs="*")
    sp.add_argument("--priority", type=int, choices=[1, 2, 3])
    sp.add_argument("--deps", nargs="*")

    sp = task_sub.add_parser("update", help="Update task status")
    sp.add_argument("task_id")
    sp.add_argument("status")
    sp.add_argument("result", nargs="?")
    sp.add_argument("--assign")
    sp.add_argument("--blocked-reason")
    sp.add_argument("--review-summary")
    sp.add_argument("--progress-note")

    sp = task_sub.add_parser("start", help="Mark a task as in progress")
    sp.add_argument("task_id")
    sp.add_argument("--assign")
    sp.add_argument("--progress-note")
    sp.add_argument("--no-dispatch", action="store_true")
    sp.add_argument("--no-report", action="store_true",
                    help="Don't append report instruction suffix when dispatching")

    sp = task_sub.add_parser("block", help="Mark a task as blocked")
    sp.add_argument("task_id")
    sp.add_argument("reason")

    sp = task_sub.add_parser("review", help="Mark a task as ready for review")
    sp.add_argument("task_id")
    sp.add_argument("summary")

    sp = task_sub.add_parser("done", help="Mark a task as completed")
    sp.add_argument("task_id")
    sp.add_argument("result", nargs="?")

    sp = task_sub.add_parser("reassign", help="Reassign a task and dispatch it to a new owner")
    sp.add_argument("task_id")
    sp.add_argument("agent")

    sp = task_sub.add_parser("unblock", help="Clear blocked state and resume dispatch")
    sp.add_argument("task_id")

    sp = task_sub.add_parser("split", help="Create a follow-up task from an existing task")
    sp.add_argument("task_id")
    sp.add_argument("title")
    sp.add_argument("--assign")

    sp = task_sub.add_parser("list", help="List tasks")
    sp.add_argument("--status")
    sp.add_argument("--assign")
    sp.add_argument("--attention", action="store_true")
    sp.add_argument("--priority", type=int, choices=[1, 2, 3])
    sp.add_argument("--stale", action="store_true")
    sp.add_argument("--depends-on")

    task_sub.add_parser("clear", help="Clear all tasks")

    return p


# ── Dispatch ──────────────────────────────────────────────────────────

COMMAND_MAP = {
    "create": cmd_create,
    "send": cmd_send,
    "delegate": cmd_delegate,
    "broadcast": cmd_broadcast,
    "status": cmd_status,
    "inbox": cmd_inbox,
    "list": cmd_list,
    "destroy": cmd_destroy,
    "read": cmd_read,
    "collect": cmd_collect,
    "brief": cmd_brief,
    "wait": cmd_wait,
    "report": cmd_report,
}

MSG_MAP = {
    "send": cmd_msg_send,
    "post": cmd_msg_post,
    "list": cmd_msg_list,
    "clear": cmd_msg_clear,
}

AGENT_MAP = {
    "ping": cmd_agent_ping,
}

TASK_MAP = {
    "get": cmd_task_get,
    "create": cmd_task_create,
    "update": cmd_task_update,
    "start": cmd_task_start,
    "block": cmd_task_block,
    "review": cmd_task_review,
    "done": cmd_task_done,
    "reassign": cmd_task_reassign,
    "unblock": cmd_task_unblock,
    "split": cmd_task_split,
    "list": cmd_task_list,
    "clear": cmd_task_clear,
}


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        print(f"\nEnvironment:")
        print(f"  TERMMESH_SOCKET={os.environ.get('TERMMESH_SOCKET', os.environ.get('CMUX_SOCKET', '(auto-detect)'))}")
        print(f"  TERMMESH_TEAM={TEAM}")
        print(f"  TERMMESH_WORKDIR={WORKDIR}")
        print(f"  TERMMESH_AGENT_NAME={AGENT_NAME or '(not set)'}")
        return

    sock = detect_socket()

    if args.command == "msg":
        if not args.msg_command:
            parser.parse_args(["msg", "--help"])
            return
        MSG_MAP[args.msg_command](sock, args)
    elif args.command == "agent":
        if not args.agent_command:
            parser.parse_args(["agent", "--help"])
            return
        AGENT_MAP[args.agent_command](sock, args)
    elif args.command == "task":
        if not args.task_command:
            parser.parse_args(["task", "--help"])
            return
        TASK_MAP[args.task_command](sock, args)
    else:
        COMMAND_MAP[args.command](sock, args)


if __name__ == "__main__":
    main()
