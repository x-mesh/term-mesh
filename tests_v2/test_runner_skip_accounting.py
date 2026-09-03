#!/usr/bin/env python3
"""The v2 runner distinguishes pass, SKIP, and failure without launching the app."""
from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path


def classify(status: int, text: str) -> int:
    with tempfile.NamedTemporaryFile("w", delete=False) as output:
        output.write(text)
        path = Path(output.name)
    try:
        return subprocess.run([
            "bash", "scripts/classify-test-result.sh", str(status), str(path),
        ]).returncode
    finally:
        path.unlink(missing_ok=True)


def main() -> int:
    assert classify(0, "PASS: real execution\n") == 0
    assert classify(0, "SKIP: fixture missing\n") == 2
    assert classify(0, "message mentions SKIP: but is not a skip line\n") == 0
    assert classify(1, "SKIP: failure still fails\n") == 1
    print("PASS: runner accounting keeps pass, SKIP, and failure distinct")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
