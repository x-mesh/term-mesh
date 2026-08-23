import importlib.util
import pathlib
import unittest


MODULE_PATH = pathlib.Path(__file__).parents[1] / "tests_v2" / "test_remote_project_restart_reattach.py"
SPEC = importlib.util.spec_from_file_location("remote_project_e2e", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(MODULE)


class FakeClient:
    def __init__(self, rows):
        self.rows = iter(rows)
        self.last = None

    def team_list(self):
        try:
            self.last = next(self.rows)
        except StopIteration:
            pass
        return [] if self.last is None else [self.last]


class FakeDeletionClient:
    def __init__(self, status):
        self.status = status

    def debug_project_delete_status(self, operation_id):
        return self.status


class RemoteProjectE2EContractTests(unittest.TestCase):
    def test_cleanup_operation_failure_cannot_look_like_success(self):
        with self.assertRaisesRegex(MODULE.termmeshError, "manifest delete.*timed out"):
            MODULE._project_deletion_succeeded(
                FakeDeletionClient({
                    "state": "failed",
                    "error": "manifest delete: rpc timed out",
                }),
                "op-1",
            )

    def test_cleanup_operation_requires_explicit_success_receipt(self):
        self.assertIsNone(MODULE._project_deletion_succeeded(
            FakeDeletionClient({"state": "running"}), "op-1"
        ))
        result = MODULE._project_deletion_succeeded(
            FakeDeletionClient({"state": "succeeded"}), "op-1"
        )
        self.assertEqual(result["state"], "succeeded")

    def test_cleanup_wait_propagates_terminal_failure_immediately(self):
        with self.assertRaisesRegex(MODULE.termmeshError, "manifest delete.*timed out"):
            MODULE._wait_for_project_deletion(
                FakeDeletionClient({
                    "state": "failed",
                    "error": "manifest delete: rpc timed out",
                }),
                "op-1",
                timeout_s=1,
            )

    def test_background_hold_reproduces_old_accept_timeout_failure(self):
        pending = {
            "team_name": "demo",
            "leader_panel_id": "panel",
            "leader_pane_attached": False,
            "leader_failure": "Remote leader relay is pending",
        }
        old_failure = dict(pending, leader_failure="Remote leader relay failed to start: acceptTimedOut")
        client = FakeClient([pending, old_failure])
        with self.assertRaisesRegex(MODULE.termmeshError, "failed before mount"):
            MODULE._assert_background_project_waits_for_mount(
                client, "demo", duration_s=0.30
            )

    def test_background_hold_accepts_pending_state_past_timeout_boundary(self):
        pending = {
            "team_name": "demo",
            "leader_panel_id": "panel",
            "leader_pane_attached": False,
            "leader_failure": "Remote leader relay is pending",
        }
        result = MODULE._assert_background_project_waits_for_mount(
            FakeClient([pending]), "demo", duration_s=0.02
        )
        self.assertEqual(result["leader_panel_id"], "panel")


if __name__ == "__main__":
    unittest.main()
