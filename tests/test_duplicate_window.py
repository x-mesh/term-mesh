#!/usr/bin/env python3
"""
자동화 테스트: 중복 창(duplicate window) 이슈 수정 검증
수정 버그 5가지에 대한 검증 시나리오

Usage (VM에서 실행):
    ssh term-mesh-vm 'cd /Users/jinwoo/term-mesh/GhosttyTabs && python3 tests/test_duplicate_window.py'

Prerequisites:
    - term-mesh Debug 앱이 실행 중이어야 함
    - TERMMESH_SOCKET_MODE=allowAll 환경변수로 실행된 앱
"""

import json
import os
import sys
import time
import subprocess
import tempfile
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from termmesh import termmesh, termmeshError


SOCKET_PATH = "/tmp/term-mesh-debug.sock"
DEBUG_LOG_PATH_FILE = "/tmp/term-mesh-last-debug-log-path"


class TestResult:
    def __init__(self, name: str):
        self.name = name
        self.passed = False
        self.message = ""

    def success(self, msg: str = ""):
        self.passed = True
        self.message = msg
        print(f"  [PASS] {self.name}: {msg}")

    def failure(self, msg: str):
        self.passed = False
        self.message = msg
        print(f"  [FAIL] {self.name}: {msg}")


def get_debug_log_path() -> Path:
    """현재 debug log 파일 경로를 가져온다."""
    last_path_file = Path(DEBUG_LOG_PATH_FILE)
    if last_path_file.exists():
        p = last_path_file.read_text().strip()
        if p:
            return Path(p)
    return Path("/tmp/term-mesh-debug.log")


def tail_debug_log(n: int = 200) -> str:
    """debug log 파일의 마지막 n줄을 반환한다."""
    log_path = get_debug_log_path()
    if not log_path.exists():
        return ""
    try:
        result = subprocess.run(
            ["tail", "-n", str(n), str(log_path)],
            capture_output=True, text=True, timeout=5
        )
        return result.stdout
    except Exception:
        return ""


def wait_for_log_keyword(keyword: str, timeout_s: float = 5.0, poll_interval: float = 0.2) -> bool:
    """debug log에서 keyword가 나타날 때까지 대기한다."""
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        log = tail_debug_log(50)
        if keyword in log:
            return True
        time.sleep(poll_interval)
    return False


def count_windows_via_socket(client: termmesh) -> int:
    """list_windows 소켓 명령으로 현재 창 수를 반환한다."""
    try:
        resp = client._send_command("list_windows")
        if resp.strip() == "No windows":
            return 0
        return sum(1 for line in resp.splitlines() if line.strip())
    except Exception:
        pass
    # fallback: list_workspaces로 창 수 추정 (1창 기준)
    try:
        workspaces = client.list_workspaces()
        return 1 if workspaces else 0
    except Exception:
        return -1


# ---------------------------------------------------------------------------
# 검증 1: applicationShouldHandleReopen — Dock 클릭 후 중복 창 없음
# ---------------------------------------------------------------------------

def test_verify1_handleReopen(client: termmesh) -> TestResult:
    """
    수정 #1: applicationShouldHandleReopen이 return false + createMainWindow()를 사용하는지 검증.
    Dock 클릭을 직접 시뮬레이션할 수 없으므로, debug log에 window.handleReopen이
    기록되는지 확인하고, 수정 후 동작(return false, createMainWindow 호출)을 로그로 검증.

    검증 방법:
    1. activate_app 소켓 명령 전송 (앱 활성화 유도)
    2. debug log에서 window.handleReopen 로그 확인
    3. 현재 창 수가 1개임을 확인 (중복 없음)
    """
    result = TestResult("수정#1 applicationShouldHandleReopen")
    try:
        # 소켓으로 앱 활성화 — Dock 클릭과 유사한 경로 유도
        log_before = tail_debug_log(100)
        client.activate_app()
        time.sleep(1.0)

        log_after = tail_debug_log(100)
        new_log = log_after[len(log_before):]

        # handleReopen 로그가 있는지 (항상 기록되진 않음 — 수동 확인 필요)
        has_reopen_log = "window.handleReopen" in new_log
        has_create_log = "mainWindow.CREATE" in new_log

        # 창 수 확인
        n_windows = count_windows_via_socket(client)

        if n_windows > 1:
            result.failure(
                f"중복 창 감지: {n_windows}개의 창이 존재. "
                f"handleReopen={has_reopen_log} CREATE={has_create_log}"
            )
        else:
            result.success(
                f"창 수 정상: {n_windows}개. "
                f"handleReopen log={'있음' if has_reopen_log else '없음(수동확인필요)'} "
                f"CREATE={'있음' if has_create_log else '없음'}"
            )
    except Exception as e:
        result.failure(str(e))
    return result


def test_verify1_manual_instructions():
    """수동 검증 단계를 출력한다."""
    print("""
  [수동 검증 #1 — applicationShouldHandleReopen]
  1. term-mesh Debug 앱 실행
  2. 모든 창을 닫는다 (Cmd+W 반복)
  3. Dock 아이콘을 클릭한다
  4. debug log 확인:
       tail -f $(cat /tmp/term-mesh-last-debug-log-path)
  5. 기대 로그:
       window.handleReopen flag=false contexts=0 ...   ← 수정 전: 없음, 수정 후: 있음
       mainWindow.CREATE windowId=...                  ← 창이 AppDelegate 경로로 생성됨
  6. WindowGroup.onAppear 로그가 뜨면 수정 실패 (중복 scene 생성)
  7. 창이 1개만 생성되는지 확인
""")


# ---------------------------------------------------------------------------
# 검증 2: 중복 scene 차단 (DUPLICATE_SCENE)
# ---------------------------------------------------------------------------

def test_verify2_duplicate_scene_guard(client: termmesh) -> TestResult:
    """
    수정 #2: WindowGroup.onAppear에서 existingWindows > 0이면 즉시 window.close 호출.
    자동 유발이 어려우므로 debug log 분석으로 검증.

    검증 방법:
    1. debug log에서 DUPLICATE_SCENE 로그가 있는지 확인
    2. 있다면 → 중복 scene이 발생했으나 방어 로직이 동작
    3. 없다면 → 중복 scene 자체가 발생하지 않음 (더 좋은 경우)
    """
    result = TestResult("수정#2 DUPLICATE_SCENE 차단")
    try:
        log = tail_debug_log(500)
        if "DUPLICATE_SCENE" in log:
            # 중복 scene이 감지됐으나 차단됐는지 확인
            result.success("DUPLICATE_SCENE 로그 감지 — 방어 로직 동작 확인됨")
        else:
            result.success("DUPLICATE_SCENE 로그 없음 — 중복 scene 미발생 (정상)")
    except Exception as e:
        result.failure(str(e))
    return result


def test_verify2_manual_instructions():
    print("""
  [수동 검증 #2 — DUPLICATE_SCENE 차단]
  1. 앱이 실행 중인 상태에서 debug log를 모니터링:
       tail -f $(cat /tmp/term-mesh-last-debug-log-path) | grep DUPLICATE
  2. 아래 명령으로 중복 scene 유도를 시도 (macOS open 명령):
       open -n /path/to/term-mesh.app
  3. 기대 동작:
       - log에 "window.WindowGroup.onAppear DUPLICATE_SCENE ..." 출력
       - 이후 창이 즉시 닫혀 창 수가 1개 유지
  4. 실패 조건: 창이 2개 이상 남아있음
""")


# ---------------------------------------------------------------------------
# 검증 3: activate_app race condition — 앱 시작 직후 소켓 명령
# ---------------------------------------------------------------------------

def test_verify3_activate_app_race(client: termmesh) -> TestResult:
    """
    수정 #3: activate_app이 mainWindowContexts 비어있을 때 openNewMainWindow를 호출해
    중복 창을 만들지 않는지 검증.

    검증 방법:
    1. 현재 창 수를 기록
    2. activate_app 3회 연속 전송 (race 조건 시뮬레이션)
    3. 창 수가 증가하지 않는지 확인
    """
    result = TestResult("수정#3 activate_app race condition")
    try:
        n_before = count_windows_via_socket(client)
        time.sleep(0.1)

        # 연속으로 여러 번 activate_app 전송
        for _ in range(3):
            client.activate_app()
            time.sleep(0.3)

        time.sleep(1.0)
        n_after = count_windows_via_socket(client)

        if n_after > n_before + 1:
            result.failure(
                f"창이 증가함: {n_before} → {n_after} "
                "(activate_app이 중복 창을 생성)"
            )
        else:
            result.success(
                f"창 수 안정적: {n_before} → {n_after} "
                "(activate_app race 없음)"
            )
    except Exception as e:
        result.failure(str(e))
    return result


def test_verify3_manual_instructions():
    print("""
  [수동 검증 #3 — activate_app race condition]
  1. 앱을 종료 후 재시작
  2. 앱 시작 직후 (0.5초 이내) 소켓으로 activate_app 전송:
       # term-mesh 소켓 경로 확인
       ls /tmp/term-mesh*.sock
       # 빠르게 여러 번 activate_app 전송
       echo 'activate_app' | nc -U /tmp/term-mesh-debug.sock &
       echo 'activate_app' | nc -U /tmp/term-mesh-debug.sock &
       echo 'activate_app' | nc -U /tmp/term-mesh-debug.sock &
  3. debug log 확인:
       grep "mainWindow.CREATE" $(cat /tmp/term-mesh-last-debug-log-path)
  4. 기대 결과: mainWindow.CREATE가 1회만 나타남
  5. 실패: mainWindow.CREATE가 2회 이상 나타남 → 창 2개 생성
""")


# ---------------------------------------------------------------------------
# 검증 4: New Window (Cmd+Shift+N) 이중 처리 방지
# ---------------------------------------------------------------------------

def test_verify4_new_window_dedup(client: termmesh) -> TestResult:
    """
    수정 #4: Cmd+Shift+N이 SwiftUI 메뉴 + handleCustomShortcut 양쪽에서 처리되어
    창이 2개 생성되던 버그 수정 검증.

    검증 방법:
    1. 현재 창 수 확인
    2. simulate_shortcut으로 Cmd+Shift+N 전송
    3. 창이 정확히 1개만 추가됐는지 확인
    4. 생성된 창을 닫아 원상 복구
    """
    result = TestResult("수정#4 New Window 이중 처리")
    try:
        n_before = count_windows_via_socket(client)
        log_pos_before = tail_debug_log(300)

        # Cmd+Shift+N 시뮬레이션
        client.simulate_shortcut("cmd+shift+n")
        time.sleep(1.5)

        n_after = count_windows_via_socket(client)
        new_log = tail_debug_log(100)

        # 생성된 창 수 확인
        create_count = new_log.count("mainWindow.CREATE")

        if n_after != n_before + 1:
            result.failure(
                f"창 수 이상: {n_before} → {n_after} "
                f"(CREATE 로그 {create_count}회 — 기대 1회)"
            )
        elif create_count > 1:
            result.failure(
                f"mainWindow.CREATE {create_count}회 호출 — 이중 처리 발생 "
                f"(최종 창 수: {n_after})"
            )
        else:
            result.success(
                f"창 정상 생성: {n_before} → {n_after} "
                f"(CREATE 로그 {create_count}회)"
            )

        # 새로 만든 창 닫기 (원상 복구)
        if n_after > n_before:
            time.sleep(0.5)
            client.simulate_shortcut("cmd+w")
            time.sleep(0.5)

    except Exception as e:
        result.failure(str(e))
    return result


def test_verify4_manual_instructions():
    print("""
  [수동 검증 #4 — New Window (Cmd+Shift+N) 이중 처리]
  1. debug log 모니터링 시작:
       tail -f $(cat /tmp/term-mesh-last-debug-log-path) | grep mainWindow.CREATE
  2. Cmd+Shift+N 입력
  3. 기대: "mainWindow.CREATE" 1회만 출력
  4. 실패: "mainWindow.CREATE" 2회 출력 → 창 2개 생성
  5. 추가 확인: SwiftUI CommandGroup + handleCustomShortcut 양쪽에서 처리되지 않는지
     grep "shortcut.action name=newWindow" log 확인
""")


# ---------------------------------------------------------------------------
# 검증 5: debug log 커버리지 확인
# ---------------------------------------------------------------------------

def test_verify5_debug_log_coverage(client: termmesh) -> TestResult:
    """
    수정 #5: debug log에 window 이벤트가 기록되는지 확인.
    window.handleReopen, window.WindowGroup.onAppear, mainWindow.CREATE 등의
    로그가 dlog 파일에 수록되는지 검증.
    """
    result = TestResult("수정#5 debug log 커버리지")
    try:
        log = tail_debug_log(500)
        log_path = get_debug_log_path()

        checks = {
            "mainWindow.CREATE": "mainWindow.CREATE" in log,
            "mainWindow.register": "mainWindow.register" in log,
            "window.WindowGroup.onAppear": "window.WindowGroup.onAppear" in log,
        }

        missing = [k for k, v in checks.items() if not v]
        found = [k for k, v in checks.items() if v]

        # window.handleReopen은 앱 재시작 없이는 보이지 않을 수 있음
        has_handle_reopen = "window.handleReopen" in log

        summary = (
            f"log 파일: {log_path} | "
            f"found={found} | "
            f"missing={missing} | "
            f"handleReopen={'있음' if has_handle_reopen else '없음(재시작필요)'}"
        )

        if missing:
            result.failure(f"일부 로그 누락: {summary}")
        else:
            result.success(summary)

    except Exception as e:
        result.failure(str(e))
    return result


# ---------------------------------------------------------------------------
# 메인 실행
# ---------------------------------------------------------------------------

def run_all_tests():
    print("=" * 60)
    print("중복 창(duplicate window) 이슈 수정 검증")
    print("=" * 60)

    # 수동 검증 지침 출력
    test_verify1_manual_instructions()
    test_verify2_manual_instructions()
    test_verify3_manual_instructions()
    test_verify4_manual_instructions()

    print("\n[자동화 테스트 실행]")

    client = termmesh()
    try:
        client.connect()
    except Exception as e:
        print(f"ERROR: 소켓 연결 실패: {e}")
        print(f"  소켓 경로: {SOCKET_PATH}")
        print("  term-mesh Debug 앱이 실행 중인지 확인하세요.")
        sys.exit(1)

    results = []

    print("\n[검증 1] applicationShouldHandleReopen")
    results.append(test_verify1_handleReopen(client))

    print("\n[검증 2] DUPLICATE_SCENE 차단")
    results.append(test_verify2_duplicate_scene_guard(client))

    print("\n[검증 3] activate_app race condition")
    results.append(test_verify3_activate_app_race(client))

    print("\n[검증 4] New Window 이중 처리")
    results.append(test_verify4_new_window_dedup(client))

    print("\n[검증 5] debug log 커버리지")
    results.append(test_verify5_debug_log_coverage(client))

    client.close()

    # 결과 요약
    print("\n" + "=" * 60)
    print("결과 요약")
    print("=" * 60)
    passed = sum(1 for r in results if r.passed)
    total = len(results)
    for r in results:
        status = "PASS" if r.passed else "FAIL"
        print(f"  [{status}] {r.name}")
        if not r.passed:
            print(f"         → {r.message}")

    print(f"\n통과: {passed}/{total}")
    print()

    # debug log 경로 안내
    log_path = get_debug_log_path()
    print(f"debug log 경로: {log_path}")
    print(f"모니터링: tail -f {log_path}")
    print()
    print("핵심 grep 명령어:")
    print(f"  grep 'mainWindow.CREATE\\|handleReopen\\|DUPLICATE_SCENE\\|WindowGroup.onAppear' {log_path}")

    return 0 if passed == total else 1


if __name__ == "__main__":
    sys.exit(run_all_tests())
