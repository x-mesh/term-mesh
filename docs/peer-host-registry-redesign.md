# Peer host registry redesign: one state machine per host

Status: proposal, fourth draft. Two cross-model panels reviewed earlier drafts:
21 findings on the second and 38 on the third (all five models). This draft
simplifies the mechanisms that produced the third draft's findings and fixes
the explorer, whose terminal-state checks could never fire. The table at the
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
restart, or the last `release` while waiters remain):

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
| up(L) | `unusedCheck(L)`, refs 0, no waiters | idle | `stopTunnel(L)` |
| up(L) | `unusedCheck(L)` otherwise | — | — |
| starting(a) | `startFinished(a, .failure)` | idle | `resume(each w, .error)`; apply the park invariant (abandon `died` / `reconnect`, keep `userDisconnected`) |
| starting(a, fresh / reconnect) | `cancel(w)` of its last waiter | idle | `cancelStart(a)`, `resume(w, .error(cancelled))`; apply the park invariant |
| any | `cancel(w)` / `deadline(w)` otherwise | − w | `resume(w, .error(cancelled / replacementUnavailable))` |
| up(L) / restarting(L) | `retain(L)` | refs + 1 | — |
| up(L) | `release(L)` to 0, no waiters | idle | `stopTunnel(L)` |
| restarting(L) | `release(L)` to 0, waiters remain | retire | as above |
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

### Layer 1: the reducer

A breadth-first search over machine states, with a visited set. Inputs come in
two kinds.

- **Internal** inputs are pending completions, armed deadlines, and queued
  checks: `startFinished` success or failure per outstanding attempt,
  `restartFinished` true or false, `deadline` for each armed waiter or token,
  and a queued `unusedCheck`.
- **Environment** inputs are acquires from each origin, with the current token,
  a stale token, or none, stamped with the current or an older generation;
  `retain` and `release`; each `disconnect` kind; `reconnectAbandoned` with and
  without `movedTo`; `cancel` for each waiter; each verdict; and late events
  for ids that were current earlier in the path.

**Specs are modelled.** Every spec carries an epoch. The epoch advances when a
lease is retired or a reconnect re-probes. A `startTunnel` must use one of
rule 5's three sources, at its current epoch.

Bounds: one host key, 3 waiters, 3 attempts, 2 restarts, 2 tokens, two of
each disconnect kind, and a depth of 14. Some inputs are only meaningful
after an earlier event, so they must stay enabled after it:

- An acquire with a stale token, after a second `.reconnect` mints a new one.
  Otherwise the `reconnectSuperseded` row is never reached.
- An acquire stamped with an older generation, after a second plain
  disconnect.

**Every state is checked for:**

- the invariants above, including the park invariant;
- every waiter having an armed deadline;
- every outstanding attempt or restart having a pending completion;
- the pooled lease's references being consistent with resumes, retains, and
  releases;
- every acquire in the path being resolved at most once.

**Every quiescent state is checked for liveness.** A quiescent state is one
with no internal inputs pending, whatever the environment could still do. It
must have:

- no waiters, attempts, or restarts;
- `park` nil or `userDisconnected`;
- no pooled lease with zero references.

This replaces the third draft's "terminal state" check, which could never fire,
because environment inputs are always enabled.

### Layer 2: the shell

A model of the shell: pooled and shell-only references, the effect list, the
event queue, and re-entrant calls during effects. A re-entrant call can be
`retain`, `release`, `acquire`, or `disconnect`. Layer 2 explores where those
calls land relative to the effect list. It checks:

- that no `stopTunnel` reaches the *pooled* lease while its machine references
  are above zero, other than a retire or a disconnect. A stop on a retired
  lease with shell-only references is correct, because Disconnect Host
  preserves panes.
- that the queue drains;
- that a shell-only `release` never produces a machine event.

### Gate

PR A passes when both layers are green and mutating each of rules 1–8 makes at
least one layer fail.

The guarantee is "no violation within these bounds". Every defect found so far
needed at most two disconnects and six events. A failure prints the exact
event sequence.

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
| `test_registry_restartWaiterStartsFreshWhenTheLeaseWasOnlyReleased` | The last `release` with waiters still present now retires and starts a replacement with `L.spec`. |

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
