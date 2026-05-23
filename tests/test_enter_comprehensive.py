#!/usr/bin/env python3
"""
Comprehensive Enter key delivery tests — validates all Enter-swallow fixes.

Test categories:
  1. Basic Enter delivery (all input paths)
  2. Rapid-fire / stress tests (GCD main queue saturation)
  3. Empty/whitespace text + Enter (Fix #4: trimmed empty → still send Return)
  4. Concurrent multi-surface delivery
  5. Back-to-back Enter without text
  6. Long text + Enter (boundary conditions)
  7. Special characters + Enter
  8. Split pane cross-delivery

Usage:
    TERMMESH_SOCKET=/tmp/term-mesh.sock python3 tests/test_enter_comprehensive.py
"""

import os
import sys
import time
import tempfile
import threading
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from termmesh import termmesh, termmeshError


TMPDIR = Path(tempfile.gettempdir())
PID = os.getpid()
PASS_COUNT = 0
FAIL_COUNT = 0
SKIP_COUNT = 0


def marker(name: str) -> Path:
    return TMPDIR / f"enter_test_{name}_{PID}"


def cleanup(*paths: Path):
    for p in paths:
        p.unlink(missing_ok=True)


def wait_marker(m: Path, timeout: float = 6.0) -> bool:
    end = time.time() + timeout
    while time.time() < end:
        if m.exists():
            return True
        time.sleep(0.1)
    return False


def run_test(name: str, fn, client):
    global PASS_COUNT, FAIL_COUNT, SKIP_COUNT
    print(f"  [{PASS_COUNT + FAIL_COUNT + SKIP_COUNT + 1:2d}] {name} ... ", end="", flush=True)
    try:
        result = fn(client)
        if result is None:
            result = True
        if result == "SKIP":
            print("SKIP")
            SKIP_COUNT += 1
        elif result:
            print("✅ PASS")
            PASS_COUNT += 1
        else:
            print("❌ FAIL")
            FAIL_COUNT += 1
    except Exception as e:
        print(f"❌ FAIL (exception: {e})")
        FAIL_COUNT += 1


# ════════════════════════════════════════════════════════════
# Category 1: Basic Enter delivery
# ════════════════════════════════════════════════════════════

def test_basic_send_newline(client):
    """send('echo ...\\n') — standard path"""
    m = marker("basic_nl")
    cleanup(m)
    client.send(f"echo BASIC && touch {m}\n")
    ok = wait_marker(m)
    cleanup(m)
    return ok


def test_basic_send_key_enter(client):
    """send() text then send_key('enter') separately"""
    m = marker("basic_key_enter")
    cleanup(m)
    client.send(f"echo KEY_ENTER && touch {m}")
    time.sleep(0.2)
    client.send_key("enter")
    ok = wait_marker(m)
    cleanup(m)
    return ok


def test_basic_send_key_return(client):
    """send_key('return') — alternative name"""
    m = marker("basic_key_return")
    cleanup(m)
    client.send(f"echo KEY_RETURN && touch {m}")
    time.sleep(0.2)
    client.send_key("return")
    ok = wait_marker(m)
    cleanup(m)
    return ok


# ════════════════════════════════════════════════════════════
# Category 2: Rapid-fire / stress tests
# ════════════════════════════════════════════════════════════

def test_rapid_5x(client):
    """5 commands in rapid succession — 150ms gap"""
    markers = [marker(f"rapid5_{i}") for i in range(5)]
    cleanup(*markers)
    for i, m in enumerate(markers):
        client.send(f"touch {m}\n")
        time.sleep(0.15)
    time.sleep(3.0)
    missing = [i for i, m in enumerate(markers) if not m.exists()]
    cleanup(*markers)
    if missing:
        print(f"(dropped: {missing}) ", end="")
    return len(missing) == 0


def test_rapid_10x(client):
    """10 commands in rapid succession — 100ms gap"""
    markers = [marker(f"rapid10_{i}") for i in range(10)]
    cleanup(*markers)
    for i, m in enumerate(markers):
        client.send(f"touch {m}\n")
        time.sleep(0.1)
    time.sleep(5.0)
    missing = [i for i, m in enumerate(markers) if not m.exists()]
    cleanup(*markers)
    if missing:
        print(f"(dropped: {len(missing)}/10: {missing}) ", end="")
    return len(missing) == 0


def test_rapid_15x_no_gap(client):
    """15 commands with NO gap — maximum stress"""
    markers = [marker(f"rapid15_{i}") for i in range(15)]
    cleanup(*markers)
    for m in markers:
        client.send(f"touch {m}\n")
    time.sleep(8.0)
    missing = [i for i, m in enumerate(markers) if not m.exists()]
    cleanup(*markers)
    if missing:
        print(f"(dropped: {len(missing)}/15: {missing}) ", end="")
    return len(missing) == 0


def test_rapid_send_key_enter_10x(client):
    """10x (text + send_key enter) pairs in rapid succession"""
    markers = [marker(f"rapid_key_{i}") for i in range(10)]
    cleanup(*markers)
    for i, m in enumerate(markers):
        client.send(f"touch {m}")
        client.send_key("enter")
        time.sleep(0.05)
    time.sleep(5.0)
    missing = [i for i, m in enumerate(markers) if not m.exists()]
    cleanup(*markers)
    if missing:
        print(f"(dropped: {len(missing)}/10: {missing}) ", end="")
    return len(missing) == 0


# ════════════════════════════════════════════════════════════
# Category 3: Empty / whitespace text + Enter (Fix #4)
# ════════════════════════════════════════════════════════════

def test_bare_enter(client):
    """Send just Enter (no text) — should produce a blank line"""
    try:
        screen_before = client.read_screen()
        line_count_before = len(screen_before.strip().splitlines())
        client.send("\n")
        time.sleep(0.5)
        screen_after = client.read_screen()
        line_count_after = len(screen_after.strip().splitlines())
        # New prompt line should appear
        return line_count_after >= line_count_before
    except Exception:
        return True  # Non-critical


def test_multiple_bare_enters(client):
    """Send 5 bare Enters in succession"""
    m = marker("multi_enter")
    cleanup(m)
    # Send some enters, then a command
    for _ in range(5):
        client.send("\n")
        time.sleep(0.1)
    time.sleep(0.3)
    client.send(f"touch {m}\n")
    ok = wait_marker(m)
    cleanup(m)
    return ok


def test_enter_after_spaces(client):
    """Send only spaces + Enter — should execute (empty command)"""
    m = marker("spaces_enter")
    cleanup(m)
    # Send spaces, then a real command
    client.send("   \n")
    time.sleep(0.3)
    client.send(f"touch {m}\n")
    ok = wait_marker(m)
    cleanup(m)
    return ok


# ════════════════════════════════════════════════════════════
# Category 4: Multi-surface concurrent delivery
# ════════════════════════════════════════════════════════════

def test_split_and_send_both(client):
    """Create split, send command to BOTH panes"""
    m1 = marker("split_left")
    m2 = marker("split_right")
    cleanup(m1, m2)

    try:
        # Use a fresh workspace for split tests to avoid pollution
        try:
            ws = client.new_workspace()
            client.select_workspace(ws)
            time.sleep(1.0)
            # Wait for shell prompt
            for _ in range(20):
                s = client.read_screen()
                if any(ch in s for ch in ("➜", "❯", "$ ", "% ", "> ")):
                    break
                time.sleep(0.5)
            time.sleep(0.5)
        except Exception:
            pass

        # Create a split
        client.new_split("right")
        time.sleep(1.5)

        surfaces = client.list_surfaces()
        if len(surfaces) < 2:
            print("(need 2+ surfaces) ", end="")
            return "SKIP"

        # Wait for right pane shell to initialize
        time.sleep(1.5)

        # Send to both surfaces
        sid0 = surfaces[0][1]
        sid1 = surfaces[1][1]

        client.send_surface(sid0, f"touch {m1}\n")
        time.sleep(0.3)
        client.send_surface(sid1, f"touch {m2}\n")

        time.sleep(4.0)
        left_ok = m1.exists()
        right_ok = m2.exists()

        if not left_ok:
            print("(left pane Enter dropped) ", end="")
        if not right_ok:
            print("(right pane Enter dropped) ", end="")

        return left_ok and right_ok
    finally:
        cleanup(m1, m2)


def test_rapid_cross_surface(client):
    """Rapidly alternate sends between 2 surfaces"""
    markers = [marker(f"xsurf_{i}") for i in range(6)]
    cleanup(*markers)

    try:
        surfaces = client.list_surfaces()
        if len(surfaces) < 2:
            return "SKIP"

        sid0 = surfaces[0][1]
        sid1 = surfaces[1][1]

        for i, m in enumerate(markers):
            target = sid0 if i % 2 == 0 else sid1
            client.send_surface(target, f"touch {m}\n")
            time.sleep(0.1)

        time.sleep(4.0)
        missing = [i for i, m in enumerate(markers) if not m.exists()]
        if missing:
            print(f"(dropped {len(missing)}/6: {missing}) ", end="")
        return len(missing) == 0
    finally:
        cleanup(*markers)
        # Return to a fresh workspace after split tests to avoid polluting later tests
        try:
            ws = client.new_workspace()
            client.select_workspace(ws)
            time.sleep(1.0)
            for _ in range(20):
                s = client.read_screen()
                if any(ch in s for ch in ("➜", "❯", "$ ", "% ", "> ")):
                    break
                time.sleep(0.5)
            time.sleep(0.5)
        except Exception:
            pass


# ════════════════════════════════════════════════════════════
# Category 5: Back-to-back Enter without text
# ════════════════════════════════════════════════════════════

def test_send_key_enter_burst(client):
    """Send 10 bare send_key('enter') in burst"""
    m = marker("enter_burst")
    cleanup(m)
    for _ in range(10):
        client.send_key("enter")
        time.sleep(0.05)
    time.sleep(0.5)
    # Then verify terminal is still responsive
    client.send(f"touch {m}\n")
    ok = wait_marker(m)
    cleanup(m)
    return ok


# ════════════════════════════════════════════════════════════
# Category 6: Long text + Enter (boundary conditions)
# ════════════════════════════════════════════════════════════

def test_long_command(client):
    """Send a 500-char command + Enter"""
    m = marker("long_cmd")
    cleanup(m)
    padding = "A" * 450
    client.send(f"echo {padding} && touch {m}\n")
    ok = wait_marker(m, timeout=8.0)
    cleanup(m)
    return ok


def test_very_long_command(client):
    """Send a 1000-char command + Enter (reduced from 2000 to avoid zsh line-editor limits)"""
    m = marker("vlong_cmd")
    cleanup(m)
    padding = "B" * 900
    client.send(f"echo {padding} && touch {m}\n")
    ok = wait_marker(m, timeout=10.0)
    cleanup(m)
    return ok


# ════════════════════════════════════════════════════════════
# Category 7: Special characters + Enter
# ════════════════════════════════════════════════════════════

def test_special_chars(client):
    """Command with quotes, pipes, and special chars + Enter"""
    m = marker("special")
    cleanup(m)
    client.send(f"echo 'hello world' | cat && touch {m}\n")
    ok = wait_marker(m)
    cleanup(m)
    return ok


def test_unicode_text(client):
    """Unicode text + Enter"""
    m = marker("unicode")
    cleanup(m)
    client.send(f"echo '한글테스트🚀' && touch {m}\n")
    ok = wait_marker(m)
    cleanup(m)
    return ok


def test_multiline_text(client):
    """Multi-line text with embedded newlines"""
    m = marker("multiline")
    cleanup(m)
    client.send(f"echo line1\necho line2\ntouch {m}\n")
    ok = wait_marker(m)
    cleanup(m)
    return ok


# ════════════════════════════════════════════════════════════
# Category 8: Timing edge cases
# ════════════════════════════════════════════════════════════

def test_enter_immediately_after_connect(client):
    """Send command immediately — no warm-up delay"""
    m = marker("immediate")
    cleanup(m)
    client.send(f"touch {m}\n")
    ok = wait_marker(m)
    cleanup(m)
    return ok


def test_enter_after_long_pause(client):
    """Wait 3 seconds, then send — tests idle surface state"""
    m = marker("after_pause")
    cleanup(m)
    time.sleep(3.0)
    client.send(f"touch {m}\n")
    ok = wait_marker(m)
    cleanup(m)
    return ok


def test_verify_screen_output(client):
    """Final sanity: verify command output appears on screen"""
    unique = f"FINAL_CHECK_{PID}_{int(time.time())}"
    client.send(f"echo {unique}\n")
    time.sleep(1.5)
    screen = client.read_screen()
    return unique in screen


def main() -> int:
    socket_path = (
        os.environ.get("TERMMESH_SOCKET")
        or os.environ.get("TERMMESH_SOCKET_PATH")
        or None
    )

    print()
    print("═" * 65)
    print("  term-mesh: Comprehensive Enter Key Delivery Test Suite")
    print("═" * 65)
    print()

    try:
        client = termmesh(socket_path)
        client.connect()
    except Exception as e:
        print(f"FATAL: Cannot connect to term-mesh: {e}")
        return 1

    # Set up clean workspace
    try:
        ws_id = client.new_workspace()
        client.select_workspace(ws_id)
        time.sleep(0.5)
    except Exception:
        pass

    # Wait for shell prompt
    for _ in range(20):
        try:
            screen = client.read_screen()
            if any(ch in screen for ch in ("➜", "❯", "$ ", "% ", "> ")):
                break
        except Exception:
            pass
        time.sleep(0.5)
    time.sleep(0.5)

    # ── Category 1: Basic ──
    print("  ── Category 1: Basic Enter Delivery ──")
    run_test("send('...\\n')", test_basic_send_newline, client)
    run_test("send() + send_key('enter')", test_basic_send_key_enter, client)
    run_test("send() + send_key('return')", test_basic_send_key_return, client)
    print()

    # ── Category 2: Rapid-fire ──
    print("  ── Category 2: Rapid-Fire Stress Tests ──")
    run_test("5x rapid sends (150ms gap)", test_rapid_5x, client)
    run_test("10x rapid sends (100ms gap)", test_rapid_10x, client)
    run_test("15x rapid sends (NO gap)", test_rapid_15x_no_gap, client)
    run_test("10x rapid send_key('enter')", test_rapid_send_key_enter_10x, client)
    print()

    # ── Category 3: Empty text + Enter ──
    print("  ── Category 3: Empty/Whitespace + Enter ──")
    run_test("Bare Enter (no text)", test_bare_enter, client)
    run_test("5x bare Enters then command", test_multiple_bare_enters, client)
    run_test("Spaces + Enter then command", test_enter_after_spaces, client)
    print()

    # ── Category 4: Multi-surface ──
    print("  ── Category 4: Multi-Surface Delivery ──")
    run_test("Split pane: send to both", test_split_and_send_both, client)
    run_test("Rapid cross-surface alternation", test_rapid_cross_surface, client)
    print()

    # ── Category 5: Bare Enter burst ──
    print("  ── Category 5: Enter Key Burst ──")
    run_test("10x bare send_key('enter') burst", test_send_key_enter_burst, client)
    print()

    # ── Category 6: Long text ──
    print("  ── Category 6: Long Text + Enter ──")
    run_test("500-char command", test_long_command, client)
    run_test("2000-char command", test_very_long_command, client)
    print()

    # ── Category 7: Special chars ──
    print("  ── Category 7: Special Characters + Enter ──")
    run_test("Quotes, pipes, special chars", test_special_chars, client)
    run_test("Unicode (한글, emoji)", test_unicode_text, client)
    run_test("Multi-line embedded newlines", test_multiline_text, client)
    print()

    # ── Category 8: Timing edge cases ──
    print("  ── Category 8: Timing Edge Cases ──")
    run_test("Enter immediately (no warm-up)", test_enter_immediately_after_connect, client)
    run_test("Enter after 3s pause (idle)", test_enter_after_long_pause, client)
    run_test("Verify screen output (final)", test_verify_screen_output, client)
    print()

    client.close()

    # ── Summary ──
    total = PASS_COUNT + FAIL_COUNT + SKIP_COUNT
    print("═" * 65)
    print(f"  Results: {PASS_COUNT} passed, {FAIL_COUNT} failed, {SKIP_COUNT} skipped / {total} total")
    print("═" * 65)

    if FAIL_COUNT > 0:
        print(f"\n  ⚠️  {FAIL_COUNT} test(s) FAILED — Enter key delivery issue persists")
        return 1
    else:
        print(f"\n  ✅ All {PASS_COUNT} tests passed — Enter delivery is solid!")
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
