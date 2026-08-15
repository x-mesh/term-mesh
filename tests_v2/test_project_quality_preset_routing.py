#!/usr/bin/env python3
"""Quality Project creation preserves the production preset's provider/model routing."""
from __future__ import annotations

import sys
import time
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError


def main() -> int:
    team = f"quality-preset-e2e-{uuid.uuid4().hex[:8]}"
    with termmesh() as c:
        resolved = c._call("team.preset.resolve", {"preset_id": "quality"})
        expected = {
            row["name"]: (row["cli"], row["model"])
            for row in resolved.get("agents", [])
        }
        created = c.debug_project_create(
            directory=f"/tmp/{team}",
            roles=list(expected),
            preset_id="quality",
        )
        if created.get("team") != team:
            raise termmeshError(f"Quality Project was not created: {created!r}")

        try:
            deadline = time.time() + 45
            status = None
            while time.time() < deadline:
                try:
                    status = c._call("team.status", {"team_name": team})
                    if len(status.get("agents", [])) == len(expected):
                        break
                except termmeshError:
                    pass
                time.sleep(0.2)
            if status is None:
                raise termmeshError("Quality Project status never appeared")
            actual = {
                row["name"]: (row.get("cli"), row.get("model"))
                for row in status.get("agents", [])
            }
            if actual != expected:
                raise termmeshError(
                    f"Project routing diverged from preset resolver: expected={expected!r} actual={actual!r}"
                )
            instance_ids = [row.get("agent_instance_id") for row in status["agents"]]
            if len(set(instance_ids)) != len(instance_ids) or any(not item for item in instance_ids):
                raise termmeshError(f"agent instance IDs are not unique: {instance_ids!r}")
            if status.get("leader_policy_version") != "8":
                raise termmeshError(f"leader policy v8 not injected: {status!r}")
            if any(row.get("read_only_default") is not True for row in status["agents"]):
                raise termmeshError(f"validator mutation defaults are unsafe: {status['agents']!r}")

            try:
                c._call("team.leader.request.list", {"team_name": team})
            except termmeshError as exc:
                if "unauthorized" not in str(exc):
                    raise
            else:
                raise termmeshError("tokenless worker context read the leader request queue")
        finally:
            c.team_destroy(team)

    print("PASS: Quality Project matches resolved provider/model routing and leader-only capability")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
