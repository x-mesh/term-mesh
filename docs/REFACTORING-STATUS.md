# term-mesh Refactoring Status

> Last updated: 2026-03-11
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

## Phase 4: Singleton 참조 제거 — 완료 ✅

### 4-A. GhosttyApp.shared (53→17, −68% ✅)

| 작업 | 상태 | 참조 감소 |
|---|---|---|
| `GhosttyTheme` SwiftUI Environment 도입 | ✅ 완료 | `develop` 6c3f1cb |
| `logBackgroundIfEnabled` 편의 메서드 적용 (4파일) | ✅ 완료 | −8 refs |
| `GhosttyTheme.current` AppKit 뷰 적용 (4파일) | ✅ 완료 | −8 refs |
| `GhosttyConfigProviderKey` SwiftUI EnvironmentKey 도입 | ✅ 완료 | — |
| `TermMeshApp` 루트에서 `.environment(\.configProvider)` 주입 | ✅ 완료 | — |
| `ContentView` @Environment 적용 (5 refs) | ✅ 완료 | −5 refs |
| `WorkspaceContentView` @Environment 적용 (3/4 refs, 1 static) | ✅ 완료 | −3 refs |
| `TermMeshApp` configProvider 프로퍼티 적용 (3 refs) | ✅ 완료 | −3 refs |
| `Workspace` configProvider 프로퍼티 적용 (3 refs) | ✅ 완료 | −3 refs |
| `AppDelegate` configProvider 프로퍼티 적용 (1/2 refs, 1 C API) | ✅ 완료 | −1 ref |
| `GhosttyTerminalView` configProvider 프로퍼티 적용 (10/12 refs) | ✅ 완료 | −10 refs |

**남은 17개 참조 (모두 제거 불필요 또는 불가):**

| 파일 | 참조 수 | 용도 | 분류 |
|---|---|---|---|
| `GhosttyApp.swift` | 6 | 내부 self 참조 (`tick`, `handleAction`, `reloadConfiguration`, `applyBackground`) | ⚪ 자기 참조 |
| `GhosttyTerminalView.swift` | 3 | 1 프로퍼티 기본값 + 2 Ghostty C API (`app`, `config`) | ⚪ 기본값/C API |
| `GhosttyTheme.swift` | 2 | Theme resolve 지점 (필수) | ⚪ 유지 |
| `TermMeshApp.swift` | 2 | 1 프로퍼티 기본값 + 1 environment 주입점 | ⚪ 기본값/주입점 |
| `AppDelegate.swift` | 2 | 1 프로퍼티 기본값 + 1 Ghostty C API (`config`) | ⚪ 기본값/C API |
| `Workspace.swift` | 1 | 프로퍼티 기본값 | ⚪ 기본값 |
| `WorkspaceContentView.swift` | 1 | static 컨텍스트 (인스턴스 접근 불가) | ⚪ static |

### 4-B. TermMeshDaemon.shared (54→8, −85% ✅)

| 작업 | 상태 | 참조 감소 |
|---|---|---|
| `DaemonService` 프로토콜 확장 (전체 public API 커버) | ✅ 완료 | — |
| `DaemonServiceKey` SwiftUI EnvironmentKey 도입 | ✅ 완료 | — |
| `TermMeshApp` 루트에서 `.environment(\.daemonService)` 주입 | ✅ 완료 | — |
| `DashboardController` daemon 프로퍼티 주입 | ✅ 완료 | −2 refs |
| `ContentViewUtilities` daemon 생성자 주입 | ✅ 완료 | −3 refs |
| `TerminalPanel` daemon 프로퍼티 주입 | ✅ 완료 | −1 ref |
| `SettingsView` @Environment 적용 | ✅ 완료 | −5 refs |
| `TermMeshApp` 기존 `@ObservedObject` 활용 | ✅ 완료 | −4 refs |
| `AppDelegate` daemon 프로퍼티 주입 | ✅ 완료 | −5 refs |
| `TeamOrchestrator` daemon 프로퍼티 주입 | ✅ 완료 | −5 refs |
| `ContentView` @Environment 적용 | ✅ 완료 | −11 refs |
| `TabManager` daemon 프로퍼티 주입 | ✅ 완료 | −10 refs |

**남은 8개 참조:** 모두 프로퍼티 기본값 선언 또는 루트 주입점 (제거 불필요)

### 4-C. TerminalNotificationStore.shared (18→6, −67% ✅)

| 작업 | 상태 | 참조 감소 |
|---|---|---|
| `NotificationServiceKey` SwiftUI EnvironmentKey 도입 | ✅ 완료 | — |
| `TermMeshApp` 루트에서 `.environment(\.notificationService)` 주입 | ✅ 완료 | — |
| `DashboardController` notifications 프로퍼티 주입 | ✅ 완료 | −1 ref |
| `ContentView` 기존 `@EnvironmentObject` 활용 | ✅ 완료 | −1 ref |
| `TerminalController` notifications 프로퍼티 주입 | ✅ 완료 | −5 refs |
| `TerminalController+Debug` 확장에서 self.notifications 활용 | ✅ 완료 | −5 refs |
| `GhosttyApp` notifications 프로퍼티 주입 | ✅ 완료 | −2 refs |
| `AppDelegate` 기존 notificationStore 활용 | ✅ 완료 | 0 (fallback 유지) |
| `UpdateTitlebarAccessory` notificationStore 프로퍼티 주입 | ✅ 완료 | −1 ref |

**남은 6개 참조:** 모두 프로퍼티 기본값 선언 또는 루트 주입점

---

## Phase 5: ServiceContainer & BrowserHistory (완료 ✅)

### 5-A. BrowserHistoryStore.shared (15→6, −60% ✅)

| 작업 | 상태 | 참조 감소 |
|---|---|---|
| `BrowserHistoryService` 프로토콜 확장 (clearHistory, removeHistoryEntry, flushPendingSaves) | ✅ 완료 | — |
| `BrowserHistoryServiceKey` SwiftUI EnvironmentKey 도입 | ✅ 완료 | — |
| `SettingsView` @Environment 적용 | ✅ 완료 | −3 refs |
| `BrowserPanelView` @Environment 적용 | ✅ 완료 | −5 refs |
| `BrowserPanel` browserHistory 프로퍼티 주입 | ✅ 완료 | −2 refs |
| `ContentView` @Environment 적용 | ✅ 완료 | −1 ref |
| `TermMeshApp` browserHistory 프로퍼티 적용 | ✅ 완료 | −1 ref |
| `AppDelegate` browserHistory 프로퍼티 적용 | ✅ 완료 | −1 ref |

**남은 6개 참조:** 프로퍼티 기본값(4), 주입점(0), Combine `$entries`(2)

### 5-B. ServiceContainer 도입 (✅)

| 작업 | 상태 |
|---|---|
| `ServiceContainer.swift` 생성 — 모든 서비스 통합 관리 | ✅ 완료 |
| `View.withServices()` 확장 — 한 줄로 전체 서비스 주입 | ✅ 완료 |
| `TermMeshApp` body에서 `.withServices()` 적용 | ✅ 완료 |
| `AppDelegate.createMainWindow`에서 `.withServices()` 적용 | ✅ 완료 |

---

## Phase 6: 미래 로드맵

| 우선순위 | 작업 | 사이즈 | 설명 |
|---|---|---|---|
| P1 | `TabManager` 생성자 주입 | M | daemon + notifications + config를 init 시 주입 |
| P2 | `AppDelegate` 클로저 주입 | M | lifecycle 이벤트에서 싱글톤 대신 클로저 사용 |
| P3 | 단위 테스트 인프라 | L | 프로토콜 mock 생성, XCTest 타겟 구성 |

---

## 싱글톤 참조 추이

```
               시작    Phase3   Phase4   Phase5    잔여 분류
GhosttyApp       53      37       17       17*     6 자기참조 + 2 theme + 3 C API + 4 기본값 + 1 static + 1 주입점
TermMeshDaemon   54      54        8        8*     7 기본값 + 1 주입점
Notification     18      18        6        6*     4 기본값 + 2 fallback
BrowserHistory   15      15       15        6*     4 기본값 + 2 Combine $entries
──────────────────────────────────────────────────────
합계            140+    124+      46+      37*

* 남은 참조는 모두 프로퍼티 기본값/루트 주입점/자기참조/C API/Combine publisher
  (실질적 커플링 제거 완료)
```

## 커밋 이력

```
XXXXXXX refactor: Add ServiceContainer and replace BrowserHistoryStore.shared with protocol-based injection
XXXXXXX refactor: Replace GhosttyApp.shared with ConfigProvider-based injection (37→17)
XXXXXXX refactor: Replace TermMeshDaemon.shared and TerminalNotificationStore.shared with protocol-based injection
d26b261 refactor: Replace singleton theme/logging access with GhosttyTheme and logBackgroundIfEnabled
9fdaf7a refactor: Add protocol abstractions for DaemonService, ConfigProvider, NotificationService, BrowserHistoryService
6c3f1cb feat: Introduce GhosttyTheme SwiftUI Environment for theme injection
34af607 refactor: Extract CommandPalette types and convert remaining main.sync to async
```

## 빌드 검증

모든 커밋은 `xcodebuild -scheme term-mesh -configuration Debug` 빌드 성공 확인 후 커밋됨.
