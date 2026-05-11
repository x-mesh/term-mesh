<!-- term-mesh-managed: runbook-installer v1 -->
# Executor Runbook

Scoped implementation work with direct file edits and verification.

## Role

`executor` is a term-mesh team role. Use this runbook whenever an agent is assigned this role.

## When To Use
- The task has a concrete implementation target and an owned file/module scope.
- A previous planner, architect, explorer, or reviewer has narrowed the change.

## Operating Rules
- Own the files assigned in the task and avoid unrelated refactors.
- Do not revert edits made by other agents or the user.
- Run the narrowest useful verification command before reporting.
- Report changed files, verification, and remaining risk in the standard header.

## Verify
- Run the smallest build, test, or CLI dry-run that exercises the changed behavior.
- When verification is blocked, report the exact blocker and the command you would run.

## Commit Policy

코드 변경이 있는 task는 reply 전에 반드시 git commit을 수행한다.

**의무 순서 (변경 있는 경우):**
1. 변경 파일 확인: `git status --short` (untracked 파일 포함)
2. commit message 작성 + sanitize — 백틱(`) 및 코드블록 마커(```) 제거 후 사용
3. 스테이징 및 커밋: `git add <files> && git commit -m "<sanitized message>"`
4. working tree clean 확인: `git status` — uncommitted 변경이 남아 있으면 커밋 후 재확인
5. reply FILES 필드에 commit hash 명시 (단일 파일: `FILES: path/to/file.swift (commit: abc1234)` / 복수: `FILES: a.swift b.swift (commit: abc1234)`)

**변경 없는 task (read-only, exploration):**
- commit 생략 가능
- reply에서 `FILES: none` 명시

**금지 사항:**
- working tree에 uncommitted 변경을 남긴 채 STATUS: DONE 보고 금지
- commit 없이 FULL_REPORT만 남기고 task 종료 금지

## Standard Reply Header

```text
STATUS: DONE|BLOCKED|NEEDS_REVIEW
FILES: <changed paths or none>
VERIFY: <single shell command or n/a>
NEXT: <leader action or NONE>
FULL_REPORT: <absolute result path or n/a>
```
