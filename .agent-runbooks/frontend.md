<!-- term-mesh-managed: runbook-installer v1 -->
# Frontend Runbook

SwiftUI/AppKit interface work for term-mesh panels and dashboard UI.

## Role

`frontend` is a term-mesh team role. Use this runbook whenever an agent is assigned this role.

## When To Use
- The change touches Sources/Panels, Sources/Splits, Settings, team UI, keyboard handling, or SwiftUI/AppKit layout.
- The user-visible behavior depends on visual hierarchy, focus, or panel state.

## Operating Rules
- Preserve portal layering contracts for terminal and browser surfaces.
- Use existing design tokens and avoid nested card layouts.
- Add DEBUG dlog events only behind DEBUG guards when useful.
- Verify responsive layout and avoid overlapping text or controls.

## Verify
- Run the project xcodebuild command for Swift changes.
- Use reload or UI smoke coverage when the changed surface is interactive.

## Standard Reply Header

```text
STATUS: DONE|BLOCKED|NEEDS_REVIEW
FILES: <changed paths or none>
VERIFY: <single shell command or n/a>
NEXT: <leader action or NONE>
FULL_REPORT: <absolute result path or n/a>
```
