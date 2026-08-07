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

## CLI Profiles

Named CLI profile sets (path + extraArgs + env + modelOverride) stored in `~/Library/Application Support/term-mesh/cli-profiles.json`.

**Settings에서 만들기:** Settings → CLI Paths에서 각 CLI(claude / kiro / codex / gemini / cursor / agy)별로 프로파일을 추가하고 이름, 실행 경로, 추가 인수(extraArgs), 환경 변수, 모델 override를 지정. 경로 필드에는 자동 감지된 경로와 최근 사용 경로가 dropdown으로 표시됨.

**메뉴바에서 전환:** 메뉴바 아이콘 → CLI Profile 서브메뉴에서 CLI별 프로파일을 라디오 버튼으로 즉시 전환. "Apply to Active Pane (Restart)"를 선택하면 현재 pane을 새 프로파일로 hard restart.

**마이그레이션:** 기존 `cliPath.<cli>` 값은 앱 시작 시 자동으로 "Default" 프로파일로 변환되며 원본 UserDefaults 키도 dual-write로 유지됨(구버전 빌드 호환).

**extraArgs 주의:** `--model`, `--resume`, `--session-id`, `--dangerously-skip-permissions`, `--print`, `--append-system-prompt`는 term-mesh가 자동으로 주입하므로 extraArgs에 넣지 말 것(경고 표시됨).

**헤드리스 모드:** `tm-agent create` / `tm-agent attach` 시에도 활성 프로파일의 extraArgs / env / modelOverride가 동일하게 적용됨.

**cursor / agy:** Settings → CLI Paths에는 항상 경로 필드가 있다(`cursor-agent`, `agy`). 에이전트 role/attach CLI picker에는 **Native Agent Panes**가 켜져 있을 때만 나타난다 — 둘 다 대화형 TUI·stdin 채널이 없어 터미널 pane으로는 실행할 수 없다.

## Native Agent Panes (experimental)

기본값은 **Native**다. Settings → Agent Teams → **Agent Panes**에서 기존 Ghostty pane이 필요하면 **Terminal**로 바꿀 수 있다. Native에서는:

- pipe transport(`agentPipeTransport.enabled`)와 native panel(`agentPipeTransport.nativePanel`)이 함께 켜진다. 하나만 켜는 UI는 없다.
- 에이전트 UI는 `AgentPanelView`(SwiftUI) — 지시문, streaming 답변, 접을 수 있는 tool row, 턴 종료 cost/시간.
- 파일 편집은 `ChangeRow`가 diff로 그린다: 접힌 줄에 `경로 +N −M`, 펼치면 `+`/`−` 색상 diff. 파싱은 `Sources/Panels/AgentDiff.swift`(순수 함수, `CollectionDifference` 기반)가 `tool_use.input`에서 하며 **뷰 body에서는 절대 계산하지 않는다**. 인식하는 input 모양은 `unified_diff`(브리지 정본, `@@` 헤더의 라인 번호 유지) / `old_string`+`new_string` / `edits[]` / `content`. tool 이름이 아니라 input 모양으로 분기한다. 브리지는 `input`에 `command` 키를 넣으면 안 된다 — `AgentSession.openTool()`이 그걸 먼저 골라 `file_path`를 가린다.
- `tm-agent delegate` / `send` / `broadcast`는 CLI 이름 그대로; delivery만 paste+Return → pipe/native stdin으로 바뀐다.
- 턴 완료는 `AgentPipeCompletion`이 `<fifo>.events`의 `{"type":"result"}`를 읽는다. Standard Reply Header(5-field) 계약은 동일.
- 지원 CLI: claude(직접 NDJSON), codex/kiro/cursor/agy(`scripts/spike/tm-agent-bridge.py`).
- Shell Integration health: native agent pane은 **agentMode**(파란색) — shell integration N/A.

Spike 상세: `docs/spike/agent-pipe-render.md`

### Remote native agent environment

Remote native agents start through the account's Bourne-compatible login shell.
The load order is:

1. the shell's normal login profile;
2. `~/.profile` when Bash or zsh would otherwise skip that literal file;
3. optional `~/.config/term-mesh/agent-env`;
4. explicit environment values configured for the peer host.

`agent-env` is sourced as a Bourne-compatible shell fragment. Prefer simple
`KEY=value` or `export KEY=value` entries and do not print output from it.
Explicit peer-host values win over profile and `agent-env` values. term-mesh
uses a fixed remote `PATH`, so configure CLI paths explicitly rather than
overriding `PATH` in these files. A profile or `agent-env` load failure is
reported in the native agent pane without including environment values.

VERIFY (stale CLI 이름·동작 불일치):

```bash
rg -n 'agentPipeTransport|Agent Panes|Native Agent|cursor-agent|tm-agent-bridge' AGENTS.md CLAUDE.md CHANGELOG.md docs/spike/agent-pipe-render.md
xcodebuild -project GhosttyTabs.xcodeproj -scheme term-mesh-unit -configuration Debug -destination 'platform=macOS' -only-testing:termMeshTests/AgentSessionTests -only-testing:termMeshTests/AgentPipeCompletionTests test
```

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
and each row's `command_id` / `title` / `trailing_label`).

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

## Disk reclamation (`tm-agent gc`)

Three subsystems create worktrees and none knows about the others — the daemon
(`~/.term-mesh/worktrees/<repo>/term-mesh_wt_<8hex>`), git-kit via
`tm-agent delegate --worktree` (`~/.gk/worktree/...`), and `PeerProjectBootstrap`
agent checkouts (`<root>/<project>-<role>-<yyMMdd>-<hex4>` on an `agent/*`
branch). Plus per-team results, task boards, logs and build caches. `gc` is the
one place that accounts for all of it, locally or on a peer.

```bash
tm-agent gc status                          # size + candidate count per category
tm-agent gc plan [--category X] [--deep]    # every candidate with reasons/blockers
tm-agent gc sweep                           # dry-run — shows what would go
tm-agent gc sweep --apply                   # actually reclaim
```

- **Dry-run is the default.** `sweep` without `--apply` deletes nothing.
- **Blockers beat `--apply`.** Uncommitted changes, commits missing from the
  parent repo, and worktrees an active session or task still points at are
  never removed. `--force` relaxes exactly one blocker (`unopenable`).
- **The daemon's own 6h sweep is narrower still**: only `team_results` (24h),
  `worktree_meta` and `logs`. Team boards require an authoritative live-team
  snapshot and are explicit-only. The unattended sweep never removes a
  worktree or checkout — see `AUTO_CATEGORIES` in
  `daemon/term-meshd/src/gc.rs`.
- Removal goes through git, so the registration is pruned with the directory.
  Deleting the directory alone leaves a `prunable` entry behind.
- **`git worktree remove` refuses any worktree containing a submodule**, and
  every term-mesh worktree has `ghostty` — so that path always fails here. `gc`
  handles it (delete the directory, then prune the registration), but
  `git-kit worktree cleanup -y` **reports the removals and performs none**: it
  swallows git's refusal and still returns `state: ok`. Verify with
  `git worktree list` rather than trusting its output.
- `reload.sh` records the launched PID in a tag-session manifest. The next
  reload immediately removes ended tag sessions; failed managed builds are
  removed on exit, with the 7-day sweep retained as a fallback (override with
  `TERMMESH_RELOAD_TAG_GC_DAYS`, disable with `TERMMESH_RELOAD_TAG_GC=0`). It
  caches under `~/Library/Caches/term-mesh`: SwiftPM dependency checkouts are
  shared by every tag, while the Cargo target directory is **per tag**
  (`cargo-target/<tag>`). Do not collapse the Cargo one into a single shared
  directory — cargo keys its output by package name, so every tag's
  `term-meshd` would land at the same path, and since the daemon build's
  failure is swallowed, a tag whose build broke would ship whichever branch
  last built successfully. `TERMMESH_CARGO_TARGET_DIR` overrides the path and
  takes that collision on itself. Only the binaries the current build produced
  are copied into the bundle — a daemon build that fails is fatal rather than
  falling back to `daemon/target/release`, which this script no longer writes.
  reload refuses to start below 10 GiB free
  (`TERMMESH_BUILD_MIN_FREE_GIB` overrides the threshold). At task completion,
  `./scripts/reload.sh --tag <tag> --cleanup` stops that app and immediately
  reclaims its managed DerivedData, sockets, log, manifest, and Cargo target.
- `tm-agent gc sweep --category build_caches --deep` previews regenerable
  `daemon/target` directories inside inactive worktrees. Add `--apply` to
  remove only those targets while preserving dirty source. Active session/task
  worktrees remain blocked. Shared Cargo/SwiftPM and GhosttyKit caches are
  reported but remain owned by their build scripts; `setup.sh` keeps the 3 most
  recently used GhosttyKit SHAs (`TERMMESH_GHOSTTYKIT_CACHE_KEEP`).
- Peers report free space in `HostStats`, and the sidebar shows a warning badge
  under 5GB or 10%. Run `tm-agent gc` over ssh on that host to reclaim.

VERIFY:

```bash
(cd daemon && cargo test -p term-meshd gc:: && cargo test -p term-meshd host_stats)
./scripts/test-reload-cleanup.sh
```

`bash -n` alone proves the file parses and nothing else, which is not a useful
check on code that runs `rm -rf`. `test-reload-cleanup.sh` sources reload.sh with
`TERMMESH_RELOAD_LIB_ONLY=1` and drives the reclaim helpers against a sandbox:
path-guard rejections, per-tag isolation, and the two cases where reclamation
must refuse — a tag whose app is still running behind a stale manifest PID, and a
rebuild that failed while the previous build is live.

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

## tm-op 전략 커맨드

활성 에이전트 팀에게 구조화된 전략(발산·수렴·경쟁·파이프라인·분배·숙의·토론·공격방어·브레인스토밍·자율탐색)을 지시한다.
`tm-agent create`로 팀이 먼저 구성되어 있어야 한다.

```bash
/tm-op                                    # 인터랙티브 (전략 선택)
/tm-op refine "결제 API 설계" --rounds 4  # 라운드 기반 정제
/tm-op tournament "로그인 구현"           # 경쟁 투표
/tm-op chain "보안 점검" --steps "explorer:분석,security:식별,reviewer:종합"
/tm-op review --target src/pay.ts         # 코드 다각도 리뷰
/tm-op debate "모놀리스 vs 마이크로서비스" # 정반합 토론
/tm-op red-team --target src/auth.ts      # 적대적 공격/방어
/tm-op brainstorm "v2 기능 아이디어" --vote # 자유 발산 + 투표
/tm-op distribute "6개 Sentry 이슈 분석"  # 병렬 분배 실행
/tm-op council "ECS vs K8s" --rounds 4    # 다자간 숙의 회의
/tm-op research "Rust error handling"     # 자율 multi-agent 탐색 (board.jsonl stigmergy)
```

| 전략 | 설명 |
|------|------|
| **refine** | 라운드 기반 발산→수렴→검증. 전원 독립 답변 후 종합·투표·검증 반복. `--rounds N` |
| **tournament** | 전원 동시 경쟁 후 익명 투표로 최고 결과 채택. `--judge <agent>` 지정 가능 |
| **chain** | A→B→C 순차 파이프라인. 이전 단계 결과가 다음 입력. `--steps`로 역할 직접 지정 |
| **review** | 버그·보안·성능 관점 자동 배정 후 이슈 종합·중복 제거·심각도 정렬 리포트 출력 |
| **debate** | 찬반 토론 후 판정. 설계 트레이드오프 분석에 적합. `--pro`/`--con` 팀 지정 가능 |
| **red-team** | 공격팀이 결함 발견→방어팀이 수정. 보안·견고성 강화. `--attackers`/`--defenders` 지정 |
| **brainstorm** | 수렴 없이 아이디어 발산→분류→투표. `--vote`로 도트 투표 활성화 |
| **distribute** | 대규모 태스크를 독립 서브태스크로 분할·병렬 실행·병합. `--splits`로 수동 분할, `--no-merge`로 병합 비활성화 |
| **council** | N명 자유 토의 → 교차 질의 → 심화 → 합의 도출. `--agenda`로 다중 안건, `--rounds N`으로 라운드 수 조절 |
| **research** | idle 에이전트가 board.jsonl로 stigmergy 협동 탐색. `--depth shallow\|deep\|exhaustive`, `--budget N`, `--web` |

옵션: `--rounds N`, `--preset quick|thorough|deep`, `--steps "a:t,b:t"`, `--target <file>`,
`--pr <number>`, `--judge <agent>`, `--timeout N`, `--resume`,
`--pro`/`--con` (debate), `--attackers`/`--defenders` (red-team), `--vote` (brainstorm),
`--splits "a:t,b:t"` (distribute 수동 분할), `--no-merge` (distribute 병합 비활성화),
`--agenda "a,b,c"` (council 다중 안건), `--context` (강제 맥락 주입), `--no-context` (맥락 주입 비활성화),
`--agents N` (research 에이전트 수), `--budget N` (research 라운드), `--depth shallow|deep|exhaustive` (research 깊이), `--web` (research 웹검색 허용)

## Team agent system (OMC override)

**CRITICAL OVERRIDE:** When running inside term-mesh (i.e., `TERMMESH_SOCKET` env var is set or
a socket exists at `/tmp/term-mesh*.sock` or `/tmp/term-mesh.sock`), ALL team operations MUST use
`tm-agent` (Rust binary, ~2ms). This applies regardless of how the team was triggered.

**Banned tools in term-mesh context:** `TeamCreate`, `SendMessage`, `TaskCreate`, `TaskList`,
`TaskGet`, `TaskUpdate`, `TeamDelete`. These create a parallel, disconnected team state.

**Use instead:** The project-local `/team` command (`.claude/commands/team.md`) for Claude leaders,
or the Codex IME `/team` alias backed by `~/.codex/prompts/team.md` for Codex leaders. Both route
everything through `tm-agent`.

### Command responsibility split — /team vs /tm

| 슬래시 | 책임 | 주요 명령 |
|--------|------|----------|
| `/team-up` | 0→1 팀 부트스트랩 (현재 pane을 leader로 adopt) | `team-up [N] --adopt` |
| `/team` | 팀 구성 편집 (lifecycle) | `add` / `remove` / `swap` / `ensure` / `status` / `destroy` / `edit` (no-args 인터랙티브) |
| `/tm` | 작업 디스패치 (fan-out + 3줄 합성) | `--ensure <roles>` 옵션으로 사전 보강 가능 |
| `/tm-op` | 전략 오케스트레이션 (refine/debate 등) | 변경 없음 |

`/tm`은 팀 구성을 절대 변경하지 않는다. 부족한 역할이 있으면 `--ensure` 명시적 옵트인 또는 사전에 `/team add` 필요.

### OMC keyword override

If OMC's keyword detector fires `[MODE: TEAM]` or `[MAGIC KEYWORD: TEAM]`:
1. **Do NOT invoke `/oh-my-claudecode:team`** — it uses Claude Code native teams
2. **Instead invoke `/team`** (the project-local command) or use `tm-agent` directly

### Codex leader prompt shims

Codex does not execute Claude's `.claude/commands` slash-command format natively. Project-local
`.codex/prompts/` is intentionally absent; distributable Codex prompt shims live under
`Resources/CodexPrompts/` and are installed globally into `~/.codex/prompts/`.

In the term-mesh IME box, Codex panes get short aliases that expand on submit into a normal Codex
message: "read `~/.codex/prompts/<name>.md` and execute it with these arguments." Claude panes
keep the original Claude slash commands.

| Claude leader | Codex leader | Purpose |
|---------------|--------------|---------|
| `/team ...` | `/team ...` via IME alias | Low-level `tm-agent` primitive wrapper |
| `/team-up ...` | `/team-up ...` via IME alias | Create a team with the current pane adopted as leader |
| `/tm "..."` | `/tm "..."` via IME alias | One-shot fan-out to all idle agents + synthesis |
| `/tm-op ...` | `/tm-op ...` via IME alias | Strategy orchestration |
| `/tm-bench ...` | `/tm-bench ...` via IME alias | Agent team communication benchmark |
| `/watch ...` | `/watch ...` via IME alias | Stateless drift oversight toggle/review |

The IME alias map lives in `imeSlashCommandAliases()` (`Sources/GhosttySurfaceScrollView.swift`);
each alias points at the corresponding `~/.codex/prompts/<name>.md`. Both the Claude commands and
Codex distribution prompts are bundled by `scripts/copy-claude-commands.sh` (build phase:
`COMMANDS`/`SKILLS`/`CODEX_PROMPTS`) and installed by `ClaudeCommandInstaller.swift` into
`~/.claude/` and `~/.codex/prompts/`. Adding a leader command means updating the paired source under
`Resources/CodexPrompts/`, both managed-name arrays, and the IME alias map in lockstep.

For Codex as the current leader, prefer:

```bash
tm-agent create 3 --adopt
tm-agent attach reviewer --cli codex
```

Use `--claude-leader` only when creating a Claude Code leader pane.

### Agent context lifecycle

Agent panes are reusable workers, not long-term memory stores. Durable project
state must live in the task board, result files, runbook digests, and task
capsules rather than in an individual pane transcript. A restarted agent must be
able to recover its role, constraints, and current assignment from the runbook
digest plus the next `TM-PROTOCOL-v1` task capsule alone.

After an agent completes a task and reports with the Standard Reply Header, the
leader may recycle the idle pane to avoid context compaction and transcript
drift:

```bash
tm-agent recycle <agent>
```

`recycle` is a guarded hard restart. It rejects active non-terminal tasks by
default; checkpoint long-running work first with `tm-agent heartbeat`,
`tm-agent task block`, `tm-agent task review`, or `tm-agent reply` so another
worker can resume from the task board or `~/.term-mesh/results/`. Use compaction
only for a long single task that genuinely must continue in the same pane
context. Use `tm-agent restart <agent> --hard` as the lower-level recovery
escape hatch.

### XM skill agent fan-out routing

**단일 원본**: xm 저장소(x-mesh/xm) `docs/term-mesh-integration.md` (계약) + xm 플러그인 내장
`x-agent/skills/agent/references/term-mesh-backend.md` (실행 시점 규칙 — xm 스킬의
Execution Backend 섹션이 term-mesh 감지 시 자동 로드). 로컬 요약: `docs/x-kit-integration.md`.

핵심 규칙: term-mesh 컨텍스트(`TERMMESH_SOCKET` env 또는 `/tmp/term-mesh*.sock` 존재,
`XK_BACKEND`/`.xm/config.json`의 `execution_backend`로 override 가능)에서 xm 스킬이
*Claude Code native Agent tool* fan-out을 지시하면 **반드시 `tm-agent delegate` × N
(단일 Bash 메시지) + `tm-agent wait`로 치환**한다. 치환 테이블, 4-perspective→role 맵,
결과 합성 계약, worktree lifecycle, bypass 조건은 위 reference가 규정한다. 위임 태스크의
reply는 Standard Reply Header + `XK_TASK`/`XK_CORR` 라인으로 종결해야 하며(xk-bridge
writeback 계약), 이 섹션과 원본이 다르면 원본이 우선한다.

Panel runs on the task board: `tm-agent xk-bridge`가 켜져 있으면 x-panel review/cross 런이
`xk_run` 이벤트(XK-EVENTS-v1)로 팀 태스크보드에 자동 미러링된다(run당 task 1개,
pending→in_progress→completed/blocked). leader는 `.xm/…/status.json` 폴링 대신
`tm-agent wait`/`task list`로 패널 완료를 기다리면 된다. 상세: `docs/xk-panel-phase2.md`.


### Quick CLI reference

**All operations** use `tm-agent` (Rust, ~2ms; fallback `./scripts/tm-agent.sh` ~10ms):

```bash
# Lifecycle (/team)
/team                      # interactive editor
/team status               # formatted team table
/team add reviewer         # attach default claude/sonnet reviewer
/team add executor --model opus  # attach with opus model
/team add reviewer --cli codex   # attach codex-backed reviewer
/team add builder --host jw-server --dir /root/build  # run this member on a peer
/team remove writer        # detach writer
/team swap executor opus   # change executor model
/team ensure reviewer security  # idempotent — add only if missing
/team destroy              # 2-step confirm then teardown

# Dispatch (/tm)
/tm "이 PR 보안 리뷰"                              # fan-out to all idle
/tm --ensure reviewer,security "이 PR 보안 리뷰"   # auto-add missing roles first
```

```bash
# Team lifecycle (tm-agent raw)
tm-agent create [N] [--claude-leader]          # creates a new workspace with agents
tm-agent create [N] --adopt                    # adopt current pane as leader (Codex/Claude/Kiro/Gemini)
tm-agent destroy
tm-agent status
tm-agent list

# Agent runbooks (repo-local role behavior)
tm-agent runbook status
tm-agent runbook init [--dry-run] [--force]
tm-agent runbook digest [--agent <role>]       # compact prompt-efficient role brief
tm-agent runbook install --tool claude|codex|opencode|all [--agent <role>] [--dry-run] [--force]

# Team-scoped add/remove (works for headless AND GUI teams — no workspace ID required)
tm-agent add <role> [--name N] [--model M] [--cli claude|codex|kiro|gemini]
tm-agent add <role> --host <peer> [--dir <remote path>]   # member runs on a peer
tm-agent remove <agent_name> [--force]
# Examples:
#   tm-agent add reviewer                   # add reviewer to current team (any team type)
#   tm-agent add executor --model opus      # add executor with opus model
#   tm-agent add builder --host jw-server --dir /root/build
#     A mixed team: the pane opens here beside its teammates, the shell behind
#     it belongs to the peer. `--host` takes the sidebar's name (jw-server) or
#     the stored key (ssh:root@jw-server). `--dir` says where on that machine —
#     needed unless the host reports a project of its own, since two machines
#     rarely lay a checkout out the same way. Delegating, reading the reply and
#     revealing the pane all work exactly as they do for a local member.
#   tm-agent remove reviewer               # remove agent from team (--force default: true)
# `add` routes to team.add_agent Swift RPC; rejects duplicate name within team.
# `remove` routes to team.detach Swift RPC; team-name–scoped (not workspace-panel–scoped).

# Workspace-local attach/detach (NO new workspace — uses the caller's current one)
tm-agent attach <agent_type> [--name N] [--model M] [--cli claude|codex|kiro|gemini]
tm-agent detach <agent_name>
# Examples:
#   tm-agent attach reviewer                    # split reviewer pane into current workspace
#   tm-agent attach executor --model opus       # opus-backed executor
#   tm-agent attach security --name sec1        # custom agent name
#   tm-agent detach reviewer                    # close reviewer pane, keep leader pane
# First attach auto-creates team `ws-<first8hex>` from the current workspace UUID.
# The calling pane becomes the leader (adopted). Last detach destroys the team but
# preserves the leader pane. Rejected if the workspace already hosts a `create`-based team.

# Leader → agent communication
tm-agent send <agent> '<instruction>'
tm-agent delegate <agent> '<instruction>' [--context '<prior context>']
tm-agent delegate executor 'implement T1' --worktree auto
tm-agent delegate executor 'implement T1' --worktree always --from develop
tm-agent broadcast '<instruction>'
tm-agent fan-out 'implement phase tasks' --worktree auto
tm-agent read <agent> --lines 100
tm-agent collect --lines 100
tm-agent collect --headers                    # header-only result collection for token-efficient synthesis
tm-agent reports --summary                    # headers + concise summaries, full files lazy-read via FULL_REPORT
tm-agent wait --timeout 120 --mode any        # ALWAYS use this to wait; NEVER use `sleep N && tm-agent read`
tm-agent recycle <agent>                      # guarded hard restart for idle/stopped workers; drops transcript context
tm-agent brief <agent>

# LeaderParallelPolicy v1 — runtime-enforced (single source: `Sources/LeaderParallelPolicy.swift`)
# Every local/peer leader receives the same policy_version and policy_digest. `status` exposes
# source/version/digest plus policy state; injection failure is explicit `failed`, never silent.
# For substantive work, form a parallel wave by default. Claim or dispatch only DAG-ready tasks:
# every `depends_on` task must be completed; failed/blocked dependencies never release a child.
#
# Placement is one unified local+peer pool. A task's stable correlation key is
# `task_id + agent_instance_id`; the same role/name may have multiple instances.
# Name-only selectors are rejected when ambiguous, while unique-name callers remain compatible.
# Idle-first deterministic routing selects an eligible exact instance and never collapses sibling rows.
#
# Work-pool / autonomous claim pattern:
#   tm-agent task create 'task A'            # unassigned — enters pool
#   tm-agent task create 'task B'            # unassigned — enters pool
#   tm-agent broadcast 'tm-agent claim'      # one initial kick
# AUTO-CLAIM-NEXT: a completed, non-recycled exact instance claims the next ready
# unassigned task itself. If delivery fails, that same instance's claim is released back to
# the unassigned pool; no sibling is reassigned accidentally. Directed delegate/fan-out tasks
# are already assigned and are therefore not consumed by the pool.
#
# Same-checkout concurrent writes require explicit disjoint ownership or worktree isolation.
# Distinct local/peer checkouts do not require an additional worktree; assign a branch owner and
# serialize pushes to the same remote branch. Concurrent read-only work is allowed in one checkout.
#
# isolated-checkout-ref-contract, base sync: a worker branch is expected to be BEHIND the target,
# not only differently named. When the leader says "sync your base to <SHA>", that is the assigned
# action, not a precondition to verify — run it. Do not gate it behind
# `git merge-base --is-ancestor <SHA> HEAD` and do not report BLOCKED because the SHA is not yet
# in the branch; that is the normal state the sync exists to fix.
#
# Machine-readable status/task/collect/reports retain duplicate rows and expose body-free routing
# telemetry (wave/task/agent_instance/host/checkout/delivery/synthesis). A hard timebox converges
# on completed evidence and blocks/cancels/splits remaining work — timeout is never success.
# External events (CI, deploys, remote builds) require an existence check and bounded watch. Either
# report at the cap or delegate a shorter bounded watch to a worker and wait for its reply; an ended
# leader turn does not resume by itself.
#
# Broadcast reaches ALL panels including duplicate-named agents:
#   tm-agent broadcast 'msg'
# Regression test: ./scripts/test-parallel.sh --skip-team-create

# Agent task lifecycle
tm-agent task start <task_id>
tm-agent task block <task_id> '<reason>'
tm-agent task review <task_id> '<summary>'
tm-agent task fix-attempt <task_id>   # Record a fix attempt (auto-blocks when budget exhausted)
tm-agent heartbeat '<progress summary>'
tm-agent reply '<STATUS/FILES/VERIFY/NEXT/FULL_REPORT header plus result>'  # auto-reports and completes active task

# Token-efficient protocol
# Agent init uses compact runbook digests by default. Set TERMMESH_RUNBOOK_MODE=full
# only when debugging role behavior or when a task truly needs the full source runbook.
# Delegated tasks should use compact task capsules and `TM-PROTOCOL-v1` instead of
# repeating lifecycle instructions. Leaders should read `collect --headers` or
# `reports --summary` first, then open FULL_REPORT only for BLOCKED/NEEDS_REVIEW
# or failed VERIFY cases.

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

# Autonomous behaviors
tm-agent research <topic> [options]       # Multi-agent research with board.jsonl stigmergy

# Options:
#   --agents N          Number of agents (default: 0 = all idle claude agents)
#   --budget N          Round count (default: 5)
#   --timeout N         Max wait seconds (default: 600)
#   --depth <d>         shallow|deep|exhaustive (default: deep)
#   --web               Allow web search
#   --focus "hint"      Focus hint for agents
```

### Leader: reading full agent reports

Agent replies are truncated to 1500 chars over the socket. The submitted reply is preserved on disk:

```bash
# The submitted reply for a task (canonical envelope)
cat ~/.term-mesh/results/<team>/<task_id>.md

# That instance's latest reply alias
cat ~/.term-mesh/results/<team>/<agent>-<agent_instance_id>-reply.md

# Detail the header points at — open the FULL_REPORT path verbatim
cat ~/.term-mesh/results/<team>/<task_id>-full.md
```

When `tm-agent collect` or `msg list` returns truncated content (ends with `...`), read the corresponding file from `~/.term-mesh/results/` for the full text. Files are auto-cleaned after 24 hours.

Both `<task_id>.md` and the reply alias are **replaced wholesale by each `tm-agent reply`**, so detail
must live in a separate unique file — see the Reply Truncation Protocol below.

### Auto-Fix Budget protocol

When a task has a fix budget (set via `--auto-fix-budget N` on delegate):
- **Before each fix attempt** (build fix, test fix, error correction), run:
  `tm-agent task fix-attempt <task_id>`
- The daemon tracks attempts. When budget is exhausted, the task is auto-blocked.
- Auto-blocked tasks require leader intervention to unblock.
- If no fix budget is set, fix-attempt is optional (count is still tracked).

### Agent Trigger Routing

특정 작업이 발생했을 때 leader가 직접 처리하지 않고 해당 에이전트에 위임한다.
아래 매트릭스는 brainstorm(2026-05-08) Tier 1·2 합의 결과와 persona run 운영 규칙 R1을 영구화한 것이다.

| 시그널 | → 에이전트 | 근거 |
|--------|-----------|------|
| "X is defined where", "all callers of Y", "find pattern across", "what does M depend on" | **explorer** | 심볼 탐색·파일 위치 확인은 grep-first 전문 역할 |
| Sources/Panels/*, Sources/Splits/*, UTType, performKeyEquivalent, 애니메이션, SwiftUI 레이아웃 | **frontend** | AppKit/SwiftUI 컴포넌트 경계 변경 |
| daemon/, term-meshd, JSON-RPC schema 변경, peer-federation Phase 진행 | **backend** | Rust 데몬·IPC 프로토콜 전담 |
| 신규 IPC 커맨드 설계, 모듈 경계 결정, threading/focus 정책, panel layering 계약 | **architect** | 구조적 결정 — 코드 작성 전에 ADR 필요 |
| Process(), 신규 socket 커맨드, 외부 입력 파싱, allowAll 조건 변경, quoting 코드 | **security** | 취약점 패턴 즉시 탐지 의무 |
| executor diff 완료 직후, submodule 포인터 변경, /release·/ship 직전 | **reviewer** | 코드 품질·포인터 정합성 게이트 |
| 기능 브랜치 머지 후, CLI·DX 변경, Settings UI 신규 옵션 추가, /release Step 4 | **writer** | CHANGELOG·README·CLAUDE.md 단일 소스 관리 |
| 파일 3개 이상 동시 변경, Phase·Stage 의존성 존재, 에이전트 2명+ 관여하는 작업 | **planner** | task 분해·의존성 그래프·Phase gate 설계 |
| socket 커맨드 추가, focus policy 변경, split 레이아웃 변경, PR 직전 smoke test | **tester** | VM 기반 통합 테스트 실행 |
| ghostty 서브모듈 변경, GhosttyKit.xcframework 재빌드, zig 빌드 crash | **backend** + **executor** | xcframework 빌드 = ghostty submodule + zig 의존성 |
| dSYM 업로드, Sentry 이슈 분류, 심볼화 실패 디버깅 | **executor** | scripts/upload-dsym.sh 워크플로우 |
| /xm:op·/team 슬래시 커맨드 자체 수정, tm-agent 옵션 추가, 페르소나 프롬프트 갱신 | **architect** + **writer** | 메타 도구 변경 — 설계+문서 동시 |
| executor 완료 후 build·tests 실패, fix 시도 3회+ 반복 블로킹 상황 | **executor** (재위임) + **reviewer** 동시 | 실패 원인 분류 후 fix-attempt budget 소진 전 에스컬레이션 |

> **Anti-pattern — leader가 절대 직접 처리하지 말 것:**
>
> ```bash
> # BAD — leader가 직접 탐색 후 결과를 직접 사용
> grep -r "PeerRelaySession" Sources/ | head -20
> # → 탐색 결과를 leader 컨텍스트에 적재, 탐색 비용 leader가 부담
>
> # GOOD — 탐색을 explorer에 위임, leader는 결과만 소비
> tm-agent delegate explorer 'Find all call sites of PeerRelaySession.connect() — return path:line format'
> tm-agent wait --timeout 30 --mode any
> tm-agent read explorer --lines 50
> ```

### 병렬 수정 웨이브 분할 — 발견 단위가 아니라 파일 소유권 단위

리뷰에서 나온 지적을 여러 에이전트에 나눠 고칠 때, **발견 건수로 자르지 말고 파일 소유권으로 자른다.**
2026-07-29 feat/distributed-workspaces 수정 웨이브에서 확인된 결과:

- P0 5건은 파일이 자연히 안 겹쳐서 그대로 4명에게 배분 → 옥토퍼스 머지 충돌 0, 첫 통합 빌드 컴파일 에러 0.
- P1 14건은 같은 파일에 여러 건이 몰려 있었다(`ReviewBoardCoordinatorService.swift` 3건,
  `TeamOrchestrator+RemoteAgent.swift` 3건). 발견 단위로 나눴다면 여러 에이전트가 같은 파일을
  동시에 편집했을 것이다. 파일 소유권으로 5그룹으로 재구성하니 다시 충돌 0.

각 태스크 캡슐에 반드시 세 가지를 명시한다:

1. **소유 파일 목록** — 이것만 수정 가능
2. **금지 파일과 그 이유** — "X는 executor가 동시에 고치는 중이니 열지 마라"
3. **소유권 밖 정의를 만났을 때의 행동** — 임의로 열지 말고 리더에게 소유권 확장을 요청

3번은 실제로 작동했다. 에이전트 2명이 소유 목록 밖의 타입 정의에 막혔을 때
(`AutoPilotUndoPoint`가 `AutoPilotPolicy.swift`에, `MergeQueueItem`이 `model.rs`에 있었다)
임의 편집 대신 리더에게 확장을 요청했다.

> 리더는 그룹을 자르기 전에 **각 수정 대상이 참조하는 타입·모델 정의가 소유 목록 밖에 있는지**
> 먼저 확인해라. 위 두 건이 그 패턴이다 — 고칠 코드와 그 코드가 쓰는 struct 정의가 다른 파일에
> 산다. 미리 소유 목록에 넣거나, 최소한 확장 요청이 올 것을 예상해 둔다.

### 피어 에이전트의 통신 한계 — reply만 보장된다

피어 호스트에서 도는 에이전트에는 **앱으로 되돌아오는 인가된 RPC 경로가 없다.** 역방향
프록시(`remote_leader_rpc_call`)는 `TERMMESH_LEADER_GRANT_ID`를 받은 remote leader 전용이고,
일반 워커에는 그 grant가 발급되지 않는다. 워커에 주입되는 `TERMMESH_SOCKET`은 피어 호스트의
소켓이라 Mac의 팀을 모른다.

| 호출 | 피어 워커에서 |
|------|--------------|
| `tm-agent reply` | **동작** — 앱이 pane 출력(`onTurnEnd` / `AutoReplyPoller`)에서 회수 |
| `tm-agent msg send` / `inbox` / `task *` | `no_app`·connection reset으로 실패 |

`reply`가 되는 건 RPC가 성공해서가 아니라 앱이 pane 출력에서 헤더를 주워 담기 때문이다
(설계 의도, `TeamOrchestrator+RemoteAgent.swift:892-900`). 그래서 **결과는 전부 reply 본문에
들어가야 한다.** 피어 위임 캡슐에 다음을 넣는다:

```
- 이 호스트에서는 tm-agent msg send / inbox / task 호출이 실패한다. 재시도하지 말고
  BLOCKED로 보고하지도 마라. 전할 내용은 전부 tm-agent reply 본문에 담아라.
- 파일에 상세를 쓸 거면 <task_id>-full.md 같은 고유 파일로. reply alias에 쓰면 지워진다.
```

> grant 스코프를 워커까지 확장하는 건 별건이다 — 현 grant는 `team.delegate`/`broadcast`/`send`
> 까지 포함하는 리더 권한이라 워커에 그대로 줄 수 없다.

### 에이전트의 검증 환경 — 실행 위치를 먼저 확인한다

`tm-agent status`의 host 필드만으로 에이전트의 실행 위치를 단정하지 않는다. 에이전트가 같은 Mac의
`/Users/jinwoo/work/tm-projects/term-mesh-<role>-<date>-<suffix>` worktree에서 실행되는 경우가 있으므로
먼저 `git worktree list`로 실제 경로를 확인한다. 실제 Linux 피어 호스트에는 Swift 툴체인이 없을 수
있지만, 로컬 worktree에서 Swift 빌드가 실패하는 주된 준비 누락은 `GhosttyKit.xcframework` 링크다.

| 실행 위치 | 가능한 검증 | 리더가 준비할 것 |
|-----------|-------------|------------------|
| 실제 Linux 피어 | Rust / Python 빌드·테스트; Swift는 편집·정적 확인 | Swift 변경은 로컬 통합 후 빌드·테스트 |
| 같은 Mac의 별도 worktree | Swift 빌드·테스트 포함 | `GhosttyKit.xcframework` 링크 준비 |

로컬 에이전트 worktree를 만든 뒤 리더 체크아웃과 같은 캐시 대상을 가리키게 한다:

```bash
TARGET=$(readlink GhosttyKit.xcframework)
ln -s "$TARGET" <agent-worktree>/GhosttyKit.xcframework
```

실제 Linux 피어에 Swift 작업을 보낼 때는 태스크 캡슐에 다음을 넣는다(2026-07-29 웨이브에서 효과 확인):

```
- 이 호스트에 Swift 툴체인이 없다. xcodebuild/swift build 시도 금지(시간 낭비).
- 대신 필수: 시그니처를 바꾼 뒤 `rg`로 호출부를 전부 찾아 갱신 누락이 없는지 확인하고,
  그 확인 결과를 보고에 포함해라.
```

그리고 Linux 피어의 Swift 변경은 파이프라인에 **로컬 통합 빌드 단계를 반드시 넣는다.** 피어 에이전트의
STATUS: DONE은 "편집 완료"이지 "빌드 통과"가 아니다. v0.169 웨이브 1에서는 피어의 두
그룹이 기존 테스트 6케이스를 깨뜨렸지만 Swift를 컴파일할 수 없어 로컬 통합 단계에서야
발견됐다. 통합 담당자가 대신 고치지 말고, 실패한 변경은 해당 파일 소유자에게 돌려보내
수정·재검증하게 한다.

### 에이전트 결과 회수

먼저 `git worktree list`로 에이전트의 실제 worktree와 브랜치를 찾는다. 에이전트가 커밋했다면
리더 브랜치에서 그 SHA를 `git cherry-pick <sha>`한다. tracked 변경이 미커밋 상태라면 다음처럼
패치를 만들어 적용한다. 신규 untracked 파일은 이 패치에 포함되지 않으므로 별도로 회수한다.

```bash
git -C <agent-worktree> diff > /tmp/x.patch
git apply --3way /tmp/x.patch
```

### 위임 캡슐의 전달·검증 규칙

- 캡슐이 크면 소켓 프레이밍 문제로 전달이 실패할 수 있다. 내용을 파일에 쓰고 에이전트에는
  `cat <path>`로 읽으라는 짧은 지시만 보낸다.
- 검증 요구에는 비교할 **직전 기준선 숫자**를 함께 쓴다. 예: `직전 기준선 1310 tests, 0 failures`.
- 요구한 빌드·테스트가 통과하기 전에는 완료 보고하지 말라고 명시한다.

### Reply Truncation Protocol

`tm-agent reply`와 `tm-agent collect`는 소켓 전송을 **1500자로 truncate**한다.
제출한 reply 자체는 `~/.term-mesh/results/<team>/` 아래 두 곳에 보존되며 24시간 후 자동 정리된다:

| 파일 | 성격 |
|---|---|
| `<task_id>.md` | 활성 task가 있을 때의 정본 |
| `<agent>-<agent_instance_id>-reply.md` | 그 인스턴스의 최신 reply alias (instance id가 없으면 `<agent>-reply.md`) |

**이 둘은 envelope 보존본이지 상세 저장소가 아니다.** `tm-agent reply`는 매번
`atomic_write_file`(임시파일 + rename)로 **통째 교체**한다 — append가 아니다.

#### 에이전트 의무

- **응답이 1000자를 초과할 경우** 상세를 **고유 파일에 먼저 직접 쓰고**, 그 경로를 헤더에 넣는다:

```
~/.term-mesh/results/<team>/<task_id>-full.md   # 권장 이름
FULL_REPORT: <위에서 쓴 그 경로>
```

- `<team>`: `tm-agent status`의 team_name 필드
- 상세 파일이 없으면 `FULL_REPORT: n/a`

> **절대 하지 말 것:** `<agent>-reply.md` / `<agent>-<instance>-reply.md` / `<task_id>.md` 를
> FULL_REPORT 경로로 쓰는 것. 상세를 거기 먼저 써 두면 **뒤이은 `tm-agent reply`가 그대로 덮어써
> 본문이 사라진다.** 13efe520의 자기참조 검사는 헤더를 `n/a`로 정규화해 dangling pointer만 막을
> 뿐, 파일 교체 자체는 막지 않는다. 2026-07-30 architect ADR 유실이 정확히 이 경로였다.

#### Leader가 풀 내용을 읽는 명령

```bash
# 제출된 reply 정본 (envelope)
cat ~/.term-mesh/results/my-team/<task_id>.md

# 그 인스턴스의 최신 reply alias
cat ~/.term-mesh/results/my-team/<agent>-<agent_instance_id>-reply.md

# 헤더가 가리키는 상세 본문 — FULL_REPORT 경로를 그대로 연다
cat ~/.term-mesh/results/my-team/<task_id>-full.md
```

> **BAD/GOOD 예시:**
>
> ```bash
> # BAD — collect 결과가 "..." 로 끊겨 핵심 VERIFY 명령이 누락됨
> tm-agent collect --lines 100
> # → "...확인 필요. VERIFY: xcodebuild -scheme term-mesh ..." (잘림)
>
> # GOOD — truncation 감지 후 파일 직접 읽기
> tm-agent collect --lines 100
> # 결과 끝이 "..." 이거나 FULL_REPORT가 n/a가 아니면:
> cat ~/.term-mesh/results/my-team/executor-reply.md
> ```

### Standard Reply Header

모든 에이전트 reply는 다음 **5필드 헤더**로 시작한다.
이 헤더는 brainstorm(2026-05-08) Tier 1 Cluster D 합의 결과를 영구화한 것이다.

```
STATUS: DONE|BLOCKED|NEEDS_REVIEW
FILES: <변경된 파일 경로, 복수 시 공백 구분, 없으면 "none">
VERIFY: <결과를 확인하는 단일 shell 명령, 해당 없으면 "n/a">
NEXT: <leader가 다음에 실행할 액션 한 줄, 없으면 "NONE">
FULL_REPORT: <전체 결과 파일 경로, 해당 없으면 "n/a">
```

- **모든 task**: 5필드 의무. 해당 없으면 `n/a`/`none`/`NONE` 사용.
- 헤더 다음에 페르소나별 본문 포맷이 이어진다 (아래 참조)

#### 페르소나별 포맷과의 관계

Standard Header가 **첫 블록**, 페르소나 고유 포맷이 **본문**이다. 중복 필드(예: security의 VERIFY 필드)는 헤더 VERIFY와 동일 값을 사용한다.

| 에이전트 | 본문 포맷 |
|---------|----------|
| explorer | `path:line — 역할 한 줄` |
| reviewer | `[P0-P3][file:line] 설명 → patch snippet + VERDICT: LGTM\|CHANGES` |
| security | `[SEVERITY][CWE][FILE:LINE][PoC][FIX][VERIFY]` 6필드 |
| planner | `TASK\|PHASE\|OWNER\|INPUT\|OUTPUT\|DEPS\|ACCEPT + tm-agent task create 라인` |
| architect | ADR 섹션 + Swift/Rust 스텁 + sequence pseudo |
| executor | `STATUS\|FILES\|VERIFY\|NEXT\|FULL_REPORT 헤더 + diff/build 결과` |
| frontend | `STATUS\|FILES\|VERIFY\|NEXT\|FULL_REPORT 헤더 + portal 경계 명시 + dlog 이벤트 목록` |
| backend | `STATUS\|FILES\|VERIFY\|NEXT\|FULL_REPORT 헤더 + RPC 변경 시 첫 줄 Swift 영향 YES/NO + CHANGED_FILES` |
| tester | `STATUS\|FILES\|VERIFY + 테스트 케이스 수 N/M + VM 필요 여부` |
| writer | `STATUS\|FILES\|VERIFY\|NEXT\|FULL_REPORT 헤더 + 삽입 위치 + Self-check 한 줄` |

#### Leader가 STATUS·NEXT를 일괄 추출하는 명령

```bash
# 전체 에이전트 collect 후 STATUS·NEXT만 추출
tm-agent collect --lines 100 | grep -E "^(STATUS|NEXT):"

# 특정 에이전트의 헤더만 확인
cat ~/.term-mesh/results/my-team/<agent>-<agent_instance_id>-reply.md | head -5
```

## E2E tests

term-mesh has two e2e layers. **Default to socket e2e**; reserve XCUITest for what the socket can't reach.

- **Socket e2e (`tests_v2/` via `termmesh.py`)** — the standard for app logic, layout, focus, splits, workspaces, browser, notifications, CLI parity, and regressions. Authoring/running rules live in **[`tests/CLAUDE.md`](tests/CLAUDE.md)** (single source of truth; auto-loads when working in `tests/` or `tests_v2/`). New tests go in `tests_v2/`.
- **XCUITest (`termMeshUITests/`)** — only for OS-level key routing, menu key-equivalents, system dialogs, and Accessibility-driven interaction.

Run on the UTM macOS VM (never the host). Always via `ssh term-mesh-vm`:

```bash
# Socket e2e suites (VM-only, guarded to user `term-mesh`)
ssh term-mesh-vm 'cd /Users/jinwoo/term-mesh/GhosttyTabs && ./scripts/run-tests-v2.sh'

# XCUITest example
ssh term-mesh-vm 'cd /Users/jinwoo/term-mesh/GhosttyTabs && xcodebuild -project GhosttyTabs.xcodeproj -scheme term-mesh -configuration Debug -destination "platform=macOS" -only-testing:termMeshUITests/UpdatePillUITests test'
```

## Basic tests

Run basic automated tests on the UTM macOS VM (never on the host machine):

```bash
ssh term-mesh-vm 'cd /Users/jinwoo/term-mesh/GhosttyTabs && xcodebuild -project GhosttyTabs.xcodeproj -scheme term-mesh -configuration Debug -destination "platform=macOS" build && pkill -x "term-mesh DEV" || true && APP=$(find /Users/jinwoo/term-mesh/Library/Developer/Xcode/DerivedData -path "*/Build/Products/Debug/term-mesh DEV.app" -print -quit) && open "$APP" --env TERMMESH_SOCKET_MODE=allowAll && for i in {1..20}; do [ -S /tmp/term-mesh-debug.sock ] && break; sleep 0.5; done && python3 tests/test_update_timing.py && python3 tests/test_signals_auto.py && python3 tests/test_ctrl_socket.py && python3 tests/test_notifications.py'
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

<!-- gk:agents:begin v14 — managed by `gk agents install`; edit outside this block -->
## Git workflow (git-kit)

This repository is driven with git-kit, an agent-native git CLI. Always invoke it as `git-kit` — the short name `gk` is the same binary but is commonly shadowed by shell aliases (oh-my-zsh maps `gk` to gitk), so it is not reliable from an agent shell. Set `export GK_AGENT=1` once: every command then emits a uniform envelope — `{ok, result}` on success, `{ok:false, error:{code, message, remedies:[{command,safety}]}}` on failure — so you branch on fields, never parse prose. Prefer git-kit over raw git:

- **Orient first**: `git-kit context` — one call returns branch, upstream, ahead/behind, dirty counts, any in-progress rebase/merge (with resume/abort commands), base-branch drift, worktrees, and `next_actions`. Add `--include=diff,log,precheck,remotes,release` (or `--include=all`) to fuse the uncommitted-change digest (untracked included), the last 5 commits, the next-pull conflict forecast, per-remote drift, and the commits since the latest tag (what is still unreleased) into the same document — one call instead of six; a section that cannot be collected degrades to a `notes` entry, never an error. Never chain raw git status/branch/log/diff probes across separate calls — one context call answers them all.
- **Wrap up**: `git-kit land` — commit (AI-grouped), pull --with-base, push as one transaction with per-step results; on failure the result names `failed_step` and the resume command. `--cleanup` also reclaims fully-merged branches and their worktrees.
- **Local wrap-up (no network)**: `git-kit promote` — commit, then forward-merge the current branch into its parent/base (gk-parent metadata, trunk fallback); `git-kit promote <branch>` walks the parent chain hop by hop. Nothing is pushed without `--push` — use it when integration is local and land would push too early. Same per-step result contract as land.
- **Batch any sequence**: `git-kit batch --plan -` — run several git-kit commands as one transaction from a JSON plan on stdin: `{"steps":[{"args":["pull","--with-base"]},{"args":["push"]}]}`, optional per-step `on_failure: "abort"|"continue"`. The result reports per-step outcomes plus `failed_step`/`resume`; a gating failure skip-marks the remaining steps. Draft a plan with `--plan-template`, preview with `--dry-run`. N calls → 1.
- **Sync**: `git-kit pull` (add `--with-base` to also fast-forward the local base branch, FF-only). On conflict the result lists the files plus the exact resume/abort commands. `--from <remote>[/<branch>]` integrates from a secondary remote (mirror, org fork) that the upstream chain never fetches — tracking config stays untouched.
- **Forecast before integrating**: `git-kit precheck [target]` — read-only merge-tree simulation (no target = the next pull). Clean → integrate; conflicts listed → pick a strategy first instead of try→abort.
- **Inspect changes**: `git-kit diff --digest` — per-file change kind, ±lines, hunk count, and the changed symbols, without the patch body. Same ref/path arguments as plain diff (`--staged`, `HEAD~3`, `main..feature`). Read the full patch only for the files the digest makes interesting.
- **Isolated worktree task**: `git-kit worktree run <branch> -- <command>` — create (or reuse) a worktree for `<branch>`, run the command with the worktree as its cwd, and exit with the command's own exit code: the single-shot CLI form of a parallel, isolated task (a new branch is cut off HEAD, gk-parent recorded, `worktree.init` applied). `--cleanup` reclaims the worktree when the command succeeds (and deletes the branch if this call created it); a failing command is left in place for inspection. `--from <ref>` bases a new branch elsewhere, `--init`/`--no-init` force or skip the gitignored-state bootstrap. To find which worktree holds unfinished work without a per-path probe, `git-kit worktree list --json` reports each worktree's branch, ahead/behind, parent, lock state, and dirty counts in one call.
- **Commit / push**: `git-kit commit -f` groups changes into conventional commits; `git-kit push` scans for secrets before pushing.
- **Curated multi-commit**: when YOU decide the grouping instead of the AI, `git-kit commit --plan-template` emits the dirty files as a JSON draft; split it into `{"commits":[{"message":"feat(x): ...","files":[...]}]}` and run `git-kit commit --plan -` — N curated commits in one deterministic call (no AI, secret scan included, backup ref behind `gk commit --abort`). Duplicate/unknown files and malformed messages are rejected up front; files the plan does not cover stay dirty. Use this instead of chaining raw `git add` + `git commit` pairs.
- **History editing**: never open `git rebase -i` (the editor session is unusable for you). Instead: `git-kit rebase --plan-template` emits the commit range as JSON (action/commit/subject/pushed), you decide each commit's fate (pick/squash/fixup/reword/drop), then `git-kit rebase --plan -` validates it (every commit addressed, pushed commits guarded) and drives git's own rebase with a backup ref.
- **Conflicts**: `git-kit resolve --ai` (or `--strategy ours|theirs`) resolves AND finishes the operation — it runs the continue step itself, re-resolves later picks that conflict with the same strategy, auto-skips picks the resolution emptied, and also handles delete/modify and markerless conflicts from the index stages (AI decides keep/delete/merge with a rationale); one call takes a paused rebase to done (`--no-continue` to stop after resolving, `git-kit abort` to give up). `git-kit continue` remains for manually edited resolutions. A paused state is a result (exit 3), not an error.
- **Release**: read the plan first — `git-kit ship --dry-run --json` emits the full release plan (inferred version, CHANGELOG draft, the preflight/watch/verify step lists, and `merge_to_base`). When it looks right, `git-kit ship -y` runs the whole pipeline — preflight (lint/test) → version/CHANGELOG → tag → push → CI watch → artifact verify — and works under GK_AGENT: human progress streams to stderr while stdout stays a clean result envelope `{tag, branch, base, merged_to_base, pushed, shipped_on}` (no `env -u GK_AGENT` dance needed). Preflight (lint/test) gates the release, so validate up front with `git-kit ship --preflight` (runs the configured checks on the working tree — dirty is fine — and never tags or pushes; `{result, steps, failed_step}` under GK_AGENT) and get them green before `-y`; `git-kit commit` also warns on gofmt before it reaches preflight. From a non-base branch (e.g. develop) ship fast-forwards the base (main) and tags there; if history diverged it stops, so run `git-kit pull --with-base` first. `--wait=false` (or `ship.wait`) skips the CI watch; `ship.auto_confirm` makes `-y` the default. What's still unreleased: `git-kit context --include=release`.
- **Stuck repo** (stale index.lock, orphan merge, prunable worktrees, asymmetric push-only remotes whose merged work never comes down): `git-kit doctor --fix`.
- On any failure run the first entry of `error.remedies` (check `safety` first) instead of retrying variations.
<!-- gk:agents:end -->
