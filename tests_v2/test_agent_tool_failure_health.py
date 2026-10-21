#!/usr/bin/env python3
"""Expose repeated tool failures through real app read/status without changing task verdicts."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import uuid

from test_agent_send_queue_latency import (
    DEFAULTS_DOMAIN, DEFAULTS_KEY, _read_default, _restore_default,
)
from termmesh import termmesh, termmeshError

SECRET = "fixture818-private-value"
FAKE_CODEX = r'''#!/usr/bin/env python3
import json,sys

def emit(value):
    print(json.dumps(value),flush=True)

def completed(item):
    emit({'method':'item/completed','params':{'threadId':'health-thread','item':item}})

for raw in sys.stdin:
    request=json.loads(raw)
    method=request.get('method')
    if method=='initialize':
        emit({'id':request['id'],'result':{}})
    elif method=='thread/start':
        emit({'id':request['id'],'result':{'thread':{'id':'health-thread'}}})
    elif method=='turn/start':
        text=''.join(p.get('text','') for p in request['params'].get('input',[]))
        emit({'id':request['id'],'result':{'turn':{'id':'health-turn'}}})
        answer='STATUS: DONE\nFILES: none\nVERIFY: pong\nNEXT: none\nFULL_REPORT: n/a\npong'
        if 'FAIL818' in text:
            for index in range(3):
                item={'type':'functionCallOutput','id':'failure-'+str(index),'name':'exec',
                      'namespace':None,'output':'Script failed\nWall time 0.0 seconds\nOutput:\nScript error:\nSyntaxError: Invalid or unexpected token API_KEY=fixture818-private-value'}
                completed(item)
                if index==0:
                    completed(item)
            answer='STATUS: NEEDS_REVIEW\nFILES: none\nVERIFY: failed tool fixture\nNEXT: inspect tool errors\nFULL_REPORT: n/a'
        elif 'RECOVER818' in text:
            completed({'type':'commandExecution','id':'recovered','command':'true',
                       'status':'completed','exitCode':0,'aggregatedOutput':'recovered'})
        completed({'type':'agentMessage','text':answer})
        emit({'method':'turn/completed','params':{'threadId':'health-thread','turn':{'status':'completed'}}})
'''


def wait_for(check, label):
    deadline = time.monotonic() + 40
    while time.monotonic() < deadline:
        value = check()
        if value:
            return value
        time.sleep(0.1)
    raise termmeshError(f"timeout waiting for {label}")


def require(condition, message):
    if not condition:
        raise termmeshError(message)


def main():
    repo = Path(__file__).resolve().parents[1]
    cli = repo / "daemon/target/release/tm-agent"
    team = "health818-" + uuid.uuid4().hex[:8]
    agent = "health-worker"
    existed, old_value = _read_default()
    with tempfile.TemporaryDirectory(prefix="term-mesh-health818-") as temporary:
        fake = Path(temporary) / "codex"
        fake.write_text(FAKE_CODEX)
        fake.chmod(0o755)
        subprocess.run(["defaults", "write", DEFAULTS_DOMAIN, DEFAULTS_KEY,
                        "-string", str(fake)], check=True)
        try:
            with termmesh() as client:
                client.team_create(team, [])
                try:
                    env = {k: v for k, v in os.environ.items()
                           if not k.startswith("TERMMESH_LEADER_") and k not in (
                               "TERMMESH_PEER_SOCKET", "TERMMESH_DAEMON_SOCKET",
                               "TERMMESH_DAEMON_UNIX_PATH")}
                    env.update(TERMMESH_SOCKET=client.socket_path,
                               TERMMESH_SOCKET_PATH=client.socket_path, TERMMESH_TEAM=team)

                    def command(*args):
                        result = subprocess.run([str(cli), *args], cwd=repo, env=env,
                                                text=True, capture_output=True, timeout=90)
                        require(result.returncode == 0, f"{args}: {result.stdout}{result.stderr}")
                        return result.stdout

                    def member():
                        return next(a for a in client.team_status(team)["agents"]
                                    if a["name"] == agent)

                    command("add", "reviewer", "--name", agent, "--cli", "codex",
                            "--warmup", "--warmup-timeout", "40")
                    instance = member()["agent_instance_id"]
                    focus = (client.current_workspace(),
                             [s[1] for s in client.list_surfaces() if s[2]])
                    task = client._call("team.task.create", {
                        "team_name": team, "title": "failure visibility",
                        "assignee": agent, "agent_instance_id": instance})
                    task_id = task["id"]

                    def task_status():
                        return next(t["status"] for t in client.team_task_list(team)
                                    if t["id"] == task_id)

                    command("send", agent, "FAIL818", "--task", task_id)
                    wait_for(lambda: task_status() == "review_ready", "worker review verdict")
                    status = member()
                    health = status.get("tool_failures", {})
                    require(health.get("total") == 3, f"expected 3 distinct failures: {health}")
                    require(health.get("turn_failures") == 3, f"wrong turn failure count: {health}")
                    require(health.get("consecutive") == 3, f"wrong failure streak: {health}")
                    require(health.get("needs_attention") is True, f"missing attention: {health}")
                    single = client._call("team.agent.status", {
                        "team_name": team, "agent_name": agent, "agent_instance_id": instance})
                    require(single.get("tool_failures") == health, "single-agent health differs from team health")
                    require(status.get("health") == "degraded", f"missing degraded health: {status}")
                    require("restart" in status.get("recovery_hint", ""), "missing recovery hint")
                    require("SyntaxError" in health.get("last_error", ""), f"missing root error: {health}")
                    read = command("read", agent, "--lines", "100")
                    require("SyntaxError" in read, f"read omitted tool error: {read}")
                    require(SECRET not in read + json.dumps(status), "credential leaked into read/status")
                    status_cli = json.loads(command("status"))["result"]
                    require(next(a for a in status_cli["agents"] if a["name"] == agent)
                            ["tool_failures"]["total"] == 3, "CLI status lost failure counts")
                    require(member()["agent_instance_id"] == instance, "unexpected automatic restart")

                    command("send", agent, "RECOVER818", "--task", task_id)
                    wait_for(lambda: task_status() == "completed", "recovered task completion")
                    recovered = member()
                    counters = recovered["tool_failures"]
                    require(counters["total"] == 3 and counters["turn_failures"] == 0
                            and counters["consecutive"] == 0, f"bad recovery counters: {counters}")
                    require(counters["needs_attention"] is False and recovered["health"] == "ok",
                            f"health did not recover: {recovered}")
                    require((client.current_workspace(), [s[1] for s in client.list_surfaces() if s[2]])
                            == focus, "non-focus commands changed focus")
                    print(json.dumps({"failed": health, "recovered": counters}, indent=2))
                finally:
                    client.team_destroy(team)
        finally:
            _restore_default(existed, old_value)
    print("PASS: app read/status preserve deduplicated redacted tool failures, warn and recover without changing verdict or focus")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
