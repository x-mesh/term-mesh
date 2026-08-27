#!/usr/bin/env python3
"""Prove where a leader->agent send's latency actually goes, and assert the
wiring adds no measurable delay of its own.

The claim under test was reached by polling `tm-agent read` from outside, which
cannot separate three different things: how long the agent's in-flight turn had
left to run, how long the wiring took to hand the text over, and the poll
interval of the observer. A number produced that way (5682ms was the figure)
cannot distinguish "the queue is slow" from "the turn was long", so it cannot
justify either a fix or a decision not to fix.

This measures the wiring directly instead. The agent is a fake codex whose turn
length this test chooses, and which timestamps `turn/start` arrival itself, on
its own single clock. So for a send issued while a turn of known length is
running:

    queue_overhead = turn_start_arrival - turn_would_have_ended

is the wiring's entire contribution, with the in-flight turn's remaining time
subtracted out by construction and no cross-process clock or poll interval
anywhere in it.

Three shapes, one team:
  IDLE     — no turn running; the write goes straight to the transport.
  QUEUED   — a turn is running; `send()` parks the text and the drain at turn
             end writes it. This is the shape the 5682ms came from.
  DRAIN    — two sends parked behind one turn, to show the queue drains one
             turn at a time (by design) rather than stalling on the tail.

What is asserted, versus what is only reported: the overheads are asserted
against generous ceilings, because a regression here would be a wiring bug
(a timer added to the drain, a lost wakeup, a re-poll) and would blow past them
by an order of magnitude. The absolute latencies are reported, not asserted —
they are host-speed dependent and a threshold on them would be a flake.
"""

from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError


TEAM_NAME = f"qlat-{uuid.uuid4().hex[:8]}"
AGENT = f"qlat-a-{uuid.uuid4().hex[:6]}"
DEFAULTS_DOMAIN = "com.termmesh.app.debug"
DEFAULTS_KEY = "cliPath.codex"

# The fake agent's turn length. Long enough that a send issued mid-turn is
# unambiguously parked rather than racing the turn's end, short enough to keep
# the test quick.
TURN_SECONDS = 3.0
# How far into the turn the mid-turn send is issued.
SEND_AT_SECONDS = 1.0
# Ceilings for the wiring's own contribution. Chosen ~50x above the observed
# values so only a real regression trips them.
IDLE_CEILING_MS = 1500.0
QUEUE_CEILING_MS = 1500.0

# A fake codex that (a) makes each turn take a known amount of time and (b)
# records, on its own clock, the moment each `turn/start` arrived on stdin and
# the moment it finished. Written to a trace file the test reads afterwards, so
# no measurement crosses a process boundary or depends on the app.
# NOTE the two `%s` placeholders: the fake agent is spawned by the APP through
# the bridge, not by this test process, so it inherits none of this process's
# environment. The trace path and turn length are therefore baked into the
# script text rather than passed as env vars.
FAKE_CODEX = r'''#!/usr/bin/env python3
import json
import sys
import time

TRACE = %r
TURN_SECONDS = %r


def trace(event, **fields):
    fields["event"] = event
    fields["mono"] = time.monotonic()
    # Wall clock too: the only figure that subtracts this process's stamp from
    # the test's is IDLE, and CLOCK_MONOTONIC's origin is not guaranteed to be
    # shared across processes. `time.time()` has one definition on both sides,
    # so it is the honest basis for that single cross-process difference.
    fields["wall"] = time.time()
    with open(TRACE, "a") as handle:
        handle.write(json.dumps(fields) + "\n")
        handle.flush()


trace("boot")

for raw in sys.stdin:
    try:
        request = json.loads(raw)
    except json.JSONDecodeError:
        continue
    request_id = request.get("id")
    method = request.get("method")
    if method == "initialize":
        print(json.dumps({"id": request_id, "result": {}}), flush=True)
    elif method == "thread/start":
        print(json.dumps({"id": request_id, "result": {"thread": {"id": "qlat-thread"}}}), flush=True)
    elif method == "turn/start":
        # Arrival is the measurement point: stdin carrying this line IS the
        # write landing. Recover the marker the test put in the text so each
        # arrival can be attributed to the send that caused it.
        text = ""
        for part in (request.get("params") or {}).get("input") or []:
            if isinstance(part, dict) and isinstance(part.get("text"), str):
                text += part["text"]
        trace("turn_start", text=text)
        print(json.dumps({"id": request_id, "result": {"turn": {"id": "qlat-turn"}}}), flush=True)
        # Occupy the turn for a known duration, so the app sees a turn in
        # flight for exactly as long as this test intends.
        time.sleep(TURN_SECONDS)
        # `--warmup` only counts an agent warm when the answer contains the
        # word "pong" (`warmup_task_succeeded`), so say it every turn rather
        # than special-casing the first: an agent that never warms is reported
        # as timed out and `add` exits nonzero.
        print(json.dumps({"method": "item/completed", "params": {"item": {
            "type": "agentMessage", "text": "pong"
        }}}), flush=True)
        print(json.dumps({"method": "turn/completed", "params": {
            "threadId": "qlat-thread", "turn": {"status": "completed"}
        }}), flush=True)
        trace("turn_end", text=text)
'''


def _read_default() -> tuple[bool, str]:
    proc = subprocess.run(
        ["defaults", "read", DEFAULTS_DOMAIN, DEFAULTS_KEY],
        text=True, capture_output=True, check=False,
    )
    return proc.returncode == 0, proc.stdout.rstrip("\n")


def _restore_default(existed: bool, value: str) -> None:
    if existed:
        subprocess.run(
            ["defaults", "write", DEFAULTS_DOMAIN, DEFAULTS_KEY, "-string", value],
            check=True,
        )
    else:
        subprocess.run(
            ["defaults", "delete", DEFAULTS_DOMAIN, DEFAULTS_KEY],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False,
        )


def _trace(path: Path) -> list[dict]:
    if not path.exists():
        return []
    records = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return records


def _await_arrival(path: Path, marker: str, deadline_s: float) -> dict:
    """Wait for the fake agent to record this marker's arrival.

    The wait is only how this process learns the arrival happened; the arrival
    TIME comes from the trace, written by the agent on its own clock. So a slow
    poll here cannot inflate any measurement — that was the flaw in the earlier
    external-polling estimate.
    """
    limit = time.monotonic() + deadline_s
    while time.monotonic() < limit:
        for record in _trace(path):
            if record.get("event") == "turn_start" and marker in (record.get("text") or ""):
                return record
        time.sleep(0.05)
    raise termmeshError(f"marker {marker!r} never arrived at the agent within {deadline_s}s")


def _await_event(path: Path, event: str, marker: str, deadline_s: float) -> dict:
    limit = time.monotonic() + deadline_s
    while time.monotonic() < limit:
        for record in _trace(path):
            if record.get("event") == event and marker in (record.get("text") or ""):
                return record
        time.sleep(0.05)
    raise termmeshError(f"{event} for {marker!r} did not happen within {deadline_s}s")


def main() -> int:
    repo = Path(__file__).resolve().parents[1]
    tm_agent = repo / "daemon" / "target" / "release" / "tm-agent"
    if not tm_agent.is_file():
        raise termmeshError(f"tm-agent binary not found: {tm_agent}")

    old_existed, old_value = _read_default()
    with tempfile.TemporaryDirectory(prefix="term-mesh-qlat-") as tmp:
        trace_path = Path(tmp) / "trace.jsonl"
        fake_codex = Path(tmp) / "codex"
        fake_codex.write_text(FAKE_CODEX % (str(trace_path), TURN_SECONDS))
        fake_codex.chmod(fake_codex.stat().st_mode | stat.S_IXUSR)
        subprocess.run(
            ["defaults", "write", DEFAULTS_DOMAIN, DEFAULTS_KEY,
             "-string", str(fake_codex)],
            check=True,
        )

        findings: list[str] = []

        def report() -> None:
            for line in findings:
                print(line)

        try:
            with termmesh() as client:
                client.team_create(TEAM_NAME, [])
                try:
                    env = os.environ.copy()
                    # A leader pane exports a remote-leader route (grant id,
                    # project, team uuid, expiry, peer id). Inheriting all five
                    # makes `tm-agent` proxy every call to the LEADER'S host
                    # instead of the app this test just launched: the run then
                    # measures someone else's machine, or fails with an error
                    # name that does not exist in this tree at all
                    # (`noMatchingLeaderSession`, from a differently-versioned
                    # app). Drop the route so the socket below is authoritative.
                    for leaked in (
                        "TERMMESH_LEADER_GRANT_ID",
                        "TERMMESH_LEADER_PROJECT_ID",
                        "TERMMESH_LEADER_TEAM_UUID",
                        "TERMMESH_LEADER_EXPIRES_AT",
                        "TERMMESH_LEADER_PEER_ID",
                        "TERMMESH_LEADER_ROUTE_FILE",
                        "TERMMESH_PEER_SOCKET",
                    ):
                        env.pop(leaked, None)
                    env["TERMMESH_SOCKET"] = client.socket_path
                    env["TERMMESH_SOCKET_PATH"] = client.socket_path
                    env["TERMMESH_TEAM"] = TEAM_NAME

                    add = subprocess.run(
                        [str(tm_agent), "add", "reviewer", "--name", AGENT,
                         "--cli", "codex", "--warmup", "--warmup-timeout", "40"],
                        cwd=repo, env=env, text=True, capture_output=True,
                        timeout=90, check=False,
                    )
                    if add.returncode != 0:
                        raise termmeshError(
                            f"add {AGENT} exited {add.returncode}:\n{add.stdout}{add.stderr}"
                        )

                    def send(text: str) -> tuple[float, float, str]:
                        """Issue one send. Returns (issued_mono, ack_ms, delivery_scope).

                        `tm-agent send` always prints the pretty-printed RPC
                        envelope, so the whole stdout is one JSON document.
                        """
                        issued = time.time()
                        started = time.monotonic()
                        proc = subprocess.run(
                            [str(tm_agent), "send", AGENT, text, "--no-report"],
                            cwd=repo, env=env, text=True, capture_output=True,
                            timeout=30, check=False,
                        )
                        # Elapsed stays on the monotonic clock (immune to a wall
                        # adjustment mid-call); only the cross-process instant is
                        # a wall-clock reading.
                        ack_ms = (time.monotonic() - started) * 1000.0
                        if proc.returncode != 0:
                            raise termmeshError(
                                f"send exited {proc.returncode}:\n{proc.stdout}{proc.stderr}"
                            )
                        scope = ""
                        try:
                            envelope = json.loads(proc.stdout)
                        except json.JSONDecodeError:
                            envelope = {}
                        if isinstance(envelope, dict):
                            result = envelope.get("result")
                            if isinstance(result, dict):
                                scope = str(result.get("delivery_scope") or "")
                            if not scope:
                                scope = str(envelope.get("delivery_scope") or "")
                        return issued, ack_ms, scope

                    # The warmup may have left a turn running. Wait for the
                    # agent to be genuinely idle so the IDLE case measures what
                    # its name says.
                    #
                    # `boot` must be present before any start/end comparison is
                    # meaningful: an empty trace also satisfies starts == ends,
                    # so without this the first case could measure a send issued
                    # before the fake agent existed at all.
                    def wait_idle(deadline_s: float = 60.0) -> None:
                        limit = time.monotonic() + deadline_s
                        while time.monotonic() < limit:
                            records = _trace(trace_path)
                            booted = any(r.get("event") == "boot" for r in records)
                            starts = sum(1 for r in records if r.get("event") == "turn_start")
                            ends = sum(1 for r in records if r.get("event") == "turn_end")
                            if booted and starts == ends:
                                return
                            time.sleep(0.05)
                        raise termmeshError(
                            f"agent never became idle (trace={_trace(trace_path)!r})"
                        )

                    wait_idle()

                    # ---- IDLE: no turn in flight, so send() writes directly.
                    idle_marker = f"QLATIDLE{uuid.uuid4().hex[:6]}"
                    idle_issued, idle_ack_ms, idle_scope = send(f"idle {idle_marker}")
                    idle_arrival = _await_arrival(trace_path, idle_marker, 30.0)
                    # The one cross-process figure in this test: issued here,
                    # stamped by the agent. Both sides read `time.time()`, whose
                    # origin is defined identically in every process, so this
                    # subtraction needs no assumption about CLOCK_MONOTONIC's
                    # origin being shared. A negative or absurd result would mean
                    # the wall clock moved, which is asserted below rather than
                    # reported as a latency.
                    idle_ms = (idle_arrival["wall"] - idle_issued) * 1000.0
                    if idle_ms < 0.0:
                        raise termmeshError(
                            f"the agent stamped its arrival {(-idle_ms):.0f}ms before the "
                            f"send was issued — the wall clock moved mid-measurement; "
                            f"rerun rather than trusting this figure"
                        )
                    findings.append(
                        f"BENCH idle issue_to_stdin_ms={idle_ms:.0f} "
                        f"ack_ms={idle_ack_ms:.0f} delivery_scope={idle_scope}"
                    )
                    if idle_ms > IDLE_CEILING_MS:
                        report()
                        raise termmeshError(
                            f"an idle agent's write took {idle_ms:.0f}ms to reach stdin "
                            f"(ceiling {IDLE_CEILING_MS:.0f}ms) — the direct write path "
                            f"has gained a delay. issued={idle_issued!r} "
                            f"arrival={idle_arrival!r}"
                        )
                    # `nativeDeliveryScope` maps `.queuedBehindTurn` to
                    # `queued_local` and everything else to `transport_write`.
                    # Pinning the value here is what makes the two cases below
                    # different measurements rather than two runs of the same one.
                    if idle_scope != "transport_write":
                        raise termmeshError(
                            f"an idle send reported delivery_scope={idle_scope!r}, expected "
                            f"'transport_write' — this case did not exercise the direct path"
                        )
                    _await_event(trace_path, "turn_end", idle_marker, TURN_SECONDS + 30.0)

                    # ---- QUEUED: occupy the agent, then send mid-turn.
                    block_marker = f"QLATBLOCK{uuid.uuid4().hex[:6]}"
                    send(f"block {block_marker}")
                    block_arrival = _await_arrival(trace_path, block_marker, 30.0)
                    turn_ends_at = block_arrival["mono"] + TURN_SECONDS

                    # Wait until the turn is genuinely mid-flight before sending,
                    # so `send()` takes the queueing branch. Timed on this
                    # process's own clock from the moment it observed the arrival
                    # — never by comparing against the agent's stamp — and the
                    # `queued_local` check below is what actually proves the send
                    # landed mid-turn.
                    observed_block = time.monotonic()
                    while time.monotonic() < observed_block + SEND_AT_SECONDS:
                        time.sleep(0.02)
                    _, q_ack_ms, q_scope = send(f"queued {block_marker}Q")
                    q_arrival = _await_arrival(
                        trace_path, f"{block_marker}Q", TURN_SECONDS + 30.0
                    )
                    # The whole point: subtract the in-flight turn's remaining
                    # time, which this test knows exactly because it chose the
                    # turn length and observed the turn's start.
                    q_overhead_ms = (q_arrival["mono"] - turn_ends_at) * 1000.0
                    findings.append(
                        f"BENCH queued turn_seconds={TURN_SECONDS} "
                        f"sent_at_seconds={SEND_AT_SECONDS} "
                        f"queue_overhead_ms={q_overhead_ms:.0f} "
                        f"ack_ms={q_ack_ms:.0f} delivery_scope={q_scope}"
                    )

                    # The send must be acknowledged immediately rather than
                    # blocking for the turn — that is what makes the wait the
                    # turn's, not the caller's.
                    if q_scope != "queued_local":
                        raise termmeshError(
                            f"a mid-turn send reported delivery_scope={q_scope!r}, expected "
                            f"'queued_local' — the send was not parked behind the running "
                            f"turn, so this case measures nothing about the queue"
                        )
                    remaining_turn_ms = (TURN_SECONDS - SEND_AT_SECONDS) * 1000.0
                    if q_ack_ms >= remaining_turn_ms:
                        raise termmeshError(
                            f"a mid-turn send blocked for {q_ack_ms:.0f}ms, at least the "
                            f"in-flight turn's remaining {remaining_turn_ms:.0f}ms — send() "
                            f"is no longer parking the text and returning at once"
                        )
                    # The arrival must not precede the turn's end: that would
                    # mean the text was written into a running turn, the exact
                    # interleaving the queue exists to prevent.
                    if q_overhead_ms < -250.0:
                        raise termmeshError(
                            f"queued text reached stdin {-q_overhead_ms:.0f}ms BEFORE the "
                            f"in-flight turn ended — it was written into a running turn"
                        )
                    if q_overhead_ms > QUEUE_CEILING_MS:
                        raise termmeshError(
                            f"the queue added {q_overhead_ms:.0f}ms beyond the in-flight "
                            f"turn's own duration (ceiling {QUEUE_CEILING_MS:.0f}ms) — the "
                            f"drain at turn end has gained a delay"
                        )
                    _await_event(
                        trace_path, "turn_end", f"{block_marker}Q", TURN_SECONDS + 30.0
                    )

                    # ---- DRAIN: two sends parked behind one turn. The second
                    # must wait for the first queued turn, not be dropped and
                    # not be merged into it.
                    wait_idle()
                    d_marker = f"QLATDRAIN{uuid.uuid4().hex[:6]}"
                    send(f"block {d_marker}")
                    d_block = _await_arrival(trace_path, d_marker, 30.0)
                    observed_d_block = time.monotonic()
                    while time.monotonic() < observed_d_block + SEND_AT_SECONDS:
                        time.sleep(0.02)
                    # Both sends must be issued while the SAME turn is still
                    # running, or the second one is not measuring the queue: if
                    # the first has already drained, the second takes the direct
                    # write path and this case silently becomes a rerun of IDLE.
                    # `delivery_scope` is the app's own answer to "was this
                    # parked?", so require it of both rather than trusting the
                    # clock.
                    _, _, a_scope = send(f"first {d_marker}A")
                    _, _, b_scope = send(f"second {d_marker}B")
                    if a_scope != "queued_local" or b_scope != "queued_local":
                        raise termmeshError(
                            f"the two drain sends reported delivery_scope "
                            f"{a_scope!r}/{b_scope!r}, expected both 'queued_local' — "
                            f"they were not both parked behind one turn, so the tail of "
                            f"the queue was never exercised"
                        )
                    a_arrival = _await_arrival(
                        trace_path, f"{d_marker}A", TURN_SECONDS * 2 + 30.0
                    )
                    b_arrival = _await_arrival(
                        trace_path, f"{d_marker}B", TURN_SECONDS * 3 + 30.0
                    )
                    a_overhead_ms = (
                        a_arrival["mono"] - (d_block["mono"] + TURN_SECONDS)
                    ) * 1000.0
                    b_overhead_ms = (
                        b_arrival["mono"] - (a_arrival["mono"] + TURN_SECONDS)
                    ) * 1000.0
                    findings.append(
                        f"BENCH drain first_overhead_ms={a_overhead_ms:.0f} "
                        f"second_overhead_ms={b_overhead_ms:.0f} "
                        f"gap_ms={(b_arrival['mono'] - a_arrival['mono']) * 1000.0:.0f}"
                    )
                    if b_arrival["mono"] <= a_arrival["mono"]:
                        raise termmeshError(
                            "the two queued sends did not arrive in order — the drain "
                            "collapsed or reordered them"
                        )
                    if b_overhead_ms > QUEUE_CEILING_MS:
                        raise termmeshError(
                            f"the second queued send waited {b_overhead_ms:.0f}ms past the "
                            f"first queued turn's end (ceiling {QUEUE_CEILING_MS:.0f}ms) — "
                            f"the drain is not immediate for the tail of the queue"
                        )

                    report()
                    print(
                        "MEASURED the wiring's own cost is the two queue_overhead "
                        "figures; the rest of a mid-turn send's latency is the "
                        "in-flight turn, which no transport change can remove"
                    )
                finally:
                    client.team_destroy(TEAM_NAME)
        finally:
            _restore_default(old_existed, old_value)

    print(
        "PASS: a leader send reaches an idle agent directly, a mid-turn send is "
        "parked and acknowledged at once, and the drain adds no delay of its own "
        "beyond the in-flight turn"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
