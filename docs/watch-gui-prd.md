# Watch GUI PRD

Last updated: May 29, 2026

## Status

Draft. This PRD covers the product UI for configuring autonomous `/watch` drift oversight from the term-mesh macOS app.

## Background

term-mesh now has daemon-side autonomous watch support. A team can register one `WatchState` and run periodic stateless checks against either one worker or all workers. For `target = nil`, empty string, or `"all"`, the daemon fans out across the configured worker list and creates one bounded one-shot watcher check per worker.

The current gap is product clarity. Users can create a "Pair with" watcher pane, but that pane may sit idle unless watch is configured. Users also need to understand whether "all" means one huge context or multiple bounded checks. The GUI should make watch state explicit, low-friction, and cost-aware.

## Current Implementation Constraints

Relevant implementation:

1. `daemon/term-meshd/src/watch.rs`
   - `WatchState.target == None | "" | "all"` means all-workers fan-out.
   - `WatchState.workers` stores the worker names for all-workers mode.
   - One `WatchCheckInput` is created per worker.
   - Checks for one team run sequentially inside a team-level task.
   - `in_flight` clears only after all worker checks finish.

2. `daemon/term-meshd/src/socket.rs`
   - `watch.on` accepts optional `workers`.
   - If `workers` is absent, headless teams are queried from `HeadlessManager`.
   - GUI teams fall back to `team.status` via `app_socket_path`.
   - Worker names are deduplicated by name; duplicate-named agents cannot be watched independently yet.

3. `daemon/term-mesh-cli/src/tm_agent.rs`
   - CLI already describes `--target` as optional with default all workers.
   - `watch.status` currently renders `target`, but does not show worker list or worker count.

## Product Problem

Users need a clear way to answer:

1. Is this team currently being watched?
2. Who is being watched?
3. What spec is the watcher judging against?
4. How expensive or slow will the next watch tick be?
5. Did the latest watch tick find drift?
6. Why did my "Pair with" agent sit idle?

Without GUI affordances, watch feels like a hidden daemon feature and `Pair with` reads as broken when no spec/config is active.

## Goals

1. Make watch configuration visible from the team UI.
2. Make `All workers` the default target when a valid spec exists.
3. Show that `All workers` means `N` bounded checks, not one unbounded context.
4. Let users switch target, stance, interval, model, and spec without destroying the team.
5. Make `Pair with` either enable watch intentionally or clearly show that watch is off.
6. Keep all watch operations focus-safe and report-only.

## Non-Goals

1. Editing files or auto-applying watcher recommendations.
2. Per-worker independent schedules in the first GUI version.
3. Rich analytics across historical teams.
4. Solving duplicate-named worker routing. The first version may show this as a limitation.
5. Replacing `/watch review` one-shot CLI workflows.

## Primary Users

1. Leader running a multi-agent team in the GUI.
2. User creating a new team with "Pair with" enabled.
3. User debugging a long-running or risky task and wanting drift oversight.

## UX Principles

1. Watch is a team policy, not just a watcher pane.
2. The default should be safe: off without a spec, all workers with a spec.
3. Cost should be visible at the point of action.
4. Status should be readable without opening a terminal.
5. The UI should use native controls: toggles, segmented controls, popovers, menus, and compact status chips.

## Entry Points

### Team Sidebar Row

Add a `Watch...` item to the team row context menu:

1. `Configure Watch...`
2. `Run Watch Check Now`
3. `Stop Watch`

If watch is enabled, the team row should show a compact indicator:

```text
Watch: All workers · pair · next 04:32
```

If watch has an error:

```text
Watch: Error · missing spec
```

### Agent Row

Add `Watch This Agent` to an agent row context menu.

Action:

```bash
tm-agent watch on <team> --target <agent> ...
```

The UI should preserve the existing spec, stance, interval, CLI, and model when switching target.

### Team Creation

In the "Pair with" area, add:

1. `Pair mode`: `Pane only` / `Auto watch`
2. `Spec`: inline text or `@.xm/watch/default-spec.md`
3. `Stance`: `Critic` / `Advisor` / `Pair`

Behavior:

1. `Pane only`: create the watcher pane, do not enable watch.
2. `Auto watch` with spec: create watcher and enable `target=all`, `stance=pair` by default.
3. `Auto watch` without spec: block creation or downgrade to `Pane only` with an explicit warning.

Recommended copy:

```text
Pair pane created. Watch is off until a spec is set.
```

## Configure Watch Sheet

Open from team row or command palette.

### Controls

1. `Enabled`: toggle.
2. `Target`: radio group.
   - `All workers`
   - `Specific agent`
3. `Specific agent`: dropdown, enabled only when selected.
4. `Stance`: segmented control.
   - `Critic`
   - `Advisor`
   - `Pair`
5. `Spec`: segmented source.
   - `Project spec file`
   - `Inline spec`
6. `Spec value`:
   - path field for `@path`
   - multiline text for inline spec
7. `Interval`: presets plus custom.
   - `5m`
   - `10m`
   - `30m`
   - `Custom`
8. `Watcher CLI`: dropdown.
9. `Watcher model`: dropdown based on selected CLI.

### Cost Preview

Always show a preview before applying:

```text
All workers: 6 bounded checks every 5m
Each check reads up to 200 recent lines and 16,000 chars.
Checks run sequentially; long teams may skip overlapping ticks.
```

For specific target:

```text
executor: 1 bounded check every 5m
```

### Status Panel

Show:

1. `enabled`
2. `target`
3. `workers`
4. `worker_count`
5. `stance`
6. `interval`
7. `last_tick`
8. `next_tick`
9. `running`
10. `last_error`
11. `drift_count`

## Required Backend/API Improvements

### R1. Expose Workers in watch.status

`watch.status` should include:

```json
{
  "target": "all",
  "workers": ["explorer", "executor", "reviewer"],
  "worker_count": 3
}
```

Reason: GUI must explain what `All workers` means without re-deriving state from team roster. In-memory watch state is the source of truth because it may have been registered with explicit workers.

### R2. Preserve Existing Config on Partial Update

When GUI changes only target, it should not need to resend every field. If the backend keeps current replace semantics, the GUI must read current status first and submit a full merged update.

Preferred future RPC:

```text
watch.update
```

For MVP, use `watch.on` as an upsert and send the full resolved config.

### R3. Report Duplicate-Name Limitation

If duplicate worker names exist, `All workers` should show a warning:

```text
Duplicate agent names detected. Watch can address only one pane per name.
```

This follows the current name-based `tm-agent read <target>` limitation.

### R4. One-Shot Check Now

GUI should support `Run Watch Check Now`.

MVP options:

1. Call existing `/watch review` command path.
2. Add a daemon RPC that triggers a watch sweep for the team immediately.

Preferred product behavior: no interval reset surprise. Manual checks should not postpone scheduled checks unless the backend explicitly documents that behavior.

## Functional Requirements

### P0

1. Add Configure Watch sheet.
2. Add team row watch indicator.
3. Add team row context menu actions.
4. Add agent row `Watch This Agent`.
5. Add team creation "Pair mode" controls.
6. Use `All workers` as the default target when spec is present.
7. Require spec before enabling watch.
8. Show worker count and bounded-check explanation.
9. Show `last_error` in the UI.
10. Preserve current watch config when changing only one setting.

### P1

1. Add command palette actions:
   - `Configure Team Watch`
   - `Run Watch Check Now`
   - `Stop Team Watch`
2. Add recent drift findings preview from `.xm/watch/board.jsonl`.
3. Add `Auto high-risk` target mode.
   - Priority: `review_ready`, blocked/stale active task, active executor, recent reviewer.
4. Add duplicate-name warning and route users toward unique agent names.
5. Add per-worker result summary for the latest all-workers tick.

### P2

1. Per-worker watch policy.
2. Parallel all-workers checks with bounded concurrency.
3. Historical trend view.
4. Per-team watch templates.

## Acceptance Criteria

1. Creating a team with `Pair with` and `Auto watch` plus a spec enables watch for all workers.
2. Creating a team with `Pair with` and no spec does not silently imply active watch.
3. The team UI shows whether watch is on or off within one refresh cycle.
4. `All workers` displays the exact worker count before enabling.
5. Changing target from `All workers` to `reviewer` updates watch without destroying the team.
6. `Watch This Agent` preserves the existing spec and stance.
7. `watch.status` includes enough data for the GUI to render workers without calling `team.status`.
8. If watch is running, the UI disables destructive config edits or marks them as applying on the next tick.
9. If the spec file is missing or empty, the UI shows the backend error and keeps watch disabled or unhealthy.
10. No watch action steals macOS focus from the user's active pane.

## Telemetry / Debug Signals

Add DEBUG logs around GUI actions:

1. `watch.gui.open team=<team>`
2. `watch.gui.enable team=<team> target=<target> workers=<n>`
3. `watch.gui.disable team=<team>`
4. `watch.gui.update team=<team> field=<field>`
5. `watch.gui.runNow team=<team>`
6. `watch.gui.error team=<team> error=<message>`

These should go through the existing debug event log in DEBUG builds.

## Open Questions

1. Should manual `Run Check Now` use the existing command shim or a daemon RPC?
2. Should `Pair with` default to `Pane only` or `Auto watch` when a default spec file exists?
3. Should the GUI auto-create `.xm/watch/default-spec.md` from a template?
4. Should all-workers fan-out remain sequential, or should the daemon add bounded concurrency?
5. Should watch config be considered part of team state, workspace state, or project state?

## Recommended MVP

1. Implement `watch.status` workers exposure.
2. Add Configure Watch sheet using `watch.on/off/status`.
3. Add `Pair mode` in team creation.
4. Add team row status indicator.
5. Add `Watch This Agent`.

This ships a coherent product without requiring a new scheduler model. The main product tradeoff is transparent: all-workers watch is easy and bounded, but it costs one check per worker per interval.
