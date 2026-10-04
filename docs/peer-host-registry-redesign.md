# Peer host registry redesign: one state machine per host

Status: fourth draft, implemented as PR A (`PeerHostMachine`, `PeerHostShellCore`,
and both explorer layers, not yet wired). The explorer found two defects in
this draft; both are fixed below and listed under "Exhaustive check".

Two cross-model panels reviewed earlier drafts: 21 findings on the second and
38 on the third (all five models). This draft simplifies the mechanisms that
produced the third draft's findings and fixes the explorer, whose terminal-state
checks could never fire. The table at the
end maps each finding cluster to its fix. Contract:
[`peer-host-registry-invariants.md`](peer-host-registry-invariants.md).

The plan is to stop iterating on paper after this draft and build the machine
and its explorer (PR A). Most of the third draft's findings were "unspecified"
or "two rules disagree". An executable model exposes those mechanically.

## Why

Every registry defect fixed in #673–#679 had the same shape. An `acquire` reads
the state, `await`s, wakes, re-reads state that something else changed, and
acts on its own. Several callers also repeat the same work independently. The
number of "await point × what another caller did meanwhile" combinations grows
faster than patches close them, and random simulation cannot prove their
absence; it found one about once in 2000 trials.

## Rules

1. **Nothing reads registry state, awaits, then writes it.** Each host has one
   state machine. Every decision is made in a pure, synchronous
   `reduce(state, event) -> (state', [effect])`. Anything that takes time is an
   *effect* the shell performs. Its completion comes back as an *event*. A
   caller is a *waiter*, and an effect resumes it.
2. **The shell commits `state'` before running effects, and queues events.**
   An event raised during an effect list is reduced only after that list
   finishes. Example: `fireDidReplace` → `retarget` → `retain` happens
   synchronously, and its `retain` waits in the queue.
3. **Facts about the shell are sampled at dequeue. The caller's identity is
   stamped at raise.**
   - Sampled at dequeue: the liveness verdict on the pooled lease.
   - Stamped at raise: the disconnect generation and the Reconnect token the
     caller acted under.

   The first is about the world now. The second is about when the caller
   asked.
4. **Every event names its subject and generation. Each kind of stale event has
   one specified outcome. An acquire is never ignored.**

   | Stale event | Outcome |
   | --- | --- |
   | A completion for a non-current attempt or restart | Nothing, except a late successful start, which gets `stopTunnel` on its lease |
   | An `acquire` stamped with an older generation | Resolved at once with `hostDisconnected` |
   | An `acquire` carrying a token that is not current | Resolved at once with `reconnectSuperseded` |
   | `retain` / `release` for a lease that is not pooled | Handled by the shell; never reaches the machine (rule 8). The shell decides whether the lease is pooled at dequeue, synchronously (rule 3). |

   Every acquire is resolved exactly once: by a resume, or by one of these
   immediate errors.
5. **Only three specs ever start a tunnel.** A waiter's spec is never used.
   1. *Fresh:* the spec of a `user` acquire, and only from `idle`.
   2. *Replacement:* the retired lease's own spec.
   3. *Reconnect:* the spec carried by the acquire holding the current
      Reconnect token, which `RemoteHostStore` re-probed.
6. **A replacement is the machine's obligation.** Retiring the pooled lease
   while it has dependents starts a replacement. Dependents are machine
   references (rule 8) or waiters, so the reducer can always compute them.
7. **Every waiter has a deadline. A deadline resolves only its own waiter.**
   - A deadline never cancels a start.
   - Only an explicit Cancel does. It cancels a *fresh* or *reconnect* start,
     and only when the cancelled waiter was that start's last.
   - A replacement start is never cancelled by a waiter.
   - A start that ends with no waiters and no references is stopped as soon as
     it lands (see the transitions).
8. **The pooled lease's references live in the machine.** `retain` and
   `release` on the pooled lease are events. The machine resumes a waiter with
   the lease and +1 reference in the same transition. When a lease leaves the
   pool, its remaining references become shell-only. Those belong to parked
   panes holding a retired lease, and their releases never reach the machine.

Review should treat a break of any rule as a blocking defect.

## The machine (per host key)

### State

```
HostState
  generation: UInt64          // bumped by Disconnect and Force Disconnect; not by Reconnect
  phase:
    idle
    starting(attempt, spec, purpose)        // purpose ∈ fresh | replacement | reconnect
    up(lease, spec, refs)
    restarting(lease, spec, restart, refs)
    awaitingReconnect(token)                // with a phase deadline
  waiters: [Waiter]           // id, origin, generation, deadline; never a spec
  park: nil | Parked(reason)  // panes parked, owed a reattach
  reason ∈ died | reconnect | userDisconnected
```

Waiters live beside the phase, not inside it. When the phase changes, its
waiters are carried over or resolved explicitly; none can be left behind.

### Park debt

The parked panes are owed one of two outcomes:

- **Reattach:** `fireDidReplace` runs when a lease is pooled.
- **Abandon:** `fireAbandoned` ends their park, which leaves them on the
  ordinary banner with its Reconnect.

`park` is cleared only by one of these two effects. Force Disconnect also
emits `fireAbandoned`; the panes are being closed anyway.

How `park` is set and upgraded:

| Event | Effect on `park` |
| --- | --- |
| Retire the pooled lease while it has references | `Parked(died)`, unless a `userDisconnected` debt is already there |
| `disconnect(.reconnect)` | `Parked(reconnect)` if a lease was pooled or a debt exists, unless the debt is `userDisconnected` |
| `disconnect(.plain)` | `Parked(userDisconnected)` if a lease was pooled or *any* debt exists. The user disconnected explicitly, so the panes now wait for the user's Connect. |
| `disconnect(.force)` | `fireAbandoned`, then nil |
| `reconnectAbandoned(t, movedTo: B)` with B set | `fireAbandoned`, then nil, **whatever the reason**. Nothing on key A can reattach panes that now belong to B. This matches what happens to them today. |

**Park invariant** (checked in every state): if `park` is set, then either its
reason is `userDisconnected`, or a start is outstanding, or the phase is
`awaitingReconnect` with its deadline armed. A `died` or `reconnect` debt
with nothing that could pay it is therefore unrepresentable. Whichever
transition would leave it that way emits `fireAbandoned`.

A failed start does not abandon a `userDisconnected` debt. That debt waits for
the user's next Connect.

### Events

| Event | Raised by |
| --- | --- |
| `acquire(waiter, origin, generation, spec?, token?)` | `acquire(_:)`. The verdict is sampled at dequeue (rule 3). |
| `retain(L)` / `release(L)` | the shell, for the pooled lease only (rule 8) |
| `startFinished(attempt, .lease(id) / .failure)` | the start task |
| `restartFinished(lease, restart, cameBack)` | `PeerPaneTransportRecovery` on the lease (decision 2) |
| `disconnect(.plain / .force / .reconnect(token))` | `RemoteHostStore` |
| `reconnectAbandoned(token, movedTo: Key?)` | `RemoteHostStore`: its connect failed, was cancelled, or landed under another key |
| `cancel(waiter)` | an explicit Cancel |
| `deadline(waiter)` / `deadline(token)` | an armed deadline fires |
| `unusedCheck(lease)` | the machine itself, through `queueUnusedCheck` |

### Effects

- `startTunnel(attempt, spec)`, `cancelStart(attempt)`, `stopTunnel(lease)`
- `resume(waiter, .lease(id) / .error(e))`
- `fireWillRetire`, `fireDidReplace(lease)`, `fireAbandoned`
- `armDeadline(waiter / token)`, `waitRestart(lease, restart)`
- `queueUnusedCheck(lease)`: appends `unusedCheck(lease)` to the event queue
  behind any events the current effect list raises (rule 2).

### Retire

Retiring the pooled lease L (a dead verdict in `up` or `restarting`, a failed
restart, or an `unusedCheck` that finds zero references while waiters remain):

0. First compute `dependents = refsBeforeRetire > 0 || !waiters.isEmpty`. Do
   this **before** step 1 moves the references. After the move they read
   zero. In the post-wake case every reference belongs to a pane that is about
   to park, so reading them late would bring back the parked-forever path.
1. Emit `fireWillRetire` and `stopTunnel(L)`. L's machine references move to
   shell-only. If `refsBeforeRetire > 0`, upgrade `park` to `died` (see the
   table).
2. If `dependents`, go to `starting(new, L.spec, replacement)` and emit
   `startTunnel(new, L.spec)`.
3. Otherwise go to `idle`.

### Transitions

Rule 4 applies before every row. Waiters are listed only where they change.

| From | Event | To | Effects |
| --- | --- | --- | --- |
| idle | `acquire(user, spec)` | starting(new, spec, fresh) + w | `startTunnel`, `armDeadline(w)` |
| idle | `acquire(sweep / waiter)` | idle | `resume(w, .error(replacementUnavailable))` |
| starting(a) | `acquire(any)` | + w | `armDeadline(w)` |
| starting(a) | `startFinished(a, .lease(L))` | up(L, spec, refs = waiters) | `resume(each w, L)`; if `park`: `fireDidReplace(L)`, clear; then `queueUnusedCheck(L)`. **Every** pool queues the check. Retargeted panes `retain` through the queue first, so the check sees their references. With waiters it is a no-op, but one rule ("a pooled lease with zero references is stopped") is what the explorer checks. |
| up(L) / restarting(L) | `unusedCheck(L)`, refs 0, no waiters | idle | `stopTunnel(L)` |
| restarting(L) | `unusedCheck(L)`, refs 0, waiters remain | retire | as above |
| up(L) / restarting(L) | `unusedCheck(L)` otherwise | — | — |
| starting(a) | `startFinished(a, .failure)` | idle | `resume(each w, .error)`; apply the park invariant (abandon `died` / `reconnect`, keep `userDisconnected`) |
| starting(a, fresh / reconnect) | `cancel(w)` of its last waiter | idle | `cancelStart(a)`, `resume(w, .error(cancelled))`; apply the park invariant |
| any | `cancel(w)` / `deadline(w)` otherwise | − w | `resume(w, .error(cancelled / replacementUnavailable))` |
| up(L) / restarting(L) | `retain(L)` | refs + 1 | — |
| up(L) / restarting(L) | `release(L)` | refs − 1 | at 0: `queueUnusedCheck(L)`. Never a stop in this transition (see the explorer findings). |
| up(L) | `acquire(any)`, verdict usable | refs + 1 | `resume(w, L)` |
| up(L) | `acquire(any)`, verdict restarting | restarting(L, new r) + w | `waitRestart(L, r)`, `armDeadline(w)` |
| up(L) / restarting(L) | `acquire(any)`, verdict dead | retire, w joins | as above |
| restarting(L) | `acquire(any)`, verdict not dead | + w | `armDeadline(w)` |
| restarting(L, r) | `restartFinished(L, r, true)` | up(L, refs + waiters) | `resume(each w, L)` |
| restarting(L, r) | `restartFinished(L, r, false)` | retire | as above |
| any | `disconnect(.plain)` | idle, generation + 1 | `cancelStart`, `stopTunnel`, `resume(every w, .error(hostDisconnected))`, park update |
| any | `disconnect(.force)` | idle, generation + 1 | as `.plain`, then `fireAbandoned`, park nil |
| any | `disconnect(.reconnect(t))` | awaitingReconnect(t) | `cancelStart`, `stopTunnel`, `armDeadline(t)`, park update. `user` waiters are **carried**; they keep their deadlines and receive the reconnect's lease. `sweep` and `waiter` origins are resolved with `replacementUnavailable`. The generation is not bumped: the old attempt, lease, and restart ids are retired, and the token now gates who may start. |
| awaitingReconnect(t) | `acquire(user, spec, token t)` | starting(new, spec, reconnect) + w | `startTunnel`, `armDeadline(w)` |
| awaitingReconnect(t) | `acquire(any, no token)` | + w | `armDeadline(w)` (they wait for the reconnect) |
| awaitingReconnect(t) | `reconnectAbandoned(t, nil)` or `deadline(t)` | idle | `resume(each w, .error(replacementUnavailable))`; apply the park invariant |
| awaitingReconnect(t) | `reconnectAbandoned(t, movedTo: B)` | idle | `resume(each w, .error(replacementUnavailable))`; `fireAbandoned`, park nil (any reason) |
| any | a late `startFinished(.lease(L))` | — | `stopTunnel(L)` |

Two changes from the third draft are worth reading closely:

- **Reconnect decides each waiter's fate explicitly.** It keeps the behavior
  #675 (N1) fixed: a pane's banner Reconnect that is mid-acquire when the user
  clicks Reconnect Host moves to the replacement. `user` waiters are carried
  into `awaitingReconnect`, where they now have deadlines, so the third
  panel's wedge does not return. Background waiters (`sweep`, `waiter`) are
  resolved. Nothing is left implicitly attached to the cancelled attempt.
- **The cross-key seam** is `reconnectAbandoned(t, movedTo: B)`. Key A resolves
  its waiters, and the park invariant abandons A's parked panes. Rebinding them
  to key B remains an open item.

## How the invariants hold

| Invariant | Structural reason |
| --- | --- |
| I1, no orphan | Only the current attempt's `startFinished` pools a lease. A late one is stopped. A pooled lease whose references and waiters reach zero is stopped, including one that landed with none (rules 7 and 8). |
| I2, references | Pooled-lease references are machine state and change only in transitions. Shell-only references on retired leases cannot touch the pool. |
| I3, I3-F, disconnect is final | Disconnect and Force Disconnect bump the generation and resolve every waiter. An acquire stamped earlier is resolved `hostDisconnected` at dequeue (rule 4). Reconnect is not a disconnect in this sense: it retires the old ids and gates new starts on its token. |
| I4, a fresh acquire after a disconnect | After a disconnect the phase is `idle`, and after a Reconnect it is `awaitingReconnect`, so there is no old start to join. |
| I5, no stale-spec start | Rule 5. Waiters carry no spec. |
| I6, termination | Rule 7: every waiter has a deadline, every acquire is resolved exactly once (rule 4), and `awaitingReconnect` has its own deadline. |
| I7, announced exactly once | `fireDidReplace` fires only on a transition that pools while `park` is set, and that transition clears `park`. Between two pools, `park` can be set again only by a retire or a disconnect. That is a new debt, so each debt is paid exactly once. |
| I8, dead is not left pooled | A dead verdict retires the lease in both `up` and `restarting`. |
| Post-wake recovery | Rule 6: dependents are computable from machine state, and retiring with dependents always starts the replacement. |
| No parked-forever | The park invariant, checked in every state. |
| Reconnect repair is not bypassed | Only the current token's holder starts from `awaitingReconnect`. A stale token is resolved `reconnectSuperseded`, never treated as a fresh start. |
| Cancel | An explicit Cancel stops a fresh or reconnect start it was the last waiter of. Deadlines never cancel. |

These stay checked rather than structural: I9 and I10 (pane-side), and pane
rebinding across a key change (an open item).

## Exhaustive check

Implemented in PR A as `PeerHostMachineExplorerTests`
(`swift/PeerProto/Tests/PeerProtoTests/`). Both layers drive the real
`PeerHostShellCore` and `PeerHostMachine`, not a model of them, so PR B's shell
wraps the code that was checked. Run them in release mode; a failure prints the
shortest event sequence that reaches it:

```
swift test -c release -Xswiftc -enable-testing --package-path swift/PeerProto \
  --filter PeerHostMachineExplorerTests
```

### The ghost ledger

The harness performs every effect and keeps what the shell and the panes would
know:

- panes holding each lease;
- panes parked on a stopped lease;
- acquires asked and not yet resolved, with the generation each was raised under;
- armed deadlines;
- pending start and restart completions, including cancelled ones;
- each lease's health, which the core samples as the verdict.

Retargeting is the handler's own behavior. `fireDidReplace` makes every parked
pane `retain` the new lease and `release` its old one, through the core.

### Inputs

- **Internal:** `startFinished` (lease or failure) for each pending attempt,
  including cancelled ones, so a late lease is reached. `restartFinished`
  (back, unless the lease is dead, or gone) for each pending restart. The
  deadline of each armed waiter or token.
- **Environment:**
  - an acquire from each origin;
  - a user acquire with the current token or a stale one;
  - an acquire *raised* now and delivered later, so its stamped generation or
    token can go stale;
  - a pane releasing the pooled lease;
  - a parked pane closing;
  - the pooled lease becoming restarting or dead;
  - each disconnect kind;
  - `reconnectAbandoned` with and without a key move, for every token minted;
  - `cancel` for each waiter.
- **Layer 2 only:** at every effect position of every transition, one
  re-entrant call:
  - a user or sweep acquire;
  - an acquire followed by the lease dying before it is dequeued;
  - a release;
  - the lease dying;
  - a plain disconnect;
  - a Reconnect.

Specs are values that name their source: `user`, `stale` (every background
waiter's), and `probed(t)` (the token holder's). Each `startTunnel` is checked
against the cause and the state before it:

| Cause | Allowed spec |
| --- | --- |
| A user acquire from `idle` | The acquire's own spec |
| The token holder from `awaitingReconnect` | The token holder's spec |
| A retire | The retired lease's spec |
| Anything else | None; a `stale` spec never starts |

### Checks

**On each effect:**

| Check | Rule |
| --- | --- |
| A `resume` resolves an acquire that is asked and unresolved. | 4 |
| A lease handed out is pooled. | I1 |
| A lease handed out goes to a waiter raised under the current generation. | I3 |
| A lease handed out was not already dead when the acquire was dequeued. | 3 |
| `stopTunnel` never reaches the lease that is pooled after the commit. | 2 |
| `cancelStart` is caused only by a Cancel or a disconnect. | 7 |
| `fireAbandoned` is caused only by a failed start, a Cancel, `reconnectAbandoned`, a Reconnect deadline, or Force Disconnect. A rule-6 regression would otherwise pass by abandoning eagerly. | 6 |
| `fireDidReplace` has a debt to pay. | I7 |

**In every state:**

- the pooled lease's refs equal the panes holding it;
- no pane holds a lease that is neither pooled nor parked;
- parked panes imply a debt;
- a `died` or `reconnect` debt has a start or an armed Reconnect deadline;
- the machine's waiters are exactly the unresolved acquires, each with an
  armed deadline and the current generation;
- every current attempt, restart, and Reconnect wait has a pending completion
  or deadline.

**In every quiescent state** (no completion, deadline, or raised acquire
pending): no waiters, and no pooled lease with zero refs.

**Coverage.** Each layer lists the transition rows it must reach: every start
purpose, every failure kind by cause, every park change, every abandon cause,
late and unused stops, and every re-entrant call kind. A bound that stops
reaching a row fails the test instead of passing on a smaller search.

### Bounds and results

Neither layer is depth-limited: each search runs until the bounded space
closes.

| Layer | Bounds | States | Closes at depth | Release build |
| --- | --- | --- | --- | --- |
| 1 | 3 waiters, 1 raised acquire in flight, 2 of each disconnect kind | 870,611 | 21 | ~31 s |
| 2 (default) | 2 waiters, 1 in flight, 2 of each disconnect kind | 370,573 | 15 | ~55 s |
| 2 (wider, manual) | 3 waiters, 1 in flight, 1 of each disconnect kind | 1,060,036 | 16 | ~190 s |
| 2 (widest, manual) | 3 waiters, 1 in flight, 2 of each disconnect kind | 6,846,071 | 19 | ~24 min, 7.7 GB |

All rows passed with no violation. The wider layer 2 bounds are run by editing
`ExplorerBounds.layer2`; they are too slow for every test run.

The guarantee is "no violation in any state reachable within these bounds",
not "within N steps".

### What the explorer found in the fourth draft

Both were fixed in the machine and in the transition table above:

1. **A zero-reference lease left pooled (layer 1, 7 events).** In `restarting`,
   the waiter's deadline fired and the last pane released. The draft had no
   row for that, so the phase stayed `restarting` with no references, and
   `restartFinished(true)` pooled an orphan tunnel.
2. **A retargeted pane stranded on a stopped lease (layer 2, 4 events).**
   1. A Connect after Disconnect Host lands.
   2. While its waiter is resumed, a release is raised.
   3. That release reached zero refs and stopped the lease at once. The
      retargeted pane's `retain` was still queued behind it.
   4. The pane parked on a stopped lease. Its debt had just been paid, so it
      stayed parked forever.

   Reaching zero refs now only queues `unusedCheck`, so every `retain` queued
   before it lands first.

Two of the explorer's own judgments were too strict and were corrected:

- A retire can now be caused by `unusedCheck`.
- A retarget `retain` that lands after a disconnect stopped the lease is not a
  defect. That pane is parked under the new debt, and the parked-forever check
  verifies that.

### Gate

`scripts/peer-host-machine-gate.py` runs both layers, then breaks one rule at a
time and requires the named layer to fail with the named violation. It
restores each source byte for byte.

- **Rule 1** cannot be broken in a synchronous core, so it is checked
  structurally: no `async`, `await`, `Task`, `DispatchQueue`, or `Thread` in
  the machine or the core, and `reduce` is static.
- **Every other rule** has a mutant. Each one, and the layer and violation
  that caught it on the PR A run:

| Mutant | Caught by | Violations |
| --- | --- | --- |
| Rule 2: commit after the effects run | layer 1 | I1, rule 2 |
| Rule 2: reduce re-entrant calls in the middle of an effect list | layer 2 | I1, I3 |
| Rule 3: sample the verdict when the acquire is raised | layer 2 | rule 3 |
| Rule 4: ignore an acquire raised before a disconnect | layer 1 | rule 4 |
| Rule 4: treat a stale token as a plain acquire | layer 1 | rule 5 |
| Rule 5: let a background waiter start from `idle` with its own spec | layer 1 | rule 5 |
| Rule 6: read dependents after the references leave the pool | layer 1 | rule 6 |
| Rule 7: a deadline cancels the start | layer 1 | rules 6, 7 |
| Rule 7: admit a waiter without a deadline | layer 1 | rule 7 |
| Rule 8: resume without counting the reference | layer 1 | rule 8 |
| Park invariant: never abandon an unpayable debt | layer 1 | parked forever |
| Zero references stop the lease at once (finding 2) | layer 2 | parked forever |

## Open items

- **Pane rebinding after a key move.** A cross-key Reconnect abandons the
  panes parked on the old key. Their banner Reconnect still uses their
  original spec. This gap already exists today.
- **The liveness probe.** It stays a synchronous `connect(2)` on the main actor,
  sampled at dequeue (rule 3).

## Migration

The external API is kept, so the 34 call sites in 7 files do not change.

| PR | Content | Gate |
| --- | --- | --- |
| A | `PeerHostMachine` and both explorer layers. Nothing wired. | Both layers green; mutating each rule makes one fail. |
| B | `PeerPaneHostRegistry` as the shell, matching layer 2. The `ForTests` seams keep their meaning. | The acceptance suite; a tagged-app pass on jwserver68 (Reconnect Host, Disconnect then Connect, Force Disconnect); a unit test for `recoverPeerTransportsAfterWake`; full Debug build. |
| C | Old paths deleted; invariants doc updated. | Same suite. |

### Acceptance suite for PR B

These tests encode old behavior and are rewritten in PR B:

| Test | Reason |
| --- | --- |
| `test_cancelPendingAcquire_refusesWhileAnotherPaneIsWaiting` | Cancel is per waiter (rule 7). |
| `test_registry_waitForRestartKeepsTheLeaseThatComesBack`, `test_registry_waitForRestartReplacesTheLeaseThatDoesNot` | A restart wait becomes the `restarting` phase. |
| `test_registry_restartWaiterJoinsTheReconnectHostReplacementWithoutStartingOne`, `test_registry_restartWaiterGivesUpWhenNoReplacementStarts` | A `user` waiter is carried into `awaitingReconnect` and still receives the replacement, so #675's N1 outcome is kept. A background waiter is now resolved `replacementUnavailable` instead of joining: **that outcome flips**. `awaitingReconnect` has its own deadline. |
| `test_registry_restartWaiterStartsFreshWhenTheLeaseWasOnlyReleased` | The last `release` with waiters still present now retires, through `unusedCheck`, and starts a replacement with `L.spec`. |

Every other registry test, the relay park and retarget tests, and the
simulation run unchanged. Socket E2E for a release goes through `mac-sub`.

## Decisions

All three still stand:

1. Reconnect Host keeps the socket re-probe in `RemoteHostStore`.
2. Restart coordination stays in `PeerPaneTransportRecovery` and reports
   through `restartFinished`.
3. Hard cutover in PR B.

## Third-draft panel findings (38, five models) → this draft

| Cluster | Findings | Models | Fix |
| --- | --- | --- | --- |
| Explorer checks never fire; bounds too small; no specs; layer 2 property wrong; re-entrancy under-modelled | 13, 15, 24, 28, 31, 33, 35, 36, 38 | claude, codex, agy, kiro, cursor | Quiescent-state liveness; every-state obligations; two of each disconnect; spec epochs; corrected layer 2 property; re-entrant acquire / disconnect |
| `owed` bookkeeping lost or misapplied | 5, 14, 16, 20, 23, 25 | agy, codex, cursor, kiro, claude | `park` with an upgrade table; the park invariant; a failed start keeps `userDisconnected`; Force Disconnect abandons explicitly |
| Stale-token acquire unspecified | 1, 9, 17 | claude, kiro, agy | Rule 4: resolved `reconnectSuperseded`, never ignored or started |
| `awaitingReplacement` wedge | 8, 11, 29, 32 | kiro, claude, cursor | `awaitingReconnect` phase deadline; cancellation raises `reconnectAbandoned`; Reconnect resolves earlier waiters |
| Dependents not computable; retire missing `startTunnel`; ambiguous dead-verdict row; no retain on acquire | 2, 3, 4, 27, 30, 37 | codex, agy, claude, kiro | Rule 8 (references in the machine); retire step 2 emits `startTunnel`; the triggering acquire joins as a waiter; resume carries +1 |
| Zero-reference replacement orphan | 10, 21 | claude, kiro | A pooled lease with zero references and no waiters is stopped |
| Reconnect revives cancelled waiters; generation not checked on acquire or advanced by Reconnect | 6, 7, 18, 34 | cursor, agy | Acquires carry a raise-time generation. Disconnect and Force Disconnect bump it and resolve every waiter. Reconnect retires the old ids, carries `user` waiters on purpose (keeping #675's N1), and resolves the rest. |
| Deadlines conflated with Cancel; Cancel cannot stop a reconnect | 12, 22 | claude, kiro | Rule 7 |
| `restarting` has no dead-verdict row | 26 | claude | A dead verdict retires from `restarting` too |
| Release exception lost | 19 | cursor | The last `release` with waiters retires and starts with `L.spec` |
