# Multi-agent effectiveness benchmark

`scripts/bench-agent.py` measures transport/RPC health. It cannot answer whether a team
finishes real development work faster. `scripts/bench-agent-effectiveness.py` compares one
Claude session with one Claude leader plus three persistent `tm-agent` workers until hidden
acceptance passes.

## Protocol

- Fixtures replay `8803af77^` (Homebrew smoke safety), `9b7745b1^` (GhosttyKit stale
  artifact guard), and `4e954beb^` (split divider color). Each is exported into a standalone
  one-commit repository, so the agent cannot resolve the solution commit or read its patch.
- The conditions share model, effort, prompt, host, prepared dependencies, and a 45-minute
  end-to-end timeout. Fixture setup is outside the timer; team creation, leader planning,
  dispatch, integration, acceptance, and correction are inside it.
- Each fixture gets three paired trials. Trial 1 runs single→multi, trial 2 multi→single, and
  later trials use a seeded order. Conditions never run concurrently.
- A failed hidden check is returned to the same persisted leader session. The timer stops only
  at the first pass or timeout. Hidden oracle files are overlaid only while testing and restored
  before the candidate patch is saved.
- Agent processes run with a controller-owned Git template whose `pre-push` hook rejects every
  non-local remote. Release-script tests may push only to a local path or `file://` bare repository;
  benchmark candidates must never mutate GitHub or another external service.
- A non-blocking lock under the results directory permits only one paid effectiveness matrix at a
  time. A duplicated or resumed controller turn fails before creating agents or making model calls.
- Divider acceptance runs targeted Swift tests and a Debug build on `mac-sub` by default. Use
  `--xcode-host local` only on a dedicated equivalent runner.

## Commands

First prove that every baseline fails, every solution passes, and solution history is hidden:

```bash
python3 scripts/bench-agent-effectiveness.py validate-suite
```

When the dedicated Xcode runner is temporarily unavailable, validate the non-Xcode fixtures
without weakening their acceptance checks:

```bash
python3 scripts/bench-agent-effectiveness.py validate-suite \
  --fixtures homebrew-smoke,ghostty-kit-guard
```

Inspect the standard 18-run matrix without paid model calls:

```bash
python3 scripts/bench-agent-effectiveness.py run --suite real-regressions \
  --workers 3 --trials 3 --seed 20260814 --dry-run
```

Run it, then generate the blinded three-judge quality comparison and final report:

```bash
python3 scripts/bench-agent-effectiveness.py run --suite real-regressions \
  --workers 3 --trials 3 --seed 20260814
python3 scripts/bench-agent-effectiveness.py report \
  ~/.term-mesh/benchmarks/effectiveness/<run-id> --evaluate
```

The runner automatically executes the existing transport check immediately before and after the
paid matrix to detect a daemon or RPC performance shift. The outputs are environment diagnostics
in `rpc-probes.json` and `rpc-*.log`; they are not combined with the effectiveness score. Use
`--skip-rpc-probe` only when the app transport is intentionally unavailable. The equivalent manual
commands are:

```bash
python3 scripts/bench-agent.py --rpc-only --mode pane --leader terminal --note "effectiveness preflight"
python3 scripts/bench-agent.py --rpc-only --mode pane --leader terminal --note "effectiveness postflight"
```

Artifacts live under `~/.term-mesh/benchmarks/effectiveness/<run-id>/`: immutable manifest,
per-run result/trace/log/patch files, `quality-eval.json`, `summary.json`, and `report.md`.
Trace JSONL contains metadata only. Judge inputs randomize A/B order; at least two ready vendors
enable cross-vendor evaluation, otherwise the report records the single-vendor fallback.

## Leader and worker overlap study

Use the orchestration study to compare three conditions.

- `single` runs one leader without workers.
- `blocking` waits for all workers before the leader starts.
- `overlap` runs a read-only leader lane while workers run.

Inspect the 27-run matrix before any model call:

```bash
python3 scripts/bench-agent-effectiveness.py orchestration-study \
  --fixtures homebrew-smoke,ghostty-kit-guard,split-divider-color \
  --trials 3 --seed 20260814 --dry-run
```

Run the study only after you approve the provider cost:

```bash
python3 scripts/bench-agent-effectiveness.py orchestration-study \
  --fixtures homebrew-smoke,ghostty-kit-guard,split-divider-color \
  --trials 3 --seed 20260814
```

After the matrix passes, run the blinded quality evaluation:

```bash
python3 scripts/bench-agent-effectiveness.py report \
  ~/.term-mesh/benchmarks/effectiveness/orchestration-study/<run-id> --evaluate
```

The overlap lane reads a separate history-free snapshot. It cannot use mutation-capable tools.
The controller checks that snapshot before and after each overlap turn.
The run fails if an overlap turn changes the snapshot.

The report compares `single` with `overlap`. It also compares `blocking` with `overlap`.
It records first-result time, last-result time, pure wait time, overlap time, and the critical path.

The controller extracts structured `Read`, `Grep`, and `Glob` paths from Claude worker transcripts.
It stores repository-relative paths and aggregate overlap values. It drops external paths and command bodies.
If transcript coverage is incomplete, the report marks read overlap as unknown.

Do not change the leader policy from latency results alone. Require the full matrix first.
Require no pass-rate loss and a paired median speedup of at least 1.20x.
Run a separate blinded quality evaluation before policy promotion.

## Worker task partition study

Use this study when the orchestration study finds high code-read overlap.
The study keeps three workers and the blocking lifecycle in both conditions.
It changes only the worker task capsules.

- `broad` uses the existing role prompts and broad repository read scope.
- `partitioned` assigns disjoint exact paths to contract, implementation, and acceptance roles.

Inspect the six-run paired matrix first:

```bash
python3 scripts/bench-agent-effectiveness.py partition-study \
  --fixtures split-divider-color --trials 3 --seed 20260814 --dry-run
```

Run the study only after you approve the provider cost:

```bash
python3 scripts/bench-agent-effectiveness.py partition-study \
  --fixtures split-divider-color --trials 3 --seed 20260814
```

Compare wall time, acceptance pass rate, worker critical path, integration time, and read-set Jaccard.
Do not compare results from different commits or mix blocking and overlap lifecycles.

## Isolated Project topology study

This study matches the Project topology. The leader owns the integration checkout.
Each worker runs in a separate detached Git worktree. Leader and worker write scopes do not overlap.
The conditions differ only in whether the leader implements its production slice before or after worker completion.

```bash
python3 scripts/bench-agent-effectiveness.py isolated-topology-study \
  --fixtures split-divider-color --trials 3 --seed 20260814 --dry-run
```

Run the paid six-cell study only after the dry run and fixture validation pass.

### Validity gates

Use explicit canonical app and daemon sockets. Reject inherited socket aliases.
Before dispatch, verify each worker directory in live daemon state and persisted agent metadata.
Require three distinct worker directories and one separate leader integration checkout.
Apply worker patches to the leader checkout in task order.

The controller runs one fixed focused validation command after leader integration.
The remote runner verifies the parent Ghostty pin and submodule HEAD before Xcode starts.
Product acceptance requires six hidden behavior tests and the full Debug build.
Incomplete read and runtime telemetry remains optional evidence. It does not change product or pair validity.

### Clean-disk Opus leader results

The study used commit `ce0ddc42ef552b3a8082da3d25e0440e938c7b7c`.
It used one Opus leader and three Sonnet workers on the `split-divider-color` fixture.
The two pairs used opposite orders. The local disk had at least 183 GiB free before each cell.

| Order | Blocking wall | Overlap wall | Speedup | Blocking cost | Overlap cost | Acceptance |
|---|---:|---:|---:|---:|---:|---|
| Blocking → overlap | 824.941 s | 459.384 s | 1.796x | $12.376824 | $8.250547 | Both passed |
| Overlap → blocking | 667.740 s | 452.924 s | 1.474x | $8.731640 | $8.718598 | Both passed |

The paired median speedup was 1.635x. The geometric mean was 1.627x.
Both orders exceeded the 1.20x latency gate. All four cells passed acceptance.
No cell used a correction. Every cell preserved isolated worker ownership and serial integration.
Overlap reduced measured wall time by 32.17% in reverse order and 44.31% in forward order.

Evidence is stored in these experiment directories:

- `~/.term-mesh/benchmarks/effectiveness/isolated-topology-study/pr546-opus-sonnet-disk-normal-reverse-overlap-ce0ddc42`
- `~/.term-mesh/benchmarks/effectiveness/isolated-topology-study/pr546-opus-sonnet-disk-normal-reverse-blocking-ce0ddc42`
- `~/.term-mesh/benchmarks/effectiveness/isolated-topology-study/pr546-opus-sonnet-clean-forward-blocking-ce0ddc42`
- `~/.term-mesh/benchmarks/effectiveness/isolated-topology-study/pr546-opus-sonnet-clean-forward-overlap-ce0ddc42`

The result is strong evidence of an overlap benefit for this fixture and model topology.
It does not prove a global routing policy. Provider queue and TTFT values were unavailable.
The worker critical path also varied between cells. Do not attribute all saved time to measured leader overlap.

### Excluded runs

| Run class | Failure | Treatment |
|---|---|---|
| Low-disk blocking → overlap | The local disk had about 3.7 GiB free and reached 100% use. The measured speedup was 0.851x. | Keep as a resource-censored reference. Do not pool it with clean-disk pairs. |
| Missing Ghostty pins | Xcode first-launch and license state caused Git and Xcode to return exit 69. The pin fields appeared missing. | Mark infra-invalid. Exclude latency and quality. |
| Socket alias topology | Inherited socket aliases selected the wrong daemon. Workers wrote in the leader checkout. | Mark infra-invalid. Exclude the pair. |
| Daemon prerequisite | The canonical daemon was unavailable before provider work. | Mark infra-invalid. Exclude the run. |
| Candidate compile or acceptance failure | Candidate code failed a product gate. | Count against pass rate. Exclude paired latency. |

`parent ghostty pin: missing` and `submodule HEAD: missing` were infrastructure symptoms.
They were not candidate or model failures. Black-box portal acceptance replaced the earlier private-helper-coupled fixture.

### Promotion status and next gate

Keep Leader Adaptive Execution Policy version 13 unchanged. Do not enable overlap globally yet.
Run one final clean-disk trial 3 in blocking → overlap order. Keep the same commit, fixture, models, host, and acceptance.
This trial closes the predefined three-trial gate without adding a new fixture implementation variable.

If trial 3 passes, permit only an explicit opt-in canary with all of these conditions:

- Use isolated worker worktrees and one leader integration checkout.
- Require at least two dependency-ready, ownership-disjoint mutation slices.
- Give the leader a separate owned production slice.
- Require zero write ownership overlap and serial patch integration.
- Pass disk, socket, daemon, Git, Xcode, focused validation, and product acceptance gates.
- Fall back to the version 13 route for every other task.

Require trial 3 to preserve pass rate, correction rate, and a three-pair median speedup of at least 1.20x.
Require another fixture and blinded quality evaluation before overlap becomes a global default.

## Project leader policy A/B

The original matrix compares one session with a controller-dispatched three-worker team. It does
not measure the Project leader policy because the controller decides to parallelize before the
leader starts. Use `policy-ab` to compare the previous delegate-first prompt with the team-aware
policy v10 while keeping the Project shape fixed: both conditions create the same idle explorer, executor,
and reviewer pool, and only the leader instruction changes. The leader first records a blinded
structured `direct`, `probe`, or `parallel` routing decision. `direct` dispatches no worker, `probe`
dispatches exactly one read-only 60-90 second task, and `parallel` dispatches the decision's two or
three dependency-ready tasks. Each task names its worker, goal, owned/forbidden scope, dependencies,
verification, mutation flag, and estimate. The controller delivers only those tasks and resumes the
same leader session with result envelopes. This avoids treating the
headless benchmark daemon as an app-visible Project board while still measuring policy choice.

Inspect the 18-run, counterbalanced matrix without model calls:

```bash
python3 scripts/bench-agent-effectiveness.py policy-ab \
  --fixtures homebrew-smoke,ghostty-kit-guard,split-divider-color \
  --trials 3 --seed 20260814 --dry-run
```

Run a cheap smoke pair first, then the complete matrix:

```bash
python3 scripts/bench-agent-effectiveness.py policy-ab \
  --fixtures homebrew-smoke --trials 1 --timeout 1200

python3 scripts/bench-agent-effectiveness.py policy-ab \
  --trials 3 --seed 20260814
```

Results are written below `~/.term-mesh/benchmarks/effectiveness/policy-ab/`. In addition to hidden
acceptance, wall time, tokens, corrections, and timeout censoring, the report records routing
decision time, selected task schema, delegation rate, worker task count, and controller
dispatch/collect waves. Team
creation is included in both conditions' end-to-end time. A timeout remains censored and is never
substituted as a completion time.

## Decision rule

Timeouts and failed acceptance reduce pass rate and do not enter successful latency medians.
Infra-invalid runs are retained but excluded. The report shows paired `single_ms / multi_ms`
speedup, median/IQR, paired bootstrap 95% CI, token amplification, pass rate, correction count,
and cost only when the provider reports the complete condition cost. By default an infra-invalid
slot is retried once with the same fixture, condition, and trial; both the invalid attempt and retry
remain in the ledger.

Multi becomes the global default only when its pass rate is no lower, paired median speedup is
at least 1.20x, and blinded quality has no regression. Otherwise routing stays single by default;
an individual fixture class may route multi at 1.15x with the same pass/quality gate. Cost is
reported but is not an adoption gate.

A fixture where neither condition completes has no comparative latency evidence and routes as
`insufficient_evidence`, not `single`. A timeout is a right-censored observation: it may count against an
explicit 45-minute completion SLA, but it must never be treated as a measured completion time or
as evidence that the other condition is faster when that condition also timed out. Paired token
amplification and cost ratio likewise use only pairs where both conditions completed; timeout
spend remains visible in the per-condition failure ledger.
