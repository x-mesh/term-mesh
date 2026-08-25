#!/usr/bin/env python3
"""Mobile remote control end to end (docs/mobile-remote-control.md §9 T7):
`tm-agent remote on` from a pane's environment -> the daemon listener lists,
reads, types into, and sends keys to a real GUI pane; a repl leader receives
phone text as a durable request; `keys=none` and `remote off` close the door.

The runner starts the e2e daemon with TERM_MESH_MOBILE_AUTH=loopback and
exports the listener address as TERMMESH_E2E_MOBILE_ADDR.
"""

import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError


MOBILE_ADDR = os.environ.get("TERMMESH_E2E_MOBILE_ADDR", "")
APP_SOCK = os.environ.get("TERMMESH_SOCKET_PATH") or os.environ.get("TERMMESH_SOCKET", "")
DAEMON_SOCK = os.environ.get("TERMMESH_DAEMON_UNIX_PATH", "")
MARKER = f"mobile-e2e-marker-{os.getpid()}"


def bundled_tm_agent() -> Path:
    app_bin = Path(os.environ["TERMMESH_APP_BIN"])
    cli = app_bin.parents[2] / "Contents" / "Resources" / "bin" / "tm-agent"
    if not os.access(cli, os.X_OK):
        raise termmeshError(f"bundled tm-agent is not executable: {cli}")
    return cli


def http(method: str, path: str, body=None, expect=None):
    """One request against the listener. Returns (status, json_or_None)."""
    url = f"http://{MOBILE_ADDR}{path}"
    data = None
    headers = {}
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=15) as res:
            status = res.status
            raw = res.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as err:
        status = err.code
        raw = err.read().decode("utf-8", "replace")
    parsed = None
    if raw:
        try:
            parsed = json.loads(raw)
        except json.JSONDecodeError:
            parsed = None
    if expect is not None and status != expect:
        raise termmeshError(f"{method} {path}: expected HTTP {expect}, got {status}: {raw[:300]}")
    return status, parsed


def error_code(payload) -> str:
    return str(((payload or {}).get("error") or {}).get("code") or "")


def rc(cli: Path, args, *, surface_id: str, team: str = None, extra_env=None) -> str:
    """Run `tm-agent remote ...` as the pane would: identity comes from env."""
    env = dict(os.environ)
    env.update({
        "TERMMESH_SURFACE_ID": surface_id,
        "TERMMESH_SOCKET_PATH": APP_SOCK,
        "TERMMESH_DAEMON_UNIX_PATH": DAEMON_SOCK,
    })
    env.pop("TERMMESH_AGENT_NAME", None)
    env.pop("TERMMESH_LEADER_REQUEST_TOKEN", None)
    if extra_env:
        env.update(extra_env)
    cmd = [str(cli)]
    if team:
        cmd += ["--team", team]
    cmd += ["remote", *args]
    result = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=30)
    if result.returncode != 0:
        raise termmeshError(f"{' '.join(cmd)} failed ({result.returncode}): {result.stderr.strip()}")
    return result.stdout


def read_text(c: termmesh, surface_id: str, lines: int = 80) -> str:
    result = c._call("surface.read_text", {"surface_id": surface_id, "lines": lines, "scrollback": True})
    return str((result or {}).get("text") or "")


def wait_for(predicate, timeout_s: float, what: str):
    deadline = time.time() + timeout_s
    last = None
    while time.time() < deadline:
        last = predicate()
        if last:
            return last
        time.sleep(0.25)
    raise termmeshError(f"timed out waiting for {what}")


def leader_token_from_process_env(surface_id: str):
    """`ps -E` prints each process's environment; the leader pane's shell is
    the one carrying this surface id together with the leader token."""
    out = subprocess.run(["ps", "-E", "-ax", "-o", "command="], capture_output=True, text=True).stdout
    for line in out.splitlines():
        if f"TERMMESH_SURFACE_ID={surface_id}" not in line:
            continue
        m = re.search(r"TERMMESH_LEADER_REQUEST_TOKEN=(\S+)", line)
        if m:
            return m.group(1)
    return None


def targets_by_id() -> dict:
    _, payload = http("GET", "/api/targets", expect=200)
    return {t["surface_id"]: t for t in (payload or {}).get("targets", [])}


def prompt_ready(c: termmesh, surface_id: str):
    """The shell prompt is drawn once the last non-empty line ends in a prompt
    character. Typing before that leaves the text echoed twice in scrollback."""
    lines = [l.rstrip() for l in read_text(c, surface_id).splitlines() if l.strip()]
    return bool(lines) and re.search(r"[%$#>➜❯]\s*$", lines[-1]) is not None


def check_pane_flow(c: termmesh, cli: Path) -> None:
    sid = c.new_surface(panel_type="terminal")
    c.focus_surface(sid)
    wait_for(lambda: prompt_ready(c, sid) or None, 20, "shell prompt in the new pane")

    out = rc(cli, ["on", "--title", "e2e-pane", "--cli", "shell", "--ttl", "10m"], surface_id=sid)
    if f"/t/{sid}" not in out:
        raise termmeshError(f"remote on did not print the target URL: {out!r}")
    target = targets_by_id().get(sid)
    if not target or target.get("kind") != "pane" or target.get("keys") != "safe":
        raise termmeshError(f"pane not listed as expected: {target}")

    _, screen = http("GET", f"/api/targets/{sid}/screen?lines=100", expect=200)
    if not isinstance((screen or {}).get("text"), str):
        raise termmeshError(f"screen payload lacks text: {screen}")

    # Type a command, press Enter through the key route, observe the pane.
    req_id = f"e2e-{os.getpid()}-1"
    _, sent = http("POST", f"/api/targets/{sid}/text",
                   {"text": f"echo {MARKER}", "request_id": req_id}, expect=200)
    if not sent.get("delivered") or sent.get("deduplicated"):
        raise termmeshError(f"first send should deliver: {sent}")
    _, again = http("POST", f"/api/targets/{sid}/text",
                    {"text": f"echo {MARKER}", "request_id": req_id}, expect=200)
    if not again.get("deduplicated"):
        raise termmeshError(f"retry with the same request_id must dedupe: {again}")
    wait_for(lambda: f"echo {MARKER}" in read_text(c, sid) or None, 10, "typed command in the pane")
    http("POST", f"/api/targets/{sid}/key", {"key": "Enter"}, expect=200)
    # The marker shows once on the command line as soon as it is typed and a
    # second time as the echo output only after Enter ran it.
    wait_for(lambda: read_text(c, sid).count(MARKER) >= 2 or None, 10,
             "echo output after Enter (surface.send_key enter)")
    text = read_text(c, sid)
    # Exactly one output line: a second execution (duplicate typing or a
    # duplicate Enter) would print the marker twice on its own line.
    outputs = [l for l in text.splitlines() if l.strip() == MARKER]
    if len(outputs) != 1:
        raise termmeshError(f"expected exactly one echo output line, got {len(outputs)}: {text[-400:]!r}")

    # The listener's screen matches what the app reports.
    _, screen = http("GET", f"/api/targets/{sid}/screen?lines=100", expect=200)
    if MARKER not in screen.get("text", ""):
        raise termmeshError("listener screen does not show the marker")

    # Allowlist and policy.
    status, payload = http("POST", f"/api/targets/{sid}/key", {"key": "q"})
    if status != 403 or error_code(payload) != "key_not_allowed":
        raise termmeshError(f"'q' must be refused: {status} {payload}")
    rc(cli, ["on", "--keys", "none", "--ttl", "10m"], surface_id=sid)
    status, payload = http("POST", f"/api/targets/{sid}/key", {"key": "Enter"})
    if status != 403 or error_code(payload) != "keys_disabled":
        raise termmeshError(f"keys=none must refuse Enter: {status} {payload}")
    if targets_by_id().get(sid, {}).get("keys") != "none":
        raise termmeshError("re-registration did not update the keys policy")

    # Off.
    out = rc(cli, ["off"], surface_id=sid)
    if "no longer exposed" not in out:
        raise termmeshError(f"remote off output unexpected: {out!r}")
    status, payload = http("GET", f"/api/targets/{sid}/screen")
    if status != 404 or error_code(payload) != "not_exposed":
        raise termmeshError(f"screen after off must be 404 not_exposed: {status} {payload}")
    if sid in targets_by_id():
        raise termmeshError("pane still listed after remote off")
    c.close_surface(sid)


def check_leader_flow(c: termmesh, cli: Path) -> None:
    team = f"mobile-e2e-{os.getpid()}"
    created = c.team_create(team, [], leader_mode="repl")
    # team.create reports surface_id only for adopted leaders; a repl leader is
    # the sole terminal in the fresh team workspace it returns.
    ws = str(created.get("workspace_id") or "")
    if not ws:
        raise termmeshError(f"team.create did not return the team workspace: {created}")
    surfaces = [sid for (_, sid, _) in c.list_surfaces(ws)]
    if len(surfaces) != 1:
        raise termmeshError(f"expected exactly one surface in the team workspace, got {surfaces}")
    leader_sid = surfaces[0]
    try:
        wait_for(lambda: prompt_ready(c, leader_sid) or None, 20, "leader pane prompt")
        # The leader pane carries the board capability token in its env; the
        # test is not that pane, so read it from the pane's shell process the
        # way the daemon's pane tracker does and hand it over as the pane would.
        token = wait_for(lambda: leader_token_from_process_env(leader_sid), 15,
                         "TERMMESH_LEADER_REQUEST_TOKEN in the leader pane environment")
        rc(cli, ["on", "--leader", "--title", "e2e-leader", "--ttl", "10m"],
           surface_id=leader_sid, team=team, extra_env={"TERMMESH_LEADER_REQUEST_TOKEN": token})
        target = targets_by_id().get(leader_sid)
        if not target or target.get("kind") != "leader" or target.get("team_name") != team:
            raise termmeshError(f"leader not listed as expected: {target}")

        _, screen = http("GET", f"/api/targets/{leader_sid}/screen?lines=100", expect=200)
        if not isinstance((screen or {}).get("text"), str):
            raise termmeshError(f"leader screen payload lacks text: {screen}")

        req_id = f"e2e-leader-{os.getpid()}"
        _, accepted = http("POST", f"/api/targets/{leader_sid}/text",
                           {"text": f"mobile leader request {MARKER}", "request_id": req_id}, expect=202)
        if accepted.get("request_id") != req_id or accepted.get("stored") is not True:
            raise termmeshError(f"leader send did not store the request: {accepted}")

        _, listed = http("GET", f"/api/targets/{leader_sid}/requests", expect=200)
        ids = {str(r.get("id") or r.get("request_id")) for r in (listed or {}).get("requests", [])}
        if req_id not in ids:
            raise termmeshError(f"durable request missing from /requests: {listed}")

        board = c._call("team.leader.request.list", {"team_name": team}) or {}
        board_ids = {str(r.get("id") or r.get("request_id")) for r in board.get("requests", [])}
        if req_id not in board_ids:
            raise termmeshError(f"durable request missing from the app board: {board}")

        rc(cli, ["off"], surface_id=leader_sid, team=team)
        if leader_sid in targets_by_id():
            raise termmeshError("leader still listed after remote off")
    finally:
        try:
            c.team_destroy(team)
        except termmeshError:
            pass


def main() -> int:
    if not MOBILE_ADDR:
        raise termmeshError("TERMMESH_E2E_MOBILE_ADDR is not set; run through scripts/run-tests-v2.sh")
    if not APP_SOCK or not DAEMON_SOCK:
        raise termmeshError("TERMMESH_SOCKET_PATH / TERMMESH_DAEMON_UNIX_PATH are required")
    cli = bundled_tm_agent()

    _, health = http("GET", "/api/health", expect=200)
    if not health.get("ok") or health.get("auth_mode") != "loopback":
        raise termmeshError(f"unexpected health payload: {health}")
    status, _ = http("GET", "/api/agents/spawn")
    if status != 404:
        raise termmeshError(f"dashboard routes must not exist on the mobile listener: {status}")

    with termmesh() as c:
        check_pane_flow(c, cli)
        check_leader_flow(c, cli)

    print("PASS: mobile remote control lists, reads, types, keys, and leader requests through the listener")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
