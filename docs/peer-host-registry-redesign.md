# Peer host registry redesign: one state machine per host

Status: proposal, revised after an advisor pass. Contract:
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
2. **The shell commits `state'` before it runs any effect, and queues events.**
   An effect can call back into the registry synchronously.
   `fireDidReplace` → `resumePanesAfterHostReconnect` → `retarget` → `retain`
   is one such chain. An event that arrives that way is queued and reduced only
   after the current effect list has finished. It is never reduced in the
   middle of that list. Without this rule the reducer is correct and the shell
   reintroduces the interleaving bug.
3. **A tunnel is only ever started with a spec that is current by
   construction.** That is either the spec of a user's own acquire, or the
   `spec` of the pooled lease being retired. A waiter whose lease vanished
   never contributes a spec.

If a decision ends up on the caller side of an `await`, or the shell reduces
an event while effects are still running, the old bug class is back. Review
should treat either as a blocking defect.

## The machine (per host key)

### State

```
HostState
  phase:
    idle
    starting(attempt: AttemptID, spec: Spec, waiters: [Waiter])
    up(lease: LeaseID, spec: Spec)
    restarting(lease: LeaseID, spec: Spec, waiters: [Waiter])
    awaitingReplacement(token: Token, waiters: [Waiter])
  disconnectGeneration: UInt64
  announceOnNextPool: Bool          // the old replacingKeys
```

Reference counts stay on `PeerPaneHostLease` and are not machine state.
Panes keep references on leases that have already left the pool; Disconnect
Host preserves them. The shell decrements the count and sends
`lastReleased(lease)` only when the *pooled* lease reaches zero. I2 stays a
checked invariant, as before.

### Waiter origins

| Origin | Who | May start a tunnel |
| --- | --- | --- |
| `user` | sidebar Connect, a Peer-menu pane, banner Reconnect, a team spawn: any acquire made fresh with a spec | Yes, with its own spec |
| `sweep` | the wake sweep, judging a pooled lease | Only to replace the lease it retires, with that lease's `spec` |
| `waiter` | a caller whose awaited lease vanished (the old restart waiter) | Never |

### Events

| Event | Sent by |
| --- | --- |
| `acquire(waiter, origin, spec?, verdict)` | `acquire(_:)`. The shell takes the liveness verdict synchronously (tunnel state plus a `connect(2)` probe) and passes it in, so the reducer stays pure. `spec` is present only for `user`. |
| `lastReleased(lease)` | the shell, when the pooled lease's reference count reaches zero |
| `startFinished(attempt, .lease(id) / .failure)` | the shell's start task |
| `restartFinished(lease, cameBack)` | `PeerPaneTransportRecovery` on the lease (decision 2) |
| `disconnect(.plain / .force / .reconnect(token))` | `RemoteHostStore` |
| `replacementAbandoned(token)` | `RemoteHostStore`, when its connect fails or lands under another key |
| `cancel(waiter)` | sidebar Cancel, task cancellation |
| `deadline(waiter)` | a deadline armed for a `waiter` or `sweep` |

`tunnelStateChanged` is not an input in this round. If the lease coordinates
restarts and the machine also reacts to tunnel state, "is this host
restarting" has two writers, which is the pattern rule 1 forbids. The only
inputs about restarts are the verdict passed with `acquire` and
`restartFinished`.

### Effects

`startTunnel(attempt, spec)`, `cancelStart(attempt)`, `stopTunnel(lease)`,
`resume(waiter, .lease(id) / .error(e))`, `fireWillRetire`,
`fireDidReplace(lease)`, `armDeadline(waiter, seconds)`, `waitRestart(lease)`.

Deadlines are armed only for `waiter` and `sweep` origins, while
`restarting` and `awaitingReplacement`. A `user` waiter in `starting` gets no
deadline: `connectSavedHost` already has `timeoutConnectingHost`. A registry
deadline there would cancel the attempt once its last waiter left, which
amounts to a Cancel nobody asked for.

### Transitions

Retiring a dead lease L:

- Emit `fireWillRetire`, then `stopTunnel(L)`, and set `announceOnNextPool`.
- If any current waiter has origin `user`, or the trigger is a `sweep`, start
  a replacement with that waiter's spec, or with `L.spec` for a sweep. The
  phase becomes `starting`.
- Otherwise, resume every waiter with `replacementDied`. The phase becomes
  `idle`.

| From | Event | To | Effects |
| --- | --- | --- | --- |
| idle | `acquire(user, spec)` | starting(new, spec, [w]) | `startTunnel` |
| idle | `acquire(sweep / waiter)` | idle | `resume(w, .error(replacementUnavailable))` |
| starting(a) | `acquire(any)` | starting(a, +w) | `armDeadline` (not for `user`) |
| starting(a) | `startFinished(a, .lease(L))` | up(L, spec) | `resume(each w, L)`; `fireDidReplace(L)` if `announceOnNextPool` |
| starting(a) | `startFinished(a, .failure)` | idle | `resume(each w, .error)` |
| any | `startFinished(stale a, .lease(L))` | unchanged | `stopTunnel(L)` |
| up(L) | `acquire(any, usable)` | up(L) | `resume(w, L)` |
| up(L) | `acquire(any, restarting)` | restarting(L, [w]) | `waitRestart(L)`; `armDeadline` (not for `user`) |
| up(L) | `acquire(any, dead)` | retire L (above) | as above |
| up(L) | `lastReleased(L)` | idle | `stopTunnel(L)` |
| restarting(L) | `acquire(any)` | restarting(L, +w) | `armDeadline` (not for `user`) |
| restarting(L) | `restartFinished(L, true)` | up(L) | `resume(each w, L)` |
| restarting(L) | `restartFinished(L, false)` | retire L (above) | as above |
| restarting(L) | `lastReleased(L)` | retire L, but without the sweep rule: start only for a `user` waiter | `stopTunnel(L)` and the rest as above |
| any | `disconnect(.plain / .force)` | idle, generation + 1 | `cancelStart`, `stopTunnel`, `resume(every w, .error(hostDisconnected))`; `announceOnNextPool` if a lease was up |
| any | `disconnect(.reconnect(t))` | awaitingReplacement(t, waiters) | `cancelStart`, `stopTunnel`; waiters keep their deadlines; `announceOnNextPool` if a lease was up |
| awaitingReplacement(t) | `acquire(user, spec)` | starting(new, spec, waiters + w) | `startTunnel` |
| awaitingReplacement(t) | `acquire(sweep / waiter)` | awaitingReplacement(t, +w) | `armDeadline` |
| awaitingReplacement(t) | `replacementAbandoned(t)` | idle | `resume(each w, .error(replacementUnavailable))` |
| awaitingReplacement(t) | the last waiter leaves | idle | keep `announceOnNextPool` |
| any | `cancel(w)` | w removed; `cancelStart` if it was the attempt's last waiter | `resume(w, .error(cancelled))` |
| any | `deadline(w)` | w removed | `resume(w, .error(replacementUnavailable))` |

## How the invariants become structural

| Invariant | Why it now holds by construction |
| --- | --- |
| I1, one lease and no orphan | Only `startFinished` for the current attempt pools a lease. Any other lease the shell reports is stopped in the same transition. |
| I3, I3-F, disconnect is final | `disconnect` resolves every waiter and bumps the generation in one transition. A later `startFinished` carries a stale attempt and can only produce `stopTunnel`. |
| I4, a fresh acquire after a disconnect | After a disconnect the phase is `idle`, so there is nothing left to join. |
| I5, no stale-spec start | Rule 3. `startTunnel` takes only a `user` acquire's own spec or a retired lease's `spec`. A `waiter` carries none. |
| I6, termination | Every non-`user` waiter has an armed deadline. Every `user` waiter is resolved by its attempt, a disconnect, or its own Cancel or timeout. |
| I7, announced exactly once | `fireDidReplace` is emitted only on the transition that pools, once per `announceOnNextPool`. |
| I8, dead is not left pooled | A dead verdict, or a restart that failed, leaves `up` in the same transition. |
| Post-wake recovery | A `sweep` that finds its lease dead starts the replacement with `L.spec`, and `fireDidReplace` reattaches the parked panes. That is the #673 behaviour, kept. |
| Cancel stops what it can | `cancel(w)` cancels the attempt when its last waiter leaves. This also fixes the Low from #675 where Cancel did not stop anything. |

These stay checked rather than structural:

- I2 (reference counts): the callers still call `release`.
- I9 and I10 (pane-side parking and refusal).
- The cross-key seam, resolved by `replacementAbandoned` (decision 1).

## Exhaustive check

The reducer is pure, so a test enumerates every order of events instead of
sampling a few:

- A breadth-first search over `(state, set of enabled completions)`, with a
  visited set.
- The enabled completions are what the shell could report next:
  `startFinished` succeeding or failing, `restartFinished` true or false, any
  armed deadline, and `lastReleased`.
- Bounds: one host key, at most 3 waiters across the three origins,
  2 attempts, one disconnect of each kind, the three verdicts, and a depth of
  about 10 events.
- Invariants are checked in every state. Terminal states (nothing enabled)
  must also have:
  - no unresolved waiter,
  - no outstanding attempt,
  - no lease that is neither pooled nor stopped, and
  - no **parked-forever state**: `announceOnNextPool` set with no attempt
    outstanding and no `user` or `sweep` path left that could start one.

  The last check names the regression an earlier draft of this design had,
  where the wake sweep retired a dead lease and nobody started its
  replacement.

The guarantee is "no violation within these bounds". Every defect found in
this session needed 4–6 events. The search is deterministic, so a failure
prints the exact event sequence that reproduces it.

The existing random simulation stays, aimed at the shell. It covers what the
reducer cannot, namely real `await` scheduling and rule 2's event queue.

## Migration

The external API is kept, so the 34 call sites in 7 files do not change.

| PR | Content | Gate |
| --- | --- | --- |
| A | `PeerHostMachine` (state, events, effects, reducer) and the exhaustive explorer. Nothing wired yet. | Explorer green; mutating each structural rule makes it fail. |
| B | `PeerPaneHostRegistry` rewritten as the shell: rule 2's commit-then-effects and the event queue. The `ForTests` seams keep their meaning. | The acceptance suite below, green. A tagged-app pass on jwserver68 covering Reconnect Host, Disconnect then Connect, and Force Disconnect. A unit test driving `recoverPeerTransportsAfterWake` with `livenessOverrideForTests`, because the wake path cannot be reproduced live. Full Debug build. |
| C | Old code paths deleted; the invariants doc updated to cite the machine. | Same suite. |

### Acceptance suite for PR B

Most registry tests run unchanged. These encode old behavior and are rewritten
in PR B, each for the reason given:

| Test | Reason |
| --- | --- |
| `test_cancelPendingAcquire_refusesWhileAnotherPaneIsWaiting` | Cancel becomes per waiter. It removes that caller and cancels the attempt only when it was the last. |
| The `waitForRestart*` tests | A restart wait becomes the `restarting` phase with `restartFinished`. The tests assert outcomes instead of call order. |
| `test_registry_restartWaiterJoinsTheReconnectHostReplacementWithoutStartingOne` and `...GivesUpWhenNoReplacementStarts` | Joining the replacement becomes `awaitingReplacement`. The outcomes are the same; the timing knobs move. |

Every other registry test, the relay park and retarget tests, and the
simulation run unchanged. Socket E2E for any release goes through the
`mac-sub` runner.

## Decisions

Reviewed with the advisor; all three recommendations stand.

1. **Reconnect Host keeps the socket re-probe in `RemoteHostStore`.** The
   re-probe is the only repair for a moved auto-detected socket, and a per-key
   machine cannot see across keys. The seam is `awaitingReplacement(token)`
   together with `replacementAbandoned(token)`.
2. **Restart coordination stays in `PeerPaneTransportRecovery` this round.**
   It reports outcomes through `restartFinished`. `tunnelStateChanged` is left
   out until a later round moves coordination into the machine, so that
   "restarting" never has two writers.
3. **Hard cutover in PR B.** A flag would keep the old registry's bugs live and
   double what has to be tested. The gate is the acceptance suite above.
