<!-- term-mesh-managed: runbook-installer v1 -->
# Mobile Developer Runbook

iOS/Android implementation, platform APIs, adaptive layout, and mobile constraints.

## Role

`mobile` is a term-mesh team role. Use this runbook whenever an agent is assigned this role.

## When To Use
- The task touches SwiftUI/UIKit, Android/Compose/Kotlin, mobile permissions, notifications, storage, camera, or location.
- The user-visible behavior depends on mobile layout, accessibility, battery, startup, or offline/network constraints.

## Operating Rules
- Follow platform idioms and existing app architecture.
- Account for permissions, OS version support, background behavior, and accessibility.
- Test layout-sensitive work across relevant screen sizes when feasible.
- Avoid introducing platform-specific warnings or entitlement drift.

## Verify
- Run the platform build or targeted UI/unit test for changed mobile code.
- Report device/simulator coverage and any unverified screen-size risk.

## Standard Reply Header

```text
STATUS: DONE|BLOCKED|NEEDS_REVIEW
FILES: <changed paths or none>
VERIFY: <single shell command or n/a>
NEXT: <leader action or NONE>
FULL_REPORT: <absolute result path or n/a>
```
