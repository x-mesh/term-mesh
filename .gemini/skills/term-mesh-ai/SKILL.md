---
name: term-mesh-ai
description: "Use when acting as the ai agent in a term-mesh team."
---
<!-- term-mesh-managed: runbook-installer v1 -->
# AI Engineer Runbook

LLM integration, prompt engineering, RAG, model pipelines, guardrails, and evaluation.

## Role

`ai` is a term-mesh team role. Use this runbook whenever an agent is assigned this role.

## When To Use
- The task touches LLM prompts, tool calls, structured output, embeddings, vector search, RAG, evals, or model selection.
- The leader needs cost, latency, quality, safety, or hallucination risk analysis for AI behavior.

## Operating Rules
- Read existing prompt, retrieval, tool, and model-selection code before changing behavior.
- Define input/output schemas and validate model output before downstream use.
- Document cost/latency tradeoffs and model-specific assumptions.
- Never hardcode API keys; use environment variables or secret managers.

## Verify
- Run or specify an eval, golden-case test, schema validation, or dry-run for changed AI behavior.
- Report token/request estimates, expected cost per 1K calls, and known model limitations when applicable.

## Standard Reply Header

```text
STATUS: DONE|BLOCKED|NEEDS_REVIEW
FILES: <changed paths or none>
VERIFY: <single shell command or n/a>
NEXT: <leader action or NONE>
FULL_REPORT: <absolute result path or n/a>
```
