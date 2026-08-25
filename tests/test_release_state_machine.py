#!/usr/bin/env python3

import importlib.util
import json
import subprocess
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

    def test_relay_receipt_requires_exact_candidate_and_durable_bytes(self):
        receipt = {
            "schema": 1,
            "candidate_sha": "abc123",
            "remote_fixture_candidate_sha": "abc123",
            "remote_fixture_version": "v0.213.0",
            "result": "pass",
            "required_topology": True,
            "skipped": False,
            "phases": {
                "create": "pass", "adopt": "pass",
                "reconnect": "pass", "cleanup": "pass",
            },
            "exact_surface_preserved": True,
            "leader_relay_stability_seconds": 15,
            "background_restore_hold_seconds": 12,
            "saw_first_byte": True,
            "bytes_received": 42,
            "leader_surface_id": "surface",
            "leader_process_active": True,
            "leader_process_active_known": True,
            "tested_at_unix": int(release.time.time()),
        }
        release.validate_relay_e2e_receipt(receipt, "abc123")
        for key, value in (
            ("candidate_sha", "wrong"),
            ("remote_fixture_candidate_sha", "wrong"),
            ("skipped", True),
            ("leader_relay_stability_seconds", 10),
            ("bytes_received", 0),
            ("leader_process_active", False),
        ):
            invalid = dict(receipt)
            invalid[key] = value
            with self.assertRaises(release.ReleaseError, msg=key):
                release.validate_relay_e2e_receipt(invalid, "abc123")

    def test_relay_e2e_scope_is_fail_closed_for_peer_lifecycle_only(self):
        self.assertTrue(release.relay_e2e_required_for_paths([
            "Sources/TeamOrchestrator+RemoteAgent.swift"
        ]))
        self.assertTrue(release.relay_e2e_required_for_paths([
            "daemon/term-meshd/src/peer/connection.rs"
        ]))
        self.assertFalse(release.relay_e2e_required_for_paths(["README.md"]))

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

    def test_gk_accepts_agent_envelope_from_stderr(self):
        envelope = {"state": "ok", "ok": True, "result": {"result": "updated"}}
        completed = subprocess.CompletedProcess(
            args=("git-kit", "pull"), returncode=0, stdout="", stderr=json.dumps(envelope)
        )
        with unittest.mock.patch.object(release.subprocess, "run", return_value=completed):
            self.assertEqual(release.gk("pull"), envelope)

    def test_gk_normalizes_successful_plain_text_output(self):
        completed = subprocess.CompletedProcess(
            args=("git-kit", "merge"), returncode=0,
            stdout="Already up to date", stderr="",
        )
        with unittest.mock.patch.object(release.subprocess, "run", return_value=completed):
            envelope = release.gk("merge")
        self.assertEqual(envelope["state"], "ok")
        self.assertEqual(envelope["result"]["output"], "Already up to date")

    def test_release_resync_uses_autostash(self):
        source = (ROOT / "scripts/release.py").read_text()
        self.assertIn('branch_worktree("develop", allow_dirty=True)', source)
        self.assertIn(
            'gk(\n                "merge", "--no-ai", "--autostash",',
            source,
        )


    def test_cleanup_runs_after_verify(self):
        self.assertEqual(release.STEP_ORDER[-1], "cleanup")
        self.assertLess(release.STEP_ORDER.index("verify"), release.STEP_ORDER.index("cleanup"))

    def test_load_state_backfills_steps_added_after_the_file_was_written(self):
        with tempfile.TemporaryDirectory() as directory, unittest.mock.patch.dict(
            "os.environ", {"TERMMESH_RELEASE_STATE_DIR": directory}
        ):
            (Path(directory) / "v0.202.0.json").write_text(json.dumps({
                "schema": 1, "version": "0.202.0",
                "steps": {"develop_to_main": {"status": "completed"}},
            }))
            state = release.load_state("0.202.0")
            self.assertTrue(release.completed(state, "develop_to_main"))
            self.assertFalse(release.completed(state, "cleanup"))

    def test_cleanup_claims_this_version_and_older_but_never_develop(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ("develop", "v0.212.0-source", "v0.213.0-source",
                         "v0.213.0-artifact-2e00f3b16eea", "v0.214.0-source"):
                (root / name).mkdir()
            with unittest.mock.patch.object(release, "RELEASE_WORKTREES", root):
                claimed = [path.name for path in release.obsolete_release_worktrees("0.213.0")]
        self.assertEqual(claimed, ["v0.212.0-source", "v0.213.0-artifact-2e00f3b16eea", "v0.213.0-source"])

    def test_cleanup_only_claims_release_branches_whose_tag_shipped(self):
        def fake_git(*args, **kwargs):
            if args[0] == "branch":
                return "chore/release-v0.212.0\nchore/release-v0.213.0\nchore/release-v0.214.0"
            if args[0] == "tag":
                return args[2] if args[2] in ("v0.212.0",) else ""
            raise AssertionError(args)

        with unittest.mock.patch.object(release, "git", fake_git):
            self.assertEqual(release.obsolete_release_branches("0.213.0"), ["chore/release-v0.212.0"])

    def test_cleanup_records_what_it_reclaimed(self):
        with tempfile.TemporaryDirectory() as directory, unittest.mock.patch.dict(
            "os.environ", {"TERMMESH_RELEASE_STATE_DIR": directory}
        ):
            state = {"schema": 1, "version": "0.213.0",
                     "release_branch": "chore/release-v0.213.0",
                     "steps": {name: {"status": "pending"} for name in release.STEP_ORDER}}
            deleted = []
            with unittest.mock.patch.object(
                release, "obsolete_release_worktrees",
                return_value=[Path("/tmp/v0.213.0-source")],
            ), unittest.mock.patch.object(
                release, "obsolete_release_branches", return_value=["chore/release-v0.213.0"],
            ), unittest.mock.patch.object(
                release, "remove_worktree", return_value=True,
            ), unittest.mock.patch.object(
                release, "run", side_effect=lambda *args, **kwargs: deleted.append(args) or "",
            ):
                release.cleanup(state, keep_worktrees=False)
        self.assertEqual(deleted, [("git", "branch", "-D", "chore/release-v0.213.0")])
        self.assertEqual(state["steps"]["cleanup"]["worktrees"], ["/tmp/v0.213.0-source"])
        self.assertEqual(state["steps"]["cleanup"]["branches"], ["chore/release-v0.213.0"])

    def test_cleanup_opt_out_touches_nothing(self):
        with tempfile.TemporaryDirectory() as directory, unittest.mock.patch.dict(
            "os.environ", {"TERMMESH_RELEASE_STATE_DIR": directory}
        ):
            state = {"schema": 1, "version": "0.213.0",
                     "release_branch": "chore/release-v0.213.0",
                     "steps": {name: {"status": "pending"} for name in release.STEP_ORDER}}
            with unittest.mock.patch.object(release, "remove_worktree") as remover:
                release.cleanup(state, keep_worktrees=True)
        remover.assert_not_called()
        self.assertEqual(state["steps"]["cleanup"]["skipped"], "--keep-worktrees")

    def test_a_finished_release_does_not_rebuild_its_worktrees(self):
        source = (ROOT / "scripts/release.py").read_text()
        self.assertIn(
            'wt = None if completed(state, "release_metadata") else release_worktree(state, main_sha)',
            source,
        )
        self.assertIn("if any(not completed(state, name) for name in artifact_steps)", source)


if __name__ == "__main__":
    unittest.main()
