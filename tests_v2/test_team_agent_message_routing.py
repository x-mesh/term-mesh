#!/usr/bin/env python3
"""An agent-to-agent note reaches its addressee and nobody else.

This is the contract a live team was measured against after the native-pane
environment fix: explorer messaged executor, executor read it out of its own
inbox and answered back. The delivery itself is app state rather than CLI
behaviour, so it is asserted here without spawning an agent CLI.
"""

from __future__ import annotations

import sys
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError


TEAM_NAME = f"test-msg-routing-{uuid.uuid4().hex[:8]}"
PING = f"PING-{uuid.uuid4().hex[:8]}"
PONG = f"PONG-{uuid.uuid4().hex[:8]}"


def _notes(client: "termmesh", agent: str) -> list[str]:
    return [
        item.get("reason")
        for item in client.team_inbox(TEAM_NAME, agent)
        if item.get("kind") == "message"
    ]


def main() -> int:
    with termmesh() as c:
        c.team_create(TEAM_NAME, [
            {"name": "alpha", "cli": "claude", "model": "sonnet",
             "agent_type": "worker", "color": "green"},
            {"name": "beta", "cli": "claude", "model": "sonnet",
             "agent_type": "worker", "color": "blue"},
        ])

        try:
            c.team_message_post(TEAM_NAME, "alpha", PING, to="beta")

            beta_notes = _notes(c, "beta")
            if PING not in beta_notes:
                raise termmeshError(
                    f"addressee did not receive the note: expected {PING!r} in {beta_notes!r}"
                )

            alpha_notes = _notes(c, "alpha")
            if PING in alpha_notes:
                raise termmeshError(
                    f"note addressed to beta leaked into the sender's inbox: {alpha_notes!r}"
                )

            # The reverse direction is a separate path in the store's filter:
            # it matches on `to`, so a symmetric check catches a filter that
            # accidentally keys on the sender instead.
            c.team_message_post(TEAM_NAME, "beta", PONG, to="alpha")

            alpha_notes = _notes(c, "alpha")
            if PONG not in alpha_notes:
                raise termmeshError(
                    f"reply did not reach the original sender: expected {PONG!r} in {alpha_notes!r}"
                )

            beta_notes = _notes(c, "beta")
            if PONG in beta_notes:
                raise termmeshError(
                    f"reply leaked back into its own sender's inbox: {beta_notes!r}"
                )
        finally:
            c.team_destroy(TEAM_NAME)

    print("PASS: agent-to-agent notes reach only their addressee")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
