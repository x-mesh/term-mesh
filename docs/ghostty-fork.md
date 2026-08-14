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

This list has fallen behind before; `CLAUDE.md` carries the shorter running
summary of fork deltas. Trust the diff against `upstream/main` over either.

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
- Upstreamable: yes, in principle — it adds an export and changes no behavior
  for anyone who does not call it.

### 4) Bound subprocess teardown for SIGHUP-resistant children

- Commit: `c495aadb2` (fix(termio): bound subprocess teardown)
- Files:
  - `src/termio/Exec.zig`
- Summary:
  - Keeps the existing graceful process-group shutdown, but escalates from
    repeated `SIGHUP` to `SIGKILL` after approximately one second.
  - Prevents `ghostty_surface_free` from waiting forever on the terminal IO
    thread when a pane command ignores `SIGHUP`. In an embedded app that
    synchronous wait otherwise blocks the host's main thread and makes every
    window and control socket unresponsive.
  - Adds a regression test with a child process that explicitly ignores
    `SIGHUP` and verifies that teardown escalates and reaps it.
- Upstreamable: yes — the change bounds an existing synchronous cleanup path
  without changing normal graceful-exit behavior.

## Merge conflict notes

These files change frequently upstream; be careful when rebasing the fork:

- `src/terminal/osc/parsers.zig`
  - Upstream uses `std.testing.refAllDecls(@This())` in `test {}`.
  - Ensure `iterm2` import stays, and keep `kitty_notification` import added by us.

- `src/terminal/osc.zig`
  - OSC dispatch logic moves often. Re-check the integration points for the OSC 99 parser.

- `src/termio/Exec.zig`
  - Preserve the bounded `SIGHUP` grace period and escalation when upstream
    changes subprocess/process-group cleanup.

If you resolve a conflict, update this doc with what changed.
