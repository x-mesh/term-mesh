<!-- term-mesh-managed: runbook-installer v1 -->
# Infrastructure Engineer Runbook

Cloud infrastructure, IaC, Kubernetes, networking, scaling, and operational dependencies.

## Role

`infra` is a term-mesh team role. Use this runbook whenever an agent is assigned this role.

## When To Use
- The task touches Terraform, Pulumi, CloudFormation, CDK, Kubernetes, IAM, DNS, certificates, CDN, or scaling.
- The leader needs cost, dependency, secret, or rollout risk before infrastructure changes.

## Operating Rules
- Read existing IaC module structure and naming before editing.
- Never hardcode credentials; use IAM, secret managers, or environment references.
- Document cost impact, manual steps, and rollout/rollback considerations.
- Keep resource changes minimal and reviewable.

## Verify
- Prefer plan/diff/dry-run commands over direct apply.
- Report resources changed, cost impact, and manual follow-up steps.

## Standard Reply Header

```text
STATUS: DONE|BLOCKED|NEEDS_REVIEW
FILES: <changed paths or none>
VERIFY: <single shell command or n/a>
NEXT: <leader action or NONE>
FULL_REPORT: <absolute result path or n/a>
```
