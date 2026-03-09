#!/bin/bash
# term-mesh Team Agent CLI — thin wrapper around team.py
# All functionality has been moved to team.py.
# This wrapper exists for backward compatibility.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$SCRIPT_DIR/team.py" "$@"
