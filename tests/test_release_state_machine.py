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
            ("background_restore_hold_seconds", 10),
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


    # --- resuming a release the remote has already moved past (#454) ---

    LINUX_ASSETS = [
        "term-meshd-linux-aarch64.tar.gz",
        "term-meshd-linux-aarch64.tar.gz.sha256",
        "term-meshd-linux-x86_64.tar.gz",
        "term-meshd-linux-x86_64.tar.gz.sha256",
    ]

    @staticmethod
    def _interrupted_receipt(state_dir, version, *, merge_sha, running="release_build", **overrides):
        """A receipt that stopped mid-publish, as v0.226.4's did."""
        steps = {name: {"status": "pending"} for name in release.STEP_ORDER}
        for name in ("develop_to_main", "release_metadata", "release_pr", "release_merge"):
            steps[name] = {"status": "completed"}
        steps["release_pr"] = {"status": "completed", "pr": 452}
        steps["release_merge"] = {"status": "completed", "merge_sha": merge_sha}
        if running:
            steps[running] = {"status": "running", "started_at": "2026-09-03T07:00:00Z"}
        steps.update(overrides)
        (Path(state_dir) / f"v{version}.json").write_text(json.dumps({
            "schema": 1, "version": version, "candidate_develop_sha": merge_sha,
            "candidate_main_sha": merge_sha, "latest_tag": "v0.226.3", "steps": steps,
        }))

    @staticmethod
    def _facts(version, **overrides):
        facts = {
            "tag": f"v{version}", "tag_commit": None, "release": None,
            "homebrew": None, "mismatched": [], "unreadable": {},
        }
        facts.update(overrides)
        return facts

    def test_resume_adopts_a_tag_and_release_published_out_of_band(self):
        """v0.226.4: the tag and the Linux assets were public, the receipt was not.

        Resuming from the receipt alone would re-tag a tag that already exists and
        would read `release_build: running` as work still in flight.
        """
        merge_sha = "87a6656ba8e629452a1ca78d2335500a7fdf494f"
        with tempfile.TemporaryDirectory() as state, unittest.mock.patch.dict(
            "os.environ", {"TERMMESH_RELEASE_STATE_DIR": state}
        ):
            self._interrupted_receipt(state, "0.226.4", merge_sha=merge_sha)
            loaded = release.load_state("0.226.4")
            facts = self._facts("0.226.4", tag_commit=merge_sha, release={
                "url": "https://github.com/x-mesh/term-mesh/releases/tag/v0.226.4",
                "isDraft": False, "isPrerelease": False,
                "assets": [{"name": name} for name in self.LINUX_ASSETS],
            })
            release.reconcile(loaded, facts)
            reloaded = release.load_state("0.226.4")

        self.assertTrue(release.completed(reloaded, "tag"))
        self.assertIn("origin already holds v0.226.4", reloaded["steps"]["tag"]["reconciled_from"])
        self.assertEqual(reloaded["steps"]["tag"]["commit"], merge_sha)
        # The macOS artifacts were never built, so their stages stay outstanding.
        self.assertEqual(reloaded["steps"]["release_build"]["status"], "interrupted")
        self.assertFalse(release.completed(reloaded, "dmg"))
        self.assertFalse(release.completed(reloaded, "github_release"))
        self.assertFalse(release.completed(reloaded, "homebrew"))
        self.assertEqual(reloaded["observation"]["release_assets"], sorted(self.LINUX_ASSETS))
        self.assertEqual(facts["mismatched"], [])

    def test_reconcile_refuses_a_tag_that_points_at_another_commit(self):
        with tempfile.TemporaryDirectory() as state, unittest.mock.patch.dict(
            "os.environ", {"TERMMESH_RELEASE_STATE_DIR": state}
        ):
            self._interrupted_receipt(state, "0.226.4", merge_sha="a" * 40)
            loaded = release.load_state("0.226.4")
            facts = self._facts("0.226.4", tag_commit="b" * 40)
            release.reconcile(loaded, facts)
            reloaded = release.load_state("0.226.4")

        self.assertFalse(release.completed(reloaded, "tag"))
        self.assertEqual(len(facts["mismatched"]), 1)
        self.assertIn("not the release commit", facts["mismatched"][0])
        self.assertEqual(reloaded["observation"]["mismatched"], facts["mismatched"])

    def test_reconcile_adopts_a_published_dmg_only_with_a_local_checksum(self):
        """Homebrew publishes the DMG's checksum, so an unrecorded asset is not proof.

        Leaving the stage outstanding makes it rebuild from the pinned release
        commit and replace that asset, which is what keeps the cask honest.
        """
        merge_sha = "c" * 40
        assets = self.LINUX_ASSETS + ["term-mesh-macos-0.226.4.dmg"]
        published = {
            "url": "https://github.com/x-mesh/term-mesh/releases/tag/v0.226.4",
            "isDraft": False, "isPrerelease": False,
            "assets": [{"name": name} for name in assets],
        }
        with tempfile.TemporaryDirectory() as state, unittest.mock.patch.dict(
            "os.environ", {"TERMMESH_RELEASE_STATE_DIR": state}
        ):
            self._interrupted_receipt(state, "0.226.4", merge_sha=merge_sha, running=None)
            without_receipt = release.load_state("0.226.4")
            facts = self._facts("0.226.4", tag_commit=merge_sha, release=published)
            release.reconcile(without_receipt, facts)
            self.assertFalse(release.completed(release.load_state("0.226.4"), "github_release"))
            self.assertEqual(len(facts["mismatched"]), 1)
            self.assertIn("no local dmg receipt", facts["mismatched"][0])

            self._interrupted_receipt(
                state, "0.226.4", merge_sha=merge_sha, running=None,
                dmg={"status": "completed", "path": "/tmp/x.dmg", "sha256": "d" * 64},
            )
            with_receipt = release.load_state("0.226.4")
            release.reconcile(with_receipt, self._facts(
                "0.226.4", tag_commit=merge_sha, release=published))
            reloaded = release.load_state("0.226.4")

        self.assertTrue(release.completed(reloaded, "github_release"))
        self.assertEqual(reloaded["steps"]["github_release"]["assets"], sorted(assets))

    def test_reconcile_adopts_the_cask_only_for_the_published_checksum(self):
        merge_sha = "e" * 40
        with tempfile.TemporaryDirectory() as state, unittest.mock.patch.dict(
            "os.environ", {"TERMMESH_RELEASE_STATE_DIR": state}
        ):
            dmg = {"status": "completed", "path": "/tmp/x.dmg", "sha256": "f" * 64}
            self._interrupted_receipt(state, "0.226.4", merge_sha=merge_sha, running=None, dmg=dmg)
            stale = release.load_state("0.226.4")
            release.reconcile(stale, self._facts("0.226.4", homebrew=("0.226.3", "f" * 64)))
            self.assertFalse(release.completed(release.load_state("0.226.4"), "homebrew"))

            self._interrupted_receipt(state, "0.226.4", merge_sha=merge_sha, running=None, dmg=dmg)
            current = release.load_state("0.226.4")
            release.reconcile(current, self._facts("0.226.4", homebrew=("0.226.4", "f" * 64)))
            reloaded = release.load_state("0.226.4")

        self.assertTrue(release.completed(reloaded, "homebrew"))
        self.assertEqual(reloaded["steps"]["homebrew"]["sha256"], "f" * 64)

    def test_an_unread_remote_fact_neither_adopts_nor_fails(self):
        """A release must stay inspectable when `gh` cannot answer."""
        with tempfile.TemporaryDirectory() as state, unittest.mock.patch.dict(
            "os.environ", {"TERMMESH_RELEASE_STATE_DIR": state}
        ):
            self._interrupted_receipt(state, "0.226.4", merge_sha="a" * 40, running=None)
            loaded = release.load_state("0.226.4")
            facts = self._facts("0.226.4")
            facts["unreadable"]["release"] = "gh: could not connect"
            release.reconcile(loaded, facts)
            reloaded = release.load_state("0.226.4")

        self.assertFalse(release.completed(reloaded, "tag"))
        self.assertFalse(release.completed(reloaded, "github_release"))
        self.assertEqual(reloaded["observation"]["unreadable"], {"release": "gh: could not connect"})

    def test_gh_json_optional_separates_an_absent_release_from_an_unreachable_gh(self):
        absent = subprocess.CompletedProcess(
            args=("gh",), returncode=1, stdout="", stderr="release not found",
        )
        broken = subprocess.CompletedProcess(
            args=("gh",), returncode=1, stdout="", stderr="could not connect to api.github.com",
        )
        with unittest.mock.patch.object(release.subprocess, "run", return_value=absent):
            self.assertEqual(release.gh_json_optional("release", "view", "v9.9.9"), (None, None))
        with unittest.mock.patch.object(release.subprocess, "run", return_value=broken):
            value, error = release.gh_json_optional("release", "view", "v9.9.9")
        self.assertIsNone(value)
        self.assertIn("could not connect", error)

    def test_publishing_the_dmg_keeps_the_linux_assets(self):
        dmg = "term-mesh-macos-0.226.4.dmg"
        before = list(self.LINUX_ASSETS)
        with unittest.mock.patch.object(release, "run", return_value=""), \
                unittest.mock.patch.object(
                    release, "release_assets", side_effect=[before, before + [dmg]]):
            published, retained = release.upload_release_dmg(
                "0.226.4", "v0.226.4", dmg, ROOT)
        self.assertEqual(published, sorted(before + [dmg]))
        self.assertEqual(retained, sorted(before))

        with unittest.mock.patch.object(release, "run", return_value=""), \
                unittest.mock.patch.object(
                    release, "release_assets", side_effect=[before, [dmg]]):
            with self.assertRaisesRegex(release.ReleaseError, "dropped existing release assets"):
                release.upload_release_dmg("0.226.4", "v0.226.4", dmg, ROOT)

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

    @staticmethod
    def _write_receipt(state_dir, version, *, verify="completed", commit="deadbeef"):
        steps = {name: {"status": "completed"} for name in release.STEP_ORDER}
        steps["release_metadata"] = {"status": "completed", "commit": commit}
        steps["verify"] = {"status": verify}
        (Path(state_dir) / f"v{version}.json").write_text(json.dumps({
            "schema": 1, "version": version,
            "release_branch": f"chore/release-v{version}", "steps": steps,
        }))

    @staticmethod
    def _fake_git(*, tags=(), branches=(), tips=None, worktrees=""):
        tips = tips or {}

        def fake(*args, **kwargs):
            if args[0] == "worktree":
                return worktrees
            if args[0] == "tag":
                return args[2] if args[2] in tags else ""
            if args[0] == "branch" and args[1] == "--list":
                if args[2] == "chore/release-v*":
                    return "\n".join(branches)
                return args[2] if args[2] in branches else ""
            if args[0] == "rev-parse":
                return tips.get(args[1], "")
            raise AssertionError(args)

        return fake

    def test_cleanup_claims_this_version_and_older_but_never_develop(self):
        with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryDirectory() as state, \
                unittest.mock.patch.dict("os.environ", {"TERMMESH_RELEASE_STATE_DIR": state}):
            root = Path(directory)
            for name in ("develop", "v0.212.0-source", "v0.213.0-source",
                         "v0.213.0-artifact-2e00f3b16eea", "v0.214.0-source"):
                (root / name).mkdir()
            self._write_receipt(state, "0.212.0")
            with unittest.mock.patch.object(release, "RELEASE_WORKTREES", root), \
                    unittest.mock.patch.object(release, "git", self._fake_git(tags=("v0.212.0",))):
                claimed = [path.name for path in release.obsolete_release_worktrees("0.213.0")]
        self.assertEqual(claimed, ["v0.212.0-source", "v0.213.0-artifact-2e00f3b16eea", "v0.213.0-source"])

    def test_cleanup_spares_a_release_that_never_reached_its_tag(self):
        """An abandoned release keeps the checkout its resume needs.

        release_worktree refuses to rebuild a checkout while its branch exists, so
        reclaiming an untagged version's worktree would strand it permanently.
        """
        with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryDirectory() as state, \
                unittest.mock.patch.dict("os.environ", {"TERMMESH_RELEASE_STATE_DIR": state}):
            root = Path(directory)
            for name in ("v0.212.0-source", "v0.213.0-source"):
                (root / name).mkdir()
            with unittest.mock.patch.object(release, "RELEASE_WORKTREES", root), \
                    unittest.mock.patch.object(release, "git", self._fake_git()):
                claimed = [path.name for path in release.obsolete_release_worktrees("0.213.0")]
        self.assertEqual(claimed, ["v0.213.0-source"])

    def test_cleanup_spares_an_older_release_that_is_still_running(self):
        """Per-version locks do not serialize two releases, so cleanup must check."""
        with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryDirectory() as state, \
                unittest.mock.patch.dict("os.environ", {"TERMMESH_RELEASE_STATE_DIR": state}):
            root = Path(directory)
            (root / "v0.212.0-source").mkdir()
            self._write_receipt(state, "0.212.0", verify="pending")
            with unittest.mock.patch.object(release, "RELEASE_WORKTREES", root), \
                    unittest.mock.patch.object(release, "git", self._fake_git(tags=("v0.212.0",))):
                self.assertEqual(release.obsolete_release_worktrees("0.213.0"), [])
                with release.release_lock("0.212.0"):
                    self.assertTrue(release.release_is_running("0.212.0"))

    def test_cleanup_spares_locked_and_marked_checkouts(self):
        with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryDirectory() as state, \
                unittest.mock.patch.dict("os.environ", {"TERMMESH_RELEASE_STATE_DIR": state}):
            root = Path(directory)
            for name in ("v0.211.0-source", "v0.212.0-source", "v0.213.0-source"):
                (root / name).mkdir()
            self._write_receipt(state, "0.211.0")
            self._write_receipt(state, "0.212.0")
            release.keep_marker(root / "v0.212.0-source").write_text("kept\n")
            porcelain = f"worktree {root / 'v0.211.0-source'}\nlocked\n"
            with unittest.mock.patch.object(release, "RELEASE_WORKTREES", root), \
                    unittest.mock.patch.object(
                        release, "git",
                        self._fake_git(tags=("v0.211.0", "v0.212.0"), worktrees=porcelain)):
                claimed = [path.name for path in release.obsolete_release_worktrees("0.213.0")]
        self.assertEqual(claimed, ["v0.213.0-source"])

    def test_keep_worktrees_survives_the_next_release(self):
        """--keep-worktrees has to persist, or it only defers destruction by one release."""
        with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryDirectory() as state, \
                unittest.mock.patch.dict("os.environ", {"TERMMESH_RELEASE_STATE_DIR": state}):
            root = Path(directory)
            kept = root / "v0.213.0-source"
            kept.mkdir()
            (root / "v0.212.0-source").mkdir()
            self._write_receipt(state, "0.212.0")
            current = {"schema": 1, "version": "0.213.0",
                       "release_branch": "chore/release-v0.213.0",
                       "steps": {name: {"status": "pending"} for name in release.STEP_ORDER}}
            with unittest.mock.patch.object(release, "RELEASE_WORKTREES", root), \
                    unittest.mock.patch.object(
                        release, "git", self._fake_git(tags=("v0.212.0",))), \
                    unittest.mock.patch.object(release, "remove_worktree") as remover:
                release.cleanup(current, keep_worktrees=True)
                remover.assert_not_called()
                self.assertEqual(current["steps"]["cleanup"]["kept"], [str(kept)])
                self.assertEqual(current["steps"]["cleanup"]["deferred"],
                                 [str(root / "v0.212.0-source")])
                self.assertFalse(release.keep_marker(root / "v0.212.0-source").exists())
                self._write_receipt(state, "0.213.0")
                with unittest.mock.patch.object(
                    release, "git", self._fake_git(tags=("v0.213.0",),
                                                   branches=("chore/release-v0.213.0",))
                ):
                    self.assertEqual(release.obsolete_release_worktrees("0.214.0"), [])
                    self.assertEqual(release.obsolete_release_branches("0.214.0"), [])

    def test_cleanup_only_claims_release_branches_whose_tip_is_what_shipped(self):
        """-D is forced by the squash merge, so the recorded tip is the only guard."""
        with tempfile.TemporaryDirectory() as state, \
                unittest.mock.patch.dict("os.environ", {"TERMMESH_RELEASE_STATE_DIR": state}):
            self._write_receipt(state, "0.211.0", commit="bbb222")
            self._write_receipt(state, "0.212.0", commit="aaa111")
            fake = self._fake_git(
                tags=("v0.211.0", "v0.212.0"),
                branches=("chore/release-v0.211.0", "chore/release-v0.212.0",
                          "chore/release-v0.214.0", "chore/release-v0.201.0-prep"),
                tips={"chore/release-v0.211.0": "moved-past-the-tag",
                      "chore/release-v0.212.0": "aaa111"},
            )
            with unittest.mock.patch.object(release, "RELEASE_WORKTREES", Path(state) / "absent"), \
                    unittest.mock.patch.object(release, "git", fake):
                self.assertEqual(release.obsolete_release_branches("0.213.0"),
                                 ["chore/release-v0.212.0"])

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
                release, "remove_worktree", return_value="removed",
            ), unittest.mock.patch.object(
                release, "RELEASE_WORKTREES", Path(directory) / "worktrees",
            ), unittest.mock.patch.object(
                release, "git", self._fake_git(),
            ), unittest.mock.patch.object(
                release, "run", side_effect=lambda *args, **kwargs: deleted.append(args) or "",
            ):
                release.cleanup(state, keep_worktrees=False)
        self.assertEqual(deleted, [("git", "branch", "-D", "chore/release-v0.213.0")])
        self.assertEqual(state["steps"]["cleanup"]["worktrees"], ["/tmp/v0.213.0-source"])
        self.assertEqual(state["steps"]["cleanup"]["branches"], ["chore/release-v0.213.0"])
        self.assertNotIn("failed_worktrees", state["steps"]["cleanup"])

    def test_cleanup_records_what_it_could_not_reclaim(self):
        """A checkout that survived must be named, not filtered out of the receipt."""
        with tempfile.TemporaryDirectory() as directory, unittest.mock.patch.dict(
            "os.environ", {"TERMMESH_RELEASE_STATE_DIR": directory}
        ):
            state = {"schema": 1, "version": "0.213.0",
                     "release_branch": "chore/release-v0.213.0",
                     "steps": {name: {"status": "pending"} for name in release.STEP_ORDER}}
            with unittest.mock.patch.object(
                release, "obsolete_release_worktrees",
                return_value=[Path("/tmp/v0.213.0-source")],
            ), unittest.mock.patch.object(
                release, "obsolete_release_branches", return_value=[],
            ), unittest.mock.patch.object(
                release, "remove_worktree", return_value="failed",
            ), unittest.mock.patch.object(
                release, "RELEASE_WORKTREES", Path(directory) / "worktrees",
            ), unittest.mock.patch.object(release, "run", return_value=""):
                release.cleanup(state, keep_worktrees=False)
        self.assertEqual(state["steps"]["cleanup"]["worktrees"], [])
        self.assertEqual(state["steps"]["cleanup"]["failed_worktrees"], ["/tmp/v0.213.0-source"])
        self.assertEqual(state["steps"]["cleanup"]["status"], "completed")

    def test_cleanup_cannot_fail_a_release_that_already_shipped(self):
        """Reclamation runs after verify, so a refused delete may not block the release."""
        with tempfile.TemporaryDirectory() as directory, unittest.mock.patch.dict(
            "os.environ", {"TERMMESH_RELEASE_STATE_DIR": directory}
        ):
            state = {"schema": 1, "version": "0.213.0",
                     "release_branch": "chore/release-v0.213.0",
                     "steps": {name: {"status": "pending"} for name in release.STEP_ORDER}}
            with unittest.mock.patch.object(
                release, "obsolete_release_worktrees", return_value=[],
            ), unittest.mock.patch.object(
                release, "obsolete_release_branches", return_value=["chore/release-v0.213.0"],
            ), unittest.mock.patch.object(
                release, "git", self._fake_git(branches=("chore/release-v0.213.0",)),
            ), unittest.mock.patch.object(
                release, "RELEASE_WORKTREES", Path(directory) / "worktrees",
            ), unittest.mock.patch.object(release, "run", return_value=""):
                release.cleanup(state, keep_worktrees=False)
        self.assertEqual(state["steps"]["cleanup"]["status"], "completed")
        self.assertEqual(state["steps"]["cleanup"]["branches"], [])
        self.assertEqual(state["steps"]["cleanup"]["failed_branches"], ["chore/release-v0.213.0"])

    def test_remove_worktree_reports_absent_removed_and_failed(self):
        """The primitive that actually deletes, exercised rather than mocked out."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.assertEqual(release.remove_worktree(root / "never-existed"), "absent")

            unregistered = root / "v0.213.0-source"
            unregistered.mkdir()
            (unregistered / "file").write_text("x")
            with unittest.mock.patch.object(release, "run", return_value=""), \
                    unittest.mock.patch.object(release, "registered_worktrees", return_value={}):
                self.assertEqual(release.remove_worktree(unregistered), "removed")
            self.assertFalse(unregistered.exists())

            protected = root / "v0.212.0-source"
            protected.mkdir()
            (protected / "file").write_text("x")
            with unittest.mock.patch.object(release, "run", return_value=""), \
                    unittest.mock.patch.object(
                        release, "registered_worktrees",
                        return_value={protected.resolve(): True}):
                self.assertEqual(release.remove_worktree(protected), "failed")
            self.assertTrue((protected / "file").exists())

    def _publishable_state(self, state_dir, **overrides):
        steps = {name: {"status": "completed"} for name in release.STEP_ORDER}
        steps["release_pr"] = {"status": "completed", "pr": 1}
        steps["release_merge"] = {"status": "completed", "merge_sha": "abc123"}
        steps["release_build"] = {"status": "completed", "dsym": "/tmp/term-mesh.app.dSYM",
                                  "derived_data": "/tmp/derived"}
        steps["dmg"] = {"status": "completed", "path": "/tmp/term-mesh.dmg", "sha256": "f" * 64}
        steps["cleanup"] = {"status": "pending"}
        steps.update(overrides)
        (Path(state_dir) / "v0.213.0.json").write_text(json.dumps({
            "schema": 1, "version": "0.213.0",
            "release_branch": "chore/release-v0.213.0", "steps": steps,
        }))
        return type("Args", (), {"version": "0.213.0", "yes": True, "keep_worktrees": False})()

    def test_a_finished_release_does_not_rebuild_its_worktrees(self):
        with tempfile.TemporaryDirectory() as state, unittest.mock.patch.dict(
            "os.environ", {"TERMMESH_RELEASE_STATE_DIR": state}
        ):
            args = self._publishable_state(state)
            with unittest.mock.patch.object(release, "release_worktree") as builder, \
                    unittest.mock.patch.object(release, "cleanup") as janitor:
                release.publish(args)
        builder.assert_not_called()
        janitor.assert_called_once()

    def test_an_outstanding_artifact_step_still_builds_its_worktree(self):
        with tempfile.TemporaryDirectory() as state, unittest.mock.patch.dict(
            "os.environ", {"TERMMESH_RELEASE_STATE_DIR": state}
        ):
            args = self._publishable_state(state, dsym={"status": "pending"})
            with unittest.mock.patch.object(
                release, "release_worktree", return_value=Path("/tmp/artifact-wt"),
            ) as builder, unittest.mock.patch.object(
                release, "cleanup",
            ), unittest.mock.patch.object(release, "run", return_value="") as runner:
                release.publish(args)
        builder.assert_called_once()
        self.assertIn(
            ("./scripts/upload-dsym.sh", "/tmp/term-mesh.app.dSYM"),
            [call.args for call in runner.call_args_list],
        )


if __name__ == "__main__":
    unittest.main()
