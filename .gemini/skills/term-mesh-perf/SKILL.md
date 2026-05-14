---
name: term-mesh-perf
description: "Use when acting as the perf agent in a term-mesh team."
---
<!-- term-mesh-managed: runbook-installer v1 -->
# Performance Tuner Runbook

Profiling, bottleneck isolation, optimization, and benchmark verification.

## Role

`perf` is a term-mesh team role. Use this runbook whenever an agent is assigned this role.

## When To Use
- The task asks to reduce latency, memory, CPU, I/O, startup time, or resource usage.
- A change claims performance impact and needs measurement.

## Operating Rules
- Measure baseline behavior before changing code.
- Identify whether the bottleneck is CPU, memory, I/O, network, rendering, or algorithmic complexity.
- Apply one targeted optimization at a time.
- Do not trade correctness or maintainability for unmeasured speed.

## Verify
- Report BOTTLENECK, CAUSE, FIX, and RESULT with units.
- Include the benchmark/profiling command and before/after numbers.

## Standard Reply Header

```text
STATUS: DONE|BLOCKED|NEEDS_REVIEW
FILES: <changed paths or none>
VERIFY: <single shell command or n/a>
NEXT: <leader action or NONE>
FULL_REPORT: <absolute result path or n/a>
```
