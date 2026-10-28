# Ghostty Fork Changes (manaflow-ai/ghostty)

This repo uses a fork of Ghostty for local patches that aren't upstream yet.
When we change the fork, update this document and the parent submodule SHA.

## Fork update checklist

`origin` in `ghostty/` is **`JINWOO-J/ghostty`** — that is the fork we push to.
`manaflow-ai/ghostty` is `upstream` and is read-only for us.

1) Make changes in `ghostty/`, on the `main` branch. Never on a detached HEAD:
   a commit made there is orphaned the moment anything re-checks-out the
   submodule, and `setup.sh` does exactly that.
2) Commit and push to `origin` (`JINWOO-J/ghostty`), and confirm it landed:
   `git merge-base --is-ancestor HEAD origin/main`.
3) Update this file with the new change summary + conflict notes.
4) In the parent repo: `git add ghostty` and commit the submodule SHA.
5) **Only then** run `scripts/setup.sh`. It checks the submodule out at the
   SHA the parent pins, so running it before step 4 quietly reverts the
   submodule to the old commit and builds the old library.
6) No prebuilt artifact exists for a brand-new fork SHA, so that build is a
   local `zig build -Doptimize=ReleaseFast` and takes a while. CI publishes a
   `ghostty-prebuilt-<sha>` release once the parent commit reaches
   `main`/`feat/**`, which is what makes later clones fast.

## Current fork changes

This list has fallen behind before. Trust the diff against `upstream/main`
over this summary.

### PTY tap output-sequence bridge

- Commit: `f33047ed9` (refactor: add PTY output sequence callback)
- Files: `include/ghostty.h`, `src/apprt/embedded.zig`, `src/termio/Termio.zig`, `src/renderer/State.zig`
- Adds `ghostty_surface_set_pty_data_callback_with_output_sequence` and its
  paired clear function. Registration holds `renderer_state.mutex`, installs
  the tap, then emits a zero-length baseline carrying
  `processed_output_bytes`; later callbacks run under the same lock after
  their bytes are applied. This gives embedders an exact modulo-`uint64` raw
  output boundary without an output gap between baseline and callback.
- The callback is on Ghostty's reader path under the renderer lock and must
  remain bounded and nonblocking. The term-mesh bridge records every callback
  boundary, including output fully removed by its query filter, before mapping
  an atomic VT-tail sequence to its filtered byte space.
- Parent `ghostty.h` is a synchronized copy of `ghostty/include/ghostty.h`.

### 1) OSC 99 (kitty) notification parser

- Commit: `4713b7e23` (Add OSC 99 notification parser)
- Files:
  - `src/terminal/osc.zig`
  - `src/terminal/osc/parsers.zig`
  - `src/terminal/osc/parsers/kitty_notification.zig`
- Summary:
  - Adds a parser for kitty OSC 99 notifications and wires it into the OSC dispatcher.

### 2) macOS display link restart on display changes

- Commit: `7c2562cbe` (macos: restart display link after display ID change)
- Files:
  - `src/renderer/generic.zig`
- Summary:
  - Restarts the CVDisplayLink when `setMacOSDisplayID` updates the current CGDisplay.
  - Prevents a rare state where vsync is "running" but no callbacks arrive, which can look like a frozen surface until focus/occlusion changes.

### 3) `ghostty_sync_environ` — let an embedder re-read the environment

- Commit: `5284f731b` (feat(embedded): let an embedder re-read the environment)
- Files:
  - `src/main_c.zig`
  - `include/ghostty.h`
- Summary:
  - Exports `void ghostty_sync_environ(void)`, a thin wrapper over the existing
    `global.syncEnviron()`.
  - `ghostty_init` records where the process environment block lives, and libc
    moves that block whenever `setenv` adds a name that was not already there.
    Every later `global.environMap()` then reads an address that no longer holds
    the environment — which since the Zig 0.16 port includes XDG path
    resolution, so config lookup goes with it. The GTK apprt already calls
    `global.syncEnviron` for this; the embedded apprt had no way to, because the
    writes happen in the host application.
  - This shipped as term-mesh v0.174.0 and cost a release: "Ghostty Settings…"
    returned an empty path, Reload Configuration rebuilt the config without the
    user's file, and surface creation crashed in `ghostty_surface_new` with a
    faulting address of `0x415441445f474458` — `XDG_DATA` in little-endian
    bytes, environment string read as a pointer.
  - Deliberately not automatic. Re-reading inside `environMap` would hide the
    ordering mistake instead of surfacing it, and the environment has no
    concurrency control, so only the embedder knows when its writes are done.
  - Caller contract: after `ghostty_init`, from the thread that made the change,
    with no other ghostty call in flight.
- Since the 2026-10-28 upstream sync, `global.syncEnviron()` returns
  `error.OutOfMemory`. The export keeps its `void` signature, logs the error,
  and keeps the previous environment snapshot.
- Upstreamable: yes, in principle — it adds an export and changes no behavior
  for anyone who does not call it.

### 4) Shorter subprocess teardown deadlines on top of upstream

- History: commits `c495aadb2`, `3f755ee80`, `e3854c249` and `54d11c14c` held
  a fork-only bounded teardown. In the 2026-10-28 upstream sync, upstream
  `manaflow-ai` had its own bounded teardown (`KillTimeouts`, `SIGHUP` to
  `SIGTERM` to `SIGKILL`). The sync took the upstream implementation whole and
  dropped the fork version.
- Files:
  - `src/termio/Exec.zig`
- What the fork keeps:
  - Shorter `KillTimeouts` defaults: `sighup_grace` 200 ms and `sigkill_grace`
    200 ms. Upstream uses 12 s and 3 s. `sigterm_grace` (250 ms) and
    `poll_interval` (10 ms) match upstream.
  - A failed `childPreExec` exits the child with status 1. Upstream logs the
    error and continues to exec.
- Why the defaults are shorter:
  - `stop()` runs in `Exec.threadExit` on the IO thread. `Surface.deinit`
    joins that thread, and term-mesh calls `ghostty_surface_free` on the main
    actor. Each grace period therefore blocks the UI.
  - Upstream sizes `sighup_grace` for the 10 s Claude `SessionEnd` hook. That
    size assumes that the embedder calls
    `ghostty_surface_request_process_termination` before it frees the surface.
    term-mesh does not call it yet.
  - With 200 ms, a `SIGHUP` handler that is slower than that can be cut short.
    Shell history writes, `zshexit` hooks and a Claude `SessionEnd` hook are in
    that group. If a user reports lost shell history on close, check this first.
- The fork version signaled only the group of the direct child (`login`). A
  term-mesh pane runs `login`, then `zsh` in its own group, then the
  foreground job in a third group. After a close, `zsh` and the foreground job
  survived. Upstream also signals the terminal foreground group, and
  `tests_v2/test_surface_teardown_latency.py` now fails if the child survives.
- The same test guards the shorter defaults. Its `slow_hup` workload handles
  `SIGHUP` for 5 s, so the free waits out `sighup_grace`. If the sync step for
  item 4 is missed, that free takes about 12 s and the test fails.
- Upstream covers the earlier fork invariants with its own tests: the
  embedder's own process group never gets a signal, the direct child gets
  `SIGKILL` when `setsid` did not happen yet, same-group descendants are
  reaped, and a reaped child's cached process group is not signaled.
- Upstreamable: no. The defaults are specific to an embedder that frees on
  the UI thread.

### 5) Surface teardown must not wait on the consumers it stops

- Commits:
  - `e9c86d177` (fix(termio): bound mailbox pushes so surface teardown cannot
    deadlock) — first attempt, insufficient. See below.
  - `d4a838026` (fix(termio): drop surface messages once teardown starts, do
    not wait)
- Files:
  - `src/Surface.zig`
  - `src/datastruct/blocking_queue.zig`
  - `src/termio/Options.zig`
  - `src/termio/Termio.zig`
  - `src/termio/mailbox.zig`
  - `src/termio/stream_handler.zig`
- The defect:
  - `Surface.deinit` joins the IO thread from the app thread. The app thread is
    also the only drainer of the app mailbox. The IO thread's parse stage pushes
    surface messages into that mailbox, and a `.forever` push waits for space.
    Each side then waits for the other.
  - A production app froze for 69 hours in this cycle. The main thread sat in
    `freeGhosttySurface` and `pthread_join`. The blocked producer was
    `StreamHandler.windowTitle` -> `apprt.surface.Mailbox.push`.
  - A peer-relay pane triggers it reliably. Its producer is a socket, so bytes
    keep arriving through the whole teardown. A local shell pane did not
    reproduce it in 95 rounds.
- Why the first attempt failed:
  - `e9c86d177` replaced `.forever` with a 2 second timeout and dropped the
    message after it. The budget applies per message, and a torn-down surface
    can hold thousands of queued title changes, so teardown still takes hours.
    A 2 second build stayed stalled for over 70 minutes with no recovery, the
    same as the unbounded build.
- The fix:
  - `Surface.deinit` raises a per-surface `tearing_down` flag before it stops
    any consumer, then calls `wakeWaiters` on the app mailbox, the renderer
    mailbox and the termio mailbox.
  - `BlockingQueue.wakeWaiters` broadcasts `cond_not_full`. A `.forever` push
    rechecks `full` once after a wakeup and returns 0, so one broadcast
    releases every parked producer. The shared app mailbox keeps no sticky
    state, so other surfaces are unaffected.
  - While the flag is set, `surfaceMessageWriter` and `messageWriter` push
    `.instant` and discard on failure. A discard frees the memory the message
    owns: `clipboard_write.req`, `pwd_change.pwd`, `tmux_control.data`,
    `change_config` and `write_alloc`.
  - Outside teardown the unbounded wait stays. For a live surface that wait is
    correct backpressure, and dropping a keystroke or a VT reply there is worse
    than a slow pane close.
- Measured on mac-sub, Debug app, DEBUG loopback relay pane plus an OSC title
  flood on the mirrored source:
  - pre-fix: 8 of 8 rounds deadlock.
  - with the fix: 0 of 8 rounds, pane close 2.76 s to 2.95 s.
- Still true after this change: `Surface.deinit` keeps joining the renderer and
  IO threads on the app thread. This change removes the wait that can make
  those joins permanent. It does not move them off the app thread.
- Upstreamable: yes. Upstream `ghostty-org` and `manaflow-ai` both keep the
  `.forever` push, so the defect exists there too.

### 6) Clear mouse tracking when the shell draws a prompt

- Commit: `ac5c1c33d` (fix(termio): clear mouse tracking when the shell draws a prompt)
- File: `src/termio/stream_handler.zig`
- A full-screen program that dies without sending its DECRST leaves mouse
  tracking enabled. The common way to reach that state is a dropped
  connection: ssh to a host, run a TUI, lose the network. The remote program
  never turns the modes off, so from then on every scroll or mouse move
  writes an SGR mouse report onto the prompt line and the shell echoes it as
  text.
- `prompt_start` and `fresh_line_new_prompt` (OSC 133) now clear
  `mouse_event_x10/normal/button/any`, reset `flags.mouse_event`, and put the
  pointer shape back to `.text`. The guard runs only when tracking is on, so
  an ordinary prompt costs one comparison.
- The encodings (1005/1006/1015/1016) are deliberately left alone: they
  select a report format and emit nothing on their own.
- A program that both drives a prompt marker and wants the mouse would lose
  tracking at its prompt. Shell integration is what emits these markers, so
  that combination is not expected.
- Upstream handles the same two markers for OSC 7501 program status
  (`programStatusPromptStart`). Zig rejects a duplicate switch value, so both
  actions are in one switch arm. Keep them together.

### 7) Detach the macOS layer display callback before the renderer is freed

- Commit: `de35a51a7` (fix(renderer): detach IOSurfaceLayer display callback before freeing renderer (macOS))
- Files: `src/renderer/Metal.zig`, `src/renderer/metal/IOSurfaceLayer.zig`
- `IOSurfaceLayer` keeps raw renderer pointers in the `display_cb` and
  `display_ctx` ivars. Commit `adee7043f` cleared them before renderer free on
  iOS only.
- On macOS the NSView keeps its hosted layer after `ghostty_surface_free`. A
  later Core Animation commit called `display` with the freed renderer. The
  crash was `object_getClass` in `drawFrame`. It occurred on a screen change,
  95 minutes after the last pane close.
- `prepareDeinit` now calls `detachFromHostIfDisplayCallbackOwned` on all
  platforms. On macOS the call clears the ivars and the update flag only. It
  does not clear `contents` and does not remove the layer, because the view
  owns the layer.
- term-mesh calls `ghostty_surface_free` on the main actor, so the detach runs
  inline and does not wait on the main queue.
- Upstream `e2a26bc94` fixes the same crash in a different location: it clears
  the same ivars when `invalidateSurfaceUpdates` runs on main. After the
  2026-10-28 sync both clears are present. Clearing twice is harmless. Both
  paths run inline on the main thread and use `dispatch_sync` only from other
  threads.
- Upstreamable: yes, if upstream also lets the host view outlive the renderer.

## Merge conflict notes

These files change frequently upstream; be careful when rebasing the fork:

- `src/terminal/osc/parsers.zig`
  - Upstream uses `std.testing.refAllDecls(@This())` in `test {}`.
  - Ensure `iterm2` import stays, and keep `kitty_notification` import added by us.

- `src/terminal/osc.zig`
  - OSC dispatch logic moves often. Re-check the integration points for the OSC 99 parser.

- `src/termio/Exec.zig`
  - Take the upstream teardown implementation. Then apply the shorter
    `KillTimeouts` defaults from item 4 again.

- `src/termio/stream_handler.zig`
  - Keep the fork `tearing_down` checks next to the upstream
    `kitty_replay_tracking` checks in `surfaceMessageWriter` and
    `messageWriter`. They are separate conditions.
  - Use the upstream `discardSurfaceMessage`. It also frees `program_status`.

- `src/Surface.zig`
  - In `deinit`, set `tearing_down` and call `wakeWaiters` before the upstream
    renderer stop and `requestProcessTermination` calls.

If you resolve a conflict, update this doc with what changed.
