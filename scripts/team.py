#!/usr/bin/env python3
"""cmux Team Agent CLI

Usage:
    ./scripts/team.py create [N] [--claude-leader]
    ./scripts/team.py send <agent> <text>
    ./scripts/team.py broadcast <text>
    ./scripts/team.py status
    ./scripts/team.py list
    ./scripts/team.py destroy
    ./scripts/team.py read <agent> [--lines N]
    ./scripts/team.py collect [--lines N]
    ./scripts/team.py wait [--timeout N] [--mode report|msg|any]
    ./scripts/team.py report <text>
    ./scripts/team.py msg send [--to X] [--from X] [--report] <text>
    ./scripts/team.py msg post [--report] <from> <text>
    ./scripts/team.py msg list [--from X] [--limit N]
    ./scripts/team.py msg clear
    ./scripts/team.py task create <title> [--assign agent]
    ./scripts/team.py task update <id> <status> [result]
    ./scripts/team.py task list [--status X] [--assign X]
    ./scripts/team.py task clear

Environment:
    CMUX_SOCKET  — socket path (default: auto-detect)
    CMUX_TEAM    — team name (default: live-team)
    CMUX_WORKDIR — working directory
    CMUX_AGENT_NAME — agent name (for report/msg send)
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

TEAM = os.environ.get("CMUX_TEAM", "live-team")
WORKDIR = os.environ.get("CMUX_WORKDIR", str(Path.home() / "work/project/cmux"))
AGENT_NAME = os.environ.get("CMUX_AGENT_NAME", "")

DEFAULT_AGENT_NAMES = ["explorer", "executor", "reviewer", "debugger", "writer", "tester"]
DEFAULT_AGENT_COLORS = ["green", "blue", "yellow", "magenta", "cyan", "red"]


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
    """Auto-detect a connectable cmux socket."""
    env_socket = os.environ.get("CMUX_SOCKET", "")
    if env_socket and socket_ok(env_socket):
        return env_socket

    candidates = sorted(
        glob.glob("/tmp/cmux.sock")
        + glob.glob("/tmp/cmux-debug.sock")
        + glob.glob("/tmp/cmux-debug-*.sock")
    )
    for c in candidates:
        if os.path.exists(c) and socket_ok(c):
            return c

    print("Error: No connectable cmux socket found.", file=sys.stderr)
    print("Start the app first or set CMUX_SOCKET.", file=sys.stderr)
    print("", file=sys.stderr)
    print("Available sockets:", file=sys.stderr)
    avail = glob.glob("/tmp/cmux*.sock")
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
    leader_mode = "claude" if args.claude_leader else "repl"

    agents = []
    for i in range(count):
        name = DEFAULT_AGENT_NAMES[i] if i < len(DEFAULT_AGENT_NAMES) else f"agent-{i}"
        color = DEFAULT_AGENT_COLORS[i % len(DEFAULT_AGENT_COLORS)]
        agents.append({"name": name, "model": "sonnet", "agent_type": name, "color": color})

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


def cmd_send(sock: str, args: argparse.Namespace) -> None:
    r = rpc(sock, "team.send", {
        "team_name": TEAM,
        "agent_name": args.agent,
        "text": args.text + "\n",
    })
    print(pretty(r))


def cmd_broadcast(sock: str, args: argparse.Namespace) -> None:
    r = rpc(sock, "team.broadcast", {
        "team_name": TEAM,
        "text": args.text + "\n",
    })
    print(pretty(r))


def cmd_status(sock: str, _args: argparse.Namespace) -> None:
    r = rpc(sock, "team.status", {"team_name": TEAM})
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

        # Display and check
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

        time.sleep(interval)
        elapsed += interval

    print(f"Timeout: not all agents reported within {timeout}s")
    r = rpc(sock, "team.result.status", {"team_name": TEAM})
    print(pretty(r))
    sys.exit(1)


def cmd_report(sock: str, args: argparse.Namespace) -> None:
    agent = AGENT_NAME
    if not agent:
        print("Error: CMUX_AGENT_NAME not set.", file=sys.stderr)
        print("Use: CMUX_AGENT_NAME=explorer team.py report ...", file=sys.stderr)
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
        "type": "report",
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
        "type": "report",
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

def cmd_task_create(sock: str, args: argparse.Namespace) -> None:
    params: dict = {"team_name": TEAM, "title": args.title}
    if args.assign:
        params["assignee"] = args.assign
    r = rpc(sock, "team.task.create", params)
    print(pretty(r))


def cmd_task_update(sock: str, args: argparse.Namespace) -> None:
    params: dict = {"team_name": TEAM, "task_id": args.task_id, "status": args.status}
    if args.result:
        params["result"] = args.result
    r = rpc(sock, "team.task.update", params)
    print(pretty(r))


def cmd_task_list(sock: str, args: argparse.Namespace) -> None:
    params: dict = {"team_name": TEAM}
    if args.status:
        params["status"] = args.status
    if args.assign:
        params["assignee"] = args.assign
    r = rpc(sock, "team.task.list", params)
    print(pretty(r))


def cmd_task_clear(sock: str, _args: argparse.Namespace) -> None:
    r = rpc(sock, "team.task.clear", {"team_name": TEAM})
    print(pretty(r))


# ── CLI parser ────────────────────────────────────────────────────────

def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="team.py", description="cmux Team Agent CLI")
    sub = p.add_subparsers(dest="command", help="command")

    # create
    sp = sub.add_parser("create", help="Create team with N agents")
    sp.add_argument("count", nargs="?", type=int, default=2)
    sp.add_argument("--claude-leader", action="store_true")

    # send
    sp = sub.add_parser("send", help="Send text to a specific agent")
    sp.add_argument("agent")
    sp.add_argument("text")

    # broadcast
    sp = sub.add_parser("broadcast", help="Send text to all agents")
    sp.add_argument("text")

    # status / list / destroy
    sub.add_parser("status", help="Show team status")
    sub.add_parser("list", help="List all teams")
    sub.add_parser("destroy", help="Destroy the team")

    # read
    sp = sub.add_parser("read", help="Read agent's terminal screen")
    sp.add_argument("agent")
    sp.add_argument("--lines", type=int)

    # collect
    sp = sub.add_parser("collect", help="Read all agents' terminal screens")
    sp.add_argument("--lines", type=int)

    # wait
    sp = sub.add_parser("wait", help="Wait for all agents to complete")
    sp.add_argument("--timeout", type=int, default=120)
    sp.add_argument("--interval", type=int, default=3)
    sp.add_argument("--mode", choices=["report", "msg", "any"], default="report")

    # report
    sp = sub.add_parser("report", help="Agent posts result (needs CMUX_AGENT_NAME)")
    sp.add_argument("text")

    # msg
    msg_p = sub.add_parser("msg", help="Message commands")
    msg_sub = msg_p.add_subparsers(dest="msg_command", help="msg subcommand")

    sp = msg_sub.add_parser("send", help="Send message (auto-detects sender)")
    sp.add_argument("text")
    sp.add_argument("--to", dest="to")
    sp.add_argument("--from", dest="sender")
    sp.add_argument("--report", action="store_true")

    sp = msg_sub.add_parser("post", help="Post message with explicit sender")
    sp.add_argument("sender", metavar="from")
    sp.add_argument("text")
    sp.add_argument("--report", action="store_true")

    sp = msg_sub.add_parser("list", help="List messages")
    sp.add_argument("--from", dest="sender")
    sp.add_argument("--limit", type=int)

    msg_sub.add_parser("clear", help="Clear all messages")

    # task
    task_p = sub.add_parser("task", help="Task board commands")
    task_sub = task_p.add_subparsers(dest="task_command", help="task subcommand")

    sp = task_sub.add_parser("create", help="Create a task")
    sp.add_argument("title")
    sp.add_argument("--assign")

    sp = task_sub.add_parser("update", help="Update task status")
    sp.add_argument("task_id")
    sp.add_argument("status")
    sp.add_argument("result", nargs="?")

    sp = task_sub.add_parser("list", help="List tasks")
    sp.add_argument("--status")
    sp.add_argument("--assign")

    task_sub.add_parser("clear", help="Clear all tasks")

    return p


# ── Dispatch ──────────────────────────────────────────────────────────

COMMAND_MAP = {
    "create": cmd_create,
    "send": cmd_send,
    "broadcast": cmd_broadcast,
    "status": cmd_status,
    "list": cmd_list,
    "destroy": cmd_destroy,
    "read": cmd_read,
    "collect": cmd_collect,
    "wait": cmd_wait,
    "report": cmd_report,
}

MSG_MAP = {
    "send": cmd_msg_send,
    "post": cmd_msg_post,
    "list": cmd_msg_list,
    "clear": cmd_msg_clear,
}

TASK_MAP = {
    "create": cmd_task_create,
    "update": cmd_task_update,
    "list": cmd_task_list,
    "clear": cmd_task_clear,
}


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        print(f"\nEnvironment:")
        print(f"  CMUX_SOCKET={os.environ.get('CMUX_SOCKET', '(auto-detect)')}")
        print(f"  CMUX_TEAM={TEAM}")
        print(f"  CMUX_WORKDIR={WORKDIR}")
        print(f"  CMUX_AGENT_NAME={AGENT_NAME or '(not set)'}")
        return

    sock = detect_socket()

    if args.command == "msg":
        if not args.msg_command:
            parser.parse_args(["msg", "--help"])
            return
        MSG_MAP[args.msg_command](sock, args)
    elif args.command == "task":
        if not args.task_command:
            parser.parse_args(["task", "--help"])
            return
        TASK_MAP[args.task_command](sock, args)
    else:
        COMMAND_MAP[args.command](sock, args)


if __name__ == "__main__":
    main()
