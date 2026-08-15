#!/usr/bin/env python3
"""team.read resolves the Project leader outside the ordinary agents array."""
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError


TEAM = "pair-review-leader-read-e2e"


def main() -> int:
    with termmesh() as client:
        created = client.debug_project_create(
            f"/tmp/{TEAM}", [], leader_cli="codex", leader_model="gpt-5.6-luna"
        )
        team = created.get("team")
        if not team:
            raise termmeshError(f"debug project did not return a team: {created!r}")
        try:
            deadline = time.monotonic() + 20
            last_error = None
            while time.monotonic() < deadline:
                try:
                    result = client._call("team.read", {
                        "team_name": team, "agent_name": "leader", "lines": 20,
                    })
                    if result.get("agent_name") != "leader":
                        raise termmeshError(f"wrong read target: {result!r}")
                    if not result.get("agent_instance_id"):
                        raise termmeshError(f"leader read omitted identity: {result!r}")
                    break
                except termmeshError as error:
                    last_error = error
                    time.sleep(0.2)
            else:
                raise termmeshError(f"leader never became readable: {last_error}")
        finally:
            client.debug_project_delete(team)

    print("PASS: team.read resolves the Project leader pane")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
