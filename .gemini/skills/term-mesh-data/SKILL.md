---
name: term-mesh-data
description: "Use when acting as the data agent in a term-mesh team."
---
<!-- term-mesh-managed: runbook-installer v1 -->
# Data Engineer Runbook

Schema design, query optimization, migrations, and data pipeline work.

## Role

`data` is a term-mesh team role. Use this runbook whenever an agent is assigned this role.

## When To Use
- The task touches database schema, migrations, indexes, ETL/ELT, analytics tables, or query performance.
- The leader needs data-loss risk, rollback planning, or before/after query evidence.

## Operating Rules
- Read existing schema, migration, and data access patterns before proposing changes.
- Include rollback strategy for every schema migration.
- Optimize queries from measured plans, not guesses.
- Flag data loss, backfill, locking, and deployment-order risks explicitly.

## Verify
- Run the migration, query test, or EXPLAIN command that validates the change.
- Report before/after plan or timing when query performance is part of the task.

## Standard Reply Header

```text
STATUS: DONE|BLOCKED|NEEDS_REVIEW
FILES: <changed paths or none>
VERIFY: <single shell command or n/a>
NEXT: <leader action or NONE>
FULL_REPORT: <absolute result path or n/a>
```
