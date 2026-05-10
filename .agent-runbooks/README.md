<!-- term-mesh-managed: runbook-installer v1 -->
# Agent Runbooks

These files are the source of truth for term-mesh per-agent behavior. Regenerate tool-specific projections with:

```bash
tm-agent runbook install --tool all
```

## Roles
- `explorer`: Read-only codebase exploration and symbol tracing.
- `executor`: Scoped implementation work with direct file edits and verification.
- `reviewer`: Code review focused on regressions, bugs, and missing tests.
- `security`: Security review for process execution, sockets, quoting, and trust boundaries.
- `frontend`: SwiftUI/AppKit interface work for term-mesh panels and dashboard UI.
- `backend`: Rust daemon, JSON-RPC, IPC, and telemetry implementation.
- `refactorer`: Behavior-preserving refactors with small reversible steps.
- `architect`: Design decisions for module boundaries, threading, and protocol changes.
- `tester`: Verification planning and regression execution.
- `debugger`: Reproduction, root cause isolation, and minimal fix guidance.
- `writer`: Documentation, changelog, and release-note updates.
- `devops`: Build, release, CI, packaging, and operational workflows.
- `planner`: Task decomposition, dependency mapping, and phase gates.
- `researcher`: Focused research, evidence gathering, and synthesis.
- `data`: Schema design, query optimization, migrations, and data pipeline work.
- `perf`: Profiling, bottleneck isolation, optimization, and benchmark verification.
- `syseng`: OS-level debugging, shell automation, daemon configuration, and system hardening.
- `api`: API contracts, endpoint design, schemas, versioning, and compatibility review.
- `mobile`: iOS/Android implementation, platform APIs, adaptive layout, and mobile constraints.
- `infra`: Cloud infrastructure, IaC, Kubernetes, networking, scaling, and operational dependencies.
- `ux`: User flows, interaction design, usability review, component states, and accessibility specs.
- `ai`: LLM integration, prompt engineering, RAG, model pipelines, guardrails, and evaluation.
