# Agent pipe transport & native panes (spike)

Experimental opt-in path that delivers team instructions over a pipe instead of
typing into a terminal pane, and optionally renders agent sessions in a native
SwiftUI surface rather than a Ghostty grid.

**Status:** spike / off by default. The terminal pane path remains the product
default.

## User-facing controls

| Setting | Location | Default | Effect |
|---------|----------|---------|--------|
| Agent Panes | Settings → Agent Teams → **Agent Panes** | Terminal | **Native** enables pipe transport (`agentPipeTransport.enabled`) and native rendering (`agentPipeTransport.nativePanel`) together. |
| CLI paths | Settings → CLI Paths | — | Lists all known CLIs including `cursor` and `agy`; paths can be configured before Native mode is on. |
| Agent picker CLIs | Team / role preset CLI field | claude, kiro, codex, gemini | With Native on, adds **cursor** and **agy**. |

UserDefaults keys (for debugging):

- `agentPipeTransport.enabled` — pipe delivery instead of paste+Return
- `agentPipeTransport.nativePanel` — SwiftUI `AgentPanel` instead of terminal
- `agentPipeTransport.render` — filter stdout through renderer (default `true`; no Settings UI yet)

## Modes compared

| | Terminal (default) | Native (experimental) |
|---|-------------------|----------------------|
| Transport | Paste instruction + synthetic Return | FIFO / process stdin (Claude NDJSON) or bridge |
| UI | Ghostty terminal showing CLI TUI or `--print` NDJSON | `AgentPanelView` over `AgentSession` model |
| Completion | `AutoReplyPoller` screen-diff heuristic | `AgentPipeCompletion` watches `{"type":"result"}` events |
| Watchability | Full TUI visible | Structured transcript (tools fold, streaming answer) |
| cursor / agy | Not offered (no interactive UI / no stdin channel) | Offered via bridge (turn-per-process CLIs) |

## Supported CLIs on the pipe

| CLI | Mechanism | Notes |
|-----|-----------|-------|
| claude | Direct NDJSON on stdin (`--input-format stream-json`, `--print`) | One long-lived process, context retained |
| codex, kiro | `scripts/spike/tm-agent-bridge.py` | Request/response protocols; bridge owns stdio |
| cursor, agy | Same bridge | Turn = subprocess; session id from answer (cursor) or log (agy) |

Bridge and optional terminal renderer scripts (resolved from app bundle or repo cwd):

- `scripts/spike/tm-agent-bridge.py`
- `scripts/spike/tm-render-claude.py`

Per-agent FIFO: `/tmp/term-mesh-agent-pipe/<agentId>.fifo`<br>
Event tee (completion watcher): `<fifo>.events`

## Native pane UI

`AgentPanel` / `AgentPanelView` / `AgentSession`:

- Header: role colour rail, agent name, CLI badge, optional session summary, working/writing indicator
- Transcript: instructions, streamed answers, tool rows (spinner while running, foldable output), turn-end cost/timing
- Composer: person can still type into the session (keyboard returned to user; no synthetic Return on empty panes)
- Shell integration health shows **agentMode** (blue) — TUI shell integration N/A

Role colour is assigned to the **agent role**, not the pane slot.

## tm-agent behaviour (unchanged CLI surface)

`tm-agent delegate`, `send`, and `broadcast` use the same commands. When an
agent is pipe-driven, delivery goes through `AgentPipeTransport.deliver` and
completion through `AgentPipeCompletion` instead of the auto-reply poller.

Standard Reply Header parsing reads a clean `result` string on the pipe path;
the 5-field STATUS/FILES/VERIFY/NEXT/FULL_REPORT contract is unchanged.

## Verification

```bash
# Unit tests
xcodebuild -project GhosttyTabs.xcodeproj -scheme term-mesh -configuration Debug \
  -destination 'platform=macOS' \
  -only-testing:termMeshTests/AgentSessionTests \
  -only-testing:termMeshTests/AgentPipeCompletionTests test

# Manual: enable Native in Settings, create team with claude agent, delegate a task
./scripts/reload.sh --tag agent-pipe --allow-all
```

Stress script (spike): `scripts/spike/stress-native-agents.py`

## Related source

| Area | Files |
|------|-------|
| Transport & launch | `Sources/AgentPipeTransport.swift` |
| Turn completion | `Sources/AgentPipeCompletion.swift` |
| Native UI | `Sources/Panels/AgentPanel.swift`, `AgentPanelView.swift`, `AgentSession.swift` |
| Team integration | `Sources/TeamOrchestrator.swift` |
| CLI eligibility | `Sources/AgentRolePreset.swift` |
| Settings toggle | `Sources/SettingsView.swift` (Agent Teams → Agent Panes) |
