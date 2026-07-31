import os
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch

from test_tm_agent_bridge import BRIDGE, CapturedEmitter


class InputFrameHardeningTests(unittest.TestCase):
    def test_unterminated_oversize_input_is_dropped_and_poisoned(self):
        reader = BRIDGE.InputFrameReader(limit=32)

        self.assertEqual(reader.feed(b"x" * 33), [])

        self.assertTrue(reader.poisoned)
        self.assertEqual(reader.pending, b"")

    def test_poisoned_stream_never_parses_a_later_valid_line(self):
        reader = BRIDGE.InputFrameReader(limit=32)
        reader.feed(b"x" * 33)

        frames = reader.feed(b'{"message":{"content":"safe"}}\n')

        self.assertEqual(frames, [])
        self.assertTrue(reader.poisoned)
        self.assertEqual(reader.pending, b"")

    def test_valid_frame_just_below_limit_passes_unchanged(self):
        limit = 128
        prefix = b'{"message":{"content":"'
        suffix = b'"}}'
        frame = prefix + b"x" * (limit - 1 - len(prefix) - len(suffix)) + suffix
        self.assertEqual(len(frame), limit - 1)
        reader = BRIDGE.InputFrameReader(limit=limit)

        self.assertEqual(reader.feed(frame + b"\n"), [frame])

        self.assertFalse(reader.poisoned)
        self.assertEqual(reader.pending, b"")


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


if __name__ == "__main__":
    unittest.main()
