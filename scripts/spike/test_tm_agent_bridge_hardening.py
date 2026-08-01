import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from test_tm_agent_bridge import BRIDGE, BRIDGE_PATH, CapturedEmitter


class AgyLogHardeningTests(unittest.TestCase):
    def test_log_uses_private_directory_and_mode(self):
        with tempfile.TemporaryDirectory() as root, \
                patch.object(BRIDGE.tempfile, "gettempdir", return_value=root):
            bridge = BRIDGE.PerTurnBridge("agy", "/work", None, CapturedEmitter())
            argv = bridge._argv("hello")
            log_path = Path(argv[argv.index("--log-file") + 1])
            self.assertEqual(log_path.parent.parent, Path(root))
            self.assertEqual(stat.S_IMODE(log_path.parent.stat().st_mode), 0o700)
            self.assertEqual(stat.S_IMODE(log_path.stat().st_mode), 0o600)
            self.assertNotEqual(log_path.name, f"agy-{os.getpid()}.log")
            bridge.stop()

    def test_symlink_replacement_is_rejected_when_reading_conversation(self):
        conversation = "12345678-1234-1234-1234-123456789abc"
        with tempfile.TemporaryDirectory() as root, \
                patch.object(BRIDGE.tempfile, "gettempdir", return_value=root):
            bridge = BRIDGE.PerTurnBridge("agy", "/work", None, CapturedEmitter())
            bridge._ensure_agy_log()
            log_path = Path(bridge.log_path)
            target = Path(root) / "attacker.log"
            target.write_text(f"Created conversation {conversation}\n", encoding="utf-8")
            log_path.unlink()
            log_path.symlink_to(target)
            self.assertIsNone(bridge._agy_thread())
            bridge.stop()

    def test_fstat_failure_closes_open_descriptor(self):
        with tempfile.TemporaryDirectory() as root, \
                patch.object(BRIDGE.tempfile, "gettempdir", return_value=root):
            bridge = BRIDGE.PerTurnBridge("agy", "/work", None, CapturedEmitter())
            bridge._ensure_agy_log()
            real_open = BRIDGE.os.open
            opened_fd = None

            def capture_open(*args, **kwargs):
                nonlocal opened_fd
                opened_fd = real_open(*args, **kwargs)
                return opened_fd

            with patch.object(BRIDGE.os, "open", side_effect=capture_open), \
                    patch.object(BRIDGE.os, "fstat", side_effect=OSError("injected")):
                self.assertIsNone(bridge._agy_thread())

            self.assertIsNotNone(opened_fd)
            with self.assertRaises(OSError):
                os.fstat(opened_fd)
            bridge.stop()


class InputFrameCapTests(unittest.TestCase):
    """A writer that never sends a newline must not exhaust memory.

    `consume()` appended every chunk to `pending` and removed bytes only once
    it found a `\\n`. Neither the FIFO nor the stdin path bounded that, so a
    writer could keep a long-lived native agent bridge allocating until the
    process — or the host — ran out of memory. The daemon's analogous socket
    reader has always used a bounded line; this raw reader did not.
    """

    def test_unterminated_flood_is_reported_as_oversize(self):
        oversize = b"x" * (BRIDGE.MAX_FRAME_BYTES + 1)
        frames, remainder, blew = BRIDGE.split_input_frames(b"", oversize)

        self.assertEqual(frames, [])
        self.assertEqual(blew, len(oversize))
        self.assertEqual(remainder, oversize)

    def test_flood_accumulated_across_reads_is_caught(self):
        # The realistic shape: no single read is oversized, the sum is.
        pending, blew = b"", None
        chunk = b"y" * 65536
        for _ in range(20):
            frames, pending, blew = BRIDGE.split_input_frames(pending, chunk)
            self.assertEqual(frames, [])
            if blew is not None:
                break
        self.assertIsNotNone(blew, "an accumulating flood must trip the cap")

    def test_single_terminated_frame_past_the_cap_is_also_refused(self):
        # Splitting frames before measuring must not become a way to smuggle
        # an oversized one past the cap by attaching a newline.
        payload = b"x" * (BRIDGE.MAX_FRAME_BYTES + 1) + b"\n"
        frames, _, blew = BRIDGE.split_input_frames(b"", payload)

        self.assertEqual(frames, [])
        self.assertEqual(blew, BRIDGE.MAX_FRAME_BYTES + 1)

    def test_frame_exactly_at_the_cap_is_accepted(self):
        payload = b"x" * BRIDGE.MAX_FRAME_BYTES + b"\n"
        frames, remainder, blew = BRIDGE.split_input_frames(b"", payload)

        self.assertIsNone(blew)
        self.assertEqual(len(frames), 1)
        self.assertEqual(remainder, b"")

    def test_batched_frames_exceeding_the_cap_in_total_are_delivered(self):
        # The cap bounds one frame and the remainder, not how much a
        # well-behaved writer may batch into a single read.
        one = b"z" * (BRIDGE.MAX_FRAME_BYTES // 2)
        frames, remainder, blew = BRIDGE.split_input_frames(
            b"", one + b"\n" + one + b"\n" + one + b"\n")

        self.assertIsNone(blew)
        self.assertEqual(len(frames), 3)
        self.assertEqual(remainder, b"")

    def test_ordinary_capsule_splits_normally(self):
        frames, remainder, blew = BRIDGE.split_input_frames(
            b"", b"first\nsecond\npartial")

        self.assertEqual(frames, ["first", "second"])
        self.assertEqual(remainder, b"partial")
        self.assertIsNone(blew)

    def test_frame_split_across_reads_is_reassembled(self):
        frames, pending, _ = BRIDGE.split_input_frames(b"", b"half")
        self.assertEqual(frames, [])
        frames, pending, _ = BRIDGE.split_input_frames(pending, b"-rest\n")
        self.assertEqual(frames, ["half-rest"])
        self.assertEqual(pending, b"")


if __name__ == "__main__":
    unittest.main()
