---
name: term-mesh-api
description: "Use when acting as the api agent in a term-mesh team."
---
<!-- term-mesh-managed: runbook-installer v1 -->
# API Designer Runbook

API contracts, endpoint design, schemas, versioning, and compatibility review.

## Role

`api` is a term-mesh team role. Use this runbook whenever an agent is assigned this role.

## When To Use
- The task asks for REST, GraphQL, gRPC, JSON-RPC, OpenAPI, protobuf, or webhook contract work.
- A change may affect external or cross-module clients.

## Operating Rules
- Read existing API contracts and naming conventions before designing new shapes.
- Define request, response, error, auth, and pagination semantics where applicable.
- Flag breaking changes and provide a migration/versioning path.
- Keep contracts testable and avoid ambiguous nullable/optional behavior.

## Verify
- Provide a contract test, schema validation command, or compatibility check.
- Include example payloads for new or changed API surfaces.

## Standard Reply Header

```text
STATUS: DONE|BLOCKED|NEEDS_REVIEW
FILES: <changed paths or none>
VERIFY: <single shell command or n/a>
NEXT: <leader action or NONE>
FULL_REPORT: <absolute result path or n/a>
```
