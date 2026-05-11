# ADR 0001: Remote Agent Host & tmux Backend

Status: Proposed
Date: 2026-05-11

## Context & Problem

term-mesh currently provides a macOS-native split-pane terminal experience backed
by Ghostty surfaces, plus an agent role system built around `tm-agent`,
`term-meshd`, task boards, runbooks, and role-specific agents such as explorer,
executor, and reviewer.

The existing peer relay feature already defines a useful remote terminal shape:
`WorkspaceLayout`, `SurfaceInfo`, `PtyData`, `Input`, `Resize`, and workspace
control messages. That protocol is designed for term-mesh-to-term-mesh
federation over a typed Protobuf stream.

The next user scenario is different:

1. A developer works from a personal macOS laptop.
2. The actual development environment is a remote Linux server.
3. Long-running Claude/Codex agent processes should execute on Linux, close to
   the repository, build tools, credentials, GPUs, and tmux sessions.
4. The macOS app should provide the familiar term-mesh view, or at minimum a
   high-quality terminal/tmux view, without becoming the owner of the remote
   task board or filesystem.

This creates two related but separate problems:

1. How to model a remote Linux agent team without splitting task state across
   two machines.
2. How to render and control remote tmux panes through term-mesh without
   contaminating the existing peer relay protocol.

## Decision: AgentHost Abstraction

Introduce `AgentHost` as the control-plane ownership boundary.

```text
AgentHost = LocalMac | LinuxSSH | FuturePeer
```

An `AgentHost` owns:

- task board and task lifecycle
- runbook source, digest, and installation state
- agent process lifecycle
- result store
- repository root and worktrees
- socket path and command execution context
- credentials and model CLI environment

The UI consumes:

- team status
- task list
- agent output and result summaries
- PTY surfaces
- workspace or tmux pane layout
- host health and drift warnings

The MVP uses a Linux authoritative host:

```text
macOS term-mesh
  view/control proxy only
        |
        | SSH tunnel / tmux control mode / future AgentHost RPC
        v
Linux AgentHost
  term-meshd + tm-agent + tmux + Claude/Codex CLIs
  task board + runbooks + results + repo checkout
```

The macOS app may display and proxy commands for a remote team, but it must not
maintain an independent mutable copy of the remote task board.

## Topology B Selection Rationale

### Topology Comparison

| Topology | Shape | Verdict | Rationale |
| --- | --- | --- | --- |
| A | macOS = view + leader, Linux = worker agents via SSH RPC | CONCERNS | Preserves the local leader UX, but splits task board, process state, result paths, and filesystem ownership unless macOS is only a thin proxy to Linux. |
| B | Linux = control plane + data plane, macOS = view/relay | LGTM | Keeps task board, runbooks, agents, tmux panes, result files, and repo checkout on one host. Best MVP fit. |
| C | macOS and Linux both run term-meshd with cross-host agent federation | CONCERNS for long term, BLOCKER for MVP | Requires distributed task ownership, identity, result routing, conflict handling, and reconnect semantics. Peer relay is not a distributed task consensus protocol. |

Topology B is selected for MVP because it keeps one source of truth and lets the
remote team survive macOS sleep, disconnects, and app restarts.

```text
                    read-only/proxy state
macOS UI  <------------------------------------+
  |                                            |
  | view PTY/tmux panes                         |
  | delegate/read/wait proxy                    |
  v                                            |
SSH / tmux -CC / AgentHost RPC                  |
  |                                            |
  v                                            |
Linux AgentHost -------------------------------+
  | owns task board
  | owns runbooks and digests
  | owns result store
  | owns repo root
  | spawns Claude/Codex CLIs
  v
tmux sessions / headless agents / PTY surfaces
```

## tmux Adapter Boundary

Do not make tmux speak the existing peer relay wire protocol directly.

The peer relay protocol remains the term-mesh-to-term-mesh contract:

- length-prefixed Protobuf frames
- typed `Envelope` messages
- term-mesh host as source of truth
- `PeerSurfaceProvider` over real term-mesh surfaces

tmux control mode is a separate backend:

- textual control protocol
- command blocks: `%begin`, `%end`, `%error`
- async notifications: `%output`, `%layout-change`, `%window-add`,
  `%window-close`, `%window-renamed`, `%pane-mode-changed`
- octal-escaped byte payloads
- command input via `send-keys`, `paste-buffer`, `refresh-client`, and related
  commands

Generalize at the backend boundary:

```rust
trait RemoteMultiplexerBackend {
    async fn list_workspaces(&self) -> Result<Vec<RemoteWorkspace>>;
    async fn attach_surface(&self, surface_id: SurfaceId, size: CellSize)
        -> Result<RemoteSurfaceStream>;
    async fn send_input(&self, surface_id: SurfaceId, bytes: Vec<u8>) -> Result<()>;
    async fn resize(&self, surface_id: SurfaceId, size: CellSize) -> Result<()>;
    async fn control(&self, command: WorkspaceControl) -> Result<()>;
}

trait AgentHost {
    async fn status(&self) -> Result<TeamStatus>;
    async fn tasks(&self) -> Result<Vec<Task>>;
    async fn delegate(&self, agent: &str, instruction: &str) -> Result<TaskId>;
    async fn read_agent(&self, agent: &str, lines: usize) -> Result<String>;
    async fn runbook_status(&self) -> Result<RunbookStatus>;
}
```

```swift
protocol AgentHost {
    var id: AgentHostID { get }
    var kind: AgentHostKind { get }
    func status() async throws -> TeamStatus
    func tasks() async throws -> [TeamTask]
    func delegate(to agent: String, instruction: String) async throws -> TeamTask.ID
    func read(agent: String, lines: Int) async throws -> String
    func runbookStatus() async throws -> RunbookStatus
}

protocol RemoteMultiplexerBackend {
    func listWorkspaces() async throws -> [RemoteWorkspace]
    func attachSurface(_ id: SurfaceID, size: CellSize) async throws -> RemoteSurfaceStream
    func sendInput(_ bytes: Data, to surface: SurfaceID) async throws
    func resize(_ surface: SurfaceID, to size: CellSize) async throws
    func control(_ command: WorkspaceControl) async throws
}
```

Both the existing peer relay and the new tmux backend can feed the same UI
surface layer, but they should remain separate transports and parsers.

```text
                         UI split tree
                              |
                    Remote surface facade
                     /                    \
                    /                      \
PeerSurfaceProvider / Protobuf       TmuxControlBackend / text control mode
term-mesh <-> term-mesh              term-mesh <-> ssh tmux -CC
```

## Runbook Digest and Version Contract

Remote agent behavior must not depend on an unobservable copy of local runbooks.

`tm-agent runbook status` should expose a machine-readable digest contract:

- role name
- source path
- source state: missing, preset, repo, custom, installed
- effective prompt mode: digest or full
- `sha256` of the effective runbook content
- optional version or generation timestamp
- warning list for missing, stale, or uninstalled roles

Example shape:

```json
{
  "host": "linux-ssh:devbox",
  "project_root": "/home/user/work/project",
  "roles": [
    {
      "role": "executor",
      "source": ".agent-runbooks/executor.md",
      "state": "repo",
      "sha256": "..."
    }
  ]
}
```

The macOS UI may cache this status, but mutation belongs to the authoritative
`AgentHost`. Drift is detected by comparing the remote digest against the
expected local or repository digest. A drift warning should block only actions
that depend on runbook parity; it should not prevent viewing a remote tmux
session.

## Filesystem Boundary Contract

The Linux `AgentHost` owns the canonical repository checkout for the remote
team. Linux agents may read and write only that Linux workspace and any explicit
paths granted by the Linux environment.

MVP rules:

- Linux agents do not access the macOS filesystem.
- macOS does not edit the Linux repository through an implicit mount.
- macOS may view remote output and submit delegate/read/wait requests through
  the Linux host.
- SSHFS and bidirectional mounts are not part of the supported architecture.
- If file synchronization is needed, it must be explicit: git, rsync, remote IDE,
  or a future documented sync feature.

This prevents mixed-host edits where macOS and Linux each believe they own the
same working tree.

The Linux daemon stores its task/session SQLite database through
`dirs::data_local_dir()`. With the default XDG layout, that resolves to:

```text
~/.local/share/term-mesh/agent_sessions.db
```

If `XDG_DATA_HOME` is set, the database lives under
`$XDG_DATA_HOME/term-mesh/agent_sessions.db`.

## Failure Modes

| Failure | Expected behavior |
| --- | --- |
| SSH connection drops | Linux tmux, term-meshd, and agents continue running. macOS reconnects via SSH, tmux control mode, or future AgentHost RPC. |
| SSH tunnel local socket disappears | UI marks remote host disconnected and retries or asks user to reconnect. No task board mutation happens locally. |
| Linux daemon crashes | tmux panes and interactive CLIs may keep running, but task board and headless lifecycle APIs are unavailable until daemon restart. Status should show degraded host. |
| tmux server crashes | Remote pane surfaces are lost. AgentHost should report tmux backend down while preserving daemon task state if available. |
| API key missing | Agent spawn fails with an explicit environment/secret error. Do not fall back to macOS keychain implicitly. |
| Runbook drift detected | UI warns with remote digest details and offers remote install/sync guidance. Delegation may proceed only after user accepts drift or fixes it. |
| Remote repo missing or wrong branch | AgentHost reports repository health failure. macOS remains viewer/proxy, not an editor trying to repair local paths. |

Mosh-like reconnect may be explored for interactive viewing, but the control
plane should first rely on reconnectable SSH and stable Linux-side ownership.
ControlMaster reuse is an implementation detail, not a state model.

## Consequences

Positive:

- Clear single source of truth.
- Remote agents continue across macOS disconnects.
- Linux build/test dependencies stay close to the agents.
- macOS-specific crate count on the remote-agent Rust path is 0; the daemon and
  CLI crates are already platform-portable.
- Existing headless `term-meshd` and `tm-agent` architecture can be reused.
- tmux integration does not force incompatible semantics into the peer relay
  protocol.

Negative:

- The macOS app must learn to present remote host state as proxied, not local.
- Runbook drift becomes a first-class UX concern.
- Remote secret setup is required on Linux.
- tmux control mode requires a robust parser, input encoder, and version policy.
- Cross-host federation is delayed until a separate task protocol exists.

## Migration and Coexistence

The existing peer relay remains unchanged as the term-mesh-to-term-mesh path.

The new tmux path is a separate `TmuxControlBackend`. It can implement the same
remote surface facade used by the UI, but it does not reuse the Protobuf peer
wire as its backend protocol.

Coexistence model:

- `PeerSurfaceProvider`: current term-mesh host surfaces.
- `TmuxControlBackend`: remote tmux session/window/pane surfaces.
- `AgentHost(LocalMac)`: current local team behavior.
- `AgentHost(LinuxSSH)`: authoritative remote Linux team.
- `AgentHost(FuturePeer)`: future cross-host federation, not MVP.

## Implementation Phases

### Phase 0: Linux cross-compile and manual bootstrap

- Confirm the existing Linux-ready Rust surface:
  - macOS-only crates in the daemon/CLI remote-agent path: 0.
  - Full Cargo.toml audit found no remote-agent dependency on macOS-only crates
    such as `core-foundation`, `cocoa`, `objc`, or `security-framework`.
  - `cfg(target_os = "linux")` peer credential checks already exist in
    `daemon/term-meshd/src/socket.rs:1386` and
    `daemon/term-meshd/src/peer/server.rs:239`.
  - `HeadlessManager` is a first-class `term-meshd` subsystem and can boot
    without Swift panels (`daemon/term-meshd/src/main.rs:80`).
  - Required Rust source changes for Phase 0: 0.
- Build `term-meshd` and `tm-agent` for Linux. The verified 2026-05-11 path is
  Docker `rust:alpine`, not host `rustup` + Homebrew musl cross tools:

  ```bash
  docker run --rm --platform linux/amd64 \
    -v "$PWD":/work -w /work/daemon rust:alpine \
    sh -lc 'apk add --no-cache musl-dev cmake git pkgconfig openssl-dev openssl-libs-static perl make protobuf-dev && cargo build --release --target x86_64-unknown-linux-musl -p term-meshd -p tm-agent'

  docker run --rm --platform linux/arm64 \
    -v "$PWD":/work -w /work/daemon rust:alpine \
    sh -lc 'apk add --no-cache musl-dev cmake git pkgconfig openssl-dev openssl-libs-static perl make protobuf-dev && cargo build --release --target aarch64-unknown-linux-musl -p term-meshd -p tm-agent'
  ```

  The project root must be mounted at `/work` because `peer-proto` reads
  `proto/peer/v1/peer.proto` outside the `daemon/` workspace directory.
- The host-rustup alternative remains possible but is not the standard path:
  it requires installing the Rust target plus a compatible musl linker/toolchain
  on macOS, which is slower and more fragile than the Docker build.
- Verified musl build outputs on 2026-05-11:

  | Target | Binary | Size | Format |
  | --- | --- | ---: | --- |
  | `x86_64-unknown-linux-musl` | `term-meshd` | 16M | ELF x86-64, static-pie |
  | `x86_64-unknown-linux-musl` | `tm-agent` | 2.9M | ELF x86-64, static-pie |
  | `aarch64-unknown-linux-musl` | `term-meshd` | 15M | ELF ARM aarch64, static |
  | `aarch64-unknown-linux-musl` | `tm-agent` | 2.8M | ELF ARM aarch64, static |

- `git2` with `vendored-openssl` and `vendored-libgit2` is compatible with the
  musl static build when the Alpine container includes `cmake`, `perl`, and
  `make`; no external system libgit2/OpenSSL is required.
- Use the implemented Linux daemon socket path. `default_socket_path()` first
  honors `TERMMESH_DAEMON_UNIX_PATH`; otherwise it uses
  `dirs::runtime_dir()` and appends `term-meshd.sock`. On a systemd Linux host,
  the default is:

  ```text
  /run/user/<uid>/term-meshd.sock
  ```

  If no runtime directory is available, the implementation falls back through
  `TMPDIR` and then `/tmp`.
- Use the implemented Linux SQLite path. `default_db_path()` uses
  `dirs::data_local_dir()` and appends `term-mesh/agent_sessions.db`, which
  defaults to:

  ```text
  ~/.local/share/term-mesh/agent_sessions.db
  ```

- Start `term-meshd` manually or via a systemd user service.
- Run `tm-agent runbook status` on Linux.
- Use plain SSH/tmux to validate remote leader and worker panes.

### Phase 1: tmux adapter

- Implement `TmuxControlBackend` around `ssh tmux -CC` or an equivalent control
  mode process.
- Parse command blocks and async `%` notifications.
- Decode `%output` octal escapes into raw bytes.
- Handle `%pause` and resume flow control.
- Map one tmux window/pane tree into term-mesh remote surfaces.
- Keep input, resize, and layout mutation intentionally narrow for MVP.

### Phase 2: AgentHost as a first-class abstraction

- Add `AgentHost(LocalMac)` and `AgentHost(LinuxSSH)` implementations.
- Expose remote team status, tasks, runbook digest, and result summaries.
- Make macOS mutation paths proxy to the authoritative Linux host.
- Add UI labels that distinguish local teams from remote authoritative teams.

### Phase 3: multi-host federation

- Design a task-level federation protocol separately from peer relay.
- Define identity, authorization, result routing, conflict handling, and
  reconnect semantics.
- Consider `AgentHost(FuturePeer)` only after single-authority remote hosts are
  stable.

## Alternatives Considered

### A: macOS leader with Linux worker agents

Rejected for MVP. This creates split ownership unless every command is only a
proxy to Linux. If every command is proxied, it is effectively Topology B with a
thin client.

### B: Linux authoritative host with macOS viewer

Accepted for MVP. It gives one owner for tasks, processes, runbooks, results,
and files.

### C: Cross-host federation from the start

Rejected for MVP. This needs a distributed task protocol and would turn a tmux
backend PoC into a multi-host consistency project.

### D: Make tmux speak the peer relay protocol

Rejected. tmux control mode is a textual command/event protocol with different
input, layout, snapshot, and ownership semantics. It should be adapted at the
backend boundary, not forced into the Protobuf peer wire.

## Decisions Carried Forward from Council Round 1

Council Round 1 on 2026-05-11 reached unanimous agreement on two previously
open Phase 0/Phase 2 questions.

- Linux secret store: default to an env file at `~/.config/term-mesh/env` with
  mode `0600`. `bootstrap-remote.sh` already implements this path. Add opt-in
  `--secret-backend` support for `systemd-creds`, `pass`, and `op`
  (1Password CLI). This keeps MVP setup under five minutes with zero required
  external dependencies while leaving an upgrade path toward encrypted stores.
- AgentHost RPC surface: default to a forwarded Unix socket over SSH
  `LocalForward`. This reuses the existing term-meshd JSON-RPC socket protocol
  and the implemented `TERMMESH_DAEMON_UNIX_PATH` override without daemon
  protocol changes. A future typed Protobuf/gRPC transport can replace the
  framing layer later without changing the AgentHost task model.
- Cross-compile build method: standardize on Docker `rust:alpine` with
  `musl-dev`, `cmake`, `git`, `pkgconfig`, `openssl-dev`,
  `openssl-libs-static`, `perl`, `make`, and `protobuf-dev`. This was verified
  on 2026-05-11 for both `x86_64-unknown-linux-musl` and
  `aarch64-unknown-linux-musl`. The `cross` crate or host rustup/musl toolchain
  can remain optional, but Docker is the documented Phase 0 path. The `git2`
  vendored-libgit2/cmake concern is resolved by the same Alpine package set.

## Open Questions

- How should IME and Korean key conversion flow through tmux `send-keys`,
  `send-keys -H`, paste buffers, and Ghostty input events?
- Should the MVP require tmux 3.0+, 3.2+, or a newer baseline for
  `%extended-output` and control mode behavior?
- How much multi-window synchronization is required before the UI feels
  term-mesh-native rather than just a tmux viewer?
- Should remote runbook drift block delegation by default, or warn and allow
  explicit override?
