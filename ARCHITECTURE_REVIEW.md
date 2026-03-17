# term-mesh 아키텍처 코드 리뷰 보고서
**리뷰 대상:** Sources/ 디렉토리 & tests/
**리뷰 날짜:** 2026-03-09
**리뷰어:** reviewer (Code Review Agent)

---

## 요약

term-mesh 프로젝트는 **macOS GPU-가속 멀티에이전트 제어 플레인**으로, 다음과 같은 핵심 특성을 가지고 있습니다:

- ✅ **멀티 CLI 통합:** Claude, Kiro, Codex, Gemini 4가지 AI 코딩 에이전트 지원
- ✅ **워크트리 격리:** 각 에이전트가 독립적 git 브랜치에서 작업
- ✅ **양방향 통신:** 팀 메시지 큐, 파일 기반 결과, 태스크 보드
- ⚠️ **높은 복잡도:** TerminalController 12,459줄, 8개 extension으로 분산
- ⚠️ **Protocol 부재:** Concrete extension에 로직 밀집, 테스트 불용이

---

## 1. 아키텍처 주요 구성 분석

### 1.1 TeamOrchestrator.swift (919줄)

**역할:** 멀티에이전트 팀의 생명주기 및 통신 관리

**핵심 구조:**
```swift
class TeamOrchestrator {
  struct Team                      // 팀 정보 (에이전트 N개 + leader)
  struct AgentMember              // 개별 에이전트 (이름, CLI, 모델, worktree)
  struct TeamMessage              // 메시지 큐 (agent → leader)
  struct TeamTask                 // 공유 태스크 보드

  // 4가지 CLI 지원
  func agentBinaryPath(cli: String) -> String?
  func buildClaudeCommand(...) -> String
  func buildKiroCommand(...) -> String
  func buildCodexCommand(...) -> String
  func buildGeminiCommand(...) -> String

  // 팀 생명주기
  func createTeam(...) -> Team?
  func destroyTeam(...) -> Bool
  func cleanupWorktrees(...)

  // 양방향 통신 (A, B, C, D)
  func sendToAgent(...) -> Bool
  func broadcast(...) -> Int
  func writeResult(...) -> Bool      // B: 파일 기반 결과
  func postMessage(...) -> TeamMessage?   // C: 메시지 큐
  func createTask(...) -> TeamTask?  // D: 태스크 보드
}
```

**강점:**
- ✅ CLI 선택 로직 명확 (switch/case로 바이너리 경로 해결)
- ✅ 모델명 매핑 함수들 (kiroModelName, codexModelName, geminiModelName)
- ✅ 워크트리 격리 구현 (에이전트별 독립 브랜치)
- ✅ 환경변수 관리 체계적 (PATH, CMUX_TEAM, CLAUDECODE 분리)

**약점:**
- ⚠️ **과도한 책임**: 팀 생성 + 통신 + 결과 수집 + 파일 I/O 모두 담당
- ⚠️ **Nested closure 남발**: createTeam에 300줄+ 중첩 블록
- ⚠️ **에러 처리 미흡**: 워크트리 생성 실패 시 fallback만 함 (로깅 부족)
- ⚠️ **모델명 하드코딩**: 상수로 추출하지 않음
  ```swift
  case "opus":   return "claude-opus-4.6"  // 반복됨
  ```

**개선 안:**
```swift
// 1. 모델 매핑을 Enum으로 리팩토링
enum ModelMapping {
  static let claude = ["opus": "claude-opus-4.6", ...]
  static let kiro = ["opus": "claude-opus-4.6", ...]
}

// 2. CLI 커맨드 빌더를 Protocol로 추상화
protocol CLICommandBuilder {
  func build(...) -> String
}
struct ClaudeCommandBuilder: CLICommandBuilder { ... }
struct KiroCommandBuilder: CLICommandBuilder { ... }

// 3. 팀 생성 로직을 Builder 패턴으로 분리
struct TeamBuilder {
  func buildLeaderPane(...) -> PanelId?
  func buildAgentPanes(...) -> [AgentMember]
  func buildEnvironment(...) -> [String: String]
}
```

---

### 1.2 AgentRolePreset.swift (427줄)

**역할:** 에이전트 역할 프리셋 및 팀 템플릿 관리

**핵심 구조:**
```swift
struct AgentRolePreset: Identifiable, Codable {
  var id: UUID
  var name: String          // "explorer", "executor", "reviewer"
  var cli: String           // "claude", "kiro", "codex", "gemini"
  var model: String         // "sonnet", "opus", "haiku"
  var color: String
  var instructions: String  // 시스템 프롬프트
}

class AgentRolePresetManager: ObservableObject {
  static let builtInPresets: [AgentRolePreset] = [
    // 18개 역할: explorer, architect, planner, executor, ...
  ]
  func save()
  func load()
  func add/update/delete/resetBuiltIns()
}

struct TeamTemplate: Identifiable, Codable {
  var agents: [AgentSlot]
  // 팀 구성을 저장/로드
}
```

**강점:**
- ✅ **18개 내장 역할** 포괄적 정의 (Discovery, Implementation, QA, DevOps, etc.)
- ✅ **시스템 프롬프트 명확**: 각 역할의 책임이 문장 형태로 명시
- ✅ **확장성**: 사용자 정의 프리셋 추가 가능 (isBuiltIn 플래그)
- ✅ **JSON 저장/로드**: ApplicationSupport에 자동 저장

**약점:**
- ⚠️ **문자열 기반 모델명**: 유효성 검사 없음 (잘못된 모델명 가능)
- ⚠️ **색상 하드코딩**: 6가지 색상 배열로 순환하는 구조
  ```swift
  let colors = ["green", "blue", "yellow", "magenta", "cyan", "red"]
  ```
- ⚠️ **중복된 role 이름**: "executor"와 "executor" (name vs agentType 혼동)
- ⚠️ **버전 관리 없음**: built-in 프리셋 업데이트 시 머지 로직만 있음

**개선 안:**
```swift
// 1. 모델과 색상을 Enum으로 관리
enum AgentModel: String, CaseIterable {
  case sonnet = "sonnet"
  case opus = "opus"
  case haiku = "haiku"
}

enum AgentColor: String, CaseIterable {
  case green, blue, yellow, magenta, cyan, red
}

// 2. 역할 검증 추가
struct AgentRolePreset {
  var model: AgentModel  // String 대신
  var color: AgentColor

  // Validation
  func validate() throws {
    guard !instructions.isEmpty else {
      throw AgentRoleError.emptyInstructions
    }
  }
}

// 3. 프리셋 버전 관리
struct AgentRolePreset {
  var version: Int = 1  // 마이그레이션 추적
}
```

---

### 1.3 TerminalController 확장 구조 (총 10,191줄 + main 2,268줄)

**문제:** TerminalController가 **12,459줄**로 분산되어 있음. 8개 확장으로 분리했으나 책임이 불명확.

**현재 구조:**
| 파일 | 줄수 | 책임 | 문제 |
|------|------|------|------|
| TerminalController.swift | 2,268 | 초기화, socket start/stop, 핸들러 등록 | 메인 로직도 복잡 |
| +Browser.swift | 3,210 | 브라우저 패널 기능 | 너무 큼 (3000줄) |
| +Debug.swift | 2,986 | 디버그 로깅 | 역시 너무 큼 |
| +Parsing.swift | 968 | 프로토콜 파싱 | 명확 |
| +Workspace.swift | 747 | 워크스페이스 관리 | 명확 |
| +Surface.swift | 892 | 터미널 서피스 관리 | 명확 |
| +Pane.swift | 623 | V2 API 기반 Pane 제어 | 명확 |
| +V1Commands.swift | 470 | V1 API 호환 레거시 | 기술 부채 |
| +Process.swift | 295 | 보안 (UID, PID 확인) | 명확 |

**주요 문제:**

**문제 1: 과도한 파일 크기**
```swift
// Browser.swift (3,210줄)
// - WebView 관리
// - 제스처 처리
// - 오버레이 UI
// - 네비게이션 로직
// → 분리 필요: BrowserPanelController + GestureHandler + NavigationManager
```

**문제 2: Protocol 부재로 테스트 불가**
```swift
// TerminalController가 AppKit/Bonsplit에 강하게 의존
// 단위 테스트 불가능
class TerminalController: NSObject {  // 직접 AppKit 상속
  @ObservedObject var tabManager: TabManager
  // Mock 불가능
}

// 개선: Protocol 추상화
protocol TerminalControllerDelegate {
  func getTabManager() -> TabManager
  func sendTextToPanel(_ panelId: UUID, _ text: String) -> Bool
}
```

**문제 3: V1 & V2 API 병존**
```swift
// V1Commands.swift (470줄) - 레거시
func v1SurfaceIndex(...) -> [String: Any]?
func v1PaneList(...) -> [String: Any]?

// Pane.swift (623줄) - 신규
func v2PaneList(params: [String: Any]) -> V2CallResult
func v2PaneFocus(params: [String: Any]) -> V2CallResult

// → V1 제거 계획 필요
```

**문제 4: 확장 간 의존성이 명확하지 않음**
```
TerminalController.swift
  ├─ delegates 등록
  ├─ serverSocket 관리
  └─ handleCommand()
       ├─ V1Commands (레거시)
       ├─ Parsing (프로토콜 파싱)
       ├─ Pane (V2 API)
       ├─ Workspace (워크스페이스)
       └─ Browser (브라우저)

// 호출 순서와 상태 변화를 추적하기 어려움
```

**개선 안:**

```swift
// 1. Protocol 기반 책임 분리
protocol TerminalSurfaceController {
  func selectSurface(_ surfaceId: UUID) -> Bool
  func focusSurface(_ surfaceId: UUID) -> Bool
  func listSurfaces(_ workspaceId: UUID) -> [SurfaceInfo]
}

protocol TerminalPaneController {
  func listPanes(_ workspaceId: UUID) -> [PaneInfo]
  func focusPane(_ paneId: UUID) -> Bool
  func splitPane(_ paneId: UUID, orientation: Orientation) -> PaneId?
}

protocol BrowserPanelController {
  func navigateTo(_ url: String) -> Bool
  func goBack() -> Bool
  func goForward() -> Bool
}

// 2. TerminalController는 orchestrator 역할로 단순화
@MainActor
final class TerminalController: NSObject {
  let surfaceController: TerminalSurfaceController
  let paneController: TerminalPaneController
  let browserController: BrowserPanelController
  let parsingController: ProtocolParsingController

  func handleCommand(_ cmd: String) {
    let parsed = parsingController.parse(cmd)
    switch parsed.command {
    case "pane":
      _ = paneController.listPanes(parsed.workspaceId)
    case "surface":
      _ = surfaceController.listSurfaces(parsed.workspaceId)
    case "browser":
      _ = browserController.navigateTo(parsed.url)
    }
  }
}

// 3. V1 API 제거 일정 (로드맵)
// v0.20 (현재): V1 deprecated 경고
// v0.21: V1 제거
// v0.22+: V2 만 지원
```

---

### 1.4 TeamCreationView.swift (UI 컴포넌트)

**역할:** 팀 생성 Sheet UI

**강점:**
- ✅ Form 구조 명확 (header, settings, agentList, footer)
- ✅ Template 저장/로드 기능
- ✅ 빠른 프리셋 (quick preset with count)

**약점:**
- ⚠️ **상태 관리 분산**: @State 많음 (teamName, leaderMode, agents, showPresetEditor...)
- ⚠️ **콜백 기반 통신**: onCreate 클로저로 데이터 전달 (MVVM이 아님)

---

## 2. 테스트 커버리지 분석

**테스트 현황:**
- 56개 테스트 파일
- term-mesh.py (45K) - Python 테스트 유틸
- 대부분 **E2E 테스트** (UI, 터미널 입출력)
- **단위 테스트 거의 없음**

**테스트 카테고리:**
```
E2E UI Tests (40개+)
  ├─ Tab drag/drop (test_tab_dragging.py)
  ├─ Browser (test_browser_*.py × 10+)
  ├─ Surface selection (test_close_surface_selection.py)
  ├─ Visual regression (test_visual_screenshots.py)
  └─ Socket control (test_ctrl_socket.py)

Signal/Process Tests (5개+)
  ├─ Ctrl+C, Ctrl+D (test_ctrl_socket.py)
  └─ Process ancestry check

Notification Tests (3개+)
  ├─ CPU usage (test_cpu_notifications.py)
  └─ Terminal notifications

Feature Tests (8개+)
  ├─ Tab manager
  ├─ Browser custom keybinds
  └─ Claude hook session mapping
```

**문제:**

**문제 1: 단위 테스트 부재**
```
없는 것:
- AgentRolePreset의 검증 테스트
- TeamOrchestrator의 팀 생성 로직 (mock 없이 불가능)
- TerminalController 확장들의 파싱 로직
- 모델명 매핑 함수
```

**문제 2: E2E 테스트만 있음**
- Python을 통해 앱 전체를 띄우고 테스트
- 빌드/실행에 시간 오래 걸림
- 실패 원인 파악 어려움 (UI 문제 vs 로직 문제)

**개선 안:**

```swift
// 1. AgentRolePreset 검증 테스트
import XCTest

class AgentRolePresetTests: XCTestCase {
  func testBuiltInPresetsAreValid() {
    for preset in AgentRolePresetManager.builtInPresets {
      XCTAssertFalse(preset.instructions.isEmpty, "Preset \(preset.name) has empty instructions")
      XCTAssertTrue(["claude", "kiro", "codex", "gemini"].contains(preset.cli))
      XCTAssertTrue(["sonnet", "opus", "haiku"].contains(preset.model))
    }
  }

  func testModelMapping() {
    XCTAssertEqual(TeamOrchestrator.kiroModelName("opus"), "claude-opus-4.6")
    XCTAssertEqual(TeamOrchestrator.codexModelName("sonnet"), "o4-mini")
  }
}

// 2. TeamOrchestrator 로직 테스트 (mock 필요)
class TeamOrchestratorTests: XCTestCase {
  func testBuildClaudeCommand() {
    let cmd = TeamOrchestrator().buildClaudeCommand(
      claudePath: "/usr/local/bin/claude",
      agentId: "executor@team1",
      agentName: "executor",
      teamName: "team1",
      agentColor: "blue",
      parentSessionId: "session-1",
      agentType: "executor",
      model: "sonnet",
      instructions: "You are an executor"
    )

    XCTAssertTrue(cmd.contains("--agent-id executor@team1"))
    XCTAssertTrue(cmd.contains("--model sonnet"))
    XCTAssertTrue(cmd.contains("--dangerously-skip-permissions"))
  }
}

// 3. TerminalController 로직 테스트 (Protocol로 추상화 후)
class TerminalControllerTests: XCTestCase {
  let mockSurfaceController = MockTerminalSurfaceController()
  let mockPaneController = MockTerminalPaneController()

  func testHandleCommand_Pane() {
    let controller = TerminalController(
      surfaceController: mockSurfaceController,
      paneController: mockPaneController
    )

    let result = controller.handleCommand("pane list --workspace-id abc")
    XCTAssertTrue(mockPaneController.listPanesCalled)
  }
}
```

---

## 3. 보안 분석

**강점:**
- ✅ **Socket 보안 철저** (TerminalController+Process.swift)
  ```swift
  func getPeerPid(_ socket: Int32) -> pid_t?  // LOCAL_PEERPID
  func peerHasSameUID(_ socket: Int32) -> Bool  // LOCAL_PEERCRED
  func isDescendant(_ pid: pid_t) -> Bool  // 프로세스 트리 검증
  ```

- ✅ **환경변수 신중하게 관리**
  ```swift
  let claudeAgentEnv = baseEnv.merging([...]) { _, new in new }
  let kiroAgentEnv = baseEnv  // CLAUDECODE 제외
  ```

**약점:**
- ⚠️ **명령어 쉘 Injection 가능성**
  ```swift
  let shellCommand = "\(agentCommand); exec $SHELL"
  // agentCommand에 특수문자가 있으면 위험
  // 예: agentName = "foo''; rm -rf /"
  ```

- ⚠️ **시스템 프롬프트 이스케이프 불완전**
  ```swift
  let escaped = instructions.replacingOccurrences(of: "'", with: "'\\''")
  // 다른 특수문자 미처리
  ```

**개선 안:**
```swift
// 1. 명령어 빌더를 배열로 작성
let agentArgs = [
  claudePath,
  "--agent-id", agentId,
  "--agent-name", agentName,
  "--team-name", teamName,
  "--model", model
]
let process = Process()
process.executableURL = URL(fileURLWithPath: agentArgs[0])
process.arguments = Array(agentArgs.dropFirst())

// 2. 환경변수는 Process.environment에 직접 설정
process.environment = paneEnv

// 3. 셸 명령어 불필요 시 제거
// 현재: "\(agentCommand); exec $SHELL"
// 개선: Process 직접 사용
```

---

## 4. 성능 분석

**현재 구조 문제:**

1. **메인 스레드 블로킹**
   ```swift
   func createTeam(...) {
     // 300줄 중첩 블록이 모두 @MainActor에서 실행
     // UI 반응성 저하
   }
   ```

2. **과도한 메시지 큐**
   ```swift
   messages[teamName, default: []].append(msg)  // In-memory 저장
   // 장시간 실행 시 메모리 누적
   ```

3. **파일 I/O가 동기**
   ```swift
   func writeResult(...) -> Bool {
     try? FileManager.default.createDirectory(...)
     return FileManager.default.createFile(atPath: path, contents: data)
     // sync I/O → 메인 스레드 블로킹
   }
   ```

**개선 안:**
```swift
// 1. 팀 생성을 background task로 이동
func createTeam(...) async -> Team? {
  let workspace = await createWorkspaceOnMain()
  let panels = await withTaskGroup(of: PanelId?.self) { group in
    for agent in agents {
      group.addTask {
        await createAgentPanel(agent)
      }
    }
    var results = [PanelId?]()
    for await result in group {
      results.append(result)
    }
    return results
  }
}

// 2. 메시지 큐 크기 제한
private var messages: [String: [TeamMessage]] = [:]
private let maxMessagesPerTeam = 1000

func postMessage(...) -> TeamMessage? {
  var msgs = messages[teamName, default: []]
  msgs.append(msg)
  if msgs.count > maxMessagesPerTeam {
    msgs.removeFirst()  // 오래된 메시지 제거
  }
  messages[teamName] = msgs
  return msg
}

// 3. 파일 I/O 비동기화
func writeResultAsync(...) async -> Bool {
  return await Task.detached { [weak self] in
    try? FileManager.default.createDirectory(...)
    return FileManager.default.createFile(...)
  }.value
}
```

---

## 5. 종합 평가 및 개선 우선순위

### 점수 카드

| 항목 | 점수 | 평가 |
|------|------|------|
| 아키텍처 명확성 | 5/10 | ⚠️ 높은 복잡도, Protocol 부재 |
| 코드 모듈화 | 4/10 | ⚠️ 파일 분리됐으나 책임 불명확 |
| 테스트 커버리지 | 3/10 | 🔴 E2E만 있고 단위 테스트 거의 없음 |
| 보안성 | 7/10 | ✅ Socket 보안 좋으나 Shell injection 위험 |
| 성능 | 6/10 | ⚠️ 메인 스레드 블로킹, 메모리 누적 위험 |
| 유지보수성 | 4/10 | ⚠️ V1 레거시 + 큰 파일로 인한 복잡도 |

### 우선순위별 개선 계획

**P1 (즉시):**
- [ ] V1 API 제거 로드맵 수립 (v0.21 타겟)
- [ ] Shell injection 보안 패치 (Process 직접 사용)
- [ ] TeamOrchestrator를 Builder 패턴으로 리팩토링 (중첩 블록 제거)

**P2 (1주일):**
- [ ] TerminalController를 Protocol로 추상화
- [ ] 단위 테스트 기초 구축 (AgentRolePreset, TeamOrchestrator, Parsing)
- [ ] Browser.swift를 2-3개 파일로 분리 (3,210줄 → 700줄 × 3)

**P3 (1개월):**
- [ ] 메인 스레드 블로킹 리팩토링 (async/await 도입)
- [ ] 메시지 큐 메모리 제한 구현
- [ ] E2E 테스트 회귀 테스트 자동화

---

## 6. 구체적 코드 예제

### 6.1 TeamOrchestrator 리팩토링 예

**Before (300줄 중첩):**
```swift
func createTeam(...) -> Team? {
  guard !agents.isEmpty else { return nil }

  if let existing = teams[name] {
    if tabManager.tabs.first(where: { $0.id == existing.workspaceId }) == nil {
      teams.removeValue(forKey: name)
    } else {
      return nil
    }
  }

  let cliTypes = Set(agents.map { $0.cli.isEmpty ? "claude" : $0.cli })
  var cliPaths: [String: String] = [:]
  for cli in cliTypes {
    guard let path = agentBinaryPath(cli: cli) else {
      print("[team] \(cli) binary not found")
      return nil
    }
    cliPaths[cli] = path
  }

  // 300줄 이상...
}
```

**After (Builder 패턴):**
```swift
func createTeam(...) -> Team? {
  let builder = TeamBuilder(
    name: name,
    agents: agents,
    workingDirectory: workingDirectory,
    tabManager: tabManager,
    leaderSessionId: leaderSessionId
  )

  guard let team = builder.build() else { return nil }
  teams[name] = team
  return team
}

struct TeamBuilder {
  func build() -> TeamOrchestrator.Team? {
    guard validateAgents() else { return nil }
    guard validateCLIBinaries() else { return nil }

    let workspace = createWorkspace()
    let leaderPanel = createLeaderPanel(in: workspace)
    let agentPanels = createAgentPanels(in: workspace, from: leaderPanel)
    let members = buildAgentMembers(agentPanels)

    return Team(id: name, agents: members, ...)
  }

  private func validateAgents() -> Bool { ... }
  private func validateCLIBinaries() -> Bool { ... }
  private func createWorkspace() -> Workspace { ... }
}
```

---

## 결론

**term-mesh는 야심찬 멀티에이전트 제어 플레인이지만, 현재 아키텍처에서 개선이 필요합니다:**

1. **Protocol 추상화 도입** → Protocol-Oriented Programming으로 테스트 용이성 확보
2. **거대 파일 분해** → 책임 명확화 및 이해도 향상
3. **V1 API 레거시 제거** → 유지보수 비용 감소
4. **단위 테스트 추가** → 회귀 버그 방지
5. **성능 최적화** → 메인 스레드 블로킹 제거, 메모리 관리

**권장사항:**
- 마일스톤 v0.21을 "Refactoring" 버전으로 지정
- Protocol 추상화 + V1 제거를 메인 목표로 설정
- 단위 테스트 커버리지를 70% 이상으로 목표 설정

---

## 부록: 파일별 종합 평가

| 파일 | 줄수 | 복잡도 | 평가 | 액션 |
|------|------|--------|------|------|
| TeamOrchestrator.swift | 919 | 높음 | 책임 과다, 중첩 깊음 | Builder 패턴 리팩토링 |
| AgentRolePreset.swift | 427 | 중간 | 정의는 좋으나 검증 부족 | Enum화, 테스트 추가 |
| TerminalController.swift | 2,268 | 극히 높음 | 초기화/핸들러 집중 | 책임 분리 |
| +Browser.swift | 3,210 | 극히 높음 | 너무 큼 | 3개 파일로 분리 |
| +Debug.swift | 2,986 | 높음 | 로깅 로직 혼재 | 별도 Logger로 추출 |
| +Parsing.swift | 968 | 중간 | 명확함 | ✅ 유지 |
| +Workspace.swift | 747 | 중간 | 명확함 | ✅ 유지 |
| +Surface.swift | 892 | 중간 | 명확함 | ✅ 유지 |
| +Pane.swift | 623 | 중간 | V2 API 명확 | ✅ V1 제거 후 유지 |
| +V1Commands.swift | 470 | 중간 | 레거시 | 🔴 제거 (v0.21) |
| +Process.swift | 295 | 낮음 | 보안 로직 명확 | ✅ 유지, 테스트 추가 |
| TeamCreationView.swift | ~200 | 중간 | UI 구조 좋음 | MVVM 리팩토링 고려 |
| tests/*.py | 45K | - | E2E만 있음 | 단위 테스트 추가 |

