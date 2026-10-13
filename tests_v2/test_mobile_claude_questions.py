#!/usr/bin/env python3
"""Claude AskUserQuestion mobile E2E for the tagged mac-sub runner."""

import hashlib
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path


ADDRESS = os.environ.get("TERMMESH_E2E_MOBILE_ADDR", "")
SURFACE = os.environ.get("TERMMESH_E2E_CLAUDE_QUESTION_SURFACE_ID", "")
SOCKET = os.environ.get("TERMMESH_DAEMON_UNIX_PATH", "/tmp/term-meshd.sock")


def private_mkdir(path):
    current = Path(path.anchor)
    for part in path.parts[1:]:
        current /= part
        current.mkdir(mode=0o700, exist_ok=True)
        current.chmod(0o700)
        stat = current.stat()
        if current.is_symlink() or stat.st_uid != os.getuid() or stat.st_mode & 0o077:
            raise RuntimeError(f"question store is not private: {current}")


def request(method, path, body=None):
    data = None if body is None else json.dumps(body).encode()
    headers = {} if data is None else {"Content-Type": "application/json"}
    try:
        with urllib.request.urlopen(urllib.request.Request(
            f"http://{ADDRESS}{path}", data=data, headers=headers, method=method
        ), timeout=15) as response:
            return response.status, json.loads(response.read())
    except urllib.error.HTTPError as error:
        return error.code, json.loads(error.read())


def main():
    if not ADDRESS or not SURFACE:
        print("SKIP: run through mac-sub with mobile address and Claude question surface")
        return 0
    if sys.platform == "darwin":
        root = Path.home() / "Library/Application Support/term-mesh"
    else:
        root = Path.home() / ".local/share/term-mesh"
    root = root / "questions-v1" / hashlib.sha256(SOCKET.encode()).hexdigest() / SURFACE / "e2e-question"
    private_mkdir(root)
    question = {
        "id": "e2e-question", "fingerprint": "e2e-fingerprint", "surface_id": SURFACE, "state": "pending",
        "questions": [{"question": "term-mesh mobile fixture", "options": [{"label": "Continue"}]}],
    }
    record = root / "e2e-question.json"
    record.write_text(json.dumps(question), encoding="utf-8")
    record.chmod(0o600)
    status, listed = request("GET", f"/api/targets/{SURFACE}/questions")
    if status != 200 or listed.get("question", {}).get("id") != question["id"]:
        raise RuntimeError(f"GET question fixture failed: {status} {listed}")
    status, answer = request("POST", f"/api/targets/{SURFACE}/questions/{question['id']}/answer", {
        "fingerprint": "stale", "answers": [{"question_index": 0, "selected": [1]}],
    })
    if status != 409 or answer.get("error", {}).get("code") != "prompt_gone":
        raise RuntimeError(f"stale POST must fail closed: {status} {answer}")
    if json.loads(record.read_text(encoding="utf-8"))["state"] != "pending":
        raise RuntimeError("stale POST changed the pending question")
    print("PASS: mobile Claude question GET fixture, stale POST, and pending state")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
