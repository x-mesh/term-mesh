#!/usr/bin/env python3

import importlib.util
import tempfile
import unittest
import unittest.mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("term_mesh_release", ROOT / "scripts/release.py")
release = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(release)


class ReleaseStateMachineTests(unittest.TestCase):
    def test_minor_version_is_the_default_policy(self):
        self.assertEqual(release.next_minor("0.201.7"), "0.202.0")

    def test_version_validation_rejects_non_semver(self):
        with self.assertRaises(release.ReleaseError):
            release.normalize_version("release-next")

    def test_install_notes_is_idempotent(self):
        with tempfile.TemporaryDirectory() as directory:
            changelog = Path(directory) / "CHANGELOG.md"
            changelog.write_text("# Changelog\n\n## [Unreleased]\n\n## [0.201.0]\n")
            notes = "## [0.202.0] - 2026-08-21\n\n### Fixed\n\n- Fix it.\n"
            release.install_notes(changelog, "0.202.0", notes)
            once = changelog.read_text()
            release.install_notes(changelog, "0.202.0", notes)
            self.assertEqual(changelog.read_text(), once)
            self.assertEqual(once.count("## [0.202.0]"), 1)

    def test_remote_mutations_require_explicit_yes(self):
        args = type("Args", (), {"yes": False})()
        with self.assertRaisesRegex(release.ReleaseError, "require --yes"):
            release.ensure_approved(args)

    def test_steps_preserve_release_order(self):
        self.assertLess(
            release.STEP_ORDER.index("develop_to_main"),
            release.STEP_ORDER.index("release_metadata"),
        )
        self.assertLess(
            release.STEP_ORDER.index("tag"),
            release.STEP_ORDER.index("release_build"),
        )
        self.assertLess(release.STEP_ORDER.index("release_build"), release.STEP_ORDER.index("dsym"))
        self.assertLess(release.STEP_ORDER.index("dsym"), release.STEP_ORDER.index("dmg"))

    def test_homebrew_cask_parses_version_and_sha(self):
        import base64
        body = 'cask "term-mesh" do\n  version "1.2.3"\n  sha256 "' + ('a' * 64) + '"\nend\n'
        with unittest.mock.patch.object(release, "run", return_value=base64.b64encode(body.encode()).decode()):
            self.assertEqual(release.homebrew_cask(), ("1.2.3", "a" * 64))

    def test_state_dir_can_be_isolated(self):
        with tempfile.TemporaryDirectory() as directory, unittest.mock.patch.dict(
            "os.environ", {"TERMMESH_RELEASE_STATE_DIR": directory}
        ):
            self.assertEqual(release.state_dir(), Path(directory).resolve())

    def test_auto_plan_lock_does_not_require_semver(self):
        with tempfile.TemporaryDirectory() as directory, unittest.mock.patch.dict(
            "os.environ", {"TERMMESH_RELEASE_STATE_DIR": directory}
        ):
            with release.release_lock("auto"):
                self.assertTrue((Path(directory) / "plan.lock").exists())

    def test_release_lock_rejects_a_second_owner(self):
        with tempfile.TemporaryDirectory() as directory, unittest.mock.patch.dict(
            "os.environ", {"TERMMESH_RELEASE_STATE_DIR": directory}
        ):
            with release.release_lock("0.202.0"):
                with self.assertRaisesRegex(release.ReleaseError, "already running"):
                    with release.release_lock("0.202.0"):
                        pass


if __name__ == "__main__":
    unittest.main()
