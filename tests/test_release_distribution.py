#!/usr/bin/env python3

"""Leader commands must be distributed in lockstep.

CLAUDE.md requires a new leader command to land in its Claude command, Codex
prompt, Codex skill, the installer's managed-name lists, and the IME alias map
together. This suite reads those five places and compares them, rather than
pinning the exact text of each list: an assertion that spells out every command
goes red the moment one is added, which says nothing about whether the addition
was actually in lockstep. `rc.md` was added to the copy script, the installer,
and the alias map and this file still failed, while the Makefile — which really
had been missed — went unchecked.
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def shell_array(body: str, name: str) -> list[str]:
    match = re.search(rf"^{name}=\((.*?)\)\s*$", body, re.MULTILINE)
    assert match, f"{name} array not found"
    return match.group(1).split()


def swift_string_set(body: str, name: str) -> list[str]:
    match = re.search(rf"{name}:\s*Set<String>\s*=\s*\[(.*?)\]", body, re.DOTALL)
    assert match, f"{name} set not found"
    return re.findall(r'"([^"]+)"', match.group(1))


class ReleaseDistributionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.copy_script = (ROOT / "scripts/copy-claude-commands.sh").read_text()
        cls.installer = (ROOT / "Sources/ClaudeCommandInstaller.swift").read_text()
        cls.aliases = (ROOT / "Sources/GhosttySurfaceScrollView.swift").read_text()
        cls.makefile = (ROOT / "Makefile").read_text()

    def test_bundled_commands_match_the_installer_managed_list(self):
        self.assertEqual(
            sorted(shell_array(self.copy_script, "COMMANDS")),
            sorted(swift_string_set(self.installer, "managedCommandNames")),
            "copy-claude-commands.sh COMMANDS and managedCommandNames disagree",
        )

    def test_every_bundled_command_has_a_source_file(self):
        for name in shell_array(self.copy_script, "COMMANDS"):
            self.assertTrue(
                (ROOT / ".claude/commands" / name).exists(),
                f"COMMANDS lists {name} but .claude/commands/{name} is missing",
            )

    def test_codex_prompts_match_the_installer_and_have_sources(self):
        prompts = shell_array(self.copy_script, "CODEX_PROMPTS")
        self.assertEqual(
            sorted(prompts),
            sorted(swift_string_set(self.installer, "managedCodexPromptNames")),
            "CODEX_PROMPTS and managedCodexPromptNames disagree",
        )
        for name in prompts:
            self.assertTrue(
                (ROOT / "Resources/CodexPrompts" / name).exists(),
                f"CODEX_PROMPTS lists {name} but Resources/CodexPrompts/{name} is missing",
            )

    def test_every_codex_prompt_is_reachable_from_the_ime_bar(self):
        aliases = dict(re.findall(r'"(/[\w-]+)":\s*"([^"]+)"', self.aliases))
        for name in shell_array(self.copy_script, "CODEX_PROMPTS"):
            slash = "/" + name.removesuffix(".md")
            self.assertEqual(
                aliases.get(slash),
                f"~/.codex/prompts/{name}",
                f"imeSlashCommandAliases has no entry for {slash}",
            )

    def test_codex_skills_have_their_skill_files(self):
        for name in shell_array(self.copy_script, "CODEX_SKILLS"):
            self.assertTrue(
                (ROOT / "Resources/CodexSkills" / name / "SKILL.md").exists(),
                f"CODEX_SKILLS lists {name} but Resources/CodexSkills/{name}/SKILL.md is missing",
            )

    def test_make_install_commands_covers_every_bundled_command(self):
        match = re.search(r"@for cmd in ([\w\s-]+); do", self.makefile)
        self.assertIsNotNone(match, "install-commands loop not found in the Makefile")
        self.assertEqual(
            sorted(match.group(1).split()),
            sorted(name.removesuffix(".md") for name in shell_array(self.copy_script, "COMMANDS")),
            "make install-commands installs a different set than the app bundles",
        )

    def test_wrappers_delegate_to_the_state_machine(self):
        for relative in (".claude/commands/release.md", "Resources/CodexPrompts/release.md"):
            body = (ROOT / relative).read_text()
            self.assertIn("scripts/release.py prepare", body)
            self.assertIn("scripts/release.py publish", body)
            self.assertIn("scripts/release.py resume", body)


if __name__ == "__main__":
    unittest.main()
