#!/usr/bin/env python3
"""team.delegate keeps description and acceptance_criteria on the task record."""

from __future__ import annotations

import sys
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError


TEAM_NAME = f"test-delegate-metadata-{uuid.uuid4().hex[:8]}"
AGENT_NAME = "worker"
DESCRIPTION = "Delegate metadata must survive the unified path."
ACCEPTANCE = ["description is stored", "acceptance criteria are stored"]


def main() -> int:
    with termmesh() as c:
        c._call("team.create", {
            "team_name": TEAM_NAME,
            "leader_mode": "repl",
            "skip_runbook_init_prompt": True,
            "agents": [{
                "name": AGENT_NAME,
                "cli": "claude",
                "model": "sonnet",
                "agent_type": "worker",
                "color": "green",
            }],
        })

        try:
            delegated = c._call("team.delegate", {
                "team": TEAM_NAME,
                "agent": AGENT_NAME,
                "text": "Metadata preservation probe.",
                "task_title": "delegate metadata probe",
                "request_id": f"delegate-metadata-{uuid.uuid4()}",
                "description": DESCRIPTION,
                "acceptance_criteria": ACCEPTANCE,
            })
            task_id = (delegated.get("task") or {}).get("id")
            if not task_id:
                raise termmeshError(f"delegate returned no task id: {delegated!r}")

            task = c._call("team.task.get", {"team_name": TEAM_NAME, "task_id": task_id})
            if task.get("description") != DESCRIPTION:
                raise termmeshError(
                    f"description lost: {task.get('description')!r} != {DESCRIPTION!r}"
                )
            if task.get("acceptance_criteria") != ACCEPTANCE:
                raise termmeshError(
                    f"acceptance_criteria lost: {task.get('acceptance_criteria')!r} "
                    f"!= {ACCEPTANCE!r}"
                )
        finally:
            try:
                c._call("team.destroy", {"team_name": TEAM_NAME})
            except Exception:
                pass

    print("PASS: team.delegate preserves description and acceptance_criteria")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
