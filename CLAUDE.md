# term-mesh agent notes

## Initial setup

Run the setup script to initialize submodules, install Metal Toolchain, and build GhosttyKit:

```bash
./scripts/setup.sh
```

This handles: submodule init, Metal Toolchain download, xcframework-* tag cleanup, GhosttyKit build (cached per ghostty SHA), and symlink creation.

`setup.sh` activates the project git hooks automatically (the `commit-msg` hook
strips fenced code-block markers that agents tend to wrap commit messages in).
If you skip `setup.sh`, activate them manually once per clone:

```bash
git config core.hooksPath .githooks
```

## Syncing submodules on a fresh pull (multi-machine)

**IMPORTANT:** The `ghostty` submodule is pinned to `JINWOO-J/ghostty` (personal fork).
Whenever you `git pull` on any machine and see ` m ghostty` in `git status`, or the
pulled commit updated the submodule SHA / `.gitmodules` URL, run:

```bash
./scripts/sync-submodules.sh
```

This propagates `.gitmodules` URL changes into `.git/config` (`git submodule sync`)
and checks each submodule out at the SHA the parent pins (`git submodule update --init`).
Without this step the working tree keeps showing a "dirty" submodule and builds
may use a stale ghostty.

One-time convenience on each machine (optional, recommended):

```bash
git config --global submodule.recurse true   # auto-sync on future pull/checkout
```

## Local development

Run project setup once per fresh checkout:

```bash
./scripts/setup.sh
```

After code changes, run the full Debug build and launch an isolated tagged app:

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme term-mesh -configuration Debug -destination 'platform=macOS' -clonedSourcePackagesDirPath "$HOME/Library/Caches/term-mesh/SourcePackages" build
./scripts/reload.sh --tag <short-task-name>
```

Clean up the tagged app when verification is done:

```bash
./scripts/reload.sh --tag <short-task-name> --cleanup
```

Swift unit tests use the `term-mesh-unit` scheme. New test files must also be
registered in `GhosttyTabs.xcodeproj/project.pbxproj`; confirm the executed
test count because Xcode can otherwise report success after running zero tests.

Build `term-meshd` with `(cd daemon && cargo build --release)`. Preserve the
real exit status of every build and test command; do not hide it behind a
pipeline without `set -o pipefail`.

Detailed reload variants, GhosttyKit rebuild steps, tagged socket driving, debug
logs, screenshots, and performance sampling live in
[`docs/development-workflows.md`](docs/development-workflows.md).
## CLI profiles and Native Agent Panes

Profiles are stored in
`~/Library/Application Support/term-mesh/cli-profiles.json` and apply to GUI
and headless agents. Native panes are the default; `cursor` and `agy` are
Native-only because they have no interactive terminal stdin channel.

Claude speaks NDJSON directly. Codex, Kiro, Cursor, and agy use the compiled
Rust `tm-agent-bridge` by default; the Python bridge is a compatibility
fallback selected with `TERMMESH_BRIDGE_IMPL=python`.

Remote native agents load environment in this order:

1. the account's Bourne-compatible login profile;
2. `~/.profile` when Bash or zsh would otherwise skip it;
3. `~/.config/term-mesh/agent-env`;
4. explicit peer-host environment values.

`/etc/passwd` is authoritative for the account shell. Change it with `chsh`.
Use `agent-env` for simple `KEY=value` or `export KEY=value` entries and do
not print from the file. Profile failures and key presence are shown without
exposing values.

Peer `PATH` values append to the safe bridge baseline. List only additional
directories; never include literal `$PATH`. Use an absolute CLI path when a
specific binary must win.

Profile behavior, native rendering contracts, environment diagnostics, and
verification commands live in
[`docs/native-agent-panes.md`](docs/native-agent-panes.md).
## UI debugging and performance

Reproduce UI bugs yourself with a tagged Debug app before asking the user to
click through them:

```bash
./scripts/reload.sh --tag <short-task-name> --allow-all
```

Drive its `/tmp/term-mesh-debug-<tag>.sock`, then verify both the debug state
and a full-screen screenshot. Socket state can be correct while SwiftUI pixels
remain stale.

The active Debug log is:

```bash
tail -f "$(cat /tmp/term-mesh-last-debug-log-path 2>/dev/null || echo /tmp/term-mesh-debug.log)"
```

For performance complaints, measure instead of inferring:

```bash
./scripts/perf-sample.sh --label <condition> --json
```

A non-zero sampler exit means unusable data, not a regression. Keep hands off
the machine during sampling and interleave A/B/A2 comparisons to separate code
effects from workload decay. Full commands, socket examples, screenshot
pitfalls, metrics, and verdict meanings are in
[`docs/development-workflows.md`](docs/development-workflows.md).
## Disk reclamation (`tm-agent gc`)

Use `tm-agent gc` for daemon worktrees, delegated worktrees, peer project
checkouts, results, logs, and build caches:

```bash
tm-agent gc status
tm-agent gc plan [--category X] [--deep]
tm-agent gc sweep             # dry-run
tm-agent gc sweep --apply
```

Dry-run is the default. Dirty worktrees, unpushed commits, and active
session/task references remain blocked even with `--apply`; `--force`
relaxes only the `unopenable` blocker. Do not replace this with direct
directory deletion because git worktree registration also needs cleanup.

Detailed ownership, unattended sweep limits, tagged-build cache behavior, peer
disk warnings, and destructive-path tests live in
[`docs/disk-reclamation.md`](docs/disk-reclamation.md).
## Pitfalls

- **Never add an environment variable after `ghostty_init`.** It records the address
  of the process environment block, and libc moves that block when `setenv` adds a
  name that was not already there — ghostty then reads freed memory. Overwriting an
  existing name is fine (libc replaces that entry in place); adding is not. All such
  writes belong in `GhosttyEnvironment` (`Sources/GhosttyApp.swift`), which runs
  before `ghostty_init`; route new ones through `GhosttyEnvironment.setValue(_:forName:)`.
  A late addition there is repaired — it calls the fork's `ghostty_sync_environ()`,
  which hands ghostty the new address — and a DEBUG build logs
  `ghostty.env.added_after_init` naming the value. **The repair is a safety net, not
  a licence:** fix the ordering, because anything that reads the environment between
  the write and the sync still reads the stale block.

  This shipped as v0.174.0 and was fixed in v0.174.1. It cost XDG path resolution:
  "Ghostty Settings…" returned an empty path and did nothing, Reload Configuration
  rebuilt the config without the user's file, and surface creation crashed in
  `ghostty_surface_new` with a faulting address of `0x415441445f474458` — that is
  `XDG_DATA` in little-endian bytes, a fragment of the environment read as a pointer.

  **It only reproduces from Dock/Finder/`brew`.** A shell launch already has `TERM`
  and `TERM_PROGRAM`, so those writes overwrite rather than add and nothing moves.
  Reproduce with `env -i HOME="$HOME" PATH=/usr/bin:/bin USER="$USER" open -n <app>`;
  a Debug build launched by `reload.sh` inherits the shell environment and will look
  fine. Measure with the terminal grid (`stty size`), which moves when font-size is
  lost, not by eye.
- **Custom UTTypes** for drag-and-drop must be declared in `Resources/Info.plist` under `UTExportedTypeDeclarations` (e.g. `com.splittabbar.tabtransfer`, `com.termmesh.sidebar-tab-reorder`).
- Do not add an app-level display link or manual `ghostty_surface_draw` loop; rely on Ghostty wakeups/renderer to avoid typing lag.
- **Terminal find layering contract:** `SurfaceSearchOverlay` must be mounted from `GhosttySurfaceScrollView` in `Sources/GhosttyTerminalView.swift` (AppKit portal layer), not from SwiftUI panel containers such as `Sources/Panels/TerminalPanelView.swift`. Portal-hosted terminal views can sit above SwiftUI during split/workspace churn.
- **Submodule safety:** `ghostty` is the only git submodule. When modifying it, always push the submodule commit to its remote `main` branch BEFORE committing the updated pointer in the parent repo. Never commit on a detached HEAD or temporary branch — the commit will be orphaned and lost. Verify with: `cd ghostty && git merge-base --is-ancestor HEAD origin/main`.
- **`vendor/bonsplit` is vendored code, not a submodule** (converted in `c56fdbe1`). Its files are tracked directly by this repo — edit and commit them like any other source file; no submodule push/pointer dance.

## Socket command threading policy

- Do not use `DispatchQueue.main.sync` for high-frequency socket telemetry commands (`report_*`, `ports_kick`, status/progress/log metadata updates).
- For telemetry hot paths:
  - Parse and validate arguments off-main.
  - Dedupe/coalesce off-main first.
  - Schedule minimal UI/model mutation with `DispatchQueue.main.async` only when needed.
- Commands that directly manipulate AppKit/Ghostty UI state (focus/select/open/close/send key/input, list/current queries requiring exact synchronous snapshot) are allowed to run on main actor.
- If adding a new socket command, default to off-main handling; require an explicit reason in code comments when main-thread execution is necessary.

## Socket focus policy

- Socket/CLI commands must not steal macOS app focus (no app activation/window raising side effects).
- Only explicit focus-intent commands may mutate in-app focus/selection (`window.focus`, `workspace.select/next/previous/last`, `surface.focus`, `pane.focus/last`, browser focus commands, and v1 focus equivalents).
- All non-focus commands should preserve current user focus context while still applying data/model changes.

## tm-op strategy commands

`/tm-op` runs structured strategies on an existing term-mesh team. Use
`/tm-op` without arguments for interactive selection. Strategy behavior,
options, and examples are defined in `.claude/commands/tm-op.md`; Codex uses
the matching `Resources/CodexPrompts/tm-op.md` shim.
## Team agent system (OMC override)

When term-mesh is active (`TERMMESH_SOCKET` is set or
`/tmp/term-mesh*.sock` exists), every team operation must use the Rust
`tm-agent` CLI. Do not use `TeamCreate`, `SendMessage`, `TaskCreate`,
`TaskList`, `TaskGet`, `TaskUpdate`, or `TeamDelete`; they create a
separate team state that the app cannot see.

Use the project commands, which all route through `tm-agent`:

| Command | Responsibility | Canonical source |
|---|---|---|
| `/team-up` | Adopt the current pane and create the first team | `.claude/commands/team-up.md` |
| `/team` | Add, remove, swap, inspect, or destroy members | `.claude/commands/team.md` |
| `/tm` | Dispatch work; never changes team composition unless `--ensure` is explicit | `.claude/commands/tm.md` |
| `/tm-op` | Run structured multi-agent strategies | `.claude/commands/tm-op.md` |

If OMC emits `[MODE: TEAM]` or `[MAGIC KEYWORD: TEAM]`, use `/team`;
never invoke `/oh-my-claudecode:team`.

Codex shims live in `Resources/CodexPrompts/` and are installed into
`~/.codex/prompts/`. When adding a leader command, update its Claude command,
Codex prompt, installer managed-name lists, and the IME alias map together.

### Operating contract

- Panes are disposable workers. Durable state belongs in the task board,
  `~/.term-mesh/results/`, runbook digests, and `TM-PROTOCOL-v1` capsules.
- Use `tm-agent wait --timeout <seconds> --mode any`; never poll with
  `sleep N && tm-agent read`.
- Use `tm-agent recycle <agent>` only for idle or checkpointed workers.
  `tm-agent restart <agent> --hard` is the recovery escape hatch.
- Dispatch only dependency-ready tasks. Timeout is not success.
- Concurrent writes in one checkout require disjoint file ownership or
  worktree isolation. Distinct checkouts still need one branch owner and
  serialized pushes.
- Split parallel fixes by file ownership, not by finding count. A task capsule
  must name owned files, forbidden files, and how to request ownership expansion.
- Check the worker's real path and host before assigning verification. Linux
  peers may edit Swift but cannot run Xcode; their changes require a local
  integration build.
- Generic peer workers can reliably return only `tm-agent reply`. Do not ask
  them to retry `msg`, `inbox`, or `task` RPC failures; put all required
  information in the reply.
- For auto-fix tasks, call `tm-agent task fix-attempt <task_id>` before each
  correction attempt.

### Result contract

Every worker reply starts with:

```
STATUS: DONE|BLOCKED|NEEDS_REVIEW
FILES: <paths or none>
VERIFY: <one verification command or n/a>
NEXT: <one leader action or NONE>
FULL_REPORT: <unique detail file or n/a>
```

Socket replies are truncated at 1500 characters. Write long details first to a
unique path such as
`~/.term-mesh/results/<team>/<task_id>-full.md`, then reference it in
`FULL_REPORT`. Never use `<task_id>.md` or an `*-reply.md` alias as the
detail path because `tm-agent reply` replaces those envelope files.

Read `tm-agent collect --headers` or `tm-agent reports --summary` first.
Open `FULL_REPORT` only when the header, verification, or cross-agent result
requires it.

### Detailed references

- CLI lifecycle and examples: `.claude/commands/team.md`
- Dispatch, collection, and synthesis: `.claude/commands/tm.md`
- Worker reply rules: `.agent-runbooks/_common.md`
- Role-specific output: `.agent-runbooks/<role>.md`
- Parallel policy and xm routing: `Sources/LeaderParallelPolicy.swift`,
  `docs/x-kit-integration.md`
- Panel task mirroring: `docs/xk-panel-phase2.md`
- Current CLI flags: `tm-agent --help` and `tm-agent <command> --help`

## E2E tests

term-mesh has two e2e layers. **Default to socket e2e**; reserve XCUITest for what the socket can't reach.

- **Socket e2e (`tests_v2/` via `termmesh.py`)** — the standard for app logic, layout, focus, splits, workspaces, browser, notifications, CLI parity, and regressions. Authoring/running rules live in **[`tests/CLAUDE.md`](tests/CLAUDE.md)** (single source of truth; auto-loads when working in `tests/` or `tests_v2/`). New tests go in `tests_v2/`.
- **XCUITest (`termMeshUITests/`)** — only for OS-level key routing, menu key-equivalents, system dialogs, and Accessibility-driven interaction.

Run socket E2E on the dedicated `jinwoos-macbook-pro` runner through its
`mac-sub` SSH alias (never on the development host):

```bash
# Socket e2e suites
ssh mac-sub 'cd /Users/jinwoo/work/term-mesh && ./scripts/run-tests-v2.sh'

# XCUITest remains on the UTM VM
ssh term-mesh-vm 'cd /Users/jinwoo/term-mesh/GhosttyTabs && xcodebuild -project GhosttyTabs.xcodeproj -scheme term-mesh -configuration Debug -destination "platform=macOS" -only-testing:termMeshUITests/UpdatePillUITests test'
```

## Basic tests

Run basic socket-based automated tests on `jinwoos-macbook-pro` through the
`mac-sub` SSH alias (never on the development host):

```bash
ssh mac-sub 'cd /Users/jinwoo/work/term-mesh && xcodebuild -project GhosttyTabs.xcodeproj -scheme term-mesh -configuration Debug -destination "platform=macOS" build && pkill -x "term-mesh DEV" || true && APP=$(find /Users/jinwoo/Library/Developer/Xcode/DerivedData -path "*/Build/Products/Debug/term-mesh DEV.app" -print -quit) && open "$APP" --env TERMMESH_SOCKET_MODE=allowAll && for i in {1..20}; do [ -S /tmp/term-mesh-debug.sock ] && break; sleep 0.5; done && python3 tests/test_update_timing.py && python3 tests/test_signals_auto.py && python3 tests/test_ctrl_socket.py && python3 tests/test_notifications.py'
```

## Ghostty submodule workflow

Ghostty submodule is pinned to `JINWOO-J/ghostty` (personal fork of `manaflow-ai/ghostty`).
Changes must be committed in the submodule and pushed to `origin` (JINWOO-J/ghostty) before
updating the parent pointer.

Keep `docs/ghostty-fork.md` up to date with any fork changes and conflict notes.

```bash
cd ghostty
git remote -v  # origin = JINWOO-J/ghostty (fork), upstream = manaflow-ai/ghostty (READ only)
git checkout -b <branch>
git add <files>
git commit -m "..."
git push origin <branch>
```

To keep the fork up to date with upstream (`manaflow-ai/ghostty`):

```bash
cd ghostty
git fetch upstream
git checkout main
git merge upstream/main
git push origin main
```

Then update the parent repo with the new submodule SHA:

```bash
cd ..
git add ghostty
git commit -m "Update ghostty submodule"
```

## Release

Use the `/release` command to prepare a new release. This will:
1. Determine the new version (bumps minor by default)
2. Gather commits since the last tag and update the changelog
3. Update `CHANGELOG.md` (the only changelog in this repo — there is no
   `docs-site/`; the instruction to update one there outlived the directory)
4. Run `./scripts/bump-version.sh` to update both versions
5. Commit, tag, and push
6. Upload dSYM debug symbols to Sentry (`./scripts/upload-dsym.sh --build`)

There is no PR or branch CI for `release/*`: `ghostty-prebuild` runs only on
pushes to `main` / `feat/**`, while `release-linux` runs only on a `v*` tag
push. Do not wait for branch checks during a release.

Running from a non-`main` branch: `/release` cuts the release branch from the current HEAD, so the branch's commits are **folded into the release PR** and squash-merged to `main` together with the version bump (one squash commit). The command first guards a clean tree and that the branch isn't behind `origin/main`. To keep the feature commits as a distinct change, merge the branch to `main` on its own PR first, then run `/release` from `main`.

Version bumping:

```bash
./scripts/bump-version.sh          # bump minor (0.15.0 → 0.16.0)
./scripts/bump-version.sh patch    # bump patch (0.15.0 → 0.15.1)
./scripts/bump-version.sh major    # bump major (0.15.0 → 1.0.0)
./scripts/bump-version.sh 1.0.0    # set specific version
```

This updates both `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` (build number).

Manual release steps (if not using the command):

```bash
git tag vX.Y.Z
git push origin vX.Y.Z
./scripts/upload-dsym.sh --build   # builds Release and uploads dSYM to Sentry
```

Notes:
- Versioning: bump the minor version for updates unless explicitly asked otherwise.
- Changelog: `CHANGELOG.md` is the only one. Write for the person running the
  app, not the person who wrote the diff: what changed for them, and what it
  used to do wrong. A release whose changelog covers one PR out of eighteen has
  happened here — check `[Unreleased]` against `git log <last tag>..HEAD`
  before cutting.
- Sentry dSYM: required for symbolicated crash reports (EXC_BAD_ACCESS frames otherwise show `None`). `./scripts/upload-dsym.sh` without `--build` uploads the latest Release dSYM already in DerivedData.

## Lessons (x-humble)
<!-- Section managed by x-humble. Manual editing allowed. -->
- STOP: 같은 가설이 2회 실패해도 계속 밀어붙이는 것 — 가설 자체를 폐기하고 다른 방향(데이터/호스트/회귀)으로 전환. (L3, confirmed 3 times, 2026-07-20)
- START: UI/렌더링 버그 디버깅 시 코드·아키텍처 추론 전에 런타임 ground-truth(계측·바이트 단위 로그)부터 확인. (L2, confirmed 3 times, 2026-07-20)
- START: 실패한 기능에 "동작하는 선례"(플러그인·유사 구현)가 있으면 내 가설 실험 전에 그 구현 전체를 독해 — source된 파일 포함. 부분 독해는 답을 옆에 두고 우회하게 만든다. (L5, confirmed 1 times, 2026-07-20)
