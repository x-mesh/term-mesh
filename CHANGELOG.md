# Changelog

All notable changes to term-mesh are documented here.

## [0.95.0] - 2026-04-17

### Fixed
- **Ctrl+C no longer leaks `9;5u` text after a TUI app crashes or is killed** — TUI apps (Claude Code CLI, nvim, helix, etc.) enable the kitty keyboard protocol's "disambiguate escape codes" mode via `CSI > 1 u` on startup and are expected to disable it via `CSI < u` on exit. If the app crashed, was force-quit, or exited abnormally (for example after an API error during `/compact`), the flags remained on the terminal's protocol stack, causing the next Ctrl+C at the shell prompt to be encoded as `\e[99;5u` — which the shell would then echo to the screen as `9;5u9;5u9;5u…` instead of delivering SIGINT. term-mesh's zsh and bash shell integration now automatically pops any leftover kitty keyboard flags on every prompt render, so Ctrl+C recovers cleanly on the very next prompt without any user configuration or terminal restart. Running TUIs are unaffected because they re-push their flags on each prompt cycle.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.94.0] - 2026-04-17

### Fixed
- **Observer/NSAlert leak when two deferred alerts race for the same key-window transition** — the v0.93.3 fix for the notification-permission App Hanging warning (Sentry TERM-MESH-18) installed a one-shot `NSWindow.didBecomeKeyNotification` observer to wait for a key window before presenting the sheet. If two alerts queued before any window was focused (e.g. permission prompt + quit warning while the app was activated from the menu bar) and a window then became key, the first observer would attach its sheet and the second observer fell through its guard without deregistering — leaking the observer, the `NSAlert`, and its completion closure for the remainder of the session. A Settings/About window with an attached sheet could also silently swallow an alert intended for a terminal window. The observer now re-registers cleanly when the key window already has a sheet attached, so the alert still surfaces on the next key-window transition without leaking.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.93.3] - 2026-04-17

### Fixed
- **App hang when opening a terminal whose last working directory is on a stalled filesystem** — if the previous working directory (OSC 7 / session snapshot) pointed at an unmounted network share, a spun-down external drive, or a broken SSHFS, Ghostty's internal `openat(workingDir)` during surface creation blocked the main thread for 2 s+ and tripped macOS's App Hanging watchdog (Sentry TERM-MESH-17). The working directory is now probed on a background queue with a 300 ms timeout before handing it to Ghostty; an unreachable path falls back to `$HOME` so a new terminal always opens immediately.
- **App hang when the notification-permission prompt appeared without a focused window** — `TerminalNotificationStore.promptToEnableNotifications` falls through `NSAlert.presentAsSheet` to a fallback path when no key/main window is available. That fallback used `runModal()`, which spins a nested modal event loop on the main thread and trips the App Hanging watchdog if the app is activated from the menu bar / background with no visible window (Sentry TERM-MESH-18). The fallback now defers presentation via a one-shot `NSWindow.didBecomeKeyNotification` observer — the sheet shows as soon as any window becomes key, without ever blocking main.
- **Possible app hang during SwiftUI layout involving drag-and-drop** — `FileDropOverlayView.hitTest` used to read `NSPasteboard(name: .drag).types` on every AppKit hit test, including idle-layout probes that run outside any active drag. If a prior external (Finder) drag left an `NSFilePromiseReceiver` on the drag pasteboard, macOS could wake the receiver during that probe and stall the main thread (Sentry TERM-MESH-19). The pasteboard read is now gated on an active drag-motion event; idle layout no longer touches the drag pasteboard at all. No behavior change for real drags.
- **New windows no longer stack on top of the previously-focused window** — `LastWindowPosition.restore()` used to apply the saved window position to every new window, so each new window jumped to the position of the most recently focused window and the cascade logic only offset it slightly. It now restores only the first window per app launch; subsequent new windows cascade from fresh positions. (ghostty submodule)

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.93.2] - 2026-04-16

### Fixed
- **`claude` wrapper `stop` / `notification` hooks no longer surface "Tab not found" errors to Claude Code's Stop hook log** — `term-mesh claude stop` / `claude notification` are best-effort telemetry auto-injected by the wrapper; stale session mappings (tab closed/renamed between launches, or `claude -p` subprocesses with stale workspace IDs) previously bubbled up as hook failures and spammed Claude Code's hook log. Workspace resolve failures and `notify_target` errors in the `stop`, `idle`, and `notification` subcommands are now caught and the hook returns `OK` instead of throwing. (`CLI/term-mesh.swift`)
- **`make dmg` no longer fails on stale `/Volumes/term-mesh` mounts or leftover `rw.*.dmg` intermediates** — repeated DMG builds in the same session could hit "resource busy" when a previous `/Volumes/term-mesh` mount hadn't been detached, and `create-dmg` occasionally leaves the read-write intermediate behind when Finder's detach is slow. `make dmg` now force-detaches any lingering `/Volumes/term-mesh` before and after `create-dmg` and removes `rw.*.term-mesh.dmg` intermediates so only the final UDZO image remains. (`Makefile`)

## [0.93.1] - 2026-04-15

### Fixed
- **App hang during periodic session save** — `TabManager.saveSessionState()` is called every 30 s and on tab/split churn; previously it ran JSON encoding and an `atomicWrite` on the main thread. The `rename()` behind `atomicWrite` triggers FSEvents/Darwin notify, and under file-watcher pressure this could block main for 2 s+ (Sentry TERM-MESH-2). Session snapshot is still captured on main (required by `@MainActor` isolation), but encoding and the disk write now run on a dedicated serial background queue.
- **Garbled terminal output when SSHing to servers without `xterm-ghostty` terminfo** — Ghostty defaults `TERM=xterm-ghostty`, which most remote hosts don't have. Shell redraw sequences were mis-interpreted, making every keystroke look like it echoed the previous autosuggestion. term-mesh now writes a baseline Ghostty config that enables `shell-integration-features = ssh-env,ssh-terminfo` out of the box; this installs the terminfo on the remote the first time you connect (falls back to `xterm-256color` if `tic` is unavailable). The baseline is loaded before the user config, so `~/.config/ghostty/config` can still override it.

### Changed
- **CLI symlinks moved from `~/bin` to `~/.local/bin`** — `make deploy` / `make deploy-prod` used to fail on machines without `~/bin` (the directory isn't created by default on macOS, and isn't on PATH in most default shell setups). Symlinks now go to `~/.local/bin`, which matches the XDG convention and is already on PATH for common setups. The Makefile creates the directory if it's missing.
- **Sentry dSYM upload is automatic on Release builds** — `make prod` / `make deploy-prod` / `make dmg` now run `sentry-cli debug-files upload --include-sources` at the end of the build. No-ops gracefully if `sentry-cli` is missing, unauthenticated, or no dSYMs are present, so unsigned-in contributors aren't blocked. Crash/hang reports from here on will be symbolicated with Swift file:line + source snippets.

## [0.93.0] - 2026-04-09

### Added
- **`tm-agent attach` / `tm-agent detach` — workspace-local agent management** — Add or remove agent panes inside the caller's current workspace without spawning a new one. First `attach` auto-creates a workspace-local team (`ws-<first8hex>` derived from the workspace UUID) and adopts the caller's pane as the team leader; subsequent attaches append agents to the same team. `detach <agent_name>` closes that agent's pane and removes it from the team; the last detach destroys the team while preserving the leader pane. Rejected if the workspace already hosts a `tm-agent create`-based team, so workspace-local and create-spawned teams never mix. `tm-agent create` behavior is unchanged.
- **`buildAgentPaneEnv` helper (single source of truth for agent pane env)** — Extracted from `createTeam` into `TeamOrchestrator.buildAgentPaneEnv(teamName:agentName:agentCli:windowId:workspaceId:)` so the workspace-local attach path and the existing create path construct the exact same agent environment. Guards against the 2026-03-19 regression where `TERMMESH_WINDOW_ID` / `TERMMESH_WORKSPACE_ID` went missing on spawned panes.
- **`addAgentPaneToWorkspace` helper (shared pane construction)** — Also extracted from `createTeam`, encapsulates the full CLI-specific invocation build (claude/codex/gemini/kiro), shell wrapping with worktree `cd`, env injection, split pane spawn, pane title, and `AgentMember` construction. Used by both `createTeam`'s agent loop and the new `attachToWorkspace`.
- **New JSON-RPC methods `team.attach` / `team.detach`** — Route through `dispatchTeamCommandAsync` and reuse `asyncTeamCreate`'s TabManager resolution precedence (`window_id` → `surface_id` → `workspace_id` → keyWindow) to prevent the 2026-03-17 multi-window routing regression. Both handlers run off-main with minimal `await MainActor.run` blocks and contain no `DispatchQueue.main.sync`.
- **Rust CLI `Commands::Attach` / `Commands::Detach`** — Auto-derive the team name from `TERMMESH_WORKSPACE_ID` via `resolve_workspace_team_name` when `TERMMESH_TEAM` is unset, validate agent names against `^[a-zA-Z0-9_-]{1,32}$` via `validate_agent_name`, and require `TERMMESH_PANEL_ID` / `TERMMESH_WORKSPACE_ID` context via `require_termmesh_context`. Errors surface with structured codes: `existing_gui_team`, `agent_name_conflict`, `team_not_found`, `agent_not_found`, `not_in_workspace`.
- **`tm-agent` Claude Code skill bundle** — `skills/tm-agent/SKILL.md` (328 lines) ships alongside `term-mesh`, `term-mesh-browser`, `term-mesh-debug-windows`, and `release`. Covers the full `tm-agent` CLI surface (create/attach/detach, messaging, task board, autonomous research/solve/consensus/swarm) with four end-to-end workflow examples, an invariants-and-gotchas section (socket focus policy, main-thread policy, adopted leader, send stagger, reply truncation), and a raw-RPC escape hatch.
- **CLAUDE.md `attach` / `detach` quick reference** — "Team agent system" section gains `tm-agent attach <type>` / `tm-agent detach <name>` examples noting the current-workspace-only semantics.

## [0.92.0] - 2026-04-09

### Added
- **`term-mesh-cli` Claude Code skill** — bundled skill teaches Claude (when running inside term-mesh) how to open browser splits, evaluate JavaScript in browser panels, navigate/click pages, and manage workspaces/panes via the `term-mesh` CLI. Build phase copies the skill into `Resources/claude-skills/` with a managed-file marker; `ClaudeCommandInstaller` installs it to `~/.claude/skills/` on launch and respects user-customized files.
- **README CLI usage section** — full command reference for window, workspace, surface, pane, browser, and team subcommands with worked examples.

### Changed
- **Slash command documentation refinements** — `.claude/commands/tm-op.md` extracted shared Result Collection block, added precedence rule for `--preset`/`--timeout`/`--rounds`, documented `tm-agent` binary fallback, added Autonomous Mode error-recovery subsection, defined stigmergy concept, and replaced literal `my-team` placeholders with `<team>`. `team-up.md` deduplicated command tables (links to `team.md` as canonical reference) and hoisted CRITICAL warning to top. `tm-bench.md` added explicit "Argument Parsing Precedence" section with worked examples for `agent N` + flag combinations.
- **Settings dashboard no longer auto-restarts daemon** — toggle/bind/port/password changes no longer auto-restart the daemon (reverts the auto-restart behavior introduced in 0.91.0; was causing UX friction).

### Fixed
- **Shell-integration path security** — escape shell-integration paths and sanitize temp file names across `DashboardController`, `SettingsView`, `TabManager`, and `TeamOrchestrator` to prevent shell injection through path interpolation.
- **TabManager refactor** — removed unnecessary `[weak self]` capture in `setTitle` closure (closure does not outlive `self`), added version-guard comment explaining the format compatibility strategy.

## [0.91.1] - 2026-04-08

### Fixed
- **Sleep/wake white-screen regression** — Removed the stale `suppressLayoutDuringDisplayReconfiguration` workaround (TERM-MESH-2). It was added to dodge a 2 s main-thread block from `NSHostingView.layout → CVDisplayLinkCreateWithCGDisplays`, but upstream Ghostty's 2025-06-16 renderer rework (`371d62a82`) moved macOS rendering to `IOSurfaceLayer`, so that blocker no longer exists. The leftover `contentView.isHidden = true/false` dance instead detached descendant `IOSurfaceLayer` contents on wake, leaving windows white until the user clicked. Removing the mechanism restores correct behavior with no measurable hang on current Ghostty.

## [0.91.0] - 2026-04-08

### Added
- **Dashboard preset switcher** — Overview / Team Ops / DevOps / Cost views with section visibility
- **Process Monitor tree view** — parent-child hierarchy with collapsible UI and Expand All/Collapse All
- **System Extended card** — Load Average bars, Swap usage, collapsible Network I/O (total + per-interface detail)
- **Per-Core CPU Heatmap** — color-coded grid showing per-core utilization
- **Anomaly detection** — high CPU sustained, repeated failure, no-heartbeat detection in daemon
- **Dashboard keyboard shortcut** — Cmd+Shift+D toggles the dashboard window
- **CLI: `new-split --type browser --url`** — one-step browser split creation
- **CLI: `close-surface --close-pane`** — collapse pane after closing all surfaces
- **CLI: `browser eval` scalar output** — string/number/bool printed directly without `--json`
- **Side-by-side card layout** — Watched Projects + Agent Status, Agent Sessions + Needs Attention, Daemon Tasks + Team Tasks

### Changed
- Settings dashboard toggle/bind/port/password now auto-restart the daemon (with debounce for port/password)
- WKWebView polling skip narrowed to dedicated dashboard window (split browser panels now poll correctly)
- Tagged builds (`./scripts/reload.sh --tag`) disable HTTP server to avoid port conflict with main app
- ProcessSnapshot now includes `ppid` for tree rendering

### Fixed
- **Initial cursor-in-middle-of-prompt bug** — terminal surfaces now force-refresh at 0.3s/0.8s/1.5s after launch to correct column count after SwiftUI layout settles (re-applies the c580530 fix that was reverted in c32830e)
- **Browser dashboard "disconnected"** — restored missing JS helpers (togglePid, toggleAllProcesses, updateProcessTree) that were accidentally deleted during section reorder
- **Mobile layout horizontal scroll** — reset `grid-column` on `#agents-card`/`#tasks-card`/`#team-tasks-card`/`#team-attention-card` in mobile media query, force inner grids to single/dual column
- **Card layout collapse to single column on Overview** — added agent/team cards to overview preset so paired cards stay side-by-side
- **Chart.js double-init error** — `cpuChart`/`timelineChart` initialized only in `window.onload` with destroy guards
- **Display type override** — `switchPreset` now uses `style.display = ''` instead of `'block'` so CSS grid/flex layouts are preserved
- **Sidebar Environment card visibility** — replaced hardcoded white background with theme-aware CSS variables

## [0.89.1] - 2026-04-07

### Changed
- Default Gemini model updated from `gemini-3.1-pro-preview` to `gemini-3.1-pro` (GA release)

## [0.88.1] - 2026-04-07

### Added
- `/tm-op research` strategy — invoke autonomous multi-agent research from the tm-op command palette

## [0.88.0] - 2026-04-07

### Added
- `tm-agent research <topic>` — autonomous multi-agent research with board.jsonl stigmergy coordination
  - Idle agent detection with graceful degradation (uses available agents, warns on shortfall)
  - Configurable depth (shallow/deep/exhaustive), round budget, timeout, web search toggle
  - Staggered dispatch with 3s intervals to reduce board write contention
  - Structured synthesis output with per-agent finding statistics

## [0.87.1] - 2026-04-07

### Fixed
- Dashboard metric cards (Teams, Agents, Open Tasks, Attention) now visible in dark theme — replaced hardcoded white background with theme-aware colors

## [0.87.0] - 2026-04-07

### Added
- Split pane layouts are now saved and restored across app restarts — no more manual re-splitting after relaunch
- Periodic session auto-save every 30 seconds for crash and force-quit resilience

### Fixed
- Memory growth in long-running agent teams — message history now capped at 500 per team with FIFO pruning

## [0.86.5] - 2026-04-07

### Fixed
- Terminal screen turning white after waking from sleep or monitor connect/disconnect — clicking was required to restore display

## [0.75.0] - 2026-03-21

### Added
- Default light theme for terminal — fresh installs now have proper light colors out of the box
- Auto-detect macOS system appearance and apply matching terminal theme in "System" mode
- Light/Dark theme pickers now show only matching themes (light themes for Light, dark themes for Dark)
- IME slash command picker discovers project-local commands from `.claude/commands/` (e.g. `/squash`)
- IME font zoom with Cmd+Plus/Minus shortcuts
- Plain arrow key pass-through when IME input is empty
- Stop/interrupt command for team agents

### Fixed
- Terminal always showing dark theme regardless of appearance setting
- IME Cmd+Z crash caused by stale undo stack after view teardown
- Option+Arrow keys in IME now send plain arrows instead of Alt-modified sequences
- Agent panels no longer counted in shell health assessment

## [0.74.0] - 2026-03-20

### Added
- Terminal settings GUI — configure font family, font size, light/dark theme, cursor style, cursor color, unfocused split opacity, and scrollback limit from Settings without editing config files
- 459 bundled ghostty themes available in theme picker
- System monospace fonts listed first in font picker with all fonts available

### Fixed
- Metal terminal surfaces no longer bleed through browser panels during pane zoom
- Infinite layout loops in portal sync and focus chains resolved
- IME command highlighting no longer triggers at line start — only after pipe/separator
- Worktree creation from an existing worktree now correctly resolves the main repo
- Agent Enter key delivery made reliable with atomic IME-style press/release pairs
- Worktree deletion now checks for uncommitted changes by default — dirty worktrees are protected unless explicitly force-removed
- Stale worktree cleanup during branch re-creation refuses to prune dirty worktrees

### Changed
- `worktree.remove` RPC now defaults to safe mode (rejects dirty worktrees); pass `force=true` to override

## [0.69.0] - 2026-03-17

### Fixed
- IME composition no longer strips trailing newline on Enter submit
- Team creation now routes to the correct window instead of always targeting the last active window
- Team name uniqueness is now enforced across all windows, not just the current one
- Agents in shared/isolated worktree mode now correctly start in the worktree directory

## [0.64.2] - 2026-03-16

### Fixed
- **tm-agent socket detection**: `detect_socket()` now checks `/tmp/term-mesh-last-socket-path` before glob fallback, avoiding ambiguity with multiple tagged debug sockets
- **tm-agent wait infinite loop**: `--interval 0` no longer causes an infinite loop (clamped to minimum 1 second)
- **tm-agent prompt consistency**: `agent_init_prompt` now instructs agents to use `tm-agent reply` (unified with `REPORT_SUFFIX` and `BROADCAST_SUFFIX`)
- **tm-agent RPC error surfacing**: `run_wait` and `run_create` now print warnings to stderr on RPC failures instead of silently ignoring them
- **tm-agent.sh reply**: Shell fallback `reply` command now correctly sends both `message.post` (type=report, to=leader) and `team.report`, matching Rust binary behavior

### Added
- `tests/test_tm_agent.py` — 34-test automated suite covering task lifecycle, messaging, reply integration, wait modes, and edge cases (`python3 tests/test_tm_agent.py --rounds 3`)
- `docs/tm-agent-architecture-review.md` — Architecture review with 6 identified issues and prioritized recommendations

### Changed
- `.claude/commands/team.md` — Added missing `task block`, `inbox`, `create` flags documentation; fixed `task review` signature

## [0.60.0] - 2026-02-21

### Added
- Tab context menu with rename, close, unread, and workspace actions ([#225](https://github.com/manaflow-ai/term-mesh/pull/225))
- Cmd+Shift+T reopens closed browser panels ([#253](https://github.com/manaflow-ai/term-mesh/pull/253))
- Vertical sidebar branch layout setting showing git branch and directory per pane
- JavaScript alert/confirm/prompt dialogs in browser panel ([#237](https://github.com/manaflow-ai/term-mesh/pull/237))
- File drag-and-drop and file input in browser panel ([#214](https://github.com/manaflow-ai/term-mesh/pull/214))
- tmux-compatible command set with matrix tests ([#221](https://github.com/manaflow-ai/term-mesh/pull/221))
- Pane resize divider control via CLI ([#223](https://github.com/manaflow-ai/term-mesh/pull/223))
- Production read-screen capture APIs ([#219](https://github.com/manaflow-ai/term-mesh/pull/219))
- Notification rings on terminal panes ([#132](https://github.com/manaflow-ai/term-mesh/pull/132))
- Claude Code integration enabled by default ([#247](https://github.com/manaflow-ai/term-mesh/pull/247))
- HTTP host allowlist for embedded browser with save and proceed flow ([#206](https://github.com/manaflow-ai/term-mesh/pull/206), [#203](https://github.com/manaflow-ai/term-mesh/pull/203))
- Setting to disable workspace auto-reorder on notification ([#215](https://github.com/manaflow-ai/term-mesh/issues/205))
- Browser panel mouse back/forward buttons and middle-click close ([#139](https://github.com/manaflow-ai/term-mesh/pull/139))
- Browser DevTools shortcut wiring and persistence ([#117](https://github.com/manaflow-ai/term-mesh/pull/117))
- CJK IME input support for Korean, Chinese, and Japanese ([#125](https://github.com/manaflow-ai/term-mesh/pull/125))
- `--help` flag on CLI subcommands ([#128](https://github.com/manaflow-ai/term-mesh/pull/128))
- `--command` flag for `new-workspace` CLI command ([#121](https://github.com/manaflow-ai/term-mesh/pull/121))
- `rename-tab` socket command ([#260](https://github.com/manaflow-ai/term-mesh/pull/260))
- Remap-aware bonsplit tooltips and browser split shortcuts ([#200](https://github.com/manaflow-ai/term-mesh/pull/200))

### Fixed
- IME preedit anchor sizing ([#266](https://github.com/manaflow-ai/term-mesh/pull/266))
- Cmd+Shift+T focus against deferred stale callbacks ([#267](https://github.com/manaflow-ai/term-mesh/pull/267))
- Unknown Bonsplit tab context actions causing crash ([#264](https://github.com/manaflow-ai/term-mesh/pull/264))
- Socket CLI commands stealing macOS app focus ([#260](https://github.com/manaflow-ai/term-mesh/pull/260))
- CLI unix socket lag from main-thread blocking ([#259](https://github.com/manaflow-ai/term-mesh/pull/259))
- Main-thread notification cascade causing hangs ([#232](https://github.com/manaflow-ai/term-mesh/pull/232))
- Favicon out-of-sync during back/forward navigation ([#233](https://github.com/manaflow-ai/term-mesh/pull/233))
- Stale sidebar git branch after closing a split
- Browser download UX and crash path ([#235](https://github.com/manaflow-ai/term-mesh/pull/235))
- Browser reopen focus across workspace switches ([#257](https://github.com/manaflow-ai/term-mesh/pull/257))
- Mark Tab as Unread no-op on focused tab ([#249](https://github.com/manaflow-ai/term-mesh/pull/249))
- Split dividers disappearing in tiny panes ([#250](https://github.com/manaflow-ai/term-mesh/pull/250))
- Flaky browser download activity accounting ([#246](https://github.com/manaflow-ai/term-mesh/pull/246))
- Drag overlay routing and terminal overlay regressions ([#218](https://github.com/manaflow-ai/term-mesh/pull/218))
- Initial bonsplit split animation flicker
- Window top inset on new window creation ([#224](https://github.com/manaflow-ai/term-mesh/pull/224))
- Cmd+Enter being routed as browser reload ([#213](https://github.com/manaflow-ai/term-mesh/pull/213))
- Child-exit close for last-terminal workspaces ([#254](https://github.com/manaflow-ai/term-mesh/pull/254))
- Sidebar resizer hitbox and cursor across portals ([#255](https://github.com/manaflow-ai/term-mesh/pull/255))
- Workspace-scoped tab action resolution
- IDN host allowlist normalization
- `setup.sh` cache rebuild and stale lock timeout ([#217](https://github.com/manaflow-ai/term-mesh/pull/217))
- Inconsistent Tab/Workspace terminology in settings and menus ([#187](https://github.com/manaflow-ai/term-mesh/pull/187))

### Changed
- CLI workspace commands now run off the main thread for better responsiveness ([#270](https://github.com/manaflow-ai/term-mesh/pull/270))
- Remove border below titlebar ([#242](https://github.com/manaflow-ai/term-mesh/pull/242))
- Slimmer browser omnibar with button hover/press states ([#271](https://github.com/manaflow-ai/term-mesh/pull/271))
- Browser under-page background refreshes on theme updates ([#272](https://github.com/manaflow-ai/term-mesh/pull/272))
- Command shortcut hints scoped to active window ([#226](https://github.com/manaflow-ai/term-mesh/pull/226))
- Nightly and release assets are now immutable (no accidental overwrite) ([#268](https://github.com/manaflow-ai/term-mesh/pull/268), [#269](https://github.com/manaflow-ai/term-mesh/pull/269))

## [0.59.0] - 2026-02-19

### Fixed
- Fix panel resize hitbox being too narrow and stale portal frame after panel resize

## [0.58.0] - 2026-02-19

### Fixed
- Fix split blackout race condition and focus handoff when creating or closing splits

## [0.57.0] - 2026-02-19

### Added
- Terminal panes now show an animated drop overlay when dragging tabs

### Fixed
- Fix blue hover not showing when dragging tabs onto terminal panes
- Fix stale drag overlay blocking clicks after tab drag ends

## [0.56.0] - 2026-02-19

_No user-facing changes._

## [0.55.0] - 2026-02-19

### Changed
- Move port scanning from shell to app-side with batching for faster startup

### Fixed
- Fix visual stretch when closing split panes
- Fix omnibar Cmd+L focus races

## [0.54.0] - 2026-02-18

### Fixed
- Fix browser omnibar Cmd+L causing 100% CPU from infinite focus loop

## [0.53.0] - 2026-02-18

### Changed
- CLI commands are now workspace-relative: commands use `TERMMESH_WORKSPACE_ID` environment variable so background agents target their own workspace instead of the user's focused workspace
- Remove all index-based CLI APIs in favor of short ID refs (`surface:1`, `pane:2`, `workspace:3`)
- CLI `send` and `send-key` support `--workspace` and `--surface` flags for explicit targeting
- CLI escape sequences (`\n`, `\r`, `\t`) in `send` payloads are now handled correctly
- `--id-format` flag is respected in text output for all list commands

### Fixed
- Fix background agents sending input to the wrong workspace
- Fix `close-surface` rejecting cross-workspace surface refs
- Fix malformed surface/pane/workspace/window handles passing through without error
- Fix `--window` flag being overridden by `TERMMESH_WORKSPACE_ID` environment variable

## [0.52.0] - 2026-02-18

### Changed
- Faster workspace switching with reduced rendering churn

### Fixed
- Fix Finder file drop not reaching portal-hosted terminals
- Fix unfocused pane dimming not showing for portal-hosted terminals
- Fix terminal hit-testing and visual glitches during workspace teardown

## [0.51.0] - 2026-02-18

### Fixed
- Fix menubar and right-click lag on M1 Macs in release builds
- Fix browser panel opening new tabs on link click

## [0.50.0] - 2026-02-18

### Fixed
- Fix crashes and fatal error when dropping files from Finder
- Fix zsh git branch display not refreshing after changing directories
- Fix menubar and right-click lag on M1 Macs

## [0.49.0] - 2026-02-18

### Fixed
- Fix crash (stack overflow) when clicking after a Finder file drag
- Fix titlebar folder icon briefly enlarging on workspace switch

## [0.48.0] - 2026-02-18

### Fixed
- Fix right-click context menu lag in notarized builds by adding missing hardened runtime entitlements
- Fix claude shim conflicting with `--resume`, `--continue`, and `--session-id` flags

## [0.47.0] - 2026-02-18

### Fixed
- Fix sidebar tab drag-and-drop reordering not working

## [0.46.0] - 2026-02-18

### Fixed
- Fix broken mouse click forwarding in terminal views

## [0.45.0] - 2026-02-18

### Changed
- Rebuild with Xcode 26.2 and macOS 26.2 SDK

## [0.44.0] - 2026-02-18

### Fixed
- Crash caused by infinite recursion when clicking in terminal (FileDropOverlayView mouse event forwarding)

## [0.38.1] - 2026-02-18

### Fixed
- Right-click and menubar lag in production builds (rebuilt with macOS 26.2 SDK)

## [0.38.0] - 2026-02-18

### Added
- Double-clicking the sidebar title-bar area now zooms/maximizes the window

### Fixed
- Browser omnibar `Cmd+L` now reliably refreshes/selects-all and supports immediate typing without stale inline text
- Omnibar inline completion no longer replaces typed prefixes with mismatched suggestion text

## [0.37.0] - 2026-02-17

### Added
- "+" button on the tab bar for quickly creating new terminal or browser tabs

## [0.36.0] - 2026-02-17

### Fixed
- App hang when omnibar safety timeout failed to fire (blocked main thread)
- Tab drag/drop not working when multiple workspaces exist
- Clicking in browser WebView not focusing the browser tab

## [0.35.0] - 2026-02-17

### Fixed
- App hang when clicking browser omnibar (NSTextView tracking loop spinning forever)
- White flash when creating new browser panels
- Tab drag/drop broken when dragging over WebView panes
- Stale drag timeout cancelling new drags of the same tab
- 88% idle CPU from infinite makeFirstResponder loop
- Terminal keys (arrows, Ctrl+N/P) swallowed after opening browser
- Cmd+N swallowed by browser omnibar navigation
- Split focus stolen by re-entrant becomeFirstResponder during reparenting

## [0.34.0] - 2026-02-16

### Fixed
- Browser not loading localhost URLs correctly

## [0.33.0] - 2026-02-16

### Fixed
- Menubar and general UI lag in production builds
- Sidebar tabs getting extra left padding when update pill is visible
- Memory leak when middle-clicking to close tabs

## [0.32.0] - 2026-02-16

### Added
- Sidebar metadata: git branch, listening ports, log entries, progress bars, and status pills

### Fixed
- localhost and 127.0.0.1 URLs not resolving correctly in the browser panel

### Changed
- `browser open` now targets the caller's workspace by default via TERMMESH_WORKSPACE_ID

## [0.31.0] - 2026-02-15

### Added
- Arrow key navigation in browser omnibar suggestions
- Browser zoom shortcuts (Cmd+/-, Cmd+0 to reset)
- "Install Update and Relaunch" menu item when an update is available

### Changed
- Open browser shortcut remapped from Cmd+Shift+B to Cmd+Shift+L
- Flash focused panel shortcut remapped from Cmd+Shift+L to Cmd+Shift+H
- Update pill now shows only in the sidebar footer

### Fixed
- Omnibar inline completion showing partial domain (e.g. "news." instead of "news.ycombinator.com")

## [0.30.0] - 2026-02-15

### Fixed
- Update pill not appearing when sidebar is visible in Release builds

## [0.29.0] - 2026-02-15

### Added
- Cmd+click on links in the browser opens them in a new tab
- Right-click context menu shows "Open Link in New Tab" instead of "Open in New Window"
- Third-party licenses bundled in app with Licenses button in About window
- Update availability pill now visible in Release builds

### Changed
- Cmd+[/] now triggers browser back/forward when a browser panel is focused (no-op on terminal)
- Reload configuration shortcut changed to Cmd+Shift+,
- Improved browser omnibar suggestions and focus behavior

## [0.28.2] - 2026-02-14

### Fixed
- Sparkle updates from `0.27.0` could fail to detect newer releases because release build numbers were behind the latest published appcast build number
- Release GitHub Action failed on repeat runs when `SUPublicEDKey` / `SUFeedURL` already existed in `Info.plist`

## [0.28.1] - 2026-02-14

### Fixed
- Release build failure caused by debug-only helper symbols referenced in non-debug code paths

## [0.28.0] - 2026-02-14

### Added
- Optional nightly update channel in Settings (`Receive Nightly Builds`)
- Automated nightly build and publish workflow for `main` when new commits are available

### Changed
- Settings and About windows now use the updated transparent titlebar styling and aligned controls
- Repository license changed to GNU AGPLv3

### Fixed
- Terminal panes freezing after repeated split churn
- Finder service directory resolution now normalizes paths consistently

## [0.27.0] - 2026-02-11

### Fixed
- Muted traffic lights and toolbar items on macOS 14 (Sonoma) caused by `clipsToBounds` default change
- Toolbar buttons (sidebar, notifications, new tab) disappearing after toggling sidebar with Cmd+B
- Update check pill not appearing in titlebar on macOS 14 (Sonoma)

## [0.26.0] - 2026-02-11

### Fixed
- Muted traffic lights and toolbar items in focused window caused by background blur in themeFrame
- Sidebar showing two different textures near the titlebar on older macOS versions

## [0.25.0] - 2026-02-11

### Fixed
- Blank terminal on macOS 26 (Tahoe) — two additional code paths were still clearing the window background, bypassing the initial fix
- Blank terminal on macOS 15 caused by background blur view covering terminal content

## [0.24.0] - 2026-02-09

### Changed
- Update bundle identifier to `com.termmesh.app` for consistency

## [0.23.0] - 2026-02-09

### Changed
- Rename app to term-mesh — new app name, socket paths, Homebrew tap, and CLI binary name (bundle ID remains `com.termmesh.app` for Sparkle update continuity)
- Sidebar now shows tab status as text instead of colored dots, with instant git HEAD change detection

### Fixed
- CLI `set-status` command not properly quoting values or routing `--tab` flag

## [0.22.0] - 2026-02-09

### Fixed
- Xcode and system environment variables (e.g. DYLD, LANGUAGE) leaking into terminal sessions

## [0.21.0] - 2026-02-09

### Fixed
- Zsh autosuggestions not working with shared history across terminal panes

## [0.17.3] - 2025-02-05

### Fixed
- Auto-update not working (Sparkle EdDSA signing was silently failing due to SUPublicEDKey missing from Info.plist)

## [0.17.1] - 2025-02-05

### Fixed
- Auto-update not working (Sparkle public key was missing from release builds)

## [0.17.0] - 2025-02-05

### Fixed
- Traffic lights (close/minimize/zoom) not showing on macOS 13-15
- Titlebar content overlapping traffic lights and toolbar buttons when sidebar is hidden

## [0.16.0] - 2025-02-04

### Added
- Sidebar blur effect with withinWindow blending for a polished look
- `--panel` flag for `new-split` command to control split pane placement

## [0.15.0] - 2025-01-30

### Fixed
- Typing lag caused by redundant render loop

## [0.14.0] - 2025-01-30

### Added
- Setup script for initializing submodules and building dependencies
- Contributing guide for new contributors

### Fixed
- Terminal focus when scrolling with mouse/trackpad

### Changed
- Reload scripts are more robust with better error handling

## [0.13.0] - 2025-01-29

### Added
- Customizable keyboard shortcuts via Settings

### Fixed
- Find panel focus and search alignment with Ghostty behavior

### Changed
- Sentry environment now distinguishes between production and dev builds

## [0.12.0] - 2025-01-29

### Fixed
- Handle display scale changes when moving between monitors

### Changed
- Fix SwiftPM cache handling for release builds

## [0.11.0] - 2025-01-29

### Added
- Notifications documentation for AI agent integrations

### Changed
- App and tooling updates

## [0.10.0] - 2025-01-29

### Added
- Sentry SDK for crash reporting
- Documentation site with Fumadocs
- Homebrew installation support (`brew install --cask term-mesh`)
- Auto-update Homebrew cask on release

### Fixed
- High CPU usage from notification system
- Release workflow SwiftPM cache issues

### Changed
- New tabs now insert after current tab and inherit working directory

## [0.9.0] - 2025-01-29

### Changed
- Normalized window controls appearance
- Added confirmation panel when closing windows with active processes

## [0.8.0] - 2025-01-29

### Fixed
- Socket key input handling
- OSC 777 notification sequence support

### Changed
- Customized About window
- Restricted titlebar accessories for cleaner appearance

## [0.7.0] - 2025-01-29

### Fixed
- Environment variable and terminfo packaging issues
- XDG defaults handling

## [0.6.0] - 2025-01-28

### Fixed
- Terminfo packaging for proper terminal compatibility

## [0.5.0] - 2025-01-28

### Added
- Sparkle updater cache handling
- Ghostty fork documentation

## [0.4.0] - 2025-01-28

### Added
- term-mesh CLI with socket control modes
- NSPopover-based notifications

### Fixed
- Notarization and codesigning for embedded CLI
- Release workflow reliability

### Changed
- Refined titlebar controls and variants
- Clear notifications on window close

## [0.3.0] - 2025-01-28

### Added
- Debug scrollback tab with smooth scroll wheel
- Mock update feed UI tests
- Dev build branding and reload scripts

### Fixed
- Notification focus handling and indicators
- Tab focus for key input
- Update UI error details and pill visibility

### Changed
- Renamed app to term-mesh
- Improved CI UI test stability

## [0.1.0] - 2025-01-28

### Added
- Sparkle auto-update flow
- Titlebar update UI indicator

## [0.0.x] - 2025-01-28

Initial releases with core terminal functionality:
- GPU-accelerated terminal rendering via Ghostty
- Tab management with native macOS UI
- Split pane support
- Keyboard shortcuts
- Socket API for automation
