#!/usr/bin/env python3

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class ReleaseDistributionTests(unittest.TestCase):
    def test_release_is_distributed_to_claude_and_codex(self):
        copy_script = (ROOT / "scripts/copy-claude-commands.sh").read_text()
        installer = (ROOT / "Sources/ClaudeCommandInstaller.swift").read_text()
        aliases = (ROOT / "Sources/GhosttySurfaceScrollView.swift").read_text()
        self.assertIn("COMMANDS=(tm.md team.md team-up.md tm-op.md tm-bench.md watch.md release.md)", copy_script)
        self.assertIn("CODEX_PROMPTS=(team.md team-up.md tm.md tm-op.md tm-bench.md watch.md release.md)", copy_script)
        self.assertGreaterEqual(installer.count('"release.md"'), 2)
        self.assertIn('"/release": "~/.codex/prompts/release.md"', aliases)
        self.assertTrue((ROOT / ".claude/commands/release.md").exists())
        self.assertTrue((ROOT / "Resources/CodexPrompts/release.md").exists())
        makefile = (ROOT / "Makefile").read_text()
        self.assertIn("for cmd in tm-op team team-up tm-bench release", makefile)

    def test_wrappers_delegate_to_the_state_machine(self):
        for relative in (".claude/commands/release.md", "Resources/CodexPrompts/release.md"):
            body = (ROOT / relative).read_text()
            self.assertIn("scripts/release.py prepare", body)
            self.assertIn("scripts/release.py publish", body)
            self.assertIn("scripts/release.py resume", body)


if __name__ == "__main__":
    unittest.main()
