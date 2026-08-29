# Development workflows

This document contains procedures that are useful while developing or
diagnosing term-mesh but do not need to be loaded into every agent session.
Project-wide invariants remain in [`CLAUDE.md`](../CLAUDE.md).

## Local dev

After making code changes, always run the reload script with a tag to launch the Debug app:

```bash
./scripts/reload.sh --tag fix-zsh-autosuggestions
```

After making code changes, always run the build:

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme term-mesh -configuration Debug -destination 'platform=macOS' -clonedSourcePackagesDirPath "$HOME/Library/Caches/term-mesh/SourcePackages" build
```

Swift unit tests belong to the `term-mesh-unit` scheme; the `term-mesh` scheme contains
`termMeshUITests`, not `termMeshTests`. Use `term-mesh-unit` with
`-only-testing:termMeshTests/...`. A new test file must also be registered in
`GhosttyTabs.xcodeproj/project.pbxproj` before it counts as complete: Xcode can silently run zero
tests when `-only-testing` names an unregistered file, without reporting an error. Confirm both the
project registration and the executed test count.

When rebuilding GhosttyKit.xcframework, always use Release optimizations.
Clean any xcframework-* tags first to avoid zig build crashes:

```bash
cd ghostty && git tag -l 'xcframework-*' | while read -r t; do git tag -d "$t"; done 2>/dev/null; zig build -Demit-xcframework=true -Doptimize=ReleaseFast
```

When rebuilding term-meshd (the Rust daemon):

```bash
cd daemon && cargo build --release
```

Run build and test commands so their own exit status is visible. Do not use pipelines such as
`cargo build | tail` without `set -o pipefail`: a successful `tail` masks a missing or failed
`cargo` as exit 0. Check tool availability (including `~/.cargo/bin`) and the build/test command's
exit code directly before reporting success.

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
- Enter-swallow / IME instrumentation patterns:
  - `key.PRESS_ignored keycode=36` — synthetic send_key rejected by Ghostty (from sendKeyEvent); Rust retry not triggered
  - `ime.return_with_markedText` — Return pressed during IME composition (not swallowed)
  - `ime.resignFirstResponder hadMarkedText=true` — normal IME resign on focus loss
  - `ime.ghosttyKey path=accumulated.text keycode=0` — composed text sent via UTF-8 fallback

## Verifying UI behavior yourself (do this instead of asking the user)

A tagged Debug app can be driven over its own socket, so **an agent can
reproduce and verify a UI bug without a human clicking anything.** Reach for
this before asking the user to try something — it is faster, repeatable, and
it separates "the data is wrong" from "the view is stale", which guessing
never does.

Launch with `--allow-all` so the socket accepts external callers:

```bash
./scripts/reload.sh --tag <tag> --allow-all
```

Then speak JSON-RPC to `/tmp/term-mesh-debug-<tag>.sock`:

```bash
S=/tmp/term-mesh-debug-<tag>.sock
q(){ printf '%s\n' "$1" | nc -U "$S"; }

W=$(q '{"jsonrpc":"2.0","id":1,"method":"window.list"}' \
     | python3 -c "import sys,json;print(json.load(sys.stdin)['result']['windows'][0]['id'])")

q '{"jsonrpc":"2.0","id":2,"method":"debug.app.activate"}'
q '{"jsonrpc":"2.0","id":3,"method":"debug.shortcut.simulate","params":{"combo":"cmd+shift+o"}}'
q '{"jsonrpc":"2.0","id":4,"method":"debug.type","params":{"text":"jw-server"}}'
q '{"jsonrpc":"2.0","id":5,"method":"debug.shortcut.simulate","params":{"combo":"return"}}'
q "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"debug.command_palette.results\",\"params\":{\"window_id\":\"$W\",\"limit\":9}}"
```

Useful probes (all `#if DEBUG`, see `TerminalController+Debug.swift`):
`debug.app.activate`, `debug.type`, `debug.shortcut.simulate` (`combo`:
`down` / `up` / `return` / `cmd+shift+p` …), `debug.command_palette.toggle`,
`debug.command_palette.visible`, `debug.command_palette.selection`,
`debug.command_palette.results` (returns `mode`, `query`, `selected_index`,
and each row's `command_id` / `title` / `trailing_label`). It also reports
whether the palette owns keyboard input right now — `first_responder_in_palette`,
the AppKit answer and the one to assert on — alongside the SwiftUI focus flags
`search_focused` / `rename_focused`, which lag and read false through runs that
pass. The rest is navigation diagnostics: `nav_candidate_key_count`
(n/p/j/k reaching the palette handler — typing those letters counts, arrows do
not — and process-wide, not per window),
`nav_modifier_reject_count`, `nav_last_event_modifiers_raw` (SwiftUI
`EventModifiers`, null until a navigation key arrives), `nav_ignored_empty_count`
(drops against an empty list, reset each open) and `last_focus_wait_ms` (how long
the last open waited for input focus; null when unmeasured or when it gave up).

Rules learned the hard way:

- **Read the pixels too.** `screencapture -x -o <path>` and open the PNG. A
  debug snapshot can be correct while the rendered view is stale — that gap
  IS the bug in SwiftUI-hosted surfaces, and only a screenshot shows it.
- **`debug.type` inserts text literally.** A `\u0008` in the payload lands
  as a control character, not a delete. To reset a field, close and reopen the surface.
- **`debug.shortcut.simulate` needs the app frontmost, every time.** When the
  app is not active the combo never reaches the shortcut handler — it arrives
  through the IME as text, so `cmd+]` types `ㄴ` into the focused terminal. That
  reads exactly like "the shortcut did nothing", and the probe silently measures
  the wrong thing. Call `debug.app.activate` before *each* simulate (not once
  before a loop — focus is lost in between) and allow ~1s before reading state.
- **`screencapture -R` takes physical pixels.** On Retina, coordinates read off a
  downscaled screenshot are wrong by the backing scale factor and capture the
  wrong region. Prefer a full-screen capture.
- **Identify panes by planting markers, not by reading the layout.**
  `surface.send_text` a unique string into each surface first, then screenshot:
  that maps surface ids to on-screen positions, so a later `debug.type` can be
  attributed to a specific surface instead of eyeballed.
- **`debug.command_palette.results`' `query` is the prefix-stripped matching
  string**, not the raw field. Read `mode` to know the real scope.
- **Instrumentation can kill the instrument.** `dlog` from a computed
  property runs on every body evaluation and trips DebugEventLog's rate
  breaker, which then swallows the lines you are looking for. Log only when
  the value changes.
- Driving the app calls `debug.app.activate`, which **steals focus from the
  user**. Batch the probes, and stop once verified.

## Measuring "the app feels slow" (`scripts/perf-sample.sh`)

"Slow" here has almost always meant *the main thread is busy in SwiftUI*, not
that a log is large or a daemon is looping. Sample it rather than reasoning
about it:

```bash
./scripts/perf-sample.sh                 # 3 runs of 8s against /Applications
./scripts/perf-sample.sh --tag observable    # a reloads.sh --tag staging app
./scripts/perf-sample.sh -n 1 -d 5 --keep    # one run, keep the raw samples
./scripts/perf-sample.sh --label A --json    # name a condition, emit a summary
./scripts/perf-sample.sh --replay DIR        # re-judge a kept set, sample nothing
```

It reports per run: streaming state, main-thread idle %, the SwiftUI update
cycle, `AG::Graph::UpdateStack::update`, `propagate_dirty`, and how many
term-mesh view bodies ran inside the cycle.

| symbol | what a high number means |
|---|---|
| `UpdateStack::update` | AttributeGraph is *walking* a large graph |
| `propagate_dirty` | one change is invalidating far too much |
| term-mesh bodies in cycle | app views are re-evaluating — **0 is the goal** |

Reference points (ten agents streaming, two windows, Review Board open):

| | v0.175.1 | after PR #180 + #182 |
|---|---|---|
| `UpdateStack::update` | 1017 | ~400 |
| SwiftUI update cycle | 1242 | ~470 |
| main-thread idle | 46% | 74% |
| `propagate_dirty` | 40 | 6–13 |
| app view bodies in cycle | many | 0–2 |

**Every number here is a ratio against a workload the script does not control**,
so a run can look perfectly usable and mean nothing. Four ways that happened,
each now a per-run verdict rather than something you have to remember:

| verdict | what actually happened | exit |
|---|---|---|
| `IDLE` | nothing was streaming; ~86% idle regardless of the code. Four measurements were discarded for this | 2 |
| `DIRTY` | the pointer crossed the window. One pass near a split divider put `termMesh_sendEvent` at 31% of the main thread and dragged in 51 view bodies. That run is excluded from the median | — |
| `DECAYING` | agents finished mid-set: 751 → 619 → 452 across three runs. Whatever you measure *next* wins for that reason alone | 3 |
| `DRIFTED` | the app changed underneath — workspaces 3→5, relays 16→22 between sets. Those are not the same app | 3 |

**A non-zero exit means "no data", never "a bad result".** Two rules the script
cannot enforce for you:

- **`grep -c` is the wrong statistic.** A line count reflects recursion depth,
  not cost: `StackLayout.placeChildren` appeared 167 times while costing 11
  samples. Read the sample count on the branch (the script does).
- **Keep your hands off the machine while it samples.** That is what `DIRTY`
  catches after the fact, and it costs you the run.

To compare two conditions, **interleave — never A then B.** Decay alone will
hand you a result:

```bash
./scripts/perf-sample.sh --tag t --label A-expanded
# change the condition
./scripts/perf-sample.sh --tag t --label B-collapsed
# change it back
./scripts/perf-sample.sh --tag t --label A2-expanded
```

B is real only if it sits below the line from A to A2.

For a before/after on the same machine, prefer `reloads.sh --tag <name>`: it
builds Release into an isolated app so production keeps its workspaces and
peers, and both can be sampled in the same 8-second window. `reload.sh --tag`
is Debug (`-Onone`) and will understate any optimisation that adds a comparison.

VERIFY: the verdicts fire only under conditions nobody can reproduce on demand,
so they are tested against synthetic sample sets carrying the numbers above.

```bash
./scripts/test-perf-sample.sh
```
