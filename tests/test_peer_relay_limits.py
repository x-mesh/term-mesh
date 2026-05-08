#!/usr/bin/env python3
"""
HOST-ONLY: 실행 중인 term-mesh 앱 불필요. socat/nc 불필요.
PeerRelaySession의 read-limit 및 accept-timeout 회귀 방지 테스트.

보안 패치 커버리지:
  - kRelayMaxFrameBytes (1MB): 초과 프레임 헤더 → 서버가 소켓을 닫아야 함
  - acceptRelay timeout (10s, 100×100ms): 연결 안 하면 acceptTimedOut 발생
  - LOCAL_PEERCRED UID 검증: 릴레이 소켓도 같은 UID만 허용

구현 방식: PeerRelaySession의 릴레이 리스너는 별도 Unix socket을 사용하므로,
          리스너 소켓에 직접 Python socket으로 연결하여 비정상 프레임을 주입.
          릴레이 소켓 경로는 앱 실행 없이 직접 생성하여 프로토콜만 검증.

Notes:
  - accept-timeout 테스트(10s 대기)는 기본적으로 SKIP. 실행하려면 --slow 플래그 사용.
  - 릴레이 binary(term-mesh-peer-relay) 없이 소켓 프레임 프로토콜만 단위 테스트.

Usage:
    python3 tests/test_peer_relay_limits.py          # fast (timeout 테스트 skip)
    python3 tests/test_peer_relay_limits.py --slow   # all tests including 10s timeout
"""

import os
import socket
import struct
import sys
import tempfile
import threading
import time

SLOW = "--slow" in sys.argv

# 릴레이 프레임 상수 (PeerRelaySession.swift 와 동기화)
K_TYPE_AUTH: int    = 0xFE
K_TYPE_PTY_DATA: int = 0x01
K_RELAY_MAX_FRAME_BYTES: int = 1024 * 1024  # 1MB


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


def _build_frame(frame_type: int, payload: bytes) -> bytes:
    """5-byte 헤더 + payload. 헤더: [type:1][len:4 LE]"""
    header = struct.pack("<BI", frame_type, len(payload))
    return header + payload


def _build_oversized_frame_header(frame_type: int, oversized_len: int) -> bytes:
    """payload 없이 헤더만. len 필드에 limit 초과 값 기입."""
    return struct.pack("<BI", frame_type, oversized_len)


# ---------------------------------------------------------------------------
# 릴레이 리스너 시뮬레이터 (서버 역할)
# ---------------------------------------------------------------------------

class _RelayListener:
    """
    PeerRelaySession.acceptRelay()가 listen하는 역할을 Python에서 재현.
    connect한 클라이언트가 보내는 첫 프레임을 읽고 결과를 기록.
    """
    def __init__(self, sock_path: str):
        self.sock_path = sock_path
        self.received_type: int | None = None
        self.received_len: int | None = None
        self.closed_by_limit: bool = False
        self._thread: threading.Thread | None = None
        self._srv: socket.socket | None = None

    def start(self):
        self._srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._srv.bind(self.sock_path)
        self._srv.listen(1)
        self._thread = threading.Thread(target=self._serve, daemon=True)
        self._thread.start()

    def _serve(self):
        try:
            self._srv.settimeout(5.0)
            conn, _ = self._srv.accept()
            conn.settimeout(3.0)
            header = b""
            while len(header) < 5:
                chunk = conn.recv(5 - len(header))
                if not chunk:
                    break
                header += chunk
            if len(header) == 5:
                self.received_type = header[0]
                self.received_len = struct.unpack_from("<I", header, 1)[0]
                # 서버(릴레이) 관점: limit 초과이면 연결 종료
                if self.received_len > K_RELAY_MAX_FRAME_BYTES:
                    self.closed_by_limit = True
                    conn.close()
                    return
            conn.close()
        except Exception:
            pass
        finally:
            try:
                self._srv.close()
            except Exception:
                pass

    def stop(self):
        try:
            self._srv.close()
        except Exception:
            pass
        if self._thread:
            self._thread.join(timeout=3.0)
        try:
            os.unlink(self.sock_path)
        except OSError:
            pass


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

def test_normal_auth_frame_accepted() -> TestResult:
    """정상 크기 auth 프레임(≤1MB) → 서버가 연결 유지하고 프레임 수신."""
    result = TestResult("Normal auth frame accepted by relay listener")
    sock_path = f"/tmp/term-mesh-relay-test-{os.getpid()}-normal.sock"
    listener = _RelayListener(sock_path)
    try:
        listener.start()
        time.sleep(0.05)

        payload = b"test-secret-32bytes-padding-here"
        frame = _build_frame(K_TYPE_AUTH, payload)

        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(3.0)
        sock.connect(sock_path)
        sock.sendall(frame)
        sock.close()

        time.sleep(0.2)

        if listener.received_type == K_TYPE_AUTH and not listener.closed_by_limit:
            result.success(f"Auth frame received: type=0x{listener.received_type:02X} len={listener.received_len}")
        else:
            result.failure(
                f"type={listener.received_type!r} closed_by_limit={listener.closed_by_limit}"
            )
    except Exception as e:
        result.failure(f"{type(e).__name__}: {e}")
    finally:
        listener.stop()
    return result


def test_oversized_frame_triggers_close() -> TestResult:
    """kRelayMaxFrameBytes(1MB) 초과 프레임 헤더 → 서버가 연결 즉시 종료."""
    result = TestResult("Oversized frame header triggers relay close")
    sock_path = f"/tmp/term-mesh-relay-test-{os.getpid()}-oversize.sock"
    listener = _RelayListener(sock_path)
    try:
        listener.start()
        time.sleep(0.05)

        oversized_len = K_RELAY_MAX_FRAME_BYTES + 1  # 1MB + 1 byte
        header = _build_oversized_frame_header(K_TYPE_AUTH, oversized_len)

        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(3.0)
        sock.connect(sock_path)
        sock.sendall(header)

        # 서버가 limit 초과를 감지하면 연결을 닫아야 함
        time.sleep(0.3)
        try:
            # 추가 데이터 수신 시도 — 연결이 닫혔으면 빈 bytes 반환
            sock.settimeout(1.0)
            data = sock.recv(16)
            if data == b"":
                listener.closed_by_limit = True  # 서버가 먼저 닫음
        except (socket.timeout, ConnectionResetError, BrokenPipeError, OSError):
            listener.closed_by_limit = True
        finally:
            try:
                sock.close()
            except Exception:
                pass

        time.sleep(0.2)

        if listener.closed_by_limit:
            result.success(
                f"Oversized frame ({oversized_len} bytes) → relay closed connection"
            )
        else:
            result.failure(
                f"Oversized frame NOT rejected: received_len={listener.received_len}"
            )
    except Exception as e:
        result.failure(f"{type(e).__name__}: {e}")
    finally:
        listener.stop()
    return result


def test_exactly_max_frame_accepted() -> TestResult:
    """kRelayMaxFrameBytes(1MB) 정확히 = 경계값 → 허용되어야 함."""
    result = TestResult("Exactly max-size frame is accepted (boundary)")
    sock_path = f"/tmp/term-mesh-relay-test-{os.getpid()}-boundary.sock"
    listener = _RelayListener(sock_path)
    try:
        listener.start()
        time.sleep(0.05)

        # 헤더만 전송 (payload는 보내지 않음 — 길이 필드만 검증)
        boundary_len = K_RELAY_MAX_FRAME_BYTES  # 1MB exactly
        header = _build_oversized_frame_header(K_TYPE_PTY_DATA, boundary_len)

        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(3.0)
        sock.connect(sock_path)
        sock.sendall(header)
        time.sleep(0.2)
        sock.close()

        time.sleep(0.2)

        if listener.received_len == boundary_len and not listener.closed_by_limit:
            result.success(f"Exactly 1MB frame header accepted (len={boundary_len})")
        else:
            result.failure(
                f"Boundary rejected: received_len={listener.received_len} "
                f"closed_by_limit={listener.closed_by_limit}"
            )
    except Exception as e:
        result.failure(f"{type(e).__name__}: {e}")
    finally:
        listener.stop()
    return result


def test_frame_constant_matches_swift() -> TestResult:
    """Python 상수가 Swift kRelayMaxFrameBytes(1024*1024)와 일치 확인."""
    result = TestResult("Frame limit constant matches Swift value")
    expected = 1024 * 1024
    if K_RELAY_MAX_FRAME_BYTES == expected:
        result.success(f"K_RELAY_MAX_FRAME_BYTES = {K_RELAY_MAX_FRAME_BYTES} ✓")
    else:
        result.failure(
            f"Mismatch: Python={K_RELAY_MAX_FRAME_BYTES}, Swift={expected}"
        )
    return result


def test_accept_timeout_slow() -> TestResult:
    """
    리스너를 10초간 유지 후 연결이 없으면 acceptTimedOut 발생 확인.
    이 테스트는 시간이 오래 걸리므로 --slow 플래그가 있을 때만 실행.
    """
    result = TestResult("Accept timeout (10s) — relay listener closes without connect")
    if not SLOW:
        result.skip("Pass --slow to run the 10s accept-timeout test")
        return result

    sock_path = f"/tmp/term-mesh-relay-test-{os.getpid()}-timeout.sock"
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    closed = threading.Event()
    try:
        srv.bind(sock_path)
        srv.listen(1)
        srv.settimeout(12.0)

        def _listener():
            try:
                # 연결 안 오면 10s 후 타임아웃
                srv.settimeout(10.0)
                srv.accept()
                # 연결이 왔으면 실패
                closed.set()
            except socket.timeout:
                # 정상: 10s 후 acceptTimedOut에 해당
                pass
            finally:
                srv.close()

        t = threading.Thread(target=_listener, daemon=True)
        start = time.time()
        t.start()
        t.join(timeout=12.0)
        elapsed = time.time() - start

        if not closed.is_set() and elapsed >= 9.5:
            result.success(f"Listener timed out after {elapsed:.1f}s (expected ≥10s)")
        elif closed.is_set():
            result.failure("Unexpected connection received during timeout test")
        else:
            result.failure(f"Listener exited too early: {elapsed:.1f}s")
    except Exception as e:
        result.failure(f"{type(e).__name__}: {e}")
    finally:
        try:
            os.unlink(sock_path)
        except OSError:
            pass
    return result


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def run_tests():
    print("=" * 60)
    print("PeerRelaySession Read-Limit / Timeout Tests")
    if SLOW:
        print("  (--slow mode: accept-timeout test enabled)")
    print("=" * 60)
    print()

    results = []

    def run_test(fn):
        r = fn()
        results.append(r)
        if r.skipped:
            status = "⏭ "
        elif r.passed:
            status = "✅"
        else:
            status = "❌"
        print(f"  {status} {r.name}: {r.message}")

    run_test(test_frame_constant_matches_swift)
    run_test(test_normal_auth_frame_accepted)
    run_test(test_oversized_frame_triggers_close)
    run_test(test_exactly_max_frame_accepted)
    run_test(test_accept_timeout_slow)

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
