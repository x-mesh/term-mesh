#!/usr/bin/env python3
"""Turn claude's stream-json into something a person can watch.

Under `--print --input-format stream-json` an agent takes its turns on a pipe —
no typing, a receipt for every message, a structured end to every turn. What it
does not do is draw: `--print` is the non-interactive mode, so the pane that
hosts it shows raw NDJSON. Whoever takes the channel has to draw the session
themselves.

This is that renderer at its smallest, as a filter:

    claude --print --input-format stream-json --output-format stream-json … | tm-render-claude

The pane stays a terminal and term-mesh needs no changes, which is what makes
this worth doing first — it prices the work before anyone commits to it.

What the events actually are, measured rather than assumed (22 lines for one
tool call):

    system/hook_started, system/hook_response   6 each, before anything happens
    system/init                                 tools, plugins, cwd, capabilities
    system/thinking_tokens                      running estimate
    user (isReplay)                             the receipt for what we sent
    assistant/thinking                          redacted — `thinking` is empty
    assistant/tool_use                          name + input
    user/tool_result                            content + is_error
    assistant/text                              what it says
    rate_limit_event                            quota state
    result                                      stop_reason, cost, usage, timings

Twelve hook lines for one turn is the first thing a renderer has to decide
about, and the answer is not "show everything": the point of a view is that it
leaves things out. `--raw` prints the JSON alongside so the two can be compared.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
import threading

# 256-colour codes, chosen to survive both light and dark terminals rather than
# to look good on one.
DIM = "\033[38;5;244m"
GREY = "\033[38;5;246m"
BLUE = "\033[38;5;39m"
GREEN = "\033[38;5;41m"
YELLOW = "\033[38;5;179m"
RED = "\033[38;5;203m"
MAGENTA = "\033[38;5;141m"
BOLD = "\033[1m"
OFF = "\033[0m"


def width() -> int:
    return max(40, shutil.get_terminal_size((100, 24)).columns)


def rule(label: str, colour: str) -> str:
    line = "─" * max(0, width() - len(label) - 3)
    return f"{colour}{label} {DIM}{line}{OFF}"


def wrap(text: str, indent: str = "  ") -> str:
    """Wrap at the terminal, keeping the author's own line breaks.

    Deliberately not `textwrap.fill` over the whole string: an agent's answer
    is written in paragraphs and lists, and reflowing it into one block loses
    the shape the model chose.
    """
    import textwrap

    cols = width() - len(indent)
    out = []
    for para in text.split("\n"):
        if not para.strip():
            out.append("")
            continue
        out += textwrap.wrap(para, width=cols) or [""]
    return "\n".join(indent + l for l in out)


def brief(value, limit: int = 400) -> str:
    s = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False)
    s = s.strip()
    return s if len(s) <= limit else s[:limit] + f"{DIM}… (+{len(s)-limit})"


class Renderer:
    def __init__(self, show_hooks: bool, show_raw: bool, show_thinking: bool):
        self.show_hooks = show_hooks
        self.show_raw = show_raw
        self.show_thinking = show_thinking
        self.hooks_seen = 0
        self.tools_open: dict[str, str] = {}
        self.opened = False
        # Turns this pane typed itself, so the replay can say who spoke. The
        # pane cannot otherwise tell a leader's task from a person's question,
        # and after the fact that is the more useful of the two labels.
        self.mine: set[str] = set()

    def emit(self, s: str = "") -> None:
        print(s, flush=True)

    def line(self, obj: dict) -> None:
        if self.show_raw:
            self.emit(f"{DIM}{json.dumps(obj, ensure_ascii=False)[:width()-1]}{OFF}")
        kind = obj.get("type")
        getattr(self, f"_{kind}", self._unknown)(obj)

    # ── event kinds ────────────────────────────────────────────────────

    def _system(self, o: dict) -> None:
        sub = o.get("subtype")
        if sub in ("hook_started", "hook_response"):
            # Twelve of these arrive before the agent does anything. Counting
            # them says the same thing in one line.
            if sub == "hook_response":
                self.hooks_seen += 1
            if self.show_hooks:
                name = o.get("hook_name", "?")
                if sub == "hook_started":
                    self.emit(f"{DIM}  hook ▸ {name}{OFF}")
                else:
                    bad = o.get("exit_code") not in (0, None)
                    mark = f"{RED}✗" if bad else f"{DIM}✓"
                    self.emit(f"{mark} hook {name}{OFF}")
            return
        if sub == "init":
            # Sent at the head of every turn, not once per session. Drawing the
            # whole banner again each time buries the conversation in it.
            if self.opened:
                return
            self.opened = True
            model = o.get("model") or ""
            cwd = o.get("cwd", "")
            tools = len(o.get("tools") or [])
            mcp = len(o.get("mcp_servers") or [])
            self.emit(rule("session", MAGENTA))
            self.emit(f"{DIM}  {cwd}{OFF}")
            bits = [b for b in (model, f"{tools} tools" if tools else "",
                                f"{mcp} mcp" if mcp else "") if b]
            if bits:
                self.emit(f"{DIM}  {' · '.join(bits)}{OFF}")
            if self.hooks_seen:
                self.emit(f"{DIM}  {self.hooks_seen} hooks ran{OFF}")
            return
        if sub == "thinking_tokens":
            return  # a running estimate; the total arrives with the result
        self.emit(f"{DIM}  system/{sub}{OFF}")

    def _user(self, o: dict) -> None:
        content = o.get("message", {}).get("content")
        if isinstance(content, str):
            # The replay of what we sent — the receipt the typing path lacks.
            # It is also the only framed copy of a typed line: the terminal
            # already echoed it as it was typed, and printing a third is noise.
            if not o.get("isReplay"):
                tag = "user"
            elif content.strip() in self.mine:
                self.mine.discard(content.strip())
                tag = "you"
            else:
                tag = "leader"
            self.emit(rule(tag, BLUE))
            self.emit(wrap(content))
            return
        for block in content or []:
            if block.get("type") == "tool_result":
                self._tool_result(block)

    def _tool_result(self, block: dict) -> None:
        name = self.tools_open.pop(block.get("tool_use_id", ""), "tool")
        failed = bool(block.get("is_error"))
        mark, colour = ("✗", RED) if failed else ("✓", GREEN)
        body = block.get("content")
        if isinstance(body, list):
            body = "".join(b.get("text", "") for b in body if isinstance(b, dict))
        self.emit(f"  {colour}{mark}{OFF} {DIM}{name}{OFF}  {brief(body, 200)}{OFF}")

    def _assistant(self, o: dict) -> None:
        for block in o.get("message", {}).get("content") or []:
            bt = block.get("type")
            if bt == "text":
                text = block.get("text", "")
                if text.strip():
                    self.emit(rule("claude", GREEN))
                    self.emit(wrap(text))
            elif bt == "thinking":
                # Extended thinking arrives redacted — a signature and an empty
                # string. Showing "(thinking)" is honest; showing nothing hides
                # that time passed here.
                if self.show_thinking:
                    body = (block.get("thinking") or "").strip()
                    self.emit(f"{DIM}  ✻ thinking{(' ' + brief(body, 160)) if body else ' (redacted)'}{OFF}")
            elif bt == "tool_use":
                name = block.get("name", "?")
                self.tools_open[block.get("id", "")] = name
                args = block.get("input") or {}
                # The one field that says what a call will do, per tool. A
                # generic dump buries it in schema.
                headline = (args.get("command") or args.get("file_path")
                            or args.get("pattern") or args.get("path")
                            or args.get("description") or "")
                self.emit(f"  {YELLOW}▸ {name}{OFF} {GREY}{brief(headline, 160)}{OFF}")

    def _rate_limit_event(self, o: dict) -> None:
        info = o.get("rate_limit_info") or {}
        if info.get("status") not in (None, "allowed"):
            self.emit(f"  {YELLOW}rate limit: {info.get('status')}{OFF}")

    def _result(self, o: dict) -> None:
        usage = o.get("usage") or {}
        cost = o.get("total_cost_usd")
        secs = (o.get("duration_ms") or 0) / 1000
        stop = o.get("stop_reason") or o.get("subtype") or "?"
        colour = RED if o.get("is_error") else DIM
        parts = [f"{stop}", f"{secs:.1f}s"]
        if cost is not None:
            parts.append(f"${cost:.4f}")
        tin = usage.get("input_tokens")
        tout = usage.get("output_tokens")
        if tin is not None or tout is not None:
            parts.append(f"{tin or 0}→{tout or 0} tok")
        self.emit(f"{colour}{'─' * 3} {' · '.join(parts)} {'─' * max(0, width() - len(' · '.join(parts)) - 6)}{OFF}")
        self.emit()

    def _unknown(self, o: dict) -> None:
        self.emit(f"{DIM}  {o.get('type')}{OFF}")


def type_into(fifo_path: str, renderer: "Renderer") -> None:
    """Let the person watching the pane talk to the agent.

    On the typing path this came free: the pane *was* the agent's stdin, so a
    human could always take over mid-session. That is half of what "visible"
    means here, and taking the channel takes it away — the agent now reads a
    FIFO and nobody reads the keyboard.

    Getting it back costs one thread. `stdin` is the pipe from the agent, but
    `/dev/tty` is the controlling terminal regardless of redirection, so the
    keystrokes are still reachable from here. A line typed in the pane becomes
    a turn, in the same envelope the leader's instructions use — the agent
    cannot tell the two apart, which is the point.
    """
    try:
        tty = open("/dev/tty", encoding="utf-8", errors="replace")
    except OSError:
        return  # no terminal (a test harness, a log capture) — nothing to read
    for line in tty:
        text = line.strip()
        if not text:
            continue
        try:
            with open(fifo_path, "w", encoding="utf-8") as fifo:
                fifo.write(json.dumps(
                    {"type": "user", "message": {"role": "user", "content": text}},
                    ensure_ascii=False) + "\n")
            renderer.mine.add(text)
        except OSError as exc:
            print(f"{RED}  could not deliver: {exc}{OFF}", flush=True)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--hooks", action="store_true", help="show every hook event")
    ap.add_argument("--raw", action="store_true", help="print the JSON above each line")
    ap.add_argument("--no-thinking", action="store_true", help="hide thinking markers")
    ap.add_argument("--fifo", help="deliver lines typed in the pane to this agent")
    ap.add_argument("file", nargs="?", help="read from a file instead of stdin")
    args = ap.parse_args()

    r = Renderer(show_hooks=args.hooks, show_raw=args.raw,
                 show_thinking=not args.no_thinking)
    if args.fifo:
        threading.Thread(target=type_into, args=(args.fifo, r), daemon=True).start()
    stream = open(args.file, encoding="utf-8") if args.file else sys.stdin

    try:
        for line in stream:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                # Not every line is ours — a CLI may write a warning to stdout.
                # Passing it through beats swallowing it.
                print(f"{DIM}{line}{OFF}", flush=True)
                continue
            if isinstance(obj, dict):
                r.line(obj)
    except (BrokenPipeError, KeyboardInterrupt):
        pass
    finally:
        if args.file:
            stream.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
