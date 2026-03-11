# term-mesh Refactoring Status

> Last updated: 2026-03-12
> Branch: `develop` (4 commits ahead of `main`)

---

## Phase 1: File Decomposition (완료 ✅)

대형 God Object 파일들을 기능 단위로 분할.

| 원본 파일 | 줄 수 변화 | 추출 파일 | 커밋 |
|---|---|---|---|
| `ContentView.swift` | 8820→3830 (−57%) | ContentViewModels, ContentViewUtilities, CommandPaletteTypes + 5개 | `main` |
| `AppDelegate.swift` | 5041→2959 (−41%) | AppDelegate+Shortcuts, AppDelegate+Notifications | `main` |
| `TabManager.swift` | 3828→1957 (−49%) | TabManager+Browser, TabManagerSettings | `main` |
| `TerminalController+Browser.swift` | 3210→1627 (−49%) | BrowserFind, BrowserData, BrowserScript | `main` |
| `Workspace.swift` | 3000→2036 (−32%) | WorkspaceModels, Workspace+BonsplitDelegate | `main` |
| `TerminalController+Debug.swift` | 2992→1891 (−37%) | DebugInput, DebugOverlay, DebugVisual | `main` |
| `GhosttyTerminalView.swift` | 분할 | GhosttyTerminalView+Search 등 | `main` |
| `TermMeshApp.swift` | 분할 | TermMeshApp+Menu 등 | `main` |

## Phase 2: Code Quality (완료 ✅)

| 작업 | 설명 | 커밋 |
|---|---|---|
| `print()` → `os.Logger` | 6개 파일에서 구조화된 로깅으로 전환 | `main` |
| `DispatchQueue.main.sync` → `.async` | 텔레메트리 핫패스 성능 개선 | `main` |
| CommandPalette 타입 추출 | 17개 private nested 타입을 top-level로 승격 | `develop` |

## Phase 3: Architecture — Protocol Abstractions (완료 ✅)

싱글톤 직접 참조를 대체할 프로토콜 인터페이스 도입.

| 프로토콜 | 파일 | 대상 concrete 타입 | 커밋 |
|---|---|---|---|
| `DaemonService` | `DaemonService.swift` | `TermMeshDaemon` | `develop` 9fdaf7a |
| `GhosttyConfigProvider` | `ConfigProvider.swift` | `GhosttyApp` | `develop` 9fdaf7a |
| `NotificationService` | `NotificationService.swift` | `TerminalNotificationStore` | `develop` 9fdaf7a |
| `BrowserHistoryService` | `BrowserHistoryService.swift` | `BrowserHistoryStore` | `develop` 9fdaf7a |

## Phase 4: Singleton 참조 제거 — 진행 중 🔄

### 4-A. GhosttyApp.shared (53→37, −30%)

| 작업 | 상태 | 참조 감소 |
|---|---|---|
| `GhosttyTheme` SwiftUI Environment 도입 | ✅ 완료 | `develop` 6c3f1cb |
| `logBackgroundIfEnabled` 편의 메서드 적용 (4파일) | ✅ 완료 | −8 refs |
| `GhosttyTheme.current` AppKit 뷰 적용 (4파일) | ✅ 완료 | −8 refs |

**남은 37개 참조:**

| 파일 | 참조 수 | 주요 접근 패턴 | 난이도 |
|---|---|---|---|
| `GhosttyTerminalView.swift` | 12 | `app`, `config`, `defaultBackgroundColor/Opacity`, `backgroundLogEnabled`, `markScrollActivity` | 🔴 높음 (AppKit, 깊은 의존) |
| `GhosttyApp.swift` | 6 | 내부 self 참조 (`tick`, `handleAction`, `reloadConfiguration`) | ⚪ 불필요 (자기 참조) |
| `ContentView.swift` | 5 | `backgroundLogEnabled`, `logBackground`, `defaultBackgroundColor/Opacity` | 🟡 중간 |
| `WorkspaceContentView.swift` | 4 | `backgroundLogEnabled`, `logBackground` | 🟡 중간 |
| `Workspace.swift` | 3 | `backgroundLogEnabled`, `logBackground`, `defaultBackgroundColor` | 🟢 낮음 |
| `TermMeshApp.swift` | 3 | `reloadConfiguration`, `openConfigurationInTextEdit` | 🟡 중간 |
| `AppDelegate.swift` | 2 | `config`, `reloadConfiguration` | 🟢 낮음 |
| `GhosttyTheme.swift` | 2 | `defaultBackgroundColor/Opacity` (필수 — theme resolve 지점) | ⚪ 유지 |

### 4-B. TermMeshDaemon.shared (54→54, 미착수 → 진행 중 🔄)

| 작업 | 상태 | 참조 감소 |
|---|---|---|
| `DaemonService` EnvironmentKey 추가 | 🔄 executor 작업 중 | — |
| `DashboardController` 생성자 주입 | 🔄 executor 작업 중 | −8 refs |
| `TerminalPanel` daemon 주입 | 🔄 executor 작업 중 | −1 ref |
| `ContentViewUtilities` daemon 주입 | 🔄 executor 작업 중 | −3 refs |
| `SettingsView` @Environment 적용 | 🔄 frontend 작업 중 | −5 refs |

**남은 작업 (미착수):**

| 파일 | 참조 수 | 주요 접근 패턴 | 난이도 |
|---|---|---|---|
| `ContentView.swift` | 11 | worktree CRUD, `isLocalhostOnly`, `dashboardPort`, `findGitRoot` | 🔴 높음 |
| `TabManager.swift` | 10 | `worktreeEnabled`, `createWorktree`, `findGitRoot`, `spawnAgents`, `bindAgentPanel` | 🔴 높음 |
| `TermMeshApp.swift` | 6 | `worktreeEnabled`, `ping`, `listAgents`, 메뉴 토글 | 🟡 중간 |
| `TeamOrchestrator.swift` | 5 | `worktreeEnabled`, `findGitRoot`, `createWorktreeWithError`, `syncTeams`, `removeWorktree` | 🟡 중간 |
| `AppDelegate.swift` | 5 | `startDaemon`, `stopDaemon`, `worktreeAutoCleanup`, `findGitRoot`, `cleanupStaleWorktrees` | 🟡 중간 |

### 4-C. TerminalNotificationStore.shared (33개, 미착수)

| 파일 | 참조 수 | 난이도 |
|---|---|---|
| `BrowserPanelView.swift` | 6 | 🟡 |
| `TerminalController.swift` | 5 | 🟡 |
| `TerminalController+Debug.swift` | 5 | 🟡 |
| `SettingsView.swift` | 4 | 🟡 |
| `AppDelegate.swift` | 3 | 🟢 |
| `ContentView.swift` | 2 | 🟢 |
| 기타 6개 파일 | 1-2씩 | 🟢 |

---

## Phase 5: 미래 로드맵

| 우선순위 | 작업 | 사이즈 | 설명 |
|---|---|---|---|
| P1 | Phase 4 싱글톤 제거 완료 | L | 위 남은 참조들 전부 주입 방식으로 전환 |
| P2 | `ServiceContainer` 도입 | XL | 모든 서비스를 한 곳에서 생성·주입하는 DI 컨테이너 |
| P2 | `TabManager` 생성자 주입 | M | daemon + notifications + config를 init 시 주입 |
| P2 | `AppDelegate` 클로저 주입 | M | lifecycle 이벤트에서 싱글톤 대신 클로저 사용 |
| P3 | 단위 테스트 인프라 | L | 프로토콜 mock 생성, XCTest 타겟 구성 |
| P3 | `GhosttyTerminalView` 의존성 정리 | XL | 가장 복잡한 뷰 — 점진적 인터페이스 분리 |

---

## 싱글톤 참조 추이

```
             시작     현재      목표
GhosttyApp     53      37       ~5 (Theme resolve + 자기참조)
TermMeshDaemon 54      54→37*   0
Notification   33      33       0
BrowserHistory  ?       ?       0
──────────────────────────────────
합계          140+     124+     ~5

* executor/frontend 작업 완료 시 예상치
```

## develop 브랜치 커밋 이력

```
d26b261 refactor: Replace singleton theme/logging access with GhosttyTheme and logBackgroundIfEnabled
9fdaf7a refactor: Add protocol abstractions for DaemonService, ConfigProvider, NotificationService, BrowserHistoryService
6c3f1cb feat: Introduce GhosttyTheme SwiftUI Environment for theme injection
34af607 refactor: Extract CommandPalette types and convert remaining main.sync to async
```

## 빌드 검증

모든 커밋은 `xcodebuild -scheme term-mesh -configuration Debug` 빌드 성공 확인 후 커밋됨.
