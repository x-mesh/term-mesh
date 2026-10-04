# Peer host registry invariants

This document states the rules that `PeerPaneHostRegistry`
(`Sources/PeerPaneSession.swift`) and the code that changes a host's transport
must keep. Reviews and tests judge a change against these rules, not against
the diff alone. A finding that breaks no invariant here is backlog by default;
a finding that breaks one names it.

The registry owns one SSH tunnel (a *lease*) per host key and hands it to every
remote pane, mirror, team, and sidebar row on that host. Many actors touch it
concurrently, on the main actor but across `await` points, so most defects have
been interleavings rather than single-path bugs. PRs #673–#678 each fixed one
interleaving and each review found another; this page exists to replace that
loop with explicit rules.

## State

Per host key, in the registry:

| State | Meaning |
| --- | --- |
| `leases[key]` | The pooled lease. At most one. |
| `starting[key]` | The in-flight start: `id`, `task`, `disconnectGeneration`, `replacementToken`, `waiters`. |
| `disconnectGenerations[key]` | Count of plain Disconnect Host on this key. Bumped even when nothing is pooled. |
| `pendingReplacements[key]` | Token of the Reconnect Host attempt whose replacement is not pooled yet. |
| `replacingKeys` | Keys retired (dead or disconnected) whose next pooled lease must fire `hostTransportDidReplace`. |

Per lease: `refCount`, `isTornDown`, `leftPoolByRelease`, the tunnel state, and
`transportGeneration`.

Outside the registry:

- `RemoteHostStore`, per sidebar row: `sidebarLeases`, `connectTasks`,
  `connectingLeaseKeys`, `connectAttemptIDs`, `announcedReplacements`.
- `PeerPaneSession`: `hostTransportWasDisconnected`. Its `PeerRelaySession`:
  `awaitingTransportReplacement`, the parked reconnect waiter, and
  `retargetedSurfaceWasRejected`.

## Events

| ID | Event | Entry point |
| --- | --- | --- |
| E1 | Acquire | `acquire(_:)`. 34 call sites in 7 files: sidebar connect, Peer menu panes, banner Reconnect, `reconnectParkedPane`, wake sweep, `RemoteLiveProject`, team orchestration, `SessionHostPanes`, git checkpoint, relay. |
| E2 | Restart wait | E1 finds the pooled lease `.waitForRestart` and joins the tunnel's own restart (`lease.refreshTransport`, bounded at 15 s). |
| E3 | Join | A restart waiter whose lease left the pool: `joinReplacement`. |
| E4 | Release / retain | `release(_:)`, `retain(_:)`. The last release unpools and tears down. |
| E5 | Disconnect Host | `disconnectSavedHost` → `disconnectTransport(for:)`. |
| E6 | Reconnect Host / Retry | `reconnectHost` → `disconnectTransport(for:replacementFollows: true)`, then `connectSavedHost`. |
| E7 | Force Disconnect | `forceDisconnectSavedHost`: `endTransportForForceDisconnect` (a plain disconnect), then closes every connection row and releases the sidebar lease. |
| E8 | Dead retire | An E1 with `mayStart` retires a `.dead` or unrecovered lease: `retireDeadLease`, which fires `hostTransportWillRetire`. |
| E9 | Cancel | `cancelConnectingHost` → `cancelPendingAcquire`. It only cancels a start with one waiter. |
| E10 | Start settles | `awaitStart` → `adoptUnlessDisconnected` → `adopt`. |
| E11 | Tunnel self-restart | `PeerSSHTunnel`'s own reconnect loop, outside the registry. It advances `transportGeneration`. |

## Invariants

Each invariant lists where it is enforced, which tests check it, and its
current status.

### I1 — One pooled lease per key, no orphan tunnel

At most one lease is pooled per key. Every lease that is neither pooled nor
referenced is torn down, so no ssh process outlives its last user. A torn-down
lease is never pooled again.

- Enforced by: `adopt` (pools exactly one and tears down a duplicate),
  `release` (tears down at zero), `adoptUnlessDisconnected` (tears down a
  stale start), and `settleStart` (a caller that resumes to a lease another
  caller of the same start pooled and that was since retired joins the
  replacement instead of pooling it again). A start cancelled mid-spawn is
  reaped by `PeerSSHTunnel.deinit → stop()`.
- Tests: `test_registry_concurrentFirstAcquireYieldsOneLease`, the teardown
  counts in `test_registry_disconnectDuringAReplacementStartPoolsNothing`,
  and the simulation (`PeerHostRegistrySimulationTests`).
- Status: holds. The simulation found that a late caller of a shared start
  re-pooled a torn-down lease and announced it a second time. That is fixed in
  `settleStart`. The first version of that fix recursed without suspending,
  rejoining the same finished start, until the stack ran out. The simulation
  found that too, and `settleStart` now detaches the finished start before
  joining.

### I2 — Reference counts balance

Every successful acquire or retain is balanced by exactly one release.
`PeerPaneSession.retarget(to:)` moves one reference from the old lease to the
new one.

- Tests: `test_paneRetargetMovesItsLeaseRefOntoTheAnnouncedReplacement`.
- Status: holds.

### I3 — Disconnect Host is final

After a plain Disconnect Host moves a key from generation *g* to *g*+1:

1. No start begun at generation *g* or earlier is pooled.
2. No caller that was waiting before the disconnect (a restart waiter, or a
   joiner of a start) obtains a lease. Each one fails with `hostDisconnected`.
3. Parked panes are not reattached until an acquire issued after the
   disconnect pools a lease.

- Enforced by: `disconnectGenerations`, `adoptUnlessDisconnected`, the
  generation check in `joinReplacement`, and the error mapping in `awaitStart`.
- Tests: `test_registry_restartWaiterDoesNotUndoADisconnectDuringTheWait`,
  `test_registry_disconnectDuringAReplacementStartPoolsNothing`,
  `test_registry_disconnectCancelsTheStartItOvertakes`.
- Status: holds.

### I3-F — Force Disconnect is at least as final as Disconnect Host

- Enforced by: `forceDisconnectSavedHost` calls
  `endTransportForForceDisconnect(for:)`, which is `disconnectTransport(for:)`,
  before closing connections and releasing references.
- Tests: the simulation models Force Disconnect through the same registry entry
  point and checks it as a disconnect for I3.
- Status: holds. It was violated until the simulation was written: Force
  Disconnect never bumped the disconnect generation, so the last release read
  as an ordinary one and a restart waiter (the wake sweep, a team spawn)
  reopened ssh to the host. The simulation reported 783 such breaks across
  1000 trials.

### I4 — An acquire after a disconnect starts fresh

An acquire issued after a Disconnect Host never joins a start begun before it.

- Enforced by: `disconnectTransport` detaches and cancels `starting[key]`.
- Tests: `test_registry_acquireAfterADisconnectDoesNotJoinTheOvertakenStart`.
- Status: holds.

### I5 — No start from a stale spec

A caller whose awaited lease was retired, whether by Disconnect, Reconnect, or
a dead retire, never starts a lease with its own spec. Its spec may predate
the change that retired the lease, such as a repaired identity file or an
invalidated socket. The one exception is a lease that left the pool through
`release()` (`leftPoolByRelease`): nothing retired it, so the spec is current.

- Enforced by: `acquire(_:mayStart: false)` and `joinReplacement`.
- Tests: `test_registry_restartWaiterJoinsTheReconnectHostReplacementWithoutStartingOne`,
  `test_registry_restartWaiterDoesNotStartOverADeadReplacement`,
  `test_registry_restartWaiterStartsFreshWhenTheLeaseWasOnlyReleased`.
- Status: holds.

### I6 — Every acquire terminates

Every acquire returns or throws within bounded time. A restart wait is
bounded by the refresh budget (15 s), and each join by
`replacementJoinDeadlineSeconds` (15 s). A join can recurse into another
restart wait, but only after a new lease has been pooled and has left the
pool again.

- Tests: `test_registry_restartWaiterGivesUpWhenNoReplacementStarts`.
- Status: holds. The number of rounds is not bounded by a constant; each round
  needs real lease turnover.

### I7 — Replacements are announced exactly once and withdrawn only by their owner

Once a key is in `replacingKeys`, the next lease pooled under that key fires
`hostTransportDidReplace` exactly once. The announcement is re-armed if the
adopting caller was cancelled.

A pending replacement token is withdrawn only by:

- its own attempt (`connectSavedHost` fails, is cancelled, or lands under
  another key),
- the failure of its own start,
- a waiter's deadline,
- a plain disconnect, or
- pooling a lease.

- Tests: `test_registry_replacementFiresHooksAroundTheTeardown`,
  `test_registry_pendingReplacementIsWithdrawnOnlyByItsOwnAttempt`, and the
  simulation, which fails on any lease announced twice or announced while not
  pooled.
- Status: holds. The `RemoteHostStore` hand-off (`announcedReplacements`) has
  no unit test.

### I8 — A lease observed dead is not left pooled

Once the registry observes a pooled lease as `.dead` (or as restarting without
recovering), it retires that lease. It does not hand the lease out and does
not leave it in the pool.

- Enforced by: `acquire` retires the lease on both paths. With `mayStart`
  false, a joining waiter still retires it but does not start a replacement
  (I5), and it reports `replacementDied` rather than `replacementUnavailable`.
- Tests: `test_registry_restartWaiterDoesNotStartOverADeadReplacement`, and the
  simulation's replacement-churn mix. The simulation checks this as each
  acquire finishes, because a later acquire retiring the lease would hide the
  break.
- Status: holds. It was violated on the join path until the simulation was
  written.

### I9 — Parked panes always end

Every relay parked on a retired lease is either resumed by a retarget or ended
by teardown or by abandoning the park. No relay helper (the pane's shell)
outlives its pane.

- Enforced by: `PeerRelaySession.awaitTransportReplacement` and the park, the
  waiter resume in `disconnect()`, and `reconnectParkedPane`.
- Tests: `test_parkedOwnedReconnectResumesThroughRetargetedTransport`,
  `test_parkedOwnedReconnectEndsWhenThePaneIsTornDown`,
  `test_abandoningAParkEndsThePaneThroughTheOrdinaryDisconnect`.
- Status: holds.

### I10 — Refused panes are not rebuilt unattended

A pane whose surface the host refused after a retarget stays on its banner
until the user acts. Nothing rebuilds it by title match without the user.

- Enforced by: `PeerPaneSession.hostReconnectReattach` and the
  `onDisconnect` banner.
- Tests: `test_hostReconnectLeavesARefusedPaneOnItsBanner` checks the decision
  table only. The `Workspace` wiring has no test.
- Status: holds.

## Transitions

Effects on one key. "–" means unchanged.

| Event | `leases` | `starting` | generation | pending token | `replacingKeys` | Panes |
| --- | --- | --- | --- | --- | --- | --- |
| E1, pooled and usable | +1 ref | – | – | – | – | – |
| E1, nothing pooled or starting | – | new start, captures generation and token | – | – | – | – |
| E1, start in flight | – | +1 waiter | – | – | – | – |
| E2, restart came back | +1 ref | – | – | – | – | – |
| E2, restart failed (`mayStart`) | retired | new start | – | – | insert | flagged by `WillRetire` |
| E3, lease left the pool | reuse a usable lease or join a start; a released lease may start fresh | – | checked | own token withdrawn at deadline | – | – |
| E4, release to zero while pooled | removed, `leftPoolByRelease` | – | – | – | – | – |
| E5 Disconnect Host | removed and torn down | detached and cancelled | +1 | cleared | insert if a lease was pooled | parked |
| E6 Reconnect Host | removed and torn down | the row's own start cancelled if it has one waiter | – | new token | insert if a lease was pooled | parked |
| E7 Force Disconnect | removed and torn down (as E5), then every ref released | detached and cancelled | +1 | cleared | insert if a lease was pooled | closed |
| E8 Dead retire | removed and torn down | then a new start, unless the caller is a joining waiter | – | – | insert | flagged |
| E9 Cancel | – | removed and cancelled if it has at most one waiter | – | – | – | – |
| E10, settles at the same generation | pooled, or torn down if another lease is pooled | removed | – | cleared | removed, fires `DidReplace` | reattached |
| E10, settles after a disconnect | torn down | removed | – | – | – | – |
| E10, start fails | – | removed | – | withdrawn if it is the start's own token | – | – |

## Open violations

None known. The two violations this page originally listed (I3-F and I8)
were fixed together with the simulation test, which also found a third
(a torn-down lease re-pooled, I1/I7) that no review had reported.

## Test seams

Debug-only hooks on the registry that a test can drive:

- `startDelayForTests`: holds a start open before `makeLease`.
- `livenessOverrideForTests`: makes a lease read `.usable`, `.waitForRestart`, or `.dead`.
- `restartWaitOverrideForTests`: stands in for joining a tunnel restart.
- `replacementJoinDeadlineForTests`: shortens the join deadline.
- `teardownCountForTests`, `replacementCountForTests`,
  `pendingWaiterCountForTests`: observe outcomes.
- `leaseMadeForTests`: sees every lease a start makes, including ones torn
  down without ever being pooled.
- `deadLeaseObservedForTests`: sees each lease an acquire judged dead (I8).
- `hostTransportWillRetire`, `hostTransportDidReplace`: hooks a test can replace.

A test that waits on a condition must bound the wait. A test that blocks on a
release flag set after an `await` deadlocks when its fix is removed, and
mutation testing then hangs instead of failing. This happened twice during
#677 and #678.

## Simulation test

`PeerHostRegistrySimulationTests` (in `termMeshTests/PeerPaneSessionTests.swift`)
drives E1–E10 on one `.direct` key per trial, picked by a seeded generator.
The trial holds starts and restart waits open behind gates and opens them in
random order. Each test runs 1000 trials of 30 steps. It checks:

| Invariant | How the simulation checks it |
| --- | --- |
| I1 | Once every holder releases, every lease any start made is torn down. |
| I2 | Nothing stays pooled after every holder releases. |
| I3 / I3-F | No acquire that began before a Disconnect or Force Disconnect gets a lease after it. |
| I4 | No acquire fails as disconnected unless a disconnect landed while it ran. |
| I6 | Every acquire finishes once the gates are open. |
| I7 | No lease is announced twice, and no lease is announced while not pooled. |
| I8 | After each acquire finishes, the pooled lease is not one an acquire judged dead. |

It runs two mixes. The uniform one weights all events about evenly. The
replacement-churn one favours Reconnect, restarts, and deaths: those are the
interleavings behind I5 and I8, which the uniform mix reaches about once in
thousands of trials. A failure names the invariant and the seed.

Limits:

- Interleavings depend on real scheduling, so a seed is not exactly
  reproducible. A rare break can pass one run and fail the next.
- A defect that recurses without suspending crashes the test process instead
  of failing it, because no in-test deadline can interrupt a synchronous loop.
- I5 (no stale-spec start) and I9–I10 (panes) are not simulated. Their
  dedicated tests cover them. Every trial uses one spec, so a stale spec cannot
  be told apart from a current one.

Each fix in this round was checked by reverting it. Reverting the Force
Disconnect change gives 772 I3-F breaks. Reverting the join-path retire gives
15 I8 breaks. Reverting the re-pool guard gives an I7 break. Reverting the
detach before rejoining crashes the churn test.
