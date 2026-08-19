#!/usr/bin/env python3
"""재시작해도 workspace가 정체성을 잃지 않는다.

회귀 방지 대상: session.json이 workspace의 pane/제목/디렉터리는 복원하면서 UUID는
저장하지 않아, 재시작마다 새 UUID가 발급되던 결함. 그 UUID를 키로 보관하던 Project
선언이 재시작 후 전부 조회 실패했고, 라우팅이 "이 Project를 담은 workspace가 없다"고
판단해 매 실행마다 `[project]` workspace를 하나씩 더 만들었다 (5 → 8 → 11 → 14).

재시작 경계에서만 드러나는 결함이라 러너의 테스트 간 relaunch로는 잡히지 않는다.

단언은 이 테스트가 만든 workspace로 한정한다. 전체 개수는 불변식이 아니다 — 이 호스트의
daemon이 팀을 들고 있으면 재시작 후 hosted-session workspace가 정당하게 더 붙는다.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from termmesh import termmesh, termmeshError

PROBES = 3


def main() -> int:
    with termmesh() as c:
        # arrange: 재시작을 건너고 살아남아야 할 workspace.
        made = []
        for index in range(PROBES):
            wsid = c.new_workspace(select=False)
            c.rename_workspace(f"relaunch-probe-{index}", wsid)
            made.append(wsid)

        # act + assert: 세 번 재시작. UUID가 재발급되면 첫 회차에 이미 깨진다.
        for attempt in range(1, 4):
            c.relaunch()

            rows = c.list_workspaces()
            ids = [wsid for _, wsid, _, _ in rows]
            titles = [title for _, _, title, _ in rows]

            missing = [wsid for wsid in made if wsid not in ids]
            if missing:
                raise termmeshError(
                    f"relaunch {attempt} did not restore {len(missing)} of "
                    f"{PROBES} workspaces under their saved IDs (missing={missing})"
                )

            for wsid in made:
                if ids.count(wsid) != 1:
                    raise termmeshError(
                        f"relaunch {attempt} left {ids.count(wsid)} workspaces "
                        f"claiming ID {wsid}"
                    )
            for index in range(PROBES):
                name = f"relaunch-probe-{index}"
                if titles.count(name) != 1:
                    raise termmeshError(
                        f"relaunch {attempt} left {titles.count(name)} workspaces "
                        f"titled {name} — a restored workspace was duplicated "
                        f"rather than recognized"
                    )

        # cleanup: 이 테스트가 만든 것만 닫는다.
        for wsid in made:
            c.close_workspace(wsid)

    print(f"PASS: {PROBES} workspaces keep their IDs and stay unduplicated across 3 relaunches")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
