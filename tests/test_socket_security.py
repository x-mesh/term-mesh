#!/usr/bin/env python3
"""
HOST-ONLY: 실행 중인 term-mesh 앱 불필요 (소켓 파일만 존재하면 됨).
소켓 파일 권한 및 LOCAL_PEERCRED UID 검증 회귀 방지 테스트.

보안 패치 커버리지:
  - 소켓 파일 권한 0o600 (termMeshOnly/off/password 모드)
  - allowAll 모드: 0o600 (owner-only, 패치 후)
  - LOCAL_PEERCRED: 같은 UID → 연결 허용, 다른 UID → 거부 (거부 경로는 SKIP)

Usage:
    python3 tests/test_socket_security.py

Requirements:
    - term-mesh must be running (socket file must exist)
    - Set TERMMESH_SOCKET_PATH to override the default socket path
"""

import os
import socket
import stat
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from termmesh import termmesh, termmeshError


class TestResult:
    def __init__(self, name: str):
        self.name = name
        self.passed = False
        self.message = ""
        self.skipped = False

    def success(self, msg: str = ""):
        self.passed = True
        self.message = msg

    def failure(self, msg: str):
        self.passed = False
        self.message = msg

    def skip(self, msg: str):
        self.skipped = True
        self.passed = True
        self.message = f"SKIP: {msg}"


def _get_socket_path() -> str:
    override = os.environ.get("TERMMESH_SOCKET_PATH")
    if override and os.path.exists(override):
        return override
    client = termmesh()
    return client.socket_path


def _raw_connect(socket_path: str, timeout: float = 3.0):
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    sock.connect(socket_path)
    return sock


def _raw_send(sock, command: str, timeout: float = 3.0) -> str:
    sock.sendall((command + "\n").encode())
    data = b""
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            chunk = sock.recv(4096)
            if not chunk:
                break
            data += chunk
            if b"\n" in data:
                break
        except socket.timeout:
            break
    return data.decode().strip()


# ---------------------------------------------------------------------------
# Test: 소켓 파일 권한 확인
# ---------------------------------------------------------------------------

def test_socket_file_permissions(socket_path: str) -> TestResult:
    """소켓 파일 권한이 0o600 (owner-only) 임을 확인."""
    result = TestResult("Socket file permissions")
    try:
        if not os.path.exists(socket_path):
            result.failure(f"Socket not found: {socket_path}")
            return result

        st = os.stat(socket_path)
        mode = stat.S_IMODE(st.st_mode)

        # 패치 후 모든 모드에서 정확히 0o600 (owner-only) 이어야 함
        if mode != 0o600:
            result.failure(
                f"Expected 0o600 (owner-only), got {oct(mode)} — group/other bits leak"
            )
            return result

        result.success(f"Socket permissions: {oct(mode)}")
    except Exception as e:
        result.failure(f"{type(e).__name__}: {e}")
    return result


def test_socket_owner_is_current_user(socket_path: str) -> TestResult:
    """소켓 파일 소유자가 현재 프로세스 UID와 일치 확인."""
    result = TestResult("Socket owner matches current user")
    try:
        if not os.path.exists(socket_path):
            result.failure(f"Socket not found: {socket_path}")
            return result

        st = os.stat(socket_path)
        if st.st_uid != os.getuid():
            result.failure(
                f"Socket owned by uid={st.st_uid}, current uid={os.getuid()}"
            )
            return result

        result.success(f"Socket owner uid={st.st_uid} matches current user")
    except Exception as e:
        result.failure(f"{type(e).__name__}: {e}")
    return result


def test_same_uid_connect_succeeds(socket_path: str) -> TestResult:
    """같은 UID에서 raw connect 후 응답 수신 (PEERCRED UID 검증 통과)."""
    result = TestResult("Same UID connect succeeds")
    try:
        sock = _raw_connect(socket_path)
        try:
            response = _raw_send(sock, "ping")
        finally:
            sock.close()

        # PONG, PONG-like 응답 또는 v2 JSON OK → 연결 성공으로 판정
        # (password 모드이면 "Authentication required"가 오지만 연결 자체는 성공)
        if response and "Access denied" not in response and "uid mismatch" not in response.lower():
            result.success(f"Connected as same UID, got: {response[:60]!r}")
        else:
            result.failure(f"Unexpected rejection for same UID: {response!r}")
    except Exception as e:
        result.failure(f"{type(e).__name__}: {e}")
    return result


def test_different_uid_connect_skipped() -> TestResult:
    """다른 UID 시뮬레이션은 sudo 없이 불가 → SKIP."""
    result = TestResult("Different UID connect rejected")
    result.skip("requires sudo/su to spawn a different-UID process — skipped in automated suite")
    return result


def test_socket_is_unix_type(socket_path: str) -> TestResult:
    """소켓 파일이 실제 Unix domain socket 타입인지 확인 (S_ISSOCK)."""
    result = TestResult("Socket file is Unix domain socket")
    try:
        if not os.path.exists(socket_path):
            result.failure(f"Socket not found: {socket_path}")
            return result

        st = os.stat(socket_path)
        if not stat.S_ISSOCK(st.st_mode):
            result.failure(f"Not a socket: st_mode={oct(st.st_mode)}")
            return result

        result.success("Confirmed as Unix domain socket")
    except Exception as e:
        result.failure(f"{type(e).__name__}: {e}")
    return result


def test_no_other_readable(socket_path: str) -> TestResult:
    """소켓 파일에 other-read(0o004) bit 없음 확인."""
    result = TestResult("No other-read bit on socket")
    try:
        if not os.path.exists(socket_path):
            result.failure(f"Socket not found: {socket_path}")
            return result

        st = os.stat(socket_path)
        mode = stat.S_IMODE(st.st_mode)

        if mode & 0o004:
            result.failure(f"Other-read bit set: {oct(mode)} — other users can connect")
            return result

        result.success(f"No other-read bit: {oct(mode)}")
    except Exception as e:
        result.failure(f"{type(e).__name__}: {e}")
    return result


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def run_tests():
    print("=" * 60)
    print("term-mesh Socket Security Tests")
    print("=" * 60)
    print()

    try:
        socket_path = _get_socket_path()
    except Exception as e:
        print(f"Error: could not resolve socket path: {e}")
        return 1

    if not os.path.exists(socket_path):
        print(f"Error: socket not found at {socket_path}")
        print("  → term-mesh must be running to run these tests")
        return 1

    print(f"Socket: {socket_path}")
    print()

    results = []

    def run_test(test_fn, *args):
        r = test_fn(*args)
        results.append(r)
        if r.skipped:
            status = "⏭ "
        elif r.passed:
            status = "✅"
        else:
            status = "❌"
        print(f"  {status} {r.name}: {r.message}")

    run_test(test_socket_is_unix_type, socket_path)
    run_test(test_socket_file_permissions, socket_path)
    run_test(test_socket_owner_is_current_user, socket_path)
    run_test(test_no_other_readable, socket_path)
    run_test(test_same_uid_connect_succeeds, socket_path)
    run_test(test_different_uid_connect_skipped)

    print()
    print("=" * 60)

    passed = sum(1 for r in results if r.passed)
    skipped = sum(1 for r in results if r.skipped)
    failed = len(results) - passed
    print(f"Passed: {passed}/{len(results)}  (skipped: {skipped})")

    for r in results:
        if not r.passed:
            print(f"  ❌ FAIL — {r.name}: {r.message}")

    return 0 if failed == 0 else 1


if __name__ == "__main__":
    sys.exit(run_tests())
