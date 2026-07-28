import importlib.util
import os
from pathlib import Path
import unittest
from unittest.mock import patch


BRIDGE_PATH = Path(__file__).with_name("tm-agent-bridge.py")
SPEC = importlib.util.spec_from_file_location("tm_agent_bridge", BRIDGE_PATH)
BRIDGE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(BRIDGE)


class RemoteProcessLocationTests(unittest.TestCase):
    def test_login_shell_loads_agent_env_before_explicit_host_environment(self):
        remote = {
            "TERMMESH_REMOTE_NATIVE_SSH_ARGS": '["/usr/bin/ssh", "root@peer"]',
            "TERMMESH_REMOTE_NATIVE_CWD": "/remote/project",
            "TERMMESH_REMOTE_NATIVE_ENV": '{"AI_MESH_API_KEY":"from-host"}',
        }
        with patch.dict(os.environ, remote, clear=True):
            argv, cwd = BRIDGE.process_location(
                ["codex", "app-server"],
                "/local/project",
            )

        self.assertIsNone(cwd)
        command = argv[-1]
        source = '. "$HOME/.config/term-mesh/agent-env"'
        explicit = "AI_MESH_API_KEY=from-host"
        self.assertIn('exec "${SHELL:-/bin/sh}" -lc', command)
        self.assertIn(f'[ -f "$HOME/.config/term-mesh/agent-env" ]', command)
        self.assertIn(source, command)
        self.assertIn(">/dev/null || exit 78", command)
        self.assertLess(command.index(source), command.index(explicit))


if __name__ == "__main__":
    unittest.main()
