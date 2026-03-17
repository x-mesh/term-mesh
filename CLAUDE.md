# term-mesh agent notes

## Initial setup

Run the setup script to initialize submodules, install Metal Toolchain, and build GhosttyKit:

```bash
./scripts/setup.sh
```

This handles: submodule init, Metal Toolchain download, xcframework-* tag cleanup, GhosttyKit build (cached per ghostty SHA), and symlink creation.

## Local dev

After making code changes, always run the reload script with a tag to launch the Debug app:

```bash
./scripts/reload.sh --tag fix-zsh-autosuggestions
```

After making code changes, always run the build:

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme term-mesh -configuration Debug -destination 'platform=macOS' build
```

When rebuilding GhosttyKit.xcframework, always use Release optimizations.
Clean any xcframework-* tags first to avoid zig build crashes:

```bash
cd ghostty && git tag -l 'xcframework-*' | while read -r t; do git tag -d "$t"; done 2>/dev/null; zig build -Demit-xcframework=true -Doptimize=ReleaseFast
```

When rebuilding term-meshd (the Rust daemon):

```bash
cd daemon && cargo build --release
```

`reload` = kill and launch the Debug app only (tag required):

```bash
./scripts/reload.sh --tag <tag>
```

`reloadp` = kill and launch the Release app:

```bash
./scripts/reloadp.sh
```

`reloads` = kill and launch the Release app as "term-mesh STAGING" (isolated from production term-mesh):

```bash
./scripts/reloads.sh
```

`reload2` = reload both Debug and Release (tag required for Debug reload):

```bash
./scripts/reload2.sh --tag <tag>
```

For parallel/isolated builds (e.g., testing a feature alongside the main app), use `--tag` with a short descriptive name:

```bash
./scripts/reload.sh --tag fix-blur-effect
```

This creates an isolated app with its own name, bundle ID, socket, and derived data path so it runs side-by-side with the main app. Important: use a non-`/tmp` derived data path if you need xcframework resolution (the script handles this automatically).

Before launching a new tagged run, clean up any older tags you started in this session (quit old tagged app + remove its `/tmp` socket/derived data).

## Debug event log

All debug events (keys, mouse, focus, splits, tabs) go to a unified log in DEBUG builds:

```bash
tail -f "$(cat /tmp/term-mesh-last-debug-log-path 2>/dev/null || echo /tmp/term-mesh-debug.log)"
```

- Untagged Debug app: `/tmp/term-mesh-debug.log`
- Tagged Debug app (`./scripts/reload.sh --tag <tag>`): `/tmp/term-mesh-debug-<tag>.log`
- `reload.sh` writes the current path to `/tmp/term-mesh-last-debug-log-path`

- Implementation: `vendor/bonsplit/Sources/Bonsplit/Public/DebugEventLog.swift`
- Free function `dlog("message")` — logs with timestamp and appends to file in real time
- Entire file is `#if DEBUG`; all call sites must be wrapped in `#if DEBUG` / `#endif`
- 500-entry ring buffer; `DebugEventLog.shared.dump()` writes full buffer to file
- Key events logged in `AppDelegate.swift` (monitor, performKeyEquivalent)
- Mouse/UI events logged inline in views (ContentView, BrowserPanelView, etc.)
- Focus events: `focus.panel`, `focus.bonsplit`, `focus.firstResponder`, `focus.moveFocus`
- Bonsplit events: `tab.select`, `tab.close`, `tab.dragStart`, `tab.drop`, `pane.focus`, `pane.drop`, `divider.dragStart`

## Pitfalls

- **Custom UTTypes** for drag-and-drop must be declared in `Resources/Info.plist` under `UTExportedTypeDeclarations` (e.g. `com.splittabbar.tabtransfer`, `com.termmesh.sidebar-tab-reorder`).
- Do not add an app-level display link or manual `ghostty_surface_draw` loop; rely on Ghostty wakeups/renderer to avoid typing lag.
- **Terminal find layering contract:** `SurfaceSearchOverlay` must be mounted from `GhosttySurfaceScrollView` in `Sources/GhosttyTerminalView.swift` (AppKit portal layer), not from SwiftUI panel containers such as `Sources/Panels/TerminalPanelView.swift`. Portal-hosted terminal views can sit above SwiftUI during split/workspace churn.
- **Submodule safety:** When modifying a submodule (ghostty, vendor/bonsplit, etc.), always push the submodule commit to its remote `main` branch BEFORE committing the updated pointer in the parent repo. Never commit on a detached HEAD or temporary branch — the commit will be orphaned and lost. Verify with: `cd <submodule> && git merge-base --is-ancestor HEAD origin/main`.

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

## Team agent system (OMC override)

**CRITICAL OVERRIDE:** When running inside term-mesh (i.e., `TERMMESH_SOCKET` env var is set or
a socket exists at `/tmp/term-mesh*.sock` or `/tmp/term-mesh.sock`), ALL team operations MUST use
`tm-agent` (Rust binary, ~2ms). This applies regardless of how the team was triggered.

**Banned tools in term-mesh context:** `TeamCreate`, `SendMessage`, `TaskCreate`, `TaskList`,
`TaskGet`, `TaskUpdate`, `TeamDelete`. These create a parallel, disconnected team state.

**Use instead:** The project-local `/team` command (`.claude/commands/team.md`), which routes
everything through `tm-agent`.

### OMC keyword override

If OMC's keyword detector fires `[MODE: TEAM]` or `[MAGIC KEYWORD: TEAM]`:
1. **Do NOT invoke `/oh-my-claudecode:team`** — it uses Claude Code native teams
2. **Instead invoke `/team`** (the project-local command) or use `tm-agent` directly

### Quick CLI reference

**All operations** use `tm-agent` (Rust, ~2ms; fallback `./scripts/tm-agent.sh` ~10ms):
```bash
# Team lifecycle
tm-agent create [N] [--claude-leader]
tm-agent destroy
tm-agent status
tm-agent list

# Leader → agent communication
tm-agent send <agent> '<instruction>'
tm-agent delegate <agent> '<instruction>'
tm-agent broadcast '<instruction>'
tm-agent read <agent> --lines 100
tm-agent collect --lines 100
tm-agent wait --timeout 120 --mode any
tm-agent brief <agent>

# Agent task lifecycle
tm-agent task start <task_id>
tm-agent task done <task_id> '<result>'
tm-agent task block <task_id> '<reason>'
tm-agent task review <task_id> '<summary>'
tm-agent heartbeat '<progress summary>'
tm-agent report '<result summary>'
tm-agent reply '<one-paragraph summary>'

# Messaging
tm-agent msg send '<text>'                    # to leader
tm-agent msg send '<text>' --to <agent_name>  # to another agent
tm-agent inbox                                # check messages
tm-agent msg list --from-agent <agent>        # list messages
tm-agent msg clear                            # clear queue

# Task board
tm-agent task list                        # list all tasks
tm-agent task create '<title>' --assign <agent>
tm-agent task get <id>
tm-agent task update <id> <status>
tm-agent task reassign <id> <agent>
tm-agent task unblock <id>
tm-agent task clear
```

## E2E mac UI tests

Run UI tests on the UTM macOS VM (never on the host machine). Always run e2e UI tests via `ssh term-mesh-vm`:

```bash
ssh term-mesh-vm 'cd /Users/term-mesh/GhosttyTabs && xcodebuild -project GhosttyTabs.xcodeproj -scheme term-mesh -configuration Debug -destination "platform=macOS" -only-testing:termMeshUITests/UpdatePillUITests test'
```

## Basic tests

Run basic automated tests on the UTM macOS VM (never on the host machine):

```bash
ssh term-mesh-vm 'cd /Users/term-mesh/GhosttyTabs && xcodebuild -project GhosttyTabs.xcodeproj -scheme term-mesh -configuration Debug -destination "platform=macOS" build && pkill -x "term-mesh DEV" || true && APP=$(find /Users/term-mesh/Library/Developer/Xcode/DerivedData -path "*/Build/Products/Debug/term-mesh DEV.app" -print -quit) && open "$APP" --env TERMMESH_SOCKET_MODE=allowAll && for i in {1..20}; do [ -S /tmp/term-mesh-debug.sock ] && break; sleep 0.5; done && python3 tests/test_update_timing.py && python3 tests/test_signals_auto.py && python3 tests/test_ctrl_socket.py && python3 tests/test_notifications.py'
```

## Ghostty submodule workflow

Ghostty changes must be committed in the `ghostty` submodule and pushed to the `manaflow-ai/ghostty` fork.
Keep `docs/ghostty-fork.md` up to date with any fork changes and conflict notes.

```bash
cd ghostty
git remote -v  # origin = upstream, manaflow = fork
git checkout -b <branch>
git add <files>
git commit -m "..."
git push manaflow <branch>
```

To keep the fork up to date with upstream:

```bash
cd ghostty
git fetch origin
git checkout main
git merge origin/main
git push manaflow main
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
3. Update `CHANGELOG.md` and `docs-site/content/docs/changelog.mdx`
4. Run `./scripts/bump-version.sh` to update both versions
5. Commit, tag, and push

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
```

Notes:
- Versioning: bump the minor version for updates unless explicitly asked otherwise.
- Changelog: always update both `CHANGELOG.md` and the docs-site version.
