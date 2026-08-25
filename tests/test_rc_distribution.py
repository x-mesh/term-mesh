#!/usr/bin/env python3

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class RcDistributionTests(unittest.TestCase):
    def test_rc_wrappers_forbid_zsh_status_capture(self):
        for relative in (
            ".claude/commands/rc.md",
            "Resources/CodexPrompts/rc.md",
            "Resources/CodexSkills/rc/SKILL.md",
        ):
            body = (ROOT / relative).read_text()
            self.assertIn("read-only in zsh", body)
            self.assertIn("output=$(...)", body)


if __name__ == "__main__":
    unittest.main()
