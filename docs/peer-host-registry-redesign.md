# Peer host registry redesign: one state machine per host

Status: proposal, third draft. The second draft was reviewed by a cross-model
panel (codex, agy, kiro), which reported 21 defects; the table at the end maps
each one to where this draft addresses it. Contract:
[`peer-host-registry-invariants.md`](peer-host-registry-invariants.md).

## Why

Every registry defect fixed in #673–#679 had the same shape. An `acquire` reads
the state, `await`s, wakes up, re-reads state that something else has changed,
and acts on its own. Several callers also do the same work independently: every
caller of one start used to pool its lease, which is how a late caller
re-pooled a retired lease. In that shape, the number of
"await point × what another caller did meanwhile" combinations grows faster
than patches can close them. The random simulation cannot prove the absence of
such combinations either; it found one of them about once in 2000 trials.

This design removes the shape instead of patching each instance, and it makes
the core exhaustively checkable rather than sampled.

## Rules

1. **Nothing reads registry state, awaits, then writes registry state.** Each
   host has one state machine. Every decision is made in a pure, synchronous
   `reduce(state, event) -> (state', [effect])`. Anything that takes time is an
   *effect* the shell performs. Its completion comes back as an *event*.
   Callers decide nothing: a caller is a *waiter*, and an effect resumes it.
2. **The shell commits `state'` before running effects, and queues events.** An
   effect can call back into the registry synchronously. For example,
   `fireDidReplace` → `resumePanesAfterHostReconnect` → `retarget` → `retain`,
   or a resumed caller that releases at once. An event raised that way is queued
   and reduced only after the current effect list finishes.
3. **Anything an event asserts about the shell is sampled when the event is
   dequeued, not when it is raised.** This covers the liveness verdict an
   `acquire` carries and the zero reference count a `lastReleased` claims. A
   `lastReleased(L)` raised during an effect list is dropped at dequeue if a
   later effect in the same list retained `L`. Sampling is synchronous, so no
   `await` separates it from the reduction.
4. **Every event names what it is about, and is ignored if that is no longer
   current.** That is the attempt, lease, restart, or token. A late event for
   an attempt, lease, restart, or token that is no longer current changes
   nothing. Only a late successful start has an effect: `stopTunnel` on the
   lease it produced.
5. **Only three specs ever start a tunnel:**
   - **Fresh:** the spec of a `user` acquire, sampled at dequeue, and only when
     the phase is `idle`.
   - **Replacement:** the retired lease's own `spec`.
   - **Reconnect:** the spec carried by the acquire that holds the Reconnect
     Host token. That acquire comes from `RemoteHostStore`'s connect after its
     socket re-probe.

   A waiter's spec is never used. Nothing else can start a tunnel.
6. **Starting a replacement is the machine's obligation, not a waiter's.** When
   a lease with dependents is retired, a replacement starts with that lease's
   spec, whether or not any particular waiter is still present. Dependents are
   pooled references or waiters. A waiter's deadline or cancel can resolve that
   waiter, but it never cancels a replacement or reconnect start.

If a decision lands on the caller side of an `await`, an event is reduced while
effects are running, or a fact is sampled at raise time, the old bug class is
back. Review should treat each of these as a blocking defect.

## The machine (per host key)

### State

```
HostState
  phase:
    idle
    starting(attempt: AttemptID, spec: Spec, purpose: Purpose, waiters: [Waiter])
    up(lease: LeaseID, spec: Spec)
    restarting(lease: LeaseID, spec: Spec, restart: RestartID, waiters: [Waiter])
    awaitingReplacement(token: Token, waiters: [Waiter])
  purpose ∈ { fresh, replacement, reconnect }
  disconnectGeneration: UInt64
  owed: nil | .reattach(reason)    // parked panes are owed a reattach
  reason ∈ { died, reconnect, userDisconnected }
```

Reference counts stay on `PeerPaneHostLease`. Panes keep references on leases
that have already left the pool (Disconnect Host preserves them), so the count
cannot live in the machine. The shell raises `lastReleased(L)` when the pooled
lease reaches zero, and rule 3 re-checks the count when the event is dequeued.

`owed` replaces `replacingKeys` and says why the panes are parked.

- It is set when a pooled lease is retired, disconnected, or reconnected away.
  "Pooled" covers both `up` and `restarting`.
- It is cleared in exactly two ways: by pooling a lease, which fires
  `fireDidReplace` once, or by emitting `fireAbandoned`.

Force Disconnect closes the panes, so it leaves `owed` at nil.

### Waiters

| Origin | Who | Starts |
| --- | --- | --- |
| `user` | sidebar Connect, a Peer-menu pane, banner Reconnect, a team spawn, `RemoteLiveProject`, git checkpoint | a fresh start, only from `idle` |
| `sweep` | the wake sweep judging a pooled lease | nothing directly; retiring a dead lease starts its replacement (rule 6) |
| `waiter` | a caller whose awaited lease vanished | nothing |

An acquire may carry the Reconnect token (`RemoteHostStore`'s connect after
Reconnect Host). That acquire, and only that one, starts the reconnect.

**Deadlines.** Every waiter gets a deadline, with one exception: a `user`
waiter in a `fresh` `starting` phase. That start is bounded by itself, since
the tunnel's own spawn and socket deadlines guarantee `startFinished`. The
sidebar also adds `timeoutConnectingHost`. A registry deadline there would
cancel the attempt when its last waiter left, which would be a Cancel nobody
asked for. In `restarting` and `awaitingReplacement`, `user` waiters have
deadlines like everyone else.

### Events

Each event names its subject. Rule 4 drops any event whose subject is not
current.

| Event | Raised by |
| --- | --- |
| `acquire(waiter, origin, spec?, token?)` | `acquire(_:)`. The verdict on the current pooled lease is sampled at dequeue (rule 3). |
| `lastReleased(lease)` | the shell, when the pooled lease reaches zero. Re-checked at dequeue. |
| `startFinished(attempt, .lease(id) / .failure)` | the shell's start task |
| `restartFinished(lease, restart, cameBack)` | `PeerPaneTransportRecovery` on the lease (decision 2) |
| `disconnect(.plain / .force / .reconnect(token))` | `RemoteHostStore` |
| `replacementAbandoned(token, movedTo: Key?)` | `RemoteHostStore`: its connect failed (`nil`), or it landed under another key |
| `cancel(waiter)` | sidebar Cancel, task cancellation |
| `deadline(waiter)` | an armed deadline fires |

Restart coordination stays on the lease this round (decision 2), so
`tunnelStateChanged` is not an input. Feeding it in as well would give
"restarting" two writers.

### Effects

- `startTunnel(attempt, spec)`, `cancelStart(attempt)`, `stopTunnel(lease)`
- `resume(waiter, .lease(id) / .error(e))`
- `fireWillRetire`, `fireDidReplace(lease)`, `fireAbandoned`
- `armDeadline(waiter)`, `waitRestart(lease, restart)`

`fireAbandoned` tells the coordinator that the parked panes will not be
reattached. It abandons their park, which ends them with the ordinary
disconnected banner and its Reconnect. This is the existing
`abandonTransportReplacement` path. Parked panes therefore always end one of
two ways: reattached through `fireDidReplace`, or on the ordinary banner
through `fireAbandoned`.

### Retiring a lease

Retiring the pooled lease L, after a dead verdict, a failed restart, or a
`lastReleased` while `restarting`, does this:

1. Emit `fireWillRetire` and `stopTunnel(L)`. Set `owed = .reattach(.died)`,
   unless the trigger was `lastReleased`; in that case nobody holds L and
   nothing is owed.
2. If L has dependents (pooled references, or waiters), start a replacement:
   `starting(new, L.spec, .replacement, waiters)`. This is rule 6.
3. Otherwise, go `idle`. If `owed` is still set, emit `fireAbandoned` and
   clear it.

### Transitions

`*` means the event's subject is checked by rule 4 first.

| From | Event | To | Effects |
| --- | --- | --- | --- |
| idle | `acquire(user, spec)` | starting(new, spec, fresh, [w]) | `startTunnel` |
| idle | `acquire(sweep / waiter)` | idle | `resume(w, .error(replacementUnavailable))` |
| starting(a) | `acquire(any, no token)` | starting(a, +w) | `armDeadline` unless rule says otherwise |
| starting(a) | `startFinished*(a, .lease(L))` | up(L, spec) | `resume(each w, L)`; if `owed`: `fireDidReplace(L)`, clear `owed` |
| starting(a) | `startFinished*(a, .failure)` | idle | `resume(each w, .error)`; if `owed`: `fireAbandoned`, clear |
| starting(a, fresh) | last waiter leaves (cancel or deadline) | idle | `cancelStart(a)` |
| starting(a, replacement / reconnect) | last waiter leaves | unchanged | none; the machine still owes the start |
| up(L) | `acquire(any)`, verdict usable | up(L) | `resume(w, L)` |
| up(L) | `acquire(any)`, verdict restarting | restarting(L, new r, [w]) | `waitRestart(L, r)`, `armDeadline` |
| up(L) | `acquire(any)`, verdict dead | retire L | as above; `w` joins the replacement or gets `replacementDied` |
| up(L) | `lastReleased*(L)` | idle | `stopTunnel(L)` |
| restarting(L, r) | `acquire(any)` | restarting(L, r, +w) | `armDeadline` |
| restarting(L, r) | `restartFinished*(L, r, true)` | up(L) | `resume(each w, L)` |
| restarting(L, r) | `restartFinished*(L, r, false)` | retire L | as above |
| restarting(L, r) | `lastReleased*(L)` | retire L | as above (no `owed`) |
| any | `disconnect(.plain)` | idle, generation + 1 | `cancelStart`, `stopTunnel`, `resume(every w, .error(hostDisconnected))`; if a lease was pooled: `owed = .reattach(.userDisconnected)` |
| any | `disconnect(.force)` | idle, generation + 1 | as `.plain`, but `owed = nil` (the panes are closed) |
| any | `disconnect(.reconnect(t))` | awaitingReplacement(t, waiters) | `cancelStart`, `stopTunnel`; if a lease was pooled: `owed = .reattach(.reconnect)` |
| awaitingReplacement(t) | `acquire(user, spec, token t)` | starting(new, spec, reconnect, waiters + w) | `startTunnel` |
| awaitingReplacement(t) | `acquire(any, no token)` | awaitingReplacement(t, +w) | `armDeadline` |
| awaitingReplacement(t) | `replacementAbandoned*(t, _)` | idle | `resume(each w, .error(replacementUnavailable))`; if `owed`: `fireAbandoned`, clear |
| idle | `acquire(user, spec)` while `owed = .userDisconnected` | starting(new, spec, fresh, [w]) | `startTunnel`; on pool, `fireDidReplace` reattaches the panes Disconnect Host preserved |
| any | `cancel(w)` / `deadline(w)` | w removed | `resume(w, .error(cancelled / replacementUnavailable))`, then the "last waiter leaves" row if it applies |
| any | a late `startFinished*` with `.lease(L)` | unchanged | `stopTunnel(L)` |
| any | other late events* | unchanged | none |

The cross-key seam is `replacementAbandoned(t, movedTo: B)`. Key A resolves its
waiters and abandons its parked panes. Those panes end on the ordinary banner.
Their Reconnect rebuilds through `reconnectRemotePane`, which still acquires
with the pane's original spec on key A. That gap already exists today and is
listed under open items below.

## How the invariants become structural

| Invariant | Why it now holds by construction |
| --- | --- |
| I1, one lease and no orphan | Only `startFinished` for the current attempt pools a lease. Every other successful start is stopped (rule 4). |
| I3, I3-F, disconnect is final | `disconnect` resolves every waiter, bumps the generation, and replaces every current id. Late events for the old ids are ignored (rule 4). |
| I4, a fresh acquire after a disconnect | After a disconnect the phase is `idle`, so there is nothing left to join. |
| I5, no stale-spec start | Rule 5. A fresh start uses a spec sampled at dequeue, only from `idle`. A replacement uses the retired lease's spec. A reconnect uses the re-probed spec. A waiter's spec is never used. |
| I5's release exception | `lastReleased` while waiters remain starts a replacement with `L.spec`, which the old `leftPoolByRelease` path approximated. |
| I6, termination | Every waiter but a fresh-start `user` has a deadline. That one is bounded by `startFinished`, which the tunnel's own deadlines guarantee. |
| I7, announced exactly once | `owed` is cleared in the same transition that fires `fireDidReplace` or `fireAbandoned`. |
| I8, dead is not left pooled | A dead verdict or a failed restart leaves `up` / `restarting` in the same transition. |
| Post-wake recovery | Rule 6: retiring a dead lease that has dependents starts its replacement, whoever triggered the retire and whatever happens to that trigger afterwards. |
| No parked-forever | `owed` is cleared only by `fireDidReplace` or `fireAbandoned`, and every path that ends a replacement attempt without pooling emits `fireAbandoned`. The one exception is `.userDisconnected`, which waits for the user's Connect by design. |
| Reconnect repair is not bypassed | In `awaitingReplacement`, only the acquire carrying the token starts a tunnel. Every other acquire waits for it. |
| Cancel stops what it can | Cancelling the last waiter of a fresh start cancels that start. It never cancels a replacement or reconnect start. |
| Re-entrancy | Rules 2 and 3. A `lastReleased` raised during an effect list is re-checked at dequeue, so a lease retained later in the same list is not stopped. |

These stay checked rather than structural:

- I2 (reference counts): callers still call `release`.
- I9 and I10: pane-side parking and refusal.

## Exhaustive check, in two layers

### Layer 1: the reducer

A breadth-first search over machine states, with a visited set. In every state
it enables every input the environment could produce next:

- **Completions:** `startFinished` succeeding or failing for each outstanding
  attempt, and `restartFinished` true or false.
- **External events:** `acquire` from each origin, with and without the token,
  under each verdict (usable, restarting, dead); `lastReleased`; each kind of
  `disconnect`; `replacementAbandoned` with and without `movedTo`; and
  `cancel` and `deadline` for each live waiter.
- **Late events:** every lease-, attempt-, restart-, or token-scoped event for
  an id that was current earlier in the path.

Bounds: one host key, at most 3 waiters, 3 attempts, 2 restarts, one disconnect
of each kind, and a depth of 12.

### Layer 2: the shell

A small explicit model of the shell: reference counts, the effect list, the
event queue, and re-entrant callbacks.

- `fireDidReplace` retains the lease 0–2 times.
- A resumed caller releases the lease at once, or keeps it.

Layer 2 explores where those callbacks land relative to the effect list. It
checks that no `stopTunnel` reaches a lease whose reference count is above
zero, and that the queue always drains.

### Checks

In every state:

- the invariants above.

In every terminal state (nothing enabled):

- no unresolved waiter;
- no outstanding attempt or restart;
- no lease that is neither pooled nor stopped;
- `owed` is nil, or `.userDisconnected` (no parked-forever);
- every late event in the path was a no-op apart from `stopTunnel`.

The guarantee is "no violation within these bounds". Every defect found in
this session needed 4–6 events. The search is deterministic, so a failure
prints the exact event sequence that reproduces it.

The random simulation stays, aimed at the real shell, for real `await`
scheduling.

## Open items, not solved here

- **Pane rebuild after a key move.** A parked pane abandoned by a cross-key
  Reconnect ends on the ordinary banner. Its Reconnect acquires with the
  pane's original spec on the old key. This gap already exists today. Fixing
  it needs the coordinator to rebind panes to the new key, which is a separate
  change.
- **The liveness probe.** It is a synchronous `connect(2)` on the main actor,
  as today. Rule 3 keeps it synchronous so it can be sampled at dequeue.
  Moving it off the main actor would make it an effect whose result is an
  event. That is possible but outside this round.

## Migration

The external API is kept, so the 34 call sites in 7 files do not change.

| PR | Content | Gate |
| --- | --- | --- |
| A | `PeerHostMachine` (state, events, effects, reducer), the layer 1 explorer, and the layer 2 shell model. Nothing wired yet. | Both explorers green; mutating each rule (1–6) makes one of them fail. |
| B | `PeerPaneHostRegistry` rewritten as the shell, implementing rules 2 and 3 exactly as layer 2 models them. The `ForTests` seams keep their meaning. | The acceptance suite below; a tagged-app pass on jwserver68 (Reconnect Host, Disconnect then Connect, Force Disconnect); a unit test driving `recoverPeerTransportsAfterWake` with `livenessOverrideForTests`; full Debug build. |
| C | Old code paths deleted; the invariants doc updated to cite the machine. | Same suite. |

### Acceptance suite for PR B

Most registry tests run unchanged. These encode old behavior and are rewritten,
each for the reason given:

| Test | Reason |
| --- | --- |
| `test_cancelPendingAcquire_refusesWhileAnotherPaneIsWaiting` | Cancel becomes per waiter and cancels only a fresh start. |
| `test_registry_waitForRestartKeepsTheLeaseThatComesBack`, `test_registry_waitForRestartReplacesTheLeaseThatDoesNot` | A restart wait becomes the `restarting` phase with `restartFinished`. |
| `test_registry_restartWaiterJoinsTheReconnectHostReplacementWithoutStartingOne`, `test_registry_restartWaiterGivesUpWhenNoReplacementStarts` | Joining becomes `awaitingReplacement`, and only the token holder starts. |
| `test_registry_restartWaiterStartsFreshWhenTheLeaseWasOnlyReleased` | A release while waiters remain now starts the replacement with `L.spec`. The outcome is the same; the mechanism differs. |

Every other registry test, the relay park and retarget tests, and the
simulation run unchanged. Socket E2E for any release goes through the
`mac-sub` runner.

## Decisions

Reviewed with the advisor; all three stand.

1. **Reconnect Host keeps the socket re-probe in `RemoteHostStore`.** The
   re-probed spec reaches the machine only through the token-holding acquire.
2. **Restart coordination stays in `PeerPaneTransportRecovery` this round.**
   It reports through `restartFinished`, which carries a restart id.
3. **Hard cutover in PR B**, gated by the acceptance suite.

## Panel findings on the second draft

| # | Model | Finding | Addressed by |
| --- | --- | --- | --- |
| 1 | agy | A sweep waiter's failed restart left nothing to start the replacement | Rule 6, "Retiring a lease" |
| 2 | agy | A queued `lastReleased` stops a lease that `fireDidReplace` retained | Rule 3 |
| 3 | kiro | `user` waiters in `restarting` / `awaitingReplacement` had no deadline | "Deadlines" |
| 4 | codex | A `user` waiter's own spec starts the replacement (I5) | Rule 5 |
| 5 | codex | `lastReleased` while a sweep waits left nothing starting | Rule 6 and the "Retiring a lease" dependents step |
| 6 | codex | Late `restartFinished` / `lastReleased` after a disconnect were unspecified | Rule 4 |
| 7 | codex | The announcement flag was never cleared | `owed`, cleared on pool or abandon |
| 8 | agy | `user` waiters in `restarting` could hang | "Deadlines" |
| 9 | agy | A `user` waiter's spec starts the replacement (I5) | Rule 5 |
| 10 | agy | The phase after the last waiter cancels was unspecified | The "last waiter leaves" rows |
| 11 | agy | Parked panes on the old key never resolved after a key move | `replacementAbandoned` → `fireAbandoned`; rebinding listed as an open item |
| 12 | kiro | A parked `user` waiter's spec starts the replacement (I5) | Rule 5 |
| 13 | kiro | The verdict carried no lease id and was sampled at raise time | Rule 3 (sampled at dequeue) |
| 14 | kiro | Only `startFinished` had a stale guard | Rule 4 |
| 15 | kiro | A non-token acquire bypasses the Reconnect re-probe | Only the token holder starts in `awaitingReplacement` |
| 16 | kiro | A deadline or cancel removes the waiter that owned the replacement start | Rule 6 |
| 17 | codex | The explorer never enabled `replacementAbandoned` | Layer 1 external events |
| 18 | agy | The explorer missed re-entrancy, cross-key events, and hangs | Layer 2; layer 1 late and abandon events |
| 19 | kiro | The `leftPoolByRelease` exception was lost | "I5's release exception" |
| 20 | kiro | The announcement was not set when retiring from `restarting` | `owed` is set for any pooled lease, `up` or `restarting` |
| 21 | kiro | The explorer could not reach the cancel, cross-key, stale-verdict, or cutoff defects | Layer 1 enables every external and late event |
