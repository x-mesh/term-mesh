#!/usr/bin/env python3
"""
E2E tests for text + Enter key delivery to terminal panels.

Verifies that commands sent via the socket API are properly executed
(not just displayed) in the terminal. This catches regressions where
text arrives but the Return key is swallowed or ignored.

Covers all input paths:
  Path A: send "echo ...\n"       (sendSocketText → text + handleControlScalar)
  Path B: send_key "enter"        (sendNamedKey)
  Path C: send_surface <id> "...\n" (targeted surface)

Usage:
    python3 tests/test_send_text_enter.py

Requirements:
    - term-mesh must be running with the socket controller enabled
    - CMUX_SOCKET or CMUX_SOCKET_PATH can override the socket path
"""

import os
import sys
import time
import tempfile
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from termmesh import termmesh, termmeshError


class TestResult:
    def __init__(self, name: str):
        self.name = name
        self.passed = False
        self.message = ""

    def success(self, msg: str = ""):
        self.passed = True
        self.message = msg

    def failure(self, msg: str):
        self.passed = False
        self.message = msg


TMPDIR = Path(tempfile.gettempdir())


def _marker(test_name: str) -> Path:
    return TMPDIR / f"termmesh_enter_{test_name}_{os.getpid()}"


def _wait_marker(marker: Path, timeout: float = 5.0) -> bool:
    """Wait for a marker file to appear (proof command executed)."""
    start = time.time()
    while time.time() - start < timeout:
        if marker.exists():
            return True
        time.sleep(0.15)
    return False


def _cleanup_markers(*markers: Path) -> None:
    for m in markers:
        m.unlink(missing_ok=True)


def test_send_text_with_newline(client: termmesh) -> TestResult:
    """
    Path A: send "echo ... && touch MARKER\n"
    This tests sendSocketText → socketTextChunks → sendKeyEvent for Return.
    The fix: sendKeyEvent now sends RELEASE + text:"\r".
    """
    result = TestResult("send() with \\n (Path A: sendSocketText)")
    marker = _marker("path_a")
    _cleanup_markers(marker)

    try:
        client.send(f"echo PATH_A_OK && touch {marker}\n")
        if _wait_marker(marker):
            result.success("Command executed — Return key delivered correctly")
        else:
            # Check screen for diagnostic info
            screen = client.read_screen()
            result.failure(
                f"Marker not created — Return key was likely swallowed.\n"
                f"Screen (last 3 lines): {screen.strip().splitlines()[-3:]}"
            )
    except Exception as e:
        result.failure(f"Exception: {e}")
    finally:
        _cleanup_markers(marker)
    return result


def test_send_key_enter(client: termmesh) -> TestResult:
    """
    Path B: send text without newline, then send_key "enter".
    This tests sendNamedKey → sendKeyEvent for Return.
    The fix: sendNamedKey now passes text:"\r" and sends RELEASE.
    """
    result = TestResult("send() + send_key('enter') (Path B: sendNamedKey)")
    marker = _marker("path_b")
    _cleanup_markers(marker)

    try:
        # Send command text without trailing newline
        client.send(f"echo PATH_B_OK && touch {marker}")
        time.sleep(0.3)
        # Send Enter separately
        client.send_key("enter")

        if _wait_marker(marker):
            result.success("Command executed — send_key('enter') delivered correctly")
        else:
            screen = client.read_screen()
            result.failure(
                f"Marker not created — send_key('enter') likely missing text or RELEASE.\n"
                f"Screen (last 3 lines): {screen.strip().splitlines()[-3:]}"
            )
    except Exception as e:
        result.failure(f"Exception: {e}")
    finally:
        _cleanup_markers(marker)
    return result


def test_send_key_return(client: termmesh) -> TestResult:
    """
    Same as Path B but using "return" instead of "enter".
    """
    result = TestResult("send() + send_key('return') (Path B variant)")
    marker = _marker("path_b_return")
    _cleanup_markers(marker)

    try:
        client.send(f"echo PATH_B_RETURN_OK && touch {marker}")
        time.sleep(0.3)
        client.send_key("return")

        if _wait_marker(marker):
            result.success("Command executed — send_key('return') delivered correctly")
        else:
            screen = client.read_screen()
            result.failure(
                f"Marker not created — send_key('return') failed.\n"
                f"Screen (last 3 lines): {screen.strip().splitlines()[-3:]}"
            )
    except Exception as e:
        result.failure(f"Exception: {e}")
    finally:
        _cleanup_markers(marker)
    return result


def test_send_surface_with_newline(client: termmesh) -> TestResult:
    """
    Path C: send_surface <surface_id> "echo ... && touch MARKER\n"
    Tests targeted surface input (same sendSocketText path but surface-specific).
    """
    result = TestResult("send_surface() with \\n (Path C: targeted surface)")
    marker = _marker("path_c")
    _cleanup_markers(marker)

    try:
        surfaces = client.list_surfaces()
        if not surfaces:
            result.failure("No surfaces found")
            return result

        # Find focused surface
        surface_id = None
        for _idx, sid, focused in surfaces:
            if focused:
                surface_id = sid
                break
        if not surface_id:
            surface_id = surfaces[0][1]

        client.send_surface(surface_id, f"echo PATH_C_OK && touch {marker}\n")

        if _wait_marker(marker):
            result.success("Command executed — surface-targeted Return delivered correctly")
        else:
            screen = client.read_screen()
            result.failure(
                f"Marker not created — send_surface Return was swallowed.\n"
                f"Screen (last 3 lines): {screen.strip().splitlines()[-3:]}"
            )
    except Exception as e:
        result.failure(f"Exception: {e}")
    finally:
        _cleanup_markers(marker)
    return result


def test_rapid_sequential_sends(client: termmesh) -> TestResult:
    """
    Stress test: send 5 commands rapidly in sequence.
    Each must execute (create a marker file). This tests that RELEASE
    events prevent key-state sticking under rapid fire.
    """
    result = TestResult("Rapid sequential sends (5x stress test)")
    markers = [_marker(f"rapid_{i}") for i in range(5)]
    _cleanup_markers(*markers)

    try:
        for i, marker in enumerate(markers):
            client.send(f"touch {marker}\n")
            time.sleep(0.15)  # Minimal gap between sends

        # Wait for all markers
        time.sleep(2.0)
        missing = [i for i, m in enumerate(markers) if not m.exists()]

        if not missing:
            result.success("All 5 commands executed — no Enter keys dropped")
        else:
            result.failure(
                f"Commands {missing} did not execute — "
                f"{len(missing)}/5 Enter keys dropped under rapid fire"
            )
    except Exception as e:
        result.failure(f"Exception: {e}")
    finally:
        _cleanup_markers(*markers)
    return result


def test_multiline_send(client: termmesh) -> TestResult:
    """
    Send text with embedded newlines: "echo A\necho B\ntouch MARKER\n"
    Tests that handleControlScalar processes multiple \n in a single send.
    """
    result = TestResult("Multi-newline send (multiple \\n in one send)")
    marker = _marker("multiline")
    _cleanup_markers(marker)

    try:
        client.send(f"echo MULTI_A\necho MULTI_B\ntouch {marker}\n")
        if _wait_marker(marker):
            result.success("All lines executed — embedded newlines handled correctly")
        else:
            screen = client.read_screen()
            result.failure(
                f"Marker not created — embedded newlines not all processed.\n"
                f"Screen (last 3 lines): {screen.strip().splitlines()[-3:]}"
            )
    except Exception as e:
        result.failure(f"Exception: {e}")
    finally:
        _cleanup_markers(marker)
    return result


def test_send_after_split(client: termmesh) -> TestResult:
    """
    Create a split, send to the new pane, verify Enter works.
    Tests that non-focused/background panes also receive Enter correctly.
    """
    result = TestResult("send_surface() to split pane (non-focused)")
    marker = _marker("split_pane")
    _cleanup_markers(marker)

    try:
        # Create a right split
        client.new_split("right")
        time.sleep(0.8)

        surfaces = client.list_surfaces()
        if len(surfaces) < 2:
            result.failure(f"Expected >=2 surfaces after split, got {len(surfaces)}")
            return result

        # Send to the new (focused) surface
        focused_id = None
        for _idx, sid, focused in surfaces:
            if focused:
                focused_id = sid
                break
        if not focused_id:
            focused_id = surfaces[-1][1]

        client.send_surface(focused_id, f"echo SPLIT_OK && touch {marker}\n")

        if _wait_marker(marker):
            result.success("Command executed in split pane")
        else:
            screen = client.read_screen()
            result.failure(
                f"Marker not created in split pane.\n"
                f"Screen (last 3 lines): {screen.strip().splitlines()[-3:]}"
            )
    except Exception as e:
        result.failure(f"Exception: {e}")
    finally:
        _cleanup_markers(marker)
    return result


def test_read_screen_after_send(client: termmesh) -> TestResult:
    """
    Verify that command output appears in read_screen after send+Enter.
    This is a higher-level check that the command actually ran.
    """
    result = TestResult("read_screen() shows command output after send")
    unique = f"ENTER_TEST_{os.getpid()}_{int(time.time())}"

    try:
        client.send(f"echo {unique}\n")
        time.sleep(1.0)
        screen = client.read_screen()
        if unique in screen:
            result.success(f"Output '{unique}' found in screen")
        else:
            result.failure(
                f"Output '{unique}' NOT found in screen — command didn't execute.\n"
                f"Screen (last 5 lines): {screen.strip().splitlines()[-5:]}"
            )
    except Exception as e:
        result.failure(f"Exception: {e}")
    return result


def main() -> int:
    socket_path = (
        os.environ.get("CMUX_SOCKET")
        or os.environ.get("CMUX_SOCKET_PATH")
        or None
    )

    print("=" * 60)
    print("term-mesh E2E: Text + Enter Key Delivery Tests")
    print("=" * 60)
    print()

    try:
        client = termmesh(socket_path)
        client.connect()
    except Exception as e:
        print(f"FATAL: Cannot connect to term-mesh socket: {e}")
        return 1

    # Ensure we start in a clean workspace
    try:
        ws_id = client.new_workspace()
        client.select_workspace(ws_id)
        time.sleep(0.5)
    except Exception:
        pass  # Use current workspace if new_workspace not available

    # Wait for shell to fully initialize (Starship prompt, zsh plugins, etc.)
    for _ in range(20):
        try:
            screen = client.read_screen()
            # Look for shell prompt indicators (➜, $, %, >, etc.)
            if any(ch in screen for ch in ("➜", "❯", "$ ", "% ", "> ")):
                break
        except Exception:
            pass
        time.sleep(0.5)
    else:
        print("  Warning: shell prompt not detected, proceeding anyway")
    time.sleep(0.5)

    tests = [
        test_send_text_with_newline,
        test_send_key_enter,
        test_send_key_return,
        test_send_surface_with_newline,
        test_read_screen_after_send,
        test_rapid_sequential_sends,
        test_multiline_send,
        test_send_after_split,
    ]

    results = []
    for test_fn in tests:
        print(f"  Running: {test_fn.__name__} ... ", end="", flush=True)
        r = test_fn(client)
        results.append(r)
        status = "PASS" if r.passed else "FAIL"
        print(f"{status}")
        if r.message:
            print(f"    {r.message}")
        # Brief pause between tests for terminal stability
        time.sleep(0.3)

    client.close()

    print()
    print("-" * 60)
    passed = sum(1 for r in results if r.passed)
    failed = sum(1 for r in results if not r.passed)
    print(f"Results: {passed} passed, {failed} failed, {len(results)} total")
    print("-" * 60)

    if failed > 0:
        print()
        print("FAILED TESTS:")
        for r in results:
            if not r.passed:
                print(f"  - {r.name}: {r.message}")

    return 0 if failed == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
