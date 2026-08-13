# term-mesh socket E2E test standard

이 디렉터리(`tests/` v1, `tests_v2/` v2)의 테스트를 **작성·실행·판단하는 기준**이다.
인프라 셋업은 `docs/e2e-vm-setup.md`, v1→v2 프로토콜 배경은 `docs/v2-api-migration.md` 참조.

## 핵심 전제 — socket이 곧 테스트 표면

term-mesh는 Unix socket으로 앱을 **완전히 구동**할 수 있다. window/workspace/pane/surface 생성·포커스·이동, 키/텍스트 입력, 브라우저 내비게이션, 알림뿐 아니라 **테스트 전용 introspection**(`surface_health`, `read_terminal_text`, `render_stats`, `layout_debug`, `panel_snapshot`, `*_count` 카운터, `screenshot`)까지 노출한다.

따라서 **대부분의 UI 동작은 XCUITest 없이 `termmesh.py` 클라이언트로 헤드리스 검증한다.** 새 기능을 만들 때 "socket으로 관찰 가능한가"를 먼저 묻고, 불가능하면 우회 검증 대신 **v2 socket 메서드를 추가**한다(아래 "관찰 불가일 때").

## v1 vs v2 — 새 테스트는 v2

| | 디렉터리 | 클라이언트 | 프로토콜 | 상태 |
|---|---|---|---|---|
| v1 | `tests/` | `tests/termmesh.py` | 공백 구분 line 프로토콜 | **frozen** — parity 유지보수만 |
| v2 | `tests_v2/` | `tests_v2/termmesh.py` | JSON line + UUID handle | **신규 작성 위치** |

- **새 테스트는 반드시 `tests_v2/`에 작성한다.** v1에만 있는 영역(team/peer/shell/ime)을 v2로 옮길 때도 v2 클라이언트를 쓴다.
- v2는 workspace/pane/surface를 **안정적인 UUID handle**로 다룬다. 단발 호출 외에 재사용되는 참조는 index가 아닌 handle을 보관한다.

## 실행 — 전용 mac-sub runner에서만

호스트(`/Users/jinwoo/work/project/term-mesh`)에서 절대 실행하지 않는다. 러너가 `pkill term-mesh`로 **내 작업용 앱을 죽인다.** Socket E2E의 기본 실행 머신은 `jinwoos-macbook-pro`이며 `mac-sub` SSH alias로 접근한다.

```bash
# 전체 스위트 (빌드 → 매 테스트마다 launch → 3회 재시도 → cleanup)
ssh mac-sub 'cd /Users/jinwoo/work/term-mesh && ./scripts/run-tests-v2.sh'
ssh mac-sub 'cd /Users/jinwoo/work/term-mesh && ./scripts/run-tests-v1.sh'

# 단일 테스트 (개발 중)
ssh mac-sub 'cd /Users/jinwoo/work/term-mesh && ./scripts/run-tests-v2.sh tests_v2/test_trigger_flash.py'
```

러너는 launch 시 `socketControlMode full`(레거시 alias; `migrateMode`가 변환) + `TERMMESH_UI_TEST_MODE=1`(결정론적 startup)로 socket 접근을 강제하고, 신선한 workspace 하나로 부트스트랩한다. 단일 실행 시 socket을 켜려면 launch에 `--env TERMMESH_SOCKET_MODE=allowAll`를 준다. socket 경로는 `TERMMESH_SOCKET`/`TERMMESH_SOCKET_PATH`로 주입(레거시 `CMUX_*`도 허용되나 **새 코드에서 쓰지 않는다**).

## 표준 테스트 구조

각 테스트는 **독립 실행 가능한 스크립트**다. exit 0 = pass, 예외/비0 = fail. 성공 시 단일 `PASS:` 라인을 출력한다.

```python
#!/usr/bin/env python3
"""<한 줄 목적>. <회귀 테스트면 어떤 증상의 재발 방지인지>."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError


def main() -> int:
    with termmesh() as c:               # 경로 인자 없이 — env로 자동 해석
        # arrange: 필요한 상태를 socket으로 직접 만든다 (이전 상태 가정 금지)
        sid = c.new_surface(panel_type="terminal")
        c.focus_surface(sid)

        # act
        c.reset_flash_counts()
        base = c.flash_count(sid)
        c.trigger_flash(sid)

        # assert: socket 질의로 검증, 불일치 시 termmeshError(expected vs actual)
        after = c.flash_count(sid)
        if after <= base:
            raise termmeshError(f"flash count did not increase (base={base}, after={after})")

    print("PASS: surface.trigger_flash increments flash counter")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

> 이름 규칙 — `cmux` 금지: `093d14fa` 리브랜드(cmux→term-mesh)가 `termmesh.py`의 클래스/import는 바꿨지만 테스트 호출부의 옛 이름(`cmux(...)`, `cmuxError`, `client: cmux` 주석, `CMUX_SOCKET`, `/tmp/cmux-debug.sock`)을 놓쳐, 한때 **v2 84개 중 48개가 import 단계 `NameError: cmux`로 즉시 실패**(러너는 첫 실패에서 `break` → 완주 불가)했다. 이는 v1/v2 전 테스트 일괄 정정으로 해결됨(`cmux(`→`termmesh(`, `cmuxError`→`termmeshError`, `CMUX_SOCKET`→`TERMMESH_SOCKET`, `/tmp/cmux-debug.sock`→`/tmp/term-mesh-debug.sock`, 그리고 외부 계약은 정식 이름으로: `cmuxOnly`→`termMeshOnly`, `CMUXTERM_CLI`→`TERMMESH_CLI`, `CmuxWebView`→`TermMeshWebView`). **새/수정 테스트는 `termmesh`/`termmeshError`만 쓴다.** `termmesh.py`의 `CMUX_SOCKET[_PATH]` env fallback만 하위호환 목적으로 의도적으로 남아 있다.
>
> 회귀 가드(호스트에서 안전, socket 불필요) — import + 잔여 cmux 검사:
> ```bash
> for f in tests_v2/test_*.py tests/test_*.py; do d=$(dirname "$f"); b=$(basename "$f" .py); \
>   python3 -c "import sys;sys.path.insert(0,'$d');__import__('$b')" >/dev/null 2>&1 \
>   || echo "IMPORT-FAIL $f"; done
> grep -rilE 'cmux' tests tests_v2 | grep -v '/termmesh\.py$'   # expect: (no output)
> ```

## 작성 규약 (기준)

1. **자기완결·멱등** — 러너가 신선한 workspace를 주지만, 테스트는 자기 surface/pane을 직접 만들고 이전 상태나 순서를 가정하지 않는다. 만든 것은 가능하면 정리한다.
2. **검증은 socket 질의로** — `surface_health`, `read_terminal_text`, `list_*`, `*_count`, `is_*_focused`로 단언한다. **`sleep`을 단언으로 쓰지 않는다.** 비동기 상태는 deadline 폴링(`wait_for_webview_focus` 패턴) 또는 카운터로 확인한다.
3. **카운터는 측정 전 리셋** — `reset_flash_counts`, `reset_bonsplit_underflow_count`, `reset_empty_panel_count` 후 base를 찍고 act → 재측정.
4. **handle 우선** — v2에서 재사용 참조는 UUID handle을 보관(index는 호출 시점 편의용일 뿐).
5. **focus 정책 준수** — 루트 `CLAUDE.md`의 "Socket focus policy"를 따른다. 비-focus 커맨드가 포커스를 바꾸지 않음을 검증하거나, 포커스 변경은 명시적 focus-intent 커맨드(`focus_surface`, `select_workspace` 등)로만 한다.
6. **네이밍** — `test_<area>_<behavior>.py`. 회귀 테스트는 증상을 이름에 담는다(`test_..._regression.py`).
7. **결과 출력** — 실패는 `termmeshError(expected vs actual)`로, 성공은 마지막에 `PASS: <무엇이 보장됨>` 한 줄.
8. **이름 일관성** — `cmux`/`CMUX_*` 금지. `termmesh`/`TERMMESH_*`만 사용.

## socket e2e vs XCUITest vs basic tests

- **socket e2e (`tests_v2/`, 기본)** — 앱 로직, 레이아웃, focus, split, workspace, 브라우저, 알림, CLI parity, 회귀. 빠르고 결정론적.
- **XCUITest (`termMeshUITests/`)** — socket이 닿지 못하는 것만: 실제 OS 키 라우팅/메뉴 key-equivalent, 시스템 다이얼로그, Accessibility 기반 상호작용, 실제 렌더 픽셀. 더 느리고 flaky하니 최소화.
- **basic tests (루트 `CLAUDE.md`의 one-liner)** — `TERMMESH_SOCKET_MODE=allowAll`로 직접 띄워 돌리는 빠른 스모크 부분집합.

## flaky 처리

러너는 각 테스트를 relaunch하며 **3회 재시도**한다. 이는 환경 flake 흡수용 안전망이지 정상 상태가 아니다. **3회가 필요한 테스트는 타이밍 가정 버그**다 — `sleep`을 늘리지 말고 폴링/카운터로 근본 수정한다.

## 관찰 불가일 때 — socket 메서드를 추가한다

기존 클라이언트 메서드로 동작을 관찰할 수 없으면, 간접 우회로 단언하지 말고:
1. Swift에 v2 socket 메서드를 추가(루트 `CLAUDE.md`의 "Socket command threading policy" 준수 — 텔레메트리/비-focus는 off-main 기본),
2. `tests_v2/termmesh.py`에 클라이언트 래퍼 추가,
3. 그 메서드로 검증.

introspection 전용(예: `*_count`, `layout_debug`, `panel_snapshot`)은 테스트 가시성을 위한 1급 수단이다 — 새 불변식이 필요하면 카운터/스냅샷을 먼저 만든다.
