# ADR 0002: tmux Control Backend

Status: Proposed
Date: 2026-05-11

## Context

ADR 0001 selects `AgentHost(LinuxSSH)` as the MVP authority model and keeps
tmux integration behind a separate `TmuxControlBackend`, rather than extending
the Protobuf peer relay wire. This ADR expands ADR 0001 Phase 1: how term-mesh
should parse tmux control mode, encode commands, map tmux sessions/windows/panes
into term-mesh surfaces, and reuse the existing peer relay terminal-response
filtering policies. tmux control mode is a textual protocol designed for
external clients; it emits command blocks and `%` notifications instead of
typed Protobuf frames, so it must be adapted at the backend boundary.

Non-goal: the Linux `AgentHost` task protocol; this ADR only defines the remote
multiplexer backend used to view and control tmux panes.

## Wire-level Protocol Subset

`TmuxControlBackend` starts tmux with control mode enabled and consumes stdout
line by line. It should handle only the subset needed for remote surfaces and
layout mirroring.

### Whitelisted Events

| Event | Purpose |
| --- | --- |
| `%output <pane-id> <octal-escaped-bytes>` | Convert pane output into `PtyData` for the matching surface. |
| `%extended-output <pane-id> <age> : <octal-escaped-bytes>` | tmux 3.2+ output with buffered age metadata; decode payload exactly like `%output`. |
| `%pause <pane-id>` | Flow-control signal; schedule fast resume. |
| `%continue <pane-id>` | Flow-control state returned to normal. |
| `%window-add <window-id>` | Mark workspace list stale and resync windows/panes. |
| `%window-close <window-id>` | Remove or invalidate the matching workspace. |
| `%window-renamed <window-id> <name>` | Update workspace title. |
| `%window-pane-changed <window-id> <pane-id>` | Update active pane metadata. |
| `%layout-change <window-id> <layout> <visible-layout> <window-flags>` | Rebuild or patch the split tree for that window. |
| `%sessions-changed` | Mark all session/window inventory stale and resync. |
| `%session-changed <session-id> <name>` | Update active session metadata. |
| `%session-renamed <session-id> <name>` | Update host/team label. |
| `%client-detached <client-name>` | Diagnostic; may affect size conflict warnings. |
| `%client-session-changed <client-name> <session-id> <name>` | Diagnostic and resync trigger. |
| `%exit [reason]` | End the backend session and surface disconnect. |
| `%begin <time> <cmd-number> <flags>` | Start of a command response block. |
| `%end <time> <cmd-number> <flags>` | Successful command response end. |
| `%error <time> <cmd-number> <flags>` | Failed command response end. |

`%extended-output` has historically included a literal `:` separator before the
payload. The parser must tolerate both the colon and no-colon forms.

### Ignored Events

| Event | Reason |
| --- | --- |
| `%paste-buffer-changed` | Clipboard/buffer UI is out of MVP scope. |
| `%config-error` | Log and expose diagnostics; it does not change surface state. |
| `%message` | Human tmux status messages are not pane output. |
| `%unlinked-window-add`, `%unlinked-window-close`, `%unlinked-window-renamed` | Non-current-session windows are outside Phase 1.0/1.1. |
| `%pane-mode-changed` | Copy-mode mirroring is out of MVP scope; resync active pane only. |
| Unknown `%...` notification | Log once per event kind and continue unless it breaks framing. |

Ignored events must not be forwarded to a pane as bytes.

## Parser State Machine

The parser is an async line parser over tmux stdout. It has three logical states:

```text
Idle --%begin--> InCommandBlock(cmd_number) --%end/%error--> Idle
Idle --%event--> InNotify --route event--> Idle
```

`InNotify` is intentionally short-lived: a single `%` line is parsed and routed
without holding the state across reads. Command blocks may contain arbitrary
text output lines until their `%end` or `%error` boundary.

Initial DCS framing: the first stdout chunk from `tmux -CC` begins with
`\033P1000p`, and the control-mode stream is conceptually wrapped in a DCS
envelope terminated by `\033\\` at session exit. The parser must strip the
leading `\033P1000p` and terminating ST before applying the `%`-line state
machine.

Pseudo Rust shape:

```rust
enum ControlState {
    Idle,
    InCommandBlock { cmd_number: u64, lines: Vec<String> },
    InNotify,
}

enum TmuxEvent {
    PaneOutput { pane: TmuxPaneId, bytes: Vec<u8>, age_ms: Option<u64> },
    Pause { pane: TmuxPaneId },
    Continue { pane: TmuxPaneId },
    LayoutChange { window: TmuxWindowId, layout: String, visible: String, flags: String },
    CommandDone { cmd_number: u64, output: Vec<String> },
    CommandError { cmd_number: u64, output: Vec<String> },
    Exit { reason: Option<String> },
    InventoryStale,
    Ignored,
}

fn parse_control_line(state: &mut ControlState, line: &str) -> Result<Option<TmuxEvent>>;
```

### Octal Unescape

tmux `%output` payloads escape non-printable bytes and backslash as three-digit
octal sequences. The parser must decode to raw bytes before feeding Ghostty.

```rust
fn unescape_tmux_octal(input: &[u8]) -> Result<Vec<u8>, TmuxParseError>;
```

Algorithm: copy ordinary bytes unchanged; when `\` appears, require exactly
three following octal digits and emit `(a * 64) + (b * 8) + c`. A backslash not
followed by three octal digits is malformed.

Malformed escape policy:

- In `%output`: discard the malformed line, mark the surface dirty, and request
  a `capture-pane` seed if the phase supports it.
- In command blocks: fail that command response and keep the control connection.
- Repeated malformed output from the same pane should trip a backend health
  warning rather than hard-kill the SSH process immediately.

Truncated line policy:

- The line reader must enforce a maximum line length.
- If a line exceeds the cap, discard it, emit a parse health warning, and
  trigger resync for that pane/window.
- If the stream ends mid-line, treat it as SSH EOF.

## Encoder / Command Side

All commands are sent through a single command task that owns tmux stdin. No
other task writes to the process directly.

Supported commands:

```text
send-keys -t %<pane-id> -H <hex>...
load-buffer -b <buffer-name> <safe-temp-path>
paste-buffer -t %<pane-id> -d -b <buffer-name>
refresh-client -C <w>x<h>
refresh-client -A %<pane-id>:on
select-pane -t %<pane-id>
split-window -h -t %<pane-id>
split-window -v -t %<pane-id>
```

Binary input uses `send-keys -H` with bytewise lowercase hex tokens. This avoids
tmux string quoting and preserves bytes that would be unsafe in a command line.

Paste input uses a tmux buffer for larger chunks. The adapter must not inline
arbitrary paste bytes into the control command stream. It should write the paste
payload to a backend-owned safe temporary file on the remote host, then run:

```text
load-buffer -b <buffer-name> <safe-temp-path>
paste-buffer -t %<pane-id> -d -b <buffer-name>
```

The temporary path must be generated by the backend, live under a private
directory, and be deleted after `paste-buffer` completes or times out.

### Command Queue and Correlation

The command task assigns a local command id before writing a command line. tmux
responds with `%begin/%end/%error <cmd-number>`; the parser resolves the
matching pending command through a correlation map.

If tmux does not expose the command number until `%begin`, the first unresolved
FIFO command is associated with that `%begin` number. Only one writer task may
exist, preserving order.

Security rules: validate tmux identifiers (`%N`, `@N`, `$N`), never build
commands through a shell string, never quote user payload as a substitute for
binary encoding, and generate all buffer/temp names inside the backend.

## Session Model Mapping

```text
tmux session  -> TermMeshTeam / AgentHost scope
tmux window   -> TermMeshWorkspace
tmux pane     -> TermMeshSurface leaf
tmux layout   -> SplitTree proportional layout
```

MVP mapping depth:

- Phase 1.0 attaches to one tmux window and one active pane.
- Phase 1.1 mirrors one tmux window's full pane tree.
- Window switching is an explicit command or later UI action, not automatic
  multi-window sync.

Identifiers:

```rust
struct TmuxIds {
    pane_to_surface: HashMap<TmuxPaneId, SurfaceId>,
    surface_to_pane: HashMap<SurfaceId, TmuxPaneId>,
    window_to_workspace: HashMap<TmuxWindowId, WorkspaceId>,
}
```

`SurfaceId` is term-mesh-owned for the backend attachment lifetime; tmux pane
ids remain authoritative while the tmux server is alive.

### Layout Parser

tmux layout strings encode a recursive pane tree:

```text
1f3a,200x50,0,0[100x50,0,0,1,100x50,101,0,2]
```

The parser should produce a proportional `SplitTree` with `Pane` leaves and
horizontal/vertical `Split` interior nodes. The checksum prefix is parsed for
validation but not used as an identifier. If the layout parser fails, keep
existing surfaces alive and mark layout stale.

## Resize Policy

tmux can force a window to the smallest attached client. The backend should
avoid accidental shrinkage by making its size explicit:

- Set or recommend `aggressive-resize on` for sessions managed by term-mesh.
- Send `refresh-client -C <w>x<h>` on initial attach.
- Send `refresh-client -C <w>x<h>` after every local terminal resize debounce.
- Warn, but do not auto-resolve, if other tmux clients are attached and the
  observed layout size differs from the requested size.

Phase 1.0 resize is window/client-level only.

## Pause / Flow Control

tmux may pause pane output for a control client that falls behind and can exit
with "too far behind" if the client does not respond for roughly 300 seconds.

Policy:

- On `%pause <pane-id>`, enqueue `refresh-client -A %<pane-id>:on` immediately.
- The command must be written within 5 seconds.
- Maintain a watchdog per paused pane.
- On `%continue <pane-id>`, clear the watchdog.
- If the watchdog fires, mark the backend degraded and reconnect.

Flood handling after resume:

- Prefer catch-up with bounded channels.
- Do not silently drop bytes while the bounded channel has capacity.
- If a surface channel overflows, mark the surface dirty and request a later
  `capture-pane` seed if supported.
- Phase 1.0 may disconnect the backend on repeated overflow rather than trying
  to synthesize a perfect grid snapshot.

## Input Encoding Path

Input path:

```text
Ghostty key event
  -> local terminal bytes
  -> existing terminal-response/input filter
  -> tmux send-keys -H byte hex
  -> remote tmux pane
```

`send-keys -H` is binary-safe for bytes, including escape sequences generated by
Kitty keyboard protocol. The adapter should not attempt to interpret every
Kitty sequence in Phase 1.0. It forwards the filtered byte stream as hex.

If bracketed paste handling is needed, it should be explicit and tested against
tmux's current paste behavior. The MVP should avoid inventing a second paste
protocol.

IME policy:

- Send only committed text chunks from the macOS text input system.
- Do not send partial marked text to tmux panes.
- Reuse the existing peer relay shim policy for Korean Ctrl+jamo correction.
  That policy maps Korean 2-set IME jamo generated by physical Ctrl+key back to
  QWERTY control bytes so shortcuts such as Ctrl+C remain ETX.
- The policy should live in shared filtering code rather than being duplicated
  in the tmux adapter.

## OSC / Terminal Response Filtering

The tmux adapter must reuse the peer relay shim's terminal-response filtering
policy. It should not rewrite a parallel filter with different semantics.

Existing blocked or translated classes include:

- OSC 52 clipboard read/set replies.
- OSC 5522 Kitty clipboard/file extension.
- OSC 10..19 and OSC 4 color query replies that look like terminal-generated
  color responses.
- CSI cursor position reports.
- CSI device status reports.
- DA1/DA2 device attribute replies.
- FocusIn/FocusOut reports.
- Kitty keyboard protocol state reports.
- Kitty key release events that should not become text.
- Korean Ctrl+jamo correction for physical control-key shortcuts.

Distinction:

- Bytes originating from tmux `%output` are remote pane output and should be
  rendered after octal unescape.
- Bytes originating from the local Ghostty relay stdin may include terminal
  responses and must pass through the shared filter before becoming tmux input.
- tmux status/control notifications are never fed into the terminal renderer as
  pane output.

## Connection Lifecycle

Initial connection:

```text
ssh -tt user@host tmux -CC attach-session -t <name>
```

tmux `-CC` requires a PTY. The SSH invocation must allocate one explicitly
(`ssh -tt`); without `-t`/`-tt`, tmux aborts with `tcgetattr failed`.

Optional flags:

- `-d` may be used when the user explicitly wants to detach other clients.
- Size should be set immediately after attach with `refresh-client -C <w>x<h>`.

SSH options should include `ServerAliveInterval=15`, `ServerAliveCountMax=3`,
`ExitOnForwardFailure=yes`, and `LogLevel=ERROR`.

Inventory sync:

- After attach, run `list-sessions`, `list-windows`, and `list-panes` with
  stable formats.
- On `%sessions-changed`, immediately resync sessions/windows/panes.
- On `%layout-change`, parse the supplied layout first, then optionally verify
  with `list-panes` if pane ids are missing.

Disconnect detection: SSH stdout EOF, stdin write failure, `%exit`, fatal
`%error`, or heartbeat command timeout.

Reconnect:

- Start a new SSH process.
- Reattach with `tmux -CC attach-session -t <name>`.
- Immediately send the last requested `refresh-client -C <w>x<h>`.
- Rebuild pane/window inventory and surface mappings.
- Phase 1.0 accepts scrollback loss; later phases may seed with
  `capture-pane -p`.

## Concurrency / Threading

The backend is Rust-first and async:

- Parser task: owns stdout line stream, parser state, and event dispatch.
- Command task: owns stdin writer, command FIFO, and correlation map.
- Surface tasks: one bounded broadcast channel per term-mesh surface.
- Watchdog task: pause timers, command timeouts, SSH liveness.
- UI bridge: converts backend events to Swift/AppKit updates.

Threading contract:

- Parse and decode tmux control lines off-main.
- Decode octal output off-main.
- Mutate surface output channels off-main.
- Enter MainActor only for layout changes, surface added/removed, title updates,
  and focus changes.
- Focus commands are sent only for explicit focus intent; passive output or
  metadata updates must not steal macOS focus.

## Failure Modes

| Failure | Policy |
| --- | --- |
| tmux server crash mid-stream | Treat SSH/control EOF as backend disconnect. Keep UI shell alive with reconnect affordance. |
| Control mode parse error | Discard malformed line when local; mark backend degraded after repeated errors. Hard-kill only if command boundaries are unrecoverable. |
| Command timeout | Fail pending command, resync inventory if possible, reconnect if the command was attach/resize/resume critical. |
| `%begin` without `%end` or `%error` | Timeout the command block and reconnect the control client. |
| Invalid octal sequence | Drop that output line, mark surface dirty, and request later `capture-pane` seed if available. |
| Pane disappears during command | Resolve command as surface-gone, remove mapping after inventory resync. |
| Window disappears during layout parse | Remove workspace after confirming with `list-windows`. |
| Unknown notification | Log and continue unless the same unknown event floods logs. |
| SSH process exits with nonzero status | Surface host error with stderr summary and retry option. |

## MVP Scope

### Phase 1.0: Single active pane I/O

Verdict: LGTM.

Scope:

- Attach to one tmux session/window.
- Select the active pane.
- Decode `%output` and `%extended-output` for that pane.
- Forward filtered key bytes through `send-keys -H`.
- Send explicit `refresh-client -C <w>x<h>`.
- Handle `%pause` with `refresh-client -A %<pane-id>:on`.
- Implement `%session-changed` in the parser even if semantic handling is
  deferred; otherwise it appears as `Unknown`.
- No focus changes.
- No automatic layout synchronization.
- No split/close commands.
- Scrollback seed optional; live output is sufficient.
- Integration-tested against tmux 3.4 on Ubuntu 24.04 (2026-05-11): 95% event
  recognition over a 10s attach window, 0 parse errors, and 730
  octal-unescaped control bytes processed.

### Phase 1.1: Single window multi-pane mirror

Verdict: CONCERNS.

Scope:

- Parse tmux layout strings.
- Mirror one window's pane tree into term-mesh split UI.
- Maintain pane id to surface id maps.
- Handle `%layout-change`.
- Send focus commands only for explicit focus intent.
- Send `split-window -h/-v` and close commands from workspace controls.

Risks: layout parser correctness, focus echo loops, concurrent user-driven tmux
splits, tmux size policy conflicts, copy-mode, and mouse behavior.

## Open Questions

- tmux baseline: require 3.0+ and support `%output`, or require 3.2+ for
  `%extended-output` and age metadata?
- Session naming: how should tmux session names map to term-mesh workspace IDs
  or remote host labels?
- Coexistence: what happens when the user splits panes directly in tmux while
  term-mesh is also sending split commands?
- Reconnect seed: use `capture-pane -p` to seed Ghostty after reconnect, or
  accept live `%output` only for Phase 1?
- Paste details: should large paste temp files be created via SSH subsystem,
  remote shell command, or a future helper binary?
- Mouse: should tmux mouse mode be supported through encoded input, or deferred
  until copy-mode semantics are designed?

## Alternatives Considered

### A: tmux raw mode without control protocol

Rejected. Raw PTY mode provides terminal bytes but no reliable window, pane, or
layout object model.

### B: tmate server path

Rejected. tmate adds a third-party server/shared-link dependency and is harder
to self-host as a simple private development primitive.

### C: mosh + tmux

Rejected for this ADR. mosh can improve latency and roaming for terminal I/O,
but it does not provide a multiplexer object model or command/event protocol.

### D: GUI-less Linux term-mesh full deployment

Covered by ADR 0001. It defines the remote `AgentHost` authority model; this ADR
only defines the tmux control backend used as a remote multiplexer.
