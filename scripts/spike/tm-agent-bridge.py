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
import shlex
import stat
import subprocess
import sys
import tempfile
import threading
import time


PROFILE_LOAD_EXIT = 77
AGENT_ENV_LOAD_EXIT = 78

# What a tool is allowed to say for itself. 400 characters was about five lines
# of shell output, and a patch is the one kind of output where reading it is the
# entire point of showing the row at all.
TEXT_LIMIT = 4000
DIFF_LIMIT = 65536


def clamp(text: str, limit: int) -> str:
    """Cut long output at a line boundary, and say that it was cut.

    Mid-line is fine for a shell log and wrong for a patch: half a hunk header
    is not a diff any more, and a reader that knows how to draw one would be
    handed something that cannot be drawn. So the cut lands between lines, and
    the tail says how much is missing rather than the text simply stopping and
    letting that pass for all of it.
    """
    if len(text) <= limit:
        return text
    head = text[:limit]
    edge = head.rfind("\n")
    if edge > 0:
        head = head[:edge]
    dropped = text[len(head):].count("\n") + 1
    return f"{head}\n… {dropped} more lines"


def remote_launch_failure(code: int | None) -> str | None:
    """Turn wrapper-only exit codes into safe, actionable UI messages."""
    if code == PROFILE_LOAD_EXIT:
        return "remote agent could not load ~/.profile"
    if code == AGENT_ENV_LOAD_EXIT:
        return (
            "remote agent could not load "
            "~/.config/term-mesh/agent-env"
        )
    return None


def process_location(argv: list[str], cwd: str) -> tuple[list[str], str | None]:
    """Move a child process behind SSH when the native pane hosts a peer agent."""
    raw = os.environ.get("TERMMESH_REMOTE_NATIVE_SSH_ARGS")
    if not raw:
        return argv, cwd
    try:
        ssh = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise OSError(f"invalid remote SSH arguments: {exc}") from exc
    if not isinstance(ssh, list) or not ssh or not all(isinstance(v, str) for v in ssh):
        raise OSError("invalid remote SSH arguments")
    remote_cwd = os.environ.get("TERMMESH_REMOTE_NATIVE_CWD") or cwd
    quoted_cwd = shlex.quote(remote_cwd)
    remote_env = {}
    raw_env = os.environ.get("TERMMESH_REMOTE_NATIVE_ENV")
    if raw_env:
        try:
            remote_env = json.loads(raw_env)
        except json.JSONDecodeError as exc:
            raise OSError(f"invalid remote environment: {exc}") from exc
        if not isinstance(remote_env, dict) or not all(
            isinstance(k, str) and isinstance(v, str)
            for k, v in remote_env.items()
        ):
            raise OSError("invalid remote environment")
    assignments = [
        f"{key}={value}"
        for key, value in sorted(remote_env.items())
        if key != "PATH"
        and key
        and key.replace("_", "a").isalnum()
        and not key[0].isdigit()
    ]
    # Peer-hosted terminal surfaces already carry this marker. Claude uses it
    # to permit explicitly requested bypass mode under root; native SSH must
    # preserve the same host contract instead of behaving differently.
    remote_path = (
        "$HOME/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:"
        "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    )
    # `-l` below loads the account's shell-specific login profile. Bash skips
    # `.profile` when `.bash_profile`/`.bash_login` exists, and zsh never reads
    # it, so add the literal `.profile` only for those standard cases. This
    # avoids double-sourcing it for the normal bash/sh fallback path.
    #
    # `agent-env` is a Bourne-compatible opt-in shell fragment, loaded after
    # profiles and before explicit host environment values. Keep sourced stdout
    # away from app-server's JSON-RPC stream.
    profile = "$HOME/.profile"
    agent_env = "$HOME/.config/term-mesh/agent-env"
    inner = (
        'case "${SHELL##*/}" in '
        f'bash) if {{ [ -f "$HOME/.bash_profile" ] || '
        f'[ -f "$HOME/.bash_login" ]; }} && [ -f "{profile}" ]; then '
        f'. "{profile}" >/dev/null || exit {PROFILE_LOAD_EXIT}; fi ;; '
        f'zsh) if [ -f "{profile}" ]; then '
        f'. "{profile}" >/dev/null || exit {PROFILE_LOAD_EXIT}; fi ;; '
        'esac; '
        f'if [ -f "{agent_env}" ]; then '
        f'set -a; . "{agent_env}" >/dev/null || '
        f'exit {AGENT_ENV_LOAD_EXIT}; set +a; fi; '
        f'export PATH="{remote_path}"; '
        "exec env IS_SANDBOX=1 " + shlex.join(assignments + argv)
    )
    command = (
        f"mkdir -p {quoted_cwd} && cd {quoted_cwd} && "
        f'exec "${{SHELL:-/bin/sh}}" -lc {shlex.quote(inner)}'
    )
    return ssh + [command], None


def acp_text(content) -> str:
    """Pull the text out of ACP content blocks.

    `[{"type": "content", "content": {"type": "text", "text": …}}]` is the
    nested shape; `[{"type": "text", "text": …}]` the flat one. Both appear.
    """
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    out = []
    for block in content:
        if not isinstance(block, dict):
            continue
        inner = block.get("content")
        if isinstance(inner, dict) and inner.get("type") == "text":
            out.append(inner.get("text", ""))
        elif block.get("type") == "text":
            out.append(block.get("text", ""))
        elif isinstance(inner, str):
            out.append(inner)
    return "".join(out)


def log(msg: str) -> None:
    # Colour only for a terminal. When the app hosts this there is nothing to
    # interpret the escapes, and they would arrive as literal garbage in a view
    # that draws text rather than cells.
    if sys.stdout.isatty():
        print(f"\033[38;5;244m[bridge] {msg}\033[0m", flush=True)
    else:
        print(f"[bridge] {msg}", flush=True)


def stop_process(p: subprocess.Popen, timeout: float = 5) -> None:
    """Stop, reap, and close a child; safe to call more than once."""
    try:
        if p.poll() is None:
            try:
                p.terminate()
            except (OSError, ProcessLookupError):
                pass
            try:
                p.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                try:
                    p.kill()
                except (OSError, ProcessLookupError):
                    pass
                try:
                    p.wait()
                except (OSError, ChildProcessError):
                    pass
        else:
            try:
                p.wait()
            except (OSError, ChildProcessError):
                pass
    finally:
        for stream in (p.stdin, p.stdout):
            if stream is not None:
                try:
                    stream.close()
                except (OSError, ValueError):
                    pass


class Child:
    """An agent CLI whose stdio this process owns."""

    def __init__(self, argv: list[str], cwd: str):
        env = dict(os.environ)
        # A nested agent CLI refuses to start when it thinks it is inside one.
        env.pop("CLAUDECODE", None)
        env.pop("CLAUDE_CODE_ENTRYPOINT", None)
        argv, process_cwd = process_location(argv, cwd)
        self.p = subprocess.Popen(
            argv, cwd=process_cwd, env=env,
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

    def exit_code(self) -> int | None:
        try:
            return self.p.wait(timeout=0.1)
        except subprocess.TimeoutExpired:
            return self.p.poll()

    def stop(self) -> None:
        stop_process(self.p)


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

    def tool(self, name: str, headline: str = "", call_id: str = "",
             fields: dict | None = None) -> None:
        """Open a tool row.

        The id is what lets a result land on the call it answers. Without it the
        row it opened never closes, and a spinner spins forever.

        `headline` is the one-field shorthand every caller started with, and it
        still means `{"command": …}`. `fields` is for a call that knows more
        than a line of text — a path, a patch, which of add/update/delete it is
        — and it goes through as written, because the reader downstream picks
        its own field out of it rather than being handed a sentence to re-parse.

        A caller with `fields` must not also send `command`: the reader tries
        that key first, so a `command` present at all hides the path behind it.
        """
        body = dict(fields) if fields is not None else {"command": headline}
        block = {"type": "tool_use", "name": name, "input": body}
        if call_id:
            block["id"] = call_id
        self.emit({"type": "assistant", "message": {"content": [block]}})

    def tool_result(self, body: str, failed: bool = False, call_id: str = "") -> None:
        block = {"type": "tool_result", "content": body, "is_error": failed}
        if call_id:
            block["tool_use_id"] = call_id
        self.emit({"type": "user", "message": {"content": [block]}})

    # ── streaming ──────────────────────────────────────────────────────
    #
    # Every CLI here streams, and each calls it something else: claude emits
    # the Anthropic block/delta shape wrapped in `stream_event`, codex sends
    # `item/agentMessage/delta` with a bare `delta` string, kiro sends ACP
    # `agent_message_chunk`. Measured on one 60-word answer: codex, 163 deltas.
    #
    # So the bridge speaks claude's shape here too, and everything upstream —
    # the renderer, the native pane — learns one vocabulary instead of three.
    # `message_start` matters more than it looks: it is what tells a reader a
    # new message is beginning, so a complete message arriving after a streamed
    # one is not drawn twice.

    def turn_begins(self) -> None:
        self.emit({"type": "stream_event", "event": {"type": "message_start",
                                                     "message": {"role": "assistant"}}})
        self._open = False

    def delta(self, text: str, thinking: bool = False) -> None:
        if not text:
            return
        if not getattr(self, "_open", False):
            self.emit({"type": "stream_event", "event": {
                "type": "content_block_start", "index": 0,
                "content_block": {"type": "thinking" if thinking else "text"}}})
            self._open = True
        key = "thinking" if thinking else "text"
        self.emit({"type": "stream_event", "event": {
            "type": "content_block_delta", "index": 0,
            "delta": {"type": f"{key}_delta", key: text}}})

    def block_done(self) -> None:
        if getattr(self, "_open", False):
            self.emit({"type": "stream_event",
                       "event": {"type": "content_block_stop", "index": 0}})
            self._open = False

    def streamed(self) -> bool:
        return getattr(self, "_streamed_any", False)

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
    def __init__(self, child: Child, emitter: Emitter, on_request=None):
        self.child = child
        self.out = emitter
        self._id = 0
        self.failure: str | None = None
        # Answers a request coming the other way, or None to refuse them all.
        self.on_request = on_request

    def _record_exit_failure(self) -> None:
        self.failure = remote_launch_failure(self.child.exit_code())

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

    def respond(self, rid, result: dict | None = None,
                error: dict | None = None) -> None:
        frame = {"jsonrpc": "2.0", "id": rid}
        if error is not None:
            frame["error"] = error
        else:
            frame["result"] = {} if result is None else result
        self.child.send(frame)

    def _serve(self, obj: dict) -> None:
        """Answer a frame carrying *both* an id and a method.

        That is a request coming the other way, and a request is the one thing
        that cannot be dropped: the peer is blocked on the answer. Codex asks
        for approval this way, so a bridge that only ever listened left the
        patch unapplied — and with no patch applied there is no `item/completed`
        to draw, which is why an edit that plainly happened showed up as nothing
        at all.

        Anything the caller does not claim gets an error back rather than
        silence. A refused request fails a turn; an unanswered one hangs it, and
        a hung turn is the harder failure to read.
        """
        rid = obj.get("id")
        answer = self.on_request(obj) if self.on_request else None
        if answer is None:
            self.respond(rid, error={
                "code": -32601,
                "message": f"unsupported request: {obj.get('method', '')}"})
        else:
            self.respond(rid, result=answer)

    def pump(self, until_id: int | None, timeout: float, on_notify=None,
             until_method: str | None = None) -> dict | None:
        """Read until the answer we want, handing notifications to a callback.

        Every incoming line is offered to `on_notify` — a streaming protocol
        says most of what it has to say there, and dropping notifications while
        waiting for a response would throw the session away.

        A frame with a method *and* an id is not a notification at all; it is
        the peer asking us something and waiting. Those are answered here,
        before anything else, because everything queued behind one is waiting
        too.
        """
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            try:
                obj = self.child.inbox.get(timeout=min(0.25, remaining))
            except queue.Empty:
                if not self.child.alive:
                    self._record_exit_failure()
                    return None
                continue
            if obj.get("__eof__"):
                self._record_exit_failure()
                return None
            if "id" in obj and ("result" in obj or "error" in obj):
                if until_id is not None and obj.get("id") == until_id:
                    return obj
                continue
            if "method" in obj:
                if "id" in obj:
                    self._serve(obj)
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

    def __init__(self, cli: str, cwd: str, model: str | None, emitter: Emitter,
                 exe: str | None = None):
        self.cli = cli
        self.exe = exe
        self.cwd = cwd
        self.model = model
        self.out = emitter
        self.thread: str | None = None
        self.opened = False
        self.log_dir: str | None = None
        self.log_path: str | None = None

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
            argv = [self.exe or "cursor-agent", "-p", "--force",
                    "--output-format", "stream-json"]
            if self.model:
                argv += ["--model", self.model]
            if self.thread:
                argv += ["--resume", self.thread]
            return argv + [text]
        # `--print` is a string flag: it swallows the next token as the prompt,
        # so `agy --print --dangerously-skip-permissions "…"` asks agy to
        # explain that flag. Everything else has to come first.
        self._ensure_agy_log()
        argv = [self.exe or "agy", "--dangerously-skip-permissions",
                "--log-file", self.log_path]
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
            argv, process_cwd = process_location(self._argv(text), self.cwd)
            p = subprocess.Popen(argv, cwd=process_cwd, env=env,
                                 stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                 text=True, bufsize=1)
        except OSError as exc:
            self.out.result(f"could not start {self.cli}: {exc}",
                            stop="spawn_failed", failed=True)
            return

        deadline = time.monotonic() + timeout
        read_done: queue.Queue[tuple[str, BaseException | None]] = queue.Queue()

        def read_stdout() -> None:
            try:
                said = (self._read_cursor(p) if self.cli == "cursor"
                        else self._read_agy(p))
                read_done.put((said, None))
            except BaseException as exc:
                read_done.put(("", exc))

        reader = threading.Thread(target=read_stdout, daemon=True)
        reader.start()
        try:
            code = p.wait(timeout=max(0, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            stop_process(p, timeout=0.1)
            reader.join(timeout=0.1)
            self.out.result(f"{self.cli} did not finish in {timeout:g}s",
                            stop="timeout", failed=True)
            return

        remaining = deadline - time.monotonic()
        try:
            said, read_error = read_done.get(timeout=max(0, remaining))
        except queue.Empty:
            stop_process(p, timeout=0.1)
            self.out.result(f"{self.cli} did not finish in {timeout:g}s",
                            stop="timeout", failed=True)
            return
        finally:
            if not p.stdout.closed:
                p.stdout.close()

        if read_error is not None:
            self.out.result(f"could not read {self.cli} output: {read_error}",
                            stop="read_failed", failed=True)
            return

        failure = remote_launch_failure(code)
        if failure:
            self.out.result(failure, stop="environment_failed", failed=True)
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
        self.out.tool_result(clamp(str(payload or ""), TEXT_LIMIT), failed=failed)

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
        if not self.log_path:
            return None
        try:
            flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
            fd = os.open(self.log_path, flags)
            metadata = os.fstat(fd)
            if (not stat.S_ISREG(metadata.st_mode)
                    or metadata.st_uid != os.getuid()
                    or stat.S_IMODE(metadata.st_mode) & 0o077):
                os.close(fd)
                return None
            with os.fdopen(fd, encoding="utf-8", errors="replace") as fh:
                found = self.AGY_CONVERSATION.findall(fh.read())
        except OSError:
            return None
        return found[-1] if found else None

    def _ensure_agy_log(self) -> None:
        if self.log_path:
            return
        directory = tempfile.mkdtemp(
            prefix=f"term-mesh-agy-{os.getuid()}-",
            dir=tempfile.gettempdir(),
        )
        os.chmod(directory, 0o700)
        try:
            fd, path = tempfile.mkstemp(
                prefix="conversation-", suffix=".log", dir=directory)
            os.fchmod(fd, 0o600)
            os.close(fd)
        except BaseException:
            os.rmdir(directory)
            raise
        self.log_dir = directory
        self.log_path = path

    def stop(self) -> None:
        if self.log_path:
            try:
                os.unlink(self.log_path)
            except OSError:
                pass
        if self.log_dir:
            try:
                os.rmdir(self.log_dir)
            except OSError:
                pass
        self.log_path = None
        self.log_dir = None


# ── codex: initialize → thread/start → turn/start … turn/completed ──────────

class CodexBridge:
    # What to say when codex asks permission. There is nobody at this end of
    # the pipe to ask: the pane runs an agent, not a person watching for a
    # prompt, so an unanswered request is a turn that never ends.
    #
    # This is not a new posture, it is the existing one said over JSON-RPC. The
    # app already hands the codex TUI `--ask-for-approval never --sandbox
    # danger-full-access`, claude `--dangerously-skip-permissions`, kiro
    # `--trust-all-tools`, gemini `--yolo`. A bridge that alone withheld
    # consent would not be safer — it would be the one CLI whose pane quietly
    # stopped, which is the symptom this is fixing.
    #
    # `TERMMESH_AGENT_APPROVALS=ask` declines instead. Nothing here can put the
    # question to a person, so declining is the honest other answer: the turn
    # ends and says it was refused, rather than hanging.
    APPROVALS = {
        "item/fileChange/requestApproval": ("decision", "accept", "decline"),
        "item/commandExecution/requestApproval": ("decision", "accept", "decline"),
        # Pre-v2 names. A current server never sends these; an older one sends
        # nothing else.
        "applyPatchApproval": ("decision", "approved", "denied"),
        "execCommandApproval": ("decision", "approved", "denied"),
    }

    def __init__(self, cwd: str, model: str | None, emitter: Emitter,
                 exe: str | None = None):
        argv = [exe or "codex", "app-server"]
        self.child = Child(argv, cwd)
        self.rpc = JsonRpc(self.child, emitter, on_request=self._serve_request)
        self.out = emitter
        self.cwd = cwd
        self.model = model
        self.thread_id: str | None = None

    def _serve_request(self, obj: dict) -> dict | None:
        method = obj.get("method", "")
        ask = os.environ.get("TERMMESH_AGENT_APPROVALS") == "ask"
        if method in self.APPROVALS:
            key, yes, no = self.APPROVALS[method]
            return {key: no if ask else yes}
        if method == "item/permissions/requestApproval":
            if ask:
                return {"permissions": {}, "scope": "turn"}
            # Grant what was asked for and no more. Widening a request we did
            # not read is not ours to do.
            asked = (obj.get("params") or {}).get("permissions") or {}
            granted = {k: v for k, v in asked.items() if v is not None}
            return {"permissions": granted, "scope": "session"}
        if method == "mcpServer/elicitation/request":
            # An MCP server asking the *user* something. We cannot ask, and
            # inventing an answer would put words in their mouth. Declining is
            # a thing servers know how to handle; silence is not — and this one
            # arrives whatever the approval policy says, so it is its own way
            # for a pane to stop.
            return {"action": "decline", "content": None, "_meta": None}
        if method == "currentTime/read":
            return {"currentTimeAt": int(time.time() * 1000)}
        return None

    def start(self) -> bool:
        init = self.rpc.request("initialize", {
            "clientInfo": {"name": "term-mesh-bridge", "version": "0.1.0"}}, 30)
        if not init or "error" in init:
            log(f"codex initialize failed: {json.dumps(init)[:160] if init else 'no reply'}")
            return False
        self.rpc.notify("initialized")
        # `sandbox`, not `sandboxPolicy`: that is `turn/start`'s field, and a
        # tagged object rather than a mode name. Named wrongly it is simply
        # ignored, and the difference only shows up as an agent that cannot
        # write anything.
        started = self.rpc.request("thread/start", {
            "cwd": self.cwd,
            "approvalPolicy": "never",
            "sandbox": "danger-full-access"}, 30)
        self.thread_id = self._thread_id(started)
        if not self.thread_id:
            # Measured: codex ignores a field it does not know, but rejects a
            # *value* it does not know outright. So if these names are ever
            # retired the thread never starts at all — and a pane that has to
            # ask permission beats no pane.
            log("codex would not start with an approval policy; retrying plain")
            started = self.rpc.request("thread/start", {"cwd": self.cwd}, 30)
            self.thread_id = self._thread_id(started)
        if not self.thread_id:
            log(f"codex thread/start gave no id: {json.dumps(started)[:160] if started else 'no reply'}")
            return False
        self.out.emit({"type": "system", "subtype": "init",
                       "cwd": self.cwd, "model": self.model or "", "tools": []})
        return True

    @staticmethod
    def _thread_id(started: dict | None) -> str | None:
        res = (started or {}).get("result") or {}
        # Nested: {"result":{"thread":{"id":…}}} — not `result.threadId`.
        return (res.get("thread") or {}).get("id") or res.get("threadId")

    def turn(self, text: str, timeout: float) -> None:
        self.out.sent(text)
        self.out.turn_begins()
        said: list[str] = []
        streamed = [False]

        def notify(o: dict) -> None:
            m = o.get("method", "")
            p = o.get("params") or {}
            if m == "item/agentMessage/delta":
                chunk = p.get("delta") or ""
                if chunk:
                    streamed[0] = True
                    said.append(chunk)
                    self.out.delta(chunk)
                return
            if m == "item/completed":
                item = p.get("item") or {}
                kind = item.get("type") or item.get("itemType")
                if kind in ("agentMessage", "assistant_message", "message"):
                    # Already drawn delta by delta; the completed item is the
                    # same text arriving whole.
                    if streamed[0]:
                        self.out.block_done()
                        return
                    body = item.get("text") or item.get("content") or ""
                    if isinstance(body, list):
                        body = "".join(b.get("text", "") for b in body if isinstance(b, dict))
                    if body:
                        said.append(body)
                        self.out.text(body)
                elif kind in ("commandExecution", "command_execution"):
                    # One event, both halves: codex reports the finished item,
                    # so opening a row and leaving it open would spin forever.
                    cid = str(item.get("id") or "")
                    self.out.tool("shell", item.get("command", ""), call_id=cid)
                    failed = bool(item.get("exitCode") or item.get("exit_code"))
                    self.out.tool_result(
                        clamp(str(item.get("aggregatedOutput")
                                  or item.get("output") or ""), TEXT_LIMIT),
                        failed=failed, call_id=cid)
                elif kind in ("fileChange", "file_change"):
                    self._file_change(item)

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
        self.out.block_done()
        final = ("" if streamed[0] else "\n").join(said)
        if done and not final.strip():
            # Ended without saying anything. Reporting that as a success is how
            # an empty answer becomes a completed task.
            self.out.result("the turn ended without an answer",
                            stop="empty", failed=True)
            return
        # `turn/completed` carries `{threadId, turn}` and no usage at all, so
        # there is no cost to report here. Reading one out of a key that does
        # not exist looked like the number was simply always zero.
        self.out.result(final, stop="end_turn" if done else "timeout",
                        failed=done is None)

    CHANGE_TOOL = {"add": "write", "update": "edit", "delete": "delete"}

    def _file_change(self, item: dict) -> None:
        """One row per file, because that is how an edit is read.

        Codex reports a *patch*: `changes` is a list, and each entry carries the
        path, which of add/update/delete it is, and that file's unified diff.
        There is no `path` on the item itself — which is why the row that read
        one drew a tool name against an empty line, and why the empty result
        sent after it took the disclosure control away too, leaving a row that
        announced an edit and then refused to say which file, let alone what.

        The diff goes out twice on purpose: in the call's input, where a reader
        that can draw a diff finds it under `unified_diff`, and in the result,
        where a reader that cannot still has the text.
        """
        item_id = str(item.get("id") or "")
        failed = str(item.get("status") or "") in ("failed", "declined")
        changes = item.get("changes")
        if not isinstance(changes, list):
            return
        for index, change in enumerate(changes):
            if not isinstance(change, dict):
                continue
            path = str(change.get("path") or "")
            kind = change.get("kind")
            if not isinstance(kind, dict):
                kind = {"type": str(kind or "")}
            name = str(kind.get("type") or "update")
            raw = str(change.get("diff") or "")
            diff = clamp(raw, DIFF_LIMIT)
            fields = {"file_path": path, "kind": name, "unified_diff": diff}
            if kind.get("move_path"):
                fields["move_path"] = str(kind["move_path"])
            if diff != raw:
                fields["diff_truncated"] = True
            # One item, several files, and a result has to find the row it
            # answers — so the item's own id is not enough to go around.
            cid = f"{item_id}#{index}" if item_id else ""
            self.out.tool(self.CHANGE_TOOL.get(name, "edit"),
                          call_id=cid, fields=fields)
            # An empty result closes a row with nothing under it, which is the
            # shape this was fixing. Say what happened instead.
            self.out.tool_result(diff or f"{name} {path}".strip(),
                                 failed=failed, call_id=cid)

    @property
    def alive(self) -> bool:
        return self.child.alive

    def stop(self) -> None:
        self.child.stop()


# ── kiro: ACP — initialize → session/new → session/prompt … stopReason ──────

class AcpBridge:
    def __init__(self, argv: list[str], cwd: str, emitter: Emitter,
                 model: str | None = None):
        self.child = Child(argv, cwd)
        self.rpc = JsonRpc(self.child, emitter)
        self.out = emitter
        self.cwd = cwd
        self.model = model
        self.session: str | None = None
        # A tool's output can arrive across several updates, before the one
        # that reports its status.
        self.tool_output: dict[str, str] = {}

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
        # ACP's handshake reports capabilities, not a model name, so the one we
        # were told to ask for is the only thing there is to say. Without it the
        # pane header has nothing but the agent's own name.
        self.out.emit({"type": "system", "subtype": "init", "cwd": self.cwd,
                       "model": self.model or "", "tools": []})
        return True

    def turn(self, text: str, timeout: float) -> None:
        self.out.sent(text)
        self.out.turn_begins()
        said: list[str] = []

        def notify(o: dict) -> None:
            if o.get("method") != "session/update":
                return
            u = (o.get("params") or {}).get("update") or {}
            kind = u.get("sessionUpdate")
            if kind == "agent_message_chunk":
                # These were always chunks. Joining them and showing the result
                # at the end threw away the one thing they were good for.
                chunk = (u.get("content") or {}).get("text", "")
                said.append(chunk)
                self.out.delta(chunk)
            elif kind == "tool_call":
                # `str(dict)` is a python repr, and a python repr is what this
                # row has been drawing where a path belongs. Hand the object
                # over and let the reader pick its own field out of it.
                raw = u.get("rawInput")
                fields = raw if isinstance(raw, dict) else None
                self.out.tool(u.get("title") or u.get("kind") or "tool",
                              "" if fields else str(raw or "")[:200],
                              call_id=str(u.get("toolCallId") or ""),
                              fields=fields)
            elif kind == "tool_call_update":
                cid = str(u.get("toolCallId") or "")
                # ACP's content is a list of content blocks, sometimes nested
                # one deeper. Stringifying it gave a python repr — or, when it
                # arrived on an earlier update than the status, nothing at all,
                # which is why these rows closed with no output.
                text = acp_text(u.get("content"))
                if text:
                    self.tool_output[cid] = self.tool_output.get(cid, "") + text
                status = u.get("status")
                if status in ("completed", "failed"):
                    self.out.tool_result(
                        clamp(self.tool_output.pop(cid, ""), TEXT_LIMIT),
                        failed=status == "failed", call_id=cid)

        resp = self.rpc.request("session/prompt", {
            "sessionId": self.session,
            "prompt": [{"type": "text", "text": text}]}, timeout, on_notify=notify)
        self.out.block_done()
        final = "".join(said)
        stop = ((resp or {}).get("result") or {}).get("stopReason") or "timeout"
        self.out.result(final, stop=stop, failed=resp is None)

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
    # A FIFO when a terminal hosts this and the writer is another process; plain
    # stdin when the app hosts it directly, which makes this a drop-in for the
    # same `Process` that runs claude — same NDJSON in, same events out.
    ap.add_argument("--fifo", help="turns arrive here; omit to read them from stdin")
    ap.add_argument("--events", help="normalised events are appended here too")
    ap.add_argument("--cwd", default=None)
    ap.add_argument("--model", default=None)
    # The app resolves a CLI's path from Settings; without this the bridge would
    # find a different binary on PATH than the one the user chose.
    ap.add_argument("--exe", default=None, help="path to the CLI binary")
    ap.add_argument("--turn-timeout", type=float, default=600.0)
    args = ap.parse_args()

    cwd = args.cwd or os.getcwd()
    out = Emitter(args.events)

    if args.cli in ("cursor", "agy"):
        bridge = PerTurnBridge(args.cli, cwd, args.model, out, exe=args.exe)
    elif args.cli == "codex":
        bridge = CodexBridge(cwd, args.model, out, exe=args.exe)
    elif args.cli == "kiro":
        # `kiro-cli acp`, NOT `kiro-cli chat acp`: both parse and only the first
        # is a server. The second starts the interactive chat agent, which reads
        # the handshake as a user message and answers it in prose.
        bridge = AcpBridge([args.exe or "kiro-cli", "acp", "--trust-all-tools"],
                           cwd, out, model=args.model)
    else:
        bridge = AcpBridge([args.exe or "gemini", "--acp", "--yolo"], cwd, out,
                           model=args.model)

    if not bridge.start():
        rpc = getattr(bridge, "rpc", None)
        failure = getattr(rpc, "failure", None)
        out.result(
            failure or "",
            stop="environment_failed" if failure else "startup_failed",
            failed=True,
        )
        bridge.stop()
        return 1
    log(f"{args.cli} ready — turns on {args.fifo or 'stdin'}")

    def take(line: str) -> None:
        line = line.strip()
        if not line:
            return
        # Turns arrive in claude's envelope whoever wrote them, so the caller
        # never has to know which CLI is behind this.
        try:
            obj = json.loads(line)
            text = obj.get("message", {}).get("content", "")
            if isinstance(text, list):
                text = "".join(b.get("text", "") for b in text if isinstance(b, dict))
        except json.JSONDecodeError:
            text = line
        if text:
            bridge.turn(text, args.turn_timeout)

    try:
        if args.fifo:
            while True:
                # Reopening blocks until a writer arrives, which is what keeps
                # this idle between turns without spinning.
                with open(args.fifo, encoding="utf-8") as fifo:
                    for line in fifo:
                        take(line)
                if not bridge.alive:
                    log("agent exited")
                    break
        else:
            for line in sys.stdin:
                take(line)
    except KeyboardInterrupt:
        pass
    finally:
        bridge.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
