# Workspace Remote Retrieval

## Product definition

term-mesh Workspace는 local origin을 유일한 merge point로 두고, 원격 peer 작업을 실시간 read-only로 관찰하며, 원격에 durable하게 고정된 immutable checkpoint만 검증 후 origin에 직렬·원자적으로 적용하는 원격 작업 회수 환경이다.

이 기능은 범용 파일 동기화가 아니다. 원격 작업의 관찰, 보존, 검증, 회수가 목적이다.

## Existing code boundary

현재 코드에는 다음 기반이 이미 있다.

- `PeerPaneSession`: remote surface 하나를 현재 Workspace의 일반 pane으로 연결한다.
- `PeerPaneHostRegistry`: host별 SSH tunnel을 공유하고 pane별 relay session을 관리한다.
- `PeerWorkspaceMirror`: remote workspace 전체를 local Workspace로 materialize한다.
- daemon peer layout: shell exit 시 사라지는 ephemeral pane을 이미 구분한다.
- `ProjectSyncPanelView`: Settings 안의 manifest scan 중심 PoC다. 새 UX의 진입점으로 사용하지 않는다.

새 계층은 기존 relay 수명과 UI 배치를 분리한다. `PeerPaneSession` 자체를 Workspace 소유 모델로 확장하지 않는다.

## Domain model

```text
PeerHost
└─ RemoteSession
   ├─ RemotePane
   ├─ RemotePane
   └─ DurableCheckpoint

Workspace
├─ PaneBinding ────────────────> RemotePane
├─ ProjectBinding ────────────> local origin + remote workdir
└─ RetrievalPresentation ─────> sidebar | drawer | inspector
```

### PeerHost

원격 컴퓨터의 안정적인 식별자다. SSH target, remote socket, 인증 profile을 가진다. Workspace가 소유하지 않는다.

### RemoteSession

원격 실행 수명이다. 한 Workspace 전체일 수도 있고 pane 하나의 배경 session일 수도 있다. Workspace가 닫혀도 유지될 수 있다.

### RemotePane

원격 PTY/surface다. 여러 Workspace에 표시될 수 있지만 실행 수명은 `RemoteSession`이 관리한다.

### PaneBinding

Workspace에 RemotePane을 표시하는 연결이다. Workspace에서 binding을 닫아도 remote pane 종료를 뜻하지 않는다.

```text
owned      Workspace 종료 정책에 pane 수명이 참여
linked     표시만 제거하며 remote pane은 유지
temporary  회수·보존 후 remote pane과 workdir을 정리
```

### ProjectBinding

파일 회수의 유일한 범위다.

```text
localOrigin
remoteWorkdir
baseCheckpoint
remotePaneIDs
incomingChangesets
verificationCommand
```

Peer나 Workspace 전체를 sync 범위로 사용하지 않는다. 여러 pane이 하나의 ProjectBinding을 공유하면 변경 귀속은 `Shared Session`으로 표시한다.

### DurableCheckpoint

원격 Git object와 hidden ref에 먼저 저장되는 immutable 상태다. local 수신 성공 여부와 무관하게 원격에서 복구 가능해야 한다.

### IncomingChangeset

checkpoint와 base 사이의 검증 가능한 변경 묶음이다. MVP에서는 전체 적용만 지원한다.

## Pane lifetime

### Temporary

잠깐 실행하고 버리는 기본 수명이다.

```text
creating → running → checkpointing → readyToClose → closed
                         └──────────→ recoveryRequired
```

- 변경이 없으면 즉시 닫는다.
- 변경이 있으면 `Checkpoint & Close`, `Keep Running`, `Discard & Close`를 제공한다.
- checkpoint가 durable하게 저장되기 전에는 remote pane과 workdir을 삭제하지 않는다.
- 다른 Workspace에 link하려 하면 먼저 `Keep Alive`로 승격한다.
- 연결 단절 시 remote draft checkpoint를 남기고 재연결 후 확정 또는 폐기한다.

### Keep Alive

Workspace와 독립적으로 유지되는 수명이다.

- 다른 Workspace에 link할 수 있다.
- Workspace close는 binding만 제거한다.
- 실제 종료는 `Terminate Remote Pane`이라는 별도 명시적 action이다.

### Unbounded and Shared sessions

- `tm-agent` metadata가 없으면 terminal session과 시간 구간까지만 귀속한다.
- 여러 writer가 같은 remote workdir을 사용하면 agent별 귀속을 추측하지 않는다.
- child process exit는 checkpoint 경계가 아니다.
- `Checkpoint Now`, `Finish Run`, 명시적 session teardown만 확정 경계다.
- quiet period는 checkpoint 제안과 draft 보존에만 사용한다.

## Information architecture

A, B, C는 별도 기능이 아니라 같은 retrieval state의 presentation이다.

### A. Workspace Sidebar

구조 탐색과 상태 발견용이다.

```text
Workspace
├─ Local Origin
└─ jw-server
   ├─ Live Activity       5
   ├─ Incoming Changes    1
   └─ Checkpoints
```

- 현재 Workspace에 binding된 pane만 기본 표시한다.
- host 전체 보기는 별도 remote overview Workspace에서 제공한다.
- pane의 `Temporary`, `Keep Alive`, `Linked`, `Shared` 상태를 text와 icon으로 표시한다.

### B. Activity Drawer

터미널 흐름을 유지하면서 빠르게 확인하는 기본 presentation이다.

- 평소에는 접혀 있다.
- Live Activity, Incoming count, Checkpoints를 tab으로 전환한다.
- `Checkpoint Now`를 제공한다.
- 작은 창에서는 inspector 대신 이 drawer가 상세 presentation이 된다.

### C. Changes Inspector

검증과 적용을 위한 상세 presentation이다.

- Live Preview에는 `REMOTE COPY · READ ONLY`를 항상 표시한다.
- Incoming 카드에 base, boundary source, diffstat, attribution confidence를 표시한다.
- action은 `Validate`, `Apply All`, `Discard`다.
- build/test가 없으면 `Unverified`를 표시하고 별도 명시 승인 없이는 Apply하지 않는다.

### Presentation preference

Workspace마다 기본 presentation을 저장한다.

```text
drawer     default
sidebar    structure-heavy workflows
inspector  review-heavy workflows
```

세 presentation은 동일한 selection과 state store를 공유한다. 한 View에서 선택한 peer, pane, changeset이 다른 View에서도 유지된다.

## Primary flow

```text
Create Remote Pane
→ choose peer, lifetime, project binding
→ seed local snapshot to isolated remote workdir
→ observe remote activity read-only
→ Checkpoint Now / Finish Run / teardown
→ persist checkpoint remotely
→ receive Incoming changeset
→ Validate in temporary local worktree
→ lock and revalidate origin/base/remote identities
→ Apply All atomically or Discard recoverably
```

## Close behavior

| Pane state | Close action |
|---|---|
| Temporary, clean | Close immediately |
| Temporary, remote dirty | Show Checkpoint & Close / Keep Running / Discard & Close |
| Temporary, disconnected | Preserve remote draft; mark Recovery Required |
| Keep Alive, owned | Remove local binding; keep remote session |
| Keep Alive, linked | Remove local binding only |
| Incoming exists | Closing pane does not delete Incoming |

## Safety invariants

1. Live Preview never mutates local origin or feeds local build, search, language server, or agent context.
2. Every changeset has one immutable base and a remote durable checkpoint.
3. Apply is serialized per local origin.
4. Apply revalidates base, current origin, and remote checkpoint immediately before mutation.
5. Apply uses a temporary worktree and leaves origin unchanged on validation failure.
6. Missing build/test is `Unverified`, never an implicit pass.
7. Apply and Discard remain recoverable until explicit purge.
8. Background telemetry and lifecycle work never changes app, Workspace, or pane focus.

## MVP scope

### Included

- Git project one-way seed and changeset retrieval
- one macOS origin and one SSH peer
- server without `tm-agent` through an SSH wrapper
- Temporary and Keep Alive pane lifetimes
- cross-Workspace pane linking
- Sidebar, Activity Drawer, Changes Inspector presentations
- read-only Live Activity and Live Preview
- remote durable checkpoints
- Validate, Apply All, Discard, recovery history
- disconnect and relaunch recovery

### Excluded

- Dropbox-style continuous bidirectional mutation
- simultaneous input to one RemotePane from multiple Workspaces
- file or hunk partial apply
- automatic apply and trust ratchet
- non-Git merge/apply
- automatic attribution among parallel writers
- GitHub PR reviewer, comment, and approval ceremony

## Implementation DAG

### Phase 0 — remove the false entry point

`T0.1` Mark Settings `Project Sync` as deprecated and remove it from normal navigation after the Workspace surface is available.

`T0.2` Keep existing manifest/CAS code behind internal APIs. Do not delete it until the vertical slice proves which parts are reused.

Acceptance: a user cannot mistake local manifest scan for working remote file sync.

### Phase 1 — identity and lifetime model

`T1.1` Add stable identifiers and value types for `RemoteSessionID`, `RemotePaneID`, `PaneBindingID`, `ProjectBindingID`, `CheckpointID`, and `ChangesetID`.

`T1.2` Add `RemotePaneLifetime` with `temporary` and `keepAlive`.

`T1.3` Add binding ownership (`owned`, `linked`) without changing `PeerPaneSession` transport ownership.

`T1.4` Persist Workspace presentation preference and bindings independently from remote session lifetime.

Dependencies: none.

Acceptance: removing a linked pane never tears down its remote session; closing a temporary pane enters the lifecycle gate.

### Phase 2 — remote durable checkpoint vertical slice

`T2.1` Define the SSH wrapper contract for hosts without `tm-agent`: seed, watch journal, checkpoint, fetch, purge.

`T2.2` Persist each checkpoint as remote Git objects plus a hidden ref under the project binding namespace.

`T2.3` Record boundary source: `finishRun`, `checkpointNow`, `sessionTeardown`, `disconnectDraft`, `unbounded`.

`T2.4` Fetch checkpoint metadata and patch to local Incoming storage with resume support.

Dependencies: Phase 1.

Acceptance: kill the SSH connection after remote checkpoint creation; reconnect and retrieve the same checkpoint bytes.

### Phase 3 — safe local apply

`T3.1` Build immutable Incoming changeset records with base/origin/remote identities.

`T3.2` Validate the complete changeset in a temporary local Git worktree.

`T3.3` Serialize Apply per origin, revalidate identities, then commit the complete result atomically.

`T3.4` Treat missing verification commands as `Unverified` and require a separate confirmation.

`T3.5` Store recoverable Apply/Discard history and explicit purge.

Dependencies: Phase 2.

Acceptance: failure injection at every apply step leaves origin entirely before or after the transaction, never partially changed.

### Phase 4 — shared presentation store

`T4.1` Add one Workspace retrieval store containing selection, presentation, pane activity, checkpoints, Incoming, and lifecycle state.

`T4.2` Expose file-event telemetry off-main, dedupe/coalesce it, then apply minimal UI mutations on main.

`T4.3` Preserve focus for every non-focus retrieval command and background event.

Dependencies: Phase 1 and checkpoint metadata from Phase 2.

Acceptance: A, B, C render the same selected pane and counts; a telemetry burst does not activate the app or change focused pane.

### Phase 5 — A/B/C UI

`T5.1` Extend the Workspace sidebar with bound peer/pane status and retrieval counts.

`T5.2` Add the collapsible Activity Drawer as the default presentation.

`T5.3` Add the Changes Inspector with read-only Live Preview and Incoming actions.

`T5.4` Add keyboard commands for presentation switching, `Checkpoint Now`, and opening Incoming.

`T5.5` Add compact-window fallback from inspector to drawer.

Dependencies: Phase 4.

Acceptance: all actions are keyboard reachable, VoiceOver names include state text, and state is not communicated by color alone.

### Phase 6 — pane lifecycle UX

`T6.1` Add creation choices: peer, Temporary/Keep Alive, Current Project binding.

`T6.2` Add the temporary close gate and durable `Checkpoint & Close` flow.

`T6.3` Add Keep Alive promotion before cross-Workspace linking.

`T6.4` Separate `Remove from Workspace` from `Terminate Remote Pane`.

`T6.5` Add recovery UX for disconnected temporary panes and cleanup failures.

Dependencies: Phases 2, 3, and 5.

Acceptance: every close path runs the correct transport teardown without deleting uncollected work.

### Phase 7 — end-to-end gate

`T7.1` Mac origin → `jw-server` temporary pane → edit → checkpoint → reconnect → validate → apply.

`T7.2` Keep Alive pane linked into a second Workspace; removing one binding keeps the remote session alive.

`T7.3` Shared session displays uncertain attribution and never treats child exit as task completion.

`T7.4` Connection interruption, process crash, validation failure, stale base, app relaunch, and cleanup failure tests.

`T7.5` Tagged Debug reload and manual A/B/C keyboard and accessibility walkthrough.

Dependencies: all phases.

Acceptance metrics:

- unauthorized origin mutation: 0
- partial apply after crash/failure: 0
- stale-base apply: 0
- durable checkpoint recovery after transport interruption: at least 99%
- normal run approval count: median 1, p90 at most 3
- Incoming-to-decision time: median at most 2 minutes

## Implementation references

- `Sources/PeerPaneSession.swift`: transport session and host tunnel ownership
- `Sources/Workspace.swift`: current local Workspace and remote pane binding entry point
- `Sources/PeerMenu.swift`: remote pane and workspace opening flows
- `Sources/SidebarViews.swift`: A presentation integration
- `Sources/ContentView.swift`: B/C presentation container and responsive switching
- `Sources/WorkspaceContentView.swift`: terminal content boundary
- `Sources/Panels/TerminalPanel.swift`: remote session teardown paths
- `daemon/term-meshd/src/peer/layout.rs`: remote workspace and ephemeral pane lifecycle
- `Sources/ProjectSyncPanelView.swift`: deprecated Settings PoC, not the target UX

## Verification strategy

- Unit tests: identity, lifetime transitions, binding ownership, boundary classification, stale detection.
- Rust tests: wrapper protocol, checkpoint durability, resumable fetch, hidden ref retention, purge.
- Swift integration tests: Workspace store, linked binding removal, temporary close gate, Apply transaction.
- Failure injection: SSH kill, daemon kill, app kill, disk write failure, build/test failure, origin edit during Review.
- UI tests: A/B/C state parity, keyboard navigation, VoiceOver labels, compact-window fallback, focus preservation.
- Required build and launch after code changes:

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme term-mesh -configuration Debug -destination 'platform=macOS' build
./scripts/reload.sh --tag workspace-remote-retrieval
```
