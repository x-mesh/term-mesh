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
