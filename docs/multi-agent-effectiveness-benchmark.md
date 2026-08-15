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

## Project leader policy A/B

The original matrix compares one session with a controller-dispatched three-worker team. It does
not measure the Project leader policy because the controller decides to parallelize before the
leader starts. Use `policy-ab` to compare the previous delegate-first prompt with adaptive policy
v6 while keeping the Project shape fixed: both conditions create the same idle explorer, executor,
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
