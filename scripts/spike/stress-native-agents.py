#!/usr/bin/env python3
"""Send an agent the things that used to get lost, and check every one landed.

The terminal path could never answer "did this instruction arrive intact?" —
only estimate it. Text was typed, a Return was pressed from another process,
and what came back was a rendered screen to be read by eye. So the failures it
produced are the payloads here:

    multi-line      the path flattens newlines, because a TUI composer would
                    submit on the first one. The instruction is reshaped to
                    survive its own delivery.
    long            paste chunking, and a Return that can arrive mid-paste
    korean          IME. A Return during composition was swallowed outright
    quotes/backticks  shell quoting on the way to the pane
    rapid           two turns back to back, racing text against Return
    concurrent      several agents at once, where a Return could land on the
                    wrong pane entirely (the duplicate-name bug)

Every sent turn comes back as the agent's own receipt (`--replay-user-messages`),
so this compares byte for byte rather than reading pixels.

    stress-native-agents.py --socket /tmp/term-mesh-debug-native.sock
"""

from __future__ import annotations

import argparse
import json
import socket
import sys
import time

OK, BAD, DIM, OFF = "\033[38;5;41m", "\033[38;5;203m", "\033[38;5;244m", "\033[0m"


def rpc(sock_path: str, method: str, params: dict | None = None, timeout: float = 30):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(sock_path)
    payload = {"jsonrpc": "2.0", "id": 1, "method": method}
    if params:
        payload["params"] = params
    s.sendall((json.dumps(payload) + "\n").encode())
    buf = b""
    while b"\n" not in buf:
        chunk = s.recv(65536)
        if not chunk:
            break
        buf += chunk
    s.close()
    return json.loads(buf.decode().splitlines()[0])


def transcript(sock_path: str, agent: str) -> list[dict]:
    r = rpc(sock_path, "debug.agent.transcript", {"agent": agent})
    agents = (r.get("result") or {}).get("agents") or []
    return agents[0]["entries"] if agents else []


def sent_turns(entries: list[dict]) -> list[str]:
    return [e["text"] for e in entries if e["kind"] == "said"]


def turns_ended(entries: list[dict]) -> list[dict]:
    return [e for e in entries if e["kind"] == "turn_ended"]


def answers(entries: list[dict]) -> list[str]:
    return [e["text"] for e in entries if e["kind"] == "answered"]


CASES = [
    ("multi-line",
     "Reply with only the word ALPHA.\nDo not add anything else.\nNot even a period."),
    ("long",
     "Ignore the filler and reply with only the word BRAVO. Filler follows: "
     + ("lorem ipsum dolor sit amet " * 120)),
    ("korean",
     "다음 요청에 오직 한 단어로만 답해. 답할 단어는 CHARLIE 야. 다른 말은 절대 붙이지 마."),
    ("quotes",
     "Reply with only the word DELTA. Ignore these: `backtick` \"double\" 'single' $VAR ; && | > <"),
    ("newline-heavy",
     "Reply\n\nwith\n\nonly\n\nthe\n\nword\n\nECHO"),
]

EXPECTED = ["ALPHA", "BRAVO", "CHARLIE", "DELTA", "ECHO"]


def wait_for_turns(sock_path: str, agent: str, count: int, timeout: float) -> list[dict]:
    deadline = time.time() + timeout
    while time.time() < deadline:
        entries = transcript(sock_path, agent)
        if len(turns_ended(entries)) >= count:
            return entries
        time.sleep(0.5)
    return transcript(sock_path, agent)


def crosstalk(sock_path: str, timeout: float) -> int:
    """Two agents, interleaved sends, checking nothing lands on the wrong one.

    This is where the terminal path had its worst failure: text went to pane X
    by name and the follow-up Return went to pane Y, so one agent submitted
    another's instruction. There is no Return here and no name lookup at
    delivery time — the write goes to a process this side is holding — so the
    question is whether that actually holds under interleaving.
    """
    agents = ["explorer", "executor"]
    base = {a: len(sent_turns(transcript(sock_path, a))) for a in agents}
    marks = {"explorer": ["FOXTROT", "GOLF"], "executor": ["HOTEL", "INDIA"]}

    order = [(a, w) for pair in zip(*marks.values()) for a, w in zip(agents, pair)]
    for agent, word in order:
        rpc(sock_path, "team.send", {
            "team_name": "live-team", "agent_name": agent,
            "text": f"Reply with only the word {word}."})

    deadline = time.time() + timeout
    while time.time() < deadline:
        if all(len(turns_ended(transcript(sock_path, a))) >= base[a] + 2 for a in agents):
            break
        time.sleep(0.5)

    failures = 0
    print()
    for agent in agents:
        entries = transcript(sock_path, agent)
        mine = sent_turns(entries)[base[agent]:]
        said = " ".join(answers(entries)).upper()
        wrong = [w for other, words in marks.items() if other != agent
                 for w in words if any(w in m for m in mine)]
        missing = [w for w in marks[agent] if not any(w in m for m in mine)]
        heard = [w for w in marks[agent] if w in said]

        good = not wrong and not missing and len(heard) == len(marks[agent])
        failures += 0 if good else 1
        mark = f"{OK}pass{OFF}" if good else f"{BAD}FAIL{OFF}"
        print(f"  {mark}  {agent:9} got {len(mine)} turns"
              f"  own={heard}"
              f"  strays={wrong or 'none'}"
              f"  missing={missing or 'none'}")
    return failures


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--socket", required=True)
    ap.add_argument("--agent", default="explorer")
    ap.add_argument("--timeout", type=float, default=180)
    ap.add_argument("--crosstalk", action="store_true",
                    help="interleave sends across two agents instead")
    args = ap.parse_args()

    if args.crosstalk:
        bad = crosstalk(args.socket, args.timeout)
        print()
        print(f"{BAD}{bad} agent(s) crossed{OFF}" if bad
              else f"{OK}no crosstalk — each agent got only its own turns{OFF}")
        return 1 if bad else 0

    before = transcript(args.socket, args.agent)
    baseline_turns = len(turns_ended(before))
    baseline_sent = len(sent_turns(before))
    print(f"{DIM}baseline: {baseline_sent} sent, {baseline_turns} turns{OFF}\n")

    # Fired back to back with no pause. On the terminal path this is the race
    # the retry ladder exists for: the Return for turn N can land while turn
    # N+1 is still pasting.
    for name, text in CASES:
        r = rpc(args.socket, "team.send",
                {"team_name": "live-team", "agent_name": args.agent, "text": text})
        ok = (r.get("result") or {}).get("text_delivered")
        print(f"{DIM}sent {name:14} {len(text):5}B  delivered={ok}{OFF}")

    print(f"\n{DIM}waiting for {len(CASES)} turns…{OFF}")
    entries = wait_for_turns(args.socket, args.agent,
                             baseline_turns + len(CASES), args.timeout)

    got_sent = sent_turns(entries)[baseline_sent:]
    got_turns = turns_ended(entries)[baseline_turns:]
    got_answers = answers(entries)

    failures = 0
    print()
    for i, (name, text) in enumerate(CASES):
        # 1) Did the exact bytes arrive? The receipt is the agent's own copy.
        arrived = i < len(got_sent) and got_sent[i] == text
        # 2) Did the turn end, and not in an error?
        ended = i < len(got_turns) and not got_turns[i]["failed"]
        # 3) Did the answer show the agent read it? Loose on purpose — this is
        #    a transport test, and haiku is chatty; the word being present is
        #    enough to prove the instruction was not mangled.
        word = EXPECTED[i]
        answered = any(word in a.upper() for a in got_answers)

        good = arrived and ended and answered
        failures += 0 if good else 1
        mark = f"{OK}pass{OFF}" if good else f"{BAD}FAIL{OFF}"
        print(f"  {mark}  {name:14} bytes={'ok' if arrived else 'MANGLED'}"
              f"  turn={'ok' if ended else 'MISSING/ERROR'}"
              f"  saw {word}={'yes' if answered else 'NO'}")
        if arrived and "\n" in text:
            print(f"        {DIM}newlines survived: {text.count(chr(10))}{OFF}")
        if not arrived and i < len(got_sent):
            print(f"        {DIM}sent: {text[:70]!r}{OFF}")
            print(f"        {DIM}got : {got_sent[i][:70]!r}{OFF}")

    print()
    if failures:
        print(f"{BAD}{failures}/{len(CASES)} failed{OFF}")
    else:
        print(f"{OK}{len(CASES)}/{len(CASES)} delivered byte-exact and answered{OFF}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
