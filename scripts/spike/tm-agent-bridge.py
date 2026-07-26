#!/usr/bin/env python3
"""Speak an agent CLI's protocol on its behalf, and normalise what comes back.

Claude's channel is one-directional: write a line of NDJSON to its stdin and
that is the whole delivery. A FIFO is enough, so the process can sit in a pane
with its stdout going wherever it likes.

Cursor and agy are not that shape either, in the opposite direction: they have
no stdin channel at all. A turn *is* a process, and the thread is carried by an
id handed back — in cursor's answer, in agy's log file. So the bridge runs one
process per turn and keeps that id.

Codex and Kiro are not that shape. Both are request/response — `thread/start`
hands back a `threadId` that every later `turn/start` must carry, `session/new`
hands back a `sessionId` that every later `session/prompt` must carry. Whoever
delivers a turn has to be reading the replies, which a one-way pipe cannot do.
So something in the pane has to own both ends of the child's stdio: this.

It is also the only place the three vocabularies have to be reconciled. Each
turn ends differently — claude prints `{"type":"result"}`, codex sends a
`turn/completed` notification, kiro answers `session/prompt` with a
`stopReason` — and an app that learns all three learns them everywhere. So the
bridge emits **claude's shape** for every CLI, and everything upstream keeps
speaking one language:

    {"type":"assistant","message":{"content":[{"type":"text","text":…}]}}
    {"type":"result","stop_reason":"end_turn","result":…,"total_cost_usd":…}

Usage (the pane runs this instead of the CLI):

    tm-agent-bridge --cli codex --fifo <path> --events <path> [--model …]
"""

from __future__ import annotations

import argparse
import json
import os
import queue
import re
import subprocess
import sys
import threading
import time


def log(msg: str) -> None:
    print(f"\033[38;5;244m[bridge] {msg}\033[0m", flush=True)


class Child:
    """An agent CLI whose stdio this process owns."""

    def __init__(self, argv: list[str], cwd: str):
        env = dict(os.environ)
        # A nested agent CLI refuses to start when it thinks it is inside one.
        env.pop("CLAUDECODE", None)
        env.pop("CLAUDE_CODE_ENTRYPOINT", None)
        self.p = subprocess.Popen(
            argv, cwd=cwd, env=env,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            text=True, bufsize=1,
        )
        self.inbox: queue.Queue[dict] = queue.Queue()
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self) -> None:
        for line in self.p.stdout:
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(obj, dict):
                self.inbox.put(obj)
        self.inbox.put({"__eof__": True})

    def send(self, obj: dict) -> None:
        self.p.stdin.write(json.dumps(obj) + "\n")
        self.p.stdin.flush()

    @property
    def alive(self) -> bool:
        return self.p.poll() is None

    def stop(self) -> None:
        try:
            self.p.terminate()
            self.p.wait(timeout=5)
        except Exception:
            try:
                self.p.kill()
            except Exception:
                pass


class Emitter:
    """Everything upstream sees claude's vocabulary, whoever produced it."""

    def __init__(self, events_path: str | None):
        self.path = events_path
        self.fh = open(events_path, "a", encoding="utf-8") if events_path else None

    def emit(self, obj: dict) -> None:
        line = json.dumps(obj, ensure_ascii=False)
        if self.fh:
            self.fh.write(line + "\n")
            self.fh.flush()
        # stdout is the pane, and the renderer downstream reads the same shape.
        print(line, flush=True)

    def text(self, s: str) -> None:
        if s.strip():
            self.emit({"type": "assistant",
                       "message": {"content": [{"type": "text", "text": s}]}})

    def tool(self, name: str, headline: str) -> None:
        self.emit({"type": "assistant", "message": {"content": [
            {"type": "tool_use", "name": name, "input": {"command": headline}}]}})

    def tool_result(self, body: str, failed: bool = False) -> None:
        self.emit({"type": "user", "message": {"content": [
            {"type": "tool_result", "content": body, "is_error": failed}]}})

    def sent(self, s: str) -> None:
        self.emit({"type": "user", "message": {"role": "user", "content": s},
                   "isReplay": True})

    def result(self, final: str, stop: str = "end_turn", cost: float | None = None,
               failed: bool = False) -> None:
        obj = {"type": "result", "subtype": "error" if failed else "success",
               "is_error": failed, "stop_reason": stop, "result": final}
        if cost is not None:
            obj["total_cost_usd"] = cost
        self.emit(obj)


class JsonRpc:
    def __init__(self, child: Child, emitter: Emitter):
        self.child = child
        self.out = emitter
        self._id = 0

    def request(self, method: str, params: dict | None, timeout: float,
                on_notify=None) -> dict | None:
        self._id += 1
        rid = self._id
        payload = {"jsonrpc": "2.0", "id": rid, "method": method}
        if params is not None:
            payload["params"] = params
        self.child.send(payload)
        return self.pump(until_id=rid, timeout=timeout, on_notify=on_notify)

    def notify(self, method: str, params: dict | None = None) -> None:
        payload = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            payload["params"] = params
        self.child.send(payload)

    def pump(self, until_id: int | None, timeout: float, on_notify=None,
             until_method: str | None = None) -> dict | None:
        """Read until the answer we want, handing notifications to a callback.

        Every incoming line is offered to `on_notify` — a streaming protocol
        says most of what it has to say there, and dropping notifications while
        waiting for a response would throw the session away.
        """
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                obj = self.child.inbox.get(timeout=0.25)
            except queue.Empty:
                if not self.child.alive:
                    return None
                continue
            if obj.get("__eof__"):
                return None
            if "id" in obj and ("result" in obj or "error" in obj):
                if until_id is not None and obj.get("id") == until_id:
                    return obj
                continue
            if "method" in obj:
                if on_notify:
                    on_notify(obj)
                if until_method and obj["method"] == until_method:
                    return obj
        return None


# ── cursor, agy: a turn is a process ───────────────────────────────────────

class PerTurnBridge:
    """A CLI with no stdin channel, where each turn is its own process.

    This is not the terminal path in disguise. The answer arrives on stdout
    rather than on a screen, and the process exiting *is* the end-of-turn
    signal — plainer than any of the three protocols. What it costs is the
    context reloaded each turn, and an id that has to be kept to stay on the
    same thread.

    That id is the one place the two differ. Cursor puts it in the answer, so
    it is read from the same object as everything else. agy announces it only
    in its log file, so the bridge gives it a log to write and reads the line
    back out — string-scraping for state, which is what this whole exercise is
    trying to get away from, but it is a stable server log line rather than a
    rendered screen.
    """

    # agy's own words, from the server log it is told to write.
    AGY_CONVERSATION = re.compile(r"Created conversation ([0-9a-f-]{36})")

    def __init__(self, cli: str, cwd: str, model: str | None, emitter: Emitter):
        self.cli = cli
        self.cwd = cwd
        self.model = model
        self.out = emitter
        self.thread: str | None = None
        self.opened = False
        self.log_path = os.path.join(
            os.path.dirname(emitter.path or "") or "/tmp",
            f"agy-{os.getpid()}.log")

    # Nothing is running between turns, so there is nothing to be dead.
    alive = True

    def start(self) -> bool:
        self.out.emit({"type": "system", "subtype": "init", "cwd": self.cwd,
                       "model": self.model or "", "tools": []})
        # The session has been announced once. Cursor announces it again at the
        # head of every turn, because for cursor every turn is a new process —
        # which is exactly the thing this is hiding.
        self.opened = True
        return True

    def _argv(self, text: str) -> list[str]:
        if self.cli == "cursor":
            argv = ["cursor-agent", "-p", "--force",
                    "--output-format", "stream-json"]
            if self.model:
                argv += ["--model", self.model]
            if self.thread:
                argv += ["--resume", self.thread]
            return argv + [text]
        # `--print` is a string flag: it swallows the next token as the prompt,
        # so `agy --print --dangerously-skip-permissions "…"` asks agy to
        # explain that flag. Everything else has to come first.
        argv = ["agy", "--dangerously-skip-permissions", "--log-file", self.log_path]
        if self.thread:
            argv += ["--conversation", self.thread]
        else:
            # NOT `--continue`: that means "the most recent conversation" for
            # the whole machine, so two agents here would steal each other's
            # thread. The first turn starts fresh and pins the id afterwards.
            pass
        return argv + ["--print", text]

    def turn(self, text: str, timeout: float) -> None:
        self.out.sent(text)
        env = dict(os.environ)
        env.pop("CLAUDECODE", None)
        env.pop("CLAUDE_CODE_ENTRYPOINT", None)
        try:
            p = subprocess.Popen(self._argv(text), cwd=self.cwd, env=env,
                                 stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                 text=True, bufsize=1)
        except OSError as exc:
            self.out.result(f"could not start {self.cli}: {exc}",
                            stop="spawn_failed", failed=True)
            return

        said = self._read_cursor(p) if self.cli == "cursor" else self._read_agy(p)
        try:
            code = p.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            p.kill()
            self.out.result(f"{self.cli} did not finish in {timeout:.0f}s",
                            stop="timeout", failed=True)
            return

        if self.cli == "cursor":
            return  # cursor reports its own turn; see `_read_cursor`

        self.thread = self.thread or self._agy_thread()
        # A turn that ends with nothing said is not a success — reporting it as
        # one is how an empty answer becomes a completed task.
        if code != 0:
            self.out.result(said or f"{self.cli} exited {code}",
                            stop=f"exit_{code}", failed=True)
        elif not said.strip():
            self.out.result("the turn ended without an answer",
                            stop="empty", failed=True)
        else:
            self.out.result(said, stop="end_turn")

    def _read_cursor(self, p: subprocess.Popen) -> str:
        """Pass cursor's events through — they are already claude's shape.

        `system/init`, `user`, `assistant` with content blocks, `result` with
        `is_error` and `usage`: the only CLI here that needs no translation.
        What it needs instead is the per-turn process hidden — a fresh `init`
        every turn would redraw the session banner, and its echo of the prompt
        would read as a new question rather than the receipt for one.
        """
        thinking: list[str] = []
        for line in p.stdout:
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                o = json.loads(line)
            except json.JSONDecodeError:
                continue
            self.thread = o.get("session_id") or self.thread
            kind = o.get("type")
            if kind == "result":
                self._cursor_result(o)
                continue
            if kind == "tool_call":
                self._cursor_tool(o)
                continue
            if kind == "system":
                if self.opened:
                    continue
                self.opened = True
            elif kind == "user":
                continue  # already emitted as the receipt, with the sender known
            elif kind == "thinking":
                # Deltas, so they are joined and shown once rather than a rule
                # per fragment.
                if o.get("subtype") == "delta":
                    thinking.append(o.get("text", ""))
                elif thinking:
                    self.out.emit({"type": "assistant", "message": {"content": [
                        {"type": "thinking", "thinking": "".join(thinking)}]}})
                    thinking = []
                continue
            self.out.emit(o)
        return ""

    def _cursor_tool(self, o: dict) -> None:
        """`{"<name>ToolCall": {"args": …, "result": {"success"|"error": …}}}`.

        The tool's name is the wrapper key, which is the one shape here that
        has to be read structurally rather than by field.
        """
        call = o.get("tool_call") or {}
        key = next((k for k in call if k.endswith("ToolCall")), None)
        if not key:
            return
        body = call.get(key) or {}
        name = key[: -len("ToolCall")]
        if o.get("subtype") == "started":
            args = body.get("args") or {}
            headline = (args.get("command") or args.get("path")
                        or args.get("pattern") or args.get("query") or "")
            self.out.tool(name, str(headline))
            return
        result = body.get("result") or {}
        failed = "error" in result
        payload = result.get("error") if failed else result.get("success")
        if isinstance(payload, dict):
            payload = payload.get("content") or json.dumps(payload, ensure_ascii=False)
        self.out.tool_result(str(payload or "")[:400], failed=failed)

    def _cursor_result(self, o: dict) -> None:
        """Cursor's own verdict, with one correction.

        Measured: asked to recall a word, cursor worked it out in its reasoning
        — "The word is TANGERINE" — emitted no assistant text, and ended the
        turn `is_error: false` with `result: ""`. Passed through, that is a
        completed task with no answer in it. The turn did end, so it must not
        sit open; but nothing was said, so it cannot be called a success. The
        reasoning is not promoted into the answer — inventing one from what the
        model was thinking is worse than saying nothing was said.
        """
        said = (o.get("result") or "").strip()
        if not said and not o.get("is_error"):
            o = dict(o, is_error=True, subtype="error", stop_reason="empty",
                     result="the turn ended with an answer only in its reasoning")
        self.out.emit(o)

    def _read_agy(self, p: subprocess.Popen) -> str:
        """agy answers in plain text, so the whole answer is one block.

        Emitting each line as it arrives would draw a rule per line; there is
        no structure here to tell a paragraph from a tool's output.
        """
        lines = []
        for line in p.stdout:
            # Its argument parser complains on stdout before answering.
            if line.startswith("# Un-recognized argument"):
                continue
            lines.append(line.rstrip("\n"))
        said = "\n".join(lines).strip()
        self.out.text(said)
        return said

    def _agy_thread(self) -> str | None:
        try:
            with open(self.log_path, encoding="utf-8", errors="replace") as fh:
                found = self.AGY_CONVERSATION.findall(fh.read())
        except OSError:
            return None
        return found[-1] if found else None

    def stop(self) -> None:
        pass


# ── codex: initialize → thread/start → turn/start … turn/completed ──────────

class CodexBridge:
    def __init__(self, cwd: str, model: str | None, emitter: Emitter):
        argv = ["codex", "app-server"]
        self.child = Child(argv, cwd)
        self.rpc = JsonRpc(self.child, emitter)
        self.out = emitter
        self.cwd = cwd
        self.model = model
        self.thread_id: str | None = None

    def start(self) -> bool:
        init = self.rpc.request("initialize", {
            "clientInfo": {"name": "term-mesh-bridge", "version": "0.1.0"}}, 30)
        if not init or "error" in init:
            log(f"codex initialize failed: {json.dumps(init)[:160] if init else 'no reply'}")
            return False
        self.rpc.notify("initialized")
        started = self.rpc.request("thread/start", {"cwd": self.cwd}, 30)
        res = (started or {}).get("result") or {}
        # Nested: {"result":{"thread":{"id":…}}} — not `result.threadId`.
        self.thread_id = (res.get("thread") or {}).get("id") or res.get("threadId")
        if not self.thread_id:
            log(f"codex thread/start gave no id: {json.dumps(started)[:160] if started else 'no reply'}")
            return False
        self.out.emit({"type": "system", "subtype": "init",
                       "cwd": self.cwd, "model": self.model or "", "tools": []})
        return True

    def turn(self, text: str, timeout: float) -> None:
        self.out.sent(text)
        said: list[str] = []

        def notify(o: dict) -> None:
            m = o.get("method", "")
            p = o.get("params") or {}
            if m == "item/completed":
                item = p.get("item") or {}
                kind = item.get("type") or item.get("itemType")
                if kind in ("agentMessage", "assistant_message", "message"):
                    body = item.get("text") or item.get("content") or ""
                    if isinstance(body, list):
                        body = "".join(b.get("text", "") for b in body if isinstance(b, dict))
                    if body:
                        said.append(body)
                        self.out.text(body)
                elif kind in ("commandExecution", "command_execution"):
                    self.out.tool("shell", item.get("command", ""))
                elif kind in ("fileChange", "file_change", "patchApply"):
                    self.out.tool("edit", str(item.get("path", "")))

        params = {"threadId": self.thread_id,
                  "input": [{"type": "text", "text": text}]}
        if self.model:
            params["model"] = self.model
        # `turn/start` acknowledges at once; the work arrives as notifications
        # and ends with `turn/completed`. Waiting on the response alone measures
        # how fast codex says "got it".
        ack = self.rpc.request("turn/start", params, 30, on_notify=notify)

        # A rejected turn still completes, instantly and with nothing said. The
        # first version of this reported that as a successful empty answer —
        # the same silent-success shape this whole exercise keeps turning up.
        # An unusable `--model` is the easy way to reproduce it.
        if ack and "error" in ack:
            detail = json.dumps(ack["error"], ensure_ascii=False)[:300]
            log(f"codex refused the turn: {detail}")
            self.out.result(detail, stop="rejected", failed=True)
            return
        if ack is None:
            self.out.result("codex never acknowledged the turn",
                            stop="no_ack", failed=True)
            return

        done = self.rpc.pump(until_id=None, timeout=timeout,
                             on_notify=notify, until_method="turn/completed")
        final = "\n".join(said)
        if done and not final.strip():
            # Ended without saying anything. Reporting that as a success is how
            # an empty answer becomes a completed task.
            self.out.result("the turn ended without an answer",
                            stop="empty", failed=True)
            return
        usage = ((done or {}).get("params") or {}).get("usage") or {}
        self.out.result(final, stop="end_turn" if done else "timeout",
                        cost=usage.get("total_cost_usd"))

    @property
    def alive(self) -> bool:
        return self.child.alive

    def stop(self) -> None:
        self.child.stop()


# ── kiro: ACP — initialize → session/new → session/prompt … stopReason ──────

class AcpBridge:
    def __init__(self, argv: list[str], cwd: str, emitter: Emitter):
        self.child = Child(argv, cwd)
        self.rpc = JsonRpc(self.child, emitter)
        self.out = emitter
        self.cwd = cwd
        self.session: str | None = None

    def start(self) -> bool:
        init = self.rpc.request("initialize", {
            "protocolVersion": 1,
            "clientCapabilities": {"fs": {"readTextFile": False,
                                          "writeTextFile": False}}}, 60)
        if not init or "error" in init:
            log(f"acp initialize failed: {json.dumps(init)[:200] if init else 'no reply'}")
            return False
        new = self.rpc.request("session/new", {"cwd": self.cwd, "mcpServers": []}, 90)
        self.session = ((new or {}).get("result") or {}).get("sessionId")
        if not self.session:
            log(f"acp session/new failed: {json.dumps(new)[:220] if new else 'no reply'}")
            return False
        self.out.emit({"type": "system", "subtype": "init", "cwd": self.cwd, "tools": []})
        return True

    def turn(self, text: str, timeout: float) -> None:
        self.out.sent(text)
        said: list[str] = []

        def notify(o: dict) -> None:
            if o.get("method") != "session/update":
                return
            u = (o.get("params") or {}).get("update") or {}
            kind = u.get("sessionUpdate")
            if kind == "agent_message_chunk":
                # Chunks, so they are joined rather than each printed as a line.
                said.append((u.get("content") or {}).get("text", ""))
            elif kind == "tool_call":
                self.out.tool(u.get("title") or u.get("kind") or "tool",
                              str(u.get("rawInput") or "")[:200])
            elif kind == "tool_call_update":
                status = u.get("status")
                if status in ("completed", "failed"):
                    self.out.tool_result(str(u.get("content") or "")[:400],
                                         failed=status == "failed")

        resp = self.rpc.request("session/prompt", {
            "sessionId": self.session,
            "prompt": [{"type": "text", "text": text}]}, timeout, on_notify=notify)
        final = "".join(said)
        self.out.text(final)
        stop = ((resp or {}).get("result") or {}).get("stopReason") or "timeout"
        self.out.result(final, stop=stop)

    @property
    def alive(self) -> bool:
        return self.child.alive

    def stop(self) -> None:
        self.child.stop()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--cli", required=True,
                    choices=["codex", "kiro", "gemini", "cursor", "agy"])
    ap.add_argument("--fifo", required=True, help="turns arrive here, one per line")
    ap.add_argument("--events", help="normalised events are appended here too")
    ap.add_argument("--cwd", default=None)
    ap.add_argument("--model", default=None)
    ap.add_argument("--turn-timeout", type=float, default=600.0)
    args = ap.parse_args()

    cwd = args.cwd or os.getcwd()
    out = Emitter(args.events)

    if args.cli in ("cursor", "agy"):
        bridge = PerTurnBridge(args.cli, cwd, args.model, out)
    elif args.cli == "codex":
        bridge = CodexBridge(cwd, args.model, out)
    elif args.cli == "kiro":
        # `kiro-cli acp`, NOT `kiro-cli chat acp`: both parse and only the first
        # is a server. The second starts the interactive chat agent, which reads
        # the handshake as a user message and answers it in prose.
        bridge = AcpBridge(["kiro-cli", "acp", "--trust-all-tools"], cwd, out)
    else:
        bridge = AcpBridge(["gemini", "--acp", "--yolo"], cwd, out)

    if not bridge.start():
        out.result("", stop="startup_failed", failed=True)
        bridge.stop()
        return 1
    log(f"{args.cli} ready — waiting for turns on {args.fifo}")

    try:
        while True:
            # Reopening blocks until a writer arrives, which is what keeps this
            # idle between turns without spinning.
            with open(args.fifo, encoding="utf-8") as fifo:
                for line in fifo:
                    line = line.strip()
                    if not line:
                        continue
                    # Turns arrive in claude's envelope, so the caller does not
                    # need to know which CLI is behind this.
                    try:
                        obj = json.loads(line)
                        text = obj.get("message", {}).get("content", "")
                        if isinstance(text, list):
                            text = "".join(b.get("text", "") for b in text
                                           if isinstance(b, dict))
                    except json.JSONDecodeError:
                        text = line
                    if not text:
                        continue
                    bridge.turn(text, args.turn_timeout)
            if not bridge.alive:
                log("agent exited")
                break
    except KeyboardInterrupt:
        pass
    finally:
        bridge.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
