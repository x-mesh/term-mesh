# term-mesh agent guide

Keep this file limited to project-wide invariants and routing. Follow the
nearest directory-level `CLAUDE.md` and the linked runbooks for detailed
procedures. `AGENTS.md` is a symlink to this file.

## Setup and verification

- On a fresh checkout, run `./scripts/setup.sh`. It initializes submodules,
  installs the Metal toolchain, builds or restores GhosttyKit, and enables the
  repository hooks.
- After code changes, run the narrowest relevant test plus the full Debug build,
  then launch an isolated app with `./scripts/reload.sh --tag <task>`. Clean it
  up afterward with the same command plus `--cleanup`.
- Swift unit tests use the `term-mesh-unit` scheme. Register new test files in
  `GhosttyTabs.xcodeproj/project.pbxproj` and confirm that tests actually ran;
  Xcode can succeed after running zero tests.
- Build the daemon with `(cd daemon && cargo build --release)`. Preserve the
  real exit status of builds and tests; use `set -o pipefail` with pipelines.

Detailed build, reload, socket-driving, screenshot, log, and performance
workflows: [`docs/development-workflows.md`](docs/development-workflows.md).

## Project invariants

### Ghostty and UI

- Never add an environment variable after `ghostty_init`. Put all writes in
  `GhosttyEnvironment` in `Sources/GhosttyApp.swift` and use
  `GhosttyEnvironment.setValue(_:forName:)`. The late
  `ghostty_sync_environ()` repair is a safety net, not permission to write late.
- Do not add an app-level display link or call `ghostty_surface_draw` manually;
  rely on Ghostty wakeups and its renderer.
- Mount `SurfaceSearchOverlay` from `GhosttySurfaceScrollView` in
  `Sources/GhosttyTerminalView.swift`, never from a SwiftUI panel container.
- Declare custom drag-and-drop UTTypes in `Resources/Info.plist` under
  `UTExportedTypeDeclarations`.
- `vendor/bonsplit` is tracked vendored code, not a submodule.

The environment failure history and fork contract live in
[`docs/ghostty-fork.md`](docs/ghostty-fork.md).

### Socket command threading policy

- Parse, validate, dedupe, and coalesce telemetry off-main. Never use
  `DispatchQueue.main.sync` for hot paths such as `report_*`, `ports_kick`, or
  status/progress/log updates.
- Schedule only the minimal model/UI mutation with `DispatchQueue.main.async`.
  Direct AppKit/Ghostty UI operations and exact synchronous UI snapshots may
  run on the main actor.
- New socket commands default to off-main; document any main-thread exception
  in code.

### Socket focus policy

- Socket and CLI commands must not activate the app, raise a window, or steal
  macOS focus.
- Only explicit focus-intent commands may change in-app selection: `window.focus`,
  `workspace.select/next/previous/last`, `surface.focus`, `pane.focus/last`,
  browser focus commands, and their v1 equivalents.
- Every other command must preserve the current focus context.

### Ghostty submodule

`ghostty` is the only submodule and points to `JINWOO-J/ghostty`. Work on its
`main` branch, push the submodule commit to `origin/main`, and verify
`git merge-base --is-ancestor HEAD origin/main` before committing the parent
pointer. Never leave a submodule commit detached or reachable only from a
temporary branch. Update [`docs/ghostty-fork.md`](docs/ghostty-fork.md) with
fork changes.

After pulling a changed submodule pointer or `.gitmodules`, run
`./scripts/sync-submodules.sh`.

## Testing

- Default to socket E2E for app behavior. New tests go in `tests_v2/`.
- Run socket E2E only through the `mac-sub` runner, never on the development
  host. The runner can terminate locally running term-mesh apps.
- Reserve XCUITest on `term-mesh-vm` for OS key routing, menu equivalents,
  system dialogs, Accessibility interaction, and pixels the socket cannot test.
- Reproduce UI bugs with a tagged Debug app and verify both socket state and a
  full-screen screenshot. For performance issues, measure A/B/A2 with
  `./scripts/perf-sample.sh`; do not infer from feel.

Commands and test-authoring rules: [`tests/CLAUDE.md`](tests/CLAUDE.md).

## Team operations

When term-mesh is active (`TERMMESH_SOCKET` is set or a
`/tmp/term-mesh*.sock` exists), use the Rust `tm-agent` CLI for every team
operation. Do not use OMC `TeamCreate`, `SendMessage`, `Task*`, or `TeamDelete`;
they create team state the app cannot see. If OMC requests TEAM mode, use
`/team`, never `/oh-my-claudecode:team`.

- `/team-up`: adopt the current pane and create the first team.
- `/team`: change or inspect team membership.
- `/tm`: dispatch and collect work; it changes membership only with `--ensure`.
- `/tm-op`: run a structured strategy on an existing team.
- Wait with `tm-agent wait --timeout <seconds> --mode any`; do not poll with
  `sleep` plus `tm-agent read`. A timeout is not success.
- Concurrent writers need disjoint file ownership or isolated worktrees. Name
  owned and forbidden paths in each task capsule. Only one owner may push a
  branch.
- Verify a worker's real host and path before assigning checks. Linux workers
  cannot run Xcode; Swift changes still need local macOS integration testing.
- Workers must use the reply contract in `.agent-runbooks/_common.md`. Read
  `tm-agent collect --headers` or `tm-agent reports --summary` before opening a
  referenced full report.

Canonical details: [team lifecycle](.claude/commands/team.md),
[dispatch and synthesis](.claude/commands/tm.md),
[worker replies](.agent-runbooks/_common.md), and
[x-kit routing](docs/x-kit-integration.md). Current flags come from
`tm-agent --help`.

## Operational routing

- Native agent profiles, bridge selection, remote environment, and PATH rules:
  [`docs/native-agent-panes.md`](docs/native-agent-panes.md).
- Reclaim agent worktrees, results, logs, and build caches with `tm-agent gc`;
  never delete those directories directly. `sweep` is a dry-run unless
  `--apply` is supplied, and safety blockers still win. See
  [`docs/disk-reclamation.md`](docs/disk-reclamation.md).
- Release only through `/release`. `CHANGELOG.md` is the sole changelog; cover
  every commit since the last tag in user-facing language and upload the dSYM.
  The complete workflow is [`.claude/commands/release.md`](.claude/commands/release.md).
- When adding a leader command, update its Claude command, Codex prompt,
  Codex skill (`Resources/CodexSkills/<name>/SKILL.md`, so `$<name>` works in
  Codex), installer managed-name lists, and IME alias map together.

## Lessons (x-humble)
<!-- Section managed by x-humble. Manual editing allowed. -->

- STOP: 같은 가설이 2회 실패해도 계속 밀어붙이는 것 — 가설 자체를 폐기하고 다른 방향(데이터/호스트/회귀)으로 전환. (L3, confirmed 4 times, 2026-08-20)
- STOP: 원격 E2E host에서 Release·Debug·build·daemon 교체·복수 project를 겹쳐 실행하는 것 — 한 번에 한 topology만 실행하고 CPU/RSS/process baseline 이탈 시 즉시 중단. (L9, confirmed 1 times, 2026-08-20)
- START: UI/렌더링 버그 디버깅 시 코드·아키텍처 추론 전에 런타임 ground-truth(계측·바이트 단위 로그)부터 확인. (L2, confirmed 3 times, 2026-07-20)
- START: 검증 전에 실행 topology를 고정하고 PID·binary path·socket owner·state directory·project 생성 위치를 기록 — Release/Debug와 local/relay 결과를 섞지 않기. (L4, confirmed 2 times, 2026-08-20)
- START: 실패한 기능에 "동작하는 선례"(플러그인·유사 구현)가 있으면 내 가설 실험 전에 그 구현 전체를 독해 — source된 파일 포함. 부분 독해는 답을 옆에 두고 우회하게 만든다. (L5, confirmed 1 times, 2026-07-20)
- START: 같은 결함 클래스가 2회째 나타나면 지점 수정 전에 클래스 인벤토리부터 — 관련 상태 전이 목록과 불변식(고아 프로세스 0, 기록 소실 0 등)을 명시하고, 수정은 그 불변식을 검증하는 테스트와 함께. (L6, confirmed 1 times, 2026-08-19)
- START: relay E2E는 production socket owner → 외부 project 생성 → exact project.presentation → exact workspace/pane → A/B/A2 순서의 hard gate로 실행 — 한 단계라도 실패하면 성공 판정과 다음 단계 금지. (L8, confirmed 1 times, 2026-08-20)
- START: daemon/Project health는 control socket ping만 보지 말고 peer socket pathname의 실제 connect, 단일 owner, exact Project manifest, leader pane attachment까지 함께 검증 — 기존 relay fd가 살아 있어도 새 연결은 이미 죽었을 수 있다. (L10, confirmed 1 times, 2026-08-22)
