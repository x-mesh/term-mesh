STATUS: DONE
FILES: none (design only — no code changed)
VERIFY: n/a
NEXT: executor에게 이 설계를 기반으로 CliProfile struct + CLIPathSettings 신 API + Migration 구현 위임
FULL_REPORT: /Users/jinwoo/work/project/term-mesh/.agent-results/074908c0-cli-profiles-design.md

---

# CLI Profiles Refactor — 데이터 모델 + 마이그레이션 설계

## 현재 상태 (코드 기반)

### Swift 레이어
- `CLIPathSettings` enum (`SettingsView.swift:3028`) — `resolvedPath(for:)`, `autoDetect(cli:)` 두 메서드만 존재
- `@AppStorage("cliPath.claude/kiro/codex/gemini")` — 단순 String 4개
- `TeamOrchestrator.agentBinaryPath(cli:)` (line 407) → `CLIPathSettings.resolvedPath(for:)` 호출
- `buildClaudeCommand/buildKiroCommand/buildCodexCommand/buildGeminiCommand` — `cliPath: String` + `model: String`만 받음
- `extraArgs`, `env` 개념 없음

### Rust 데몬 레이어
- `AgentSpec` (`headless/mod.rs:366`) — `cli`, `model`, `cli_path: Option<String>`, `instructions`
- `CliCommand` (`cli_builder.rs:9`) — `program`, `args`, `env`, `env_remove`
- `build_*_command` 함수들 — `cli_path: Option<&str>` + `model: &str` 고정 시그니처

---

## a) Swift CliProfile 구조체

```swift
struct CliProfile: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String           // "Default", "Work", "GPT-5.5 Heavy" 등
    var family: String         // "claude" | "kiro" | "codex" | "gemini"
    var executable: String     // 절대 경로 or "" → autoDetect fallback
    var extraArgs: [String]    // e.g. ["--no-cache", "--timeout", "60"]
    var env: [String: String]  // e.g. ["ANTHROPIC_API_KEY": "sk-..."]
    var modelOverride: String? // nil → team spawn 시 지정된 model 사용; "opus" → 강제 override
}
```

### 저장 위치: `~/Library/Application Support/term-mesh/cli-profiles.json`

**UserDefaults 대비 JSON 파일 선택 이유**:
- `[CliProfile]` 배열은 Codable 중첩 구조 — UserDefaults는 `Data` encode/decode 필요로 API 복잡
- 파일은 백업/복원/공유 가능, 사용자가 직접 편집 가능 (power user UX)
- 프로필 수가 CLI당 1-20개 수준으로 대용량 아님

**UserDefaults에 남기는 것 (가벼운 룩업용)**:
```
cliProfiles.migrated          Bool  — 마이그레이션 완료 플래그
cliProfiles.active.claude     String(UUID) — 활성 프로필 id
cliProfiles.active.kiro       String(UUID)
cliProfiles.active.codex      String(UUID)
cliProfiles.active.gemini     String(UUID)
cliProfiles.recent.claude     String(JSON Array<String>) — 최근 사용 경로 max 10
cliProfiles.recent.kiro       String(JSON Array<String>)
cliProfiles.recent.codex      String(JSON Array<String>)
cliProfiles.recent.gemini     String(JSON Array<String>)
```

---

## b) UserDefaults 마이그레이션

### 레거시 키 (현재)
```
cliPath.claude   String — 사용자 지정 경로 (없으면 "")
cliPath.kiro     String
cliPath.codex    String
cliPath.gemini   String
```

### 마이그레이션 전략 (dual-write, 단방향 one-shot)

```swift
// CliProfileMigrator.swift (신규 파일, ~50줄)
enum CliProfileMigrator {
    static let migratedKey = "cliProfiles.migrated"

    static func migrateIfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: migratedKey) else { return }

        for cli in ["claude", "kiro", "codex", "gemini"] {
            let legacyPath = defaults.string(forKey: "cliPath.\(cli)") ?? ""
            guard !legacyPath.isEmpty else { continue }

            // 기존 경로를 "Default" 프로필 1개로 변환
            let profile = CliProfile(
                name: "Default",
                family: cli,
                executable: legacyPath,
                extraArgs: [],
                env: [:],
                modelOverride: nil
            )
            CliProfileStore.shared.save(profile, for: cli)
            // 활성 프로필로 지정
            defaults.set(profile.id.uuidString, forKey: "cliProfiles.active.\(cli)")
        }
        defaults.set(true, forKey: migratedKey)
    }
}
```

**dual-write 정책**:
- `CLIPathSettings.setActiveProfile(_:for:)` 호출 시 동시에 `"cliPath.\(cli)"`도 업데이트
  → 구버전 빌드(profile 개념 없음)가 여전히 단순 경로를 읽을 수 있음
- Migration flag 이후에도 레거시 키를 1-2 마이너 버전 동안 dual-write 유지
- 미래에 `cliPath.*` 키 sunset: changelog에 명시 후 제거

---

## c) CLIPathSettings 신 public API

```swift
enum CLIPathSettings {

    // MARK: - New API

    /// 특정 CLI의 모든 저장된 프로필 반환
    static func profiles(for cli: String) -> [CliProfile]

    /// 활성 프로필 반환 (nil = 프로필 없음 → autoDetect)
    static func activeProfile(for cli: String) -> CliProfile?

    /// 활성 프로필 설정 + 레거시 dual-write
    static func setActiveProfile(_ profile: CliProfile, for cli: String)

    /// 활성 프로필 executable or autoDetect fallback (nil = 미발견)
    static func resolvedExecutable(for cli: String) -> String?

    /// 활성 프로필의 extraArgs (없으면 [])
    static func extraArgs(for cli: String) -> [String]

    /// 활성 프로필의 env (없으면 [:])
    static func env(for cli: String) -> [String: String]

    /// 최근 사용 경로 배열 (max 10, UserDefaults cliProfiles.recent.<cli>)
    static func recent(for cli: String) -> [String]

    // MARK: - Legacy (preserved, 1-liner shim — 기존 호출자 변경 불필요)

    /// 기존 API 유지 — resolvedExecutable(for:) 위임
    static func resolvedPath(for cli: String, defaults: UserDefaults = .standard) -> String? {
        return resolvedExecutable(for: cli)
    }

    /// 변경 없음
    static func autoDetect(cli: String) -> String
}
```

**`resolvedExecutable` 구현 로직**:
```
1. activeProfile(for: cli)?.executable → 비어 있지 않으면 반환
2. autoDetect(cli: cli) → 비어 있지 않으면 반환
3. 기존 버전 fallback (claude versioned installs, ~/.local/share/claude/versions/...)
4. nil
```

**기존 호출자 영향 최소화**:
- `TeamOrchestrator.agentBinaryPath(cli:)` (line 407): 변경 불필요 — `resolvedPath(for:)` 호출 유지
- `SettingsView.CLIPathRow.onAppear` (line 2849): `autoDetect(cli:)` 호출 유지
- Settings `@AppStorage("cliPath.*")` binding: 레거시 key dual-write로 계속 동작
- 기존 `resolvedPath` 9개 호출 사이트 전부 zero-change

---

## d) 데몬 영향

### Pane 모드 (Swift TeamOrchestrator)

**`addAgentPaneToWorkspace` 시그니처 확장** (line 543):
```swift
private func addAgentPaneToWorkspace(
    ...
    cliPath: String,
    extraArgs: [String] = [],       // ← 신규
    extraEnv: [String: String] = [:],  // ← 신규
    ...
) -> AgentMember?
```

**`buildClaudeCommand` 확장** (line 3696):
```swift
private func buildClaudeCommand(
    claudePath: String,
    ...,
    extraArgs: [String] = []
) -> String {
    var parts = [...기존 args...]
    // extraArgs는 표준 args 뒤에 추가 (model flag 이후)
    parts += extraArgs.map { shellQuote($0) }
    return parts.joined(separator: " ")
}

private func shellQuote(_ s: String) -> String {
    if s.rangeOfCharacter(from: .init(charactersIn: " \t\"'\\$`!")) != nil {
        return "\"" + s.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    return s
}
```

동일 패턴으로 `buildKiroCommand`, `buildCodexCommand`, `buildGeminiCommand` 확장.

**`buildAgentPaneEnv` 확장** (line 438):
```swift
static func buildAgentPaneEnv(
    ...,
    profileEnv: [String: String] = [:]  // ← 신규 마지막 파라미터
) -> [String: String] {
    var env = [...기존 빌드...]
    // profile env는 마지막에 병합 → 기존 기본값 덮어씀
    env.merge(profileEnv) { _, new in new }
    return env
}
```

**호출 사이트** (`createTeam`, `attachToWorkspace`):
```swift
let activeProfile = CLIPathSettings.activeProfile(for: agentCli)
let extraArgs = activeProfile?.extraArgs ?? []
let extraEnv = activeProfile?.env ?? [:]
// modelOverride 처리: spawn 직전 model 파라미터 교체
let effectiveModel = activeProfile?.modelOverride ?? agentModel
```

### 헤드리스 모드 (Rust daemon)

**`AgentSpec` 확장** (`headless/mod.rs:366`):
```rust
pub struct AgentSpec {
    pub name: String,
    pub cli: String,
    pub model: String,
    pub cli_path: Option<String>,
    pub instructions: Option<String>,
    pub agent_type: Option<String>,
    pub color: Option<String>,
    // ── 신규 필드 (모두 serde default, 하위 호환) ──
    #[serde(default)]
    pub extra_args: Vec<String>,
    #[serde(default)]
    pub extra_env: std::collections::HashMap<String, String>,
}
```

**`InternalSpawnArgs` 확장** (line 402):
```rust
struct InternalSpawnArgs {
    ...
    extra_args: Vec<String>,                              // ← 신규
    extra_env: std::collections::HashMap<String, String>, // ← 신규
}
```

**`build_claude_command` 시그니처 확장** (`cli_builder.rs:82`):
```rust
pub fn build_claude_command(
    name: &str,
    team_name: &str,
    model: &str,
    _working_directory: &str,
    daemon_socket: &str,
    cli_path: Option<&str>,
    app_socket_path: Option<&str>,
    instructions: Option<&[u8]>,
    mode: ClaudeSpawnMode,
    extra_args: &[String],                           // ← 신규
    extra_env: &std::collections::HashMap<String, String>, // ← 신규
) -> CliCommand {
    ...
    // --append-system-prompt 이후에 extra_args 삽입
    for arg in extra_args {
        args.push(OsString::from(arg));
    }

    let mut env = base_env(name, team_name, daemon_socket, app_socket_path);
    // profile env는 base_env 이후 병합 → 우선순위 높음
    env.extend(extra_env.iter().map(|(k, v)| (k.clone(), v.clone())));
    ...
}
```

동일 패턴으로 `build_kiro_command`, `build_codex_command`, `build_gemini_command` 확장.

**RPC AgentSpec JSON 예시 (신규 필드 포함)**:
```json
{
  "name": "executor",
  "cli": "claude",
  "model": "sonnet",
  "cli_path": "/usr/local/bin/claude",
  "extra_args": ["--no-cache"],
  "extra_env": { "ANTHROPIC_API_KEY": "sk-custom-..." }
}
```

**Swift → RPC headless create_team 업데이트** (TeamOrchestrator.swift line 1013):
```swift
var spec: [String: Any] = ["name": a.name, "cli": cli, "model": effectiveModel]
if let path = cliPaths[cli] { spec["cli_path"] = path }
if !extraArgs.isEmpty { spec["extra_args"] = extraArgs }
if !extraEnv.isEmpty { spec["extra_env"] = extraEnv }
```

**modelOverride 처리 위치**: Swift 레이어에서 `AgentSpec.model` 필드 값 교체 (Rust는 model string만 받으므로 Swift가 전처리). Rust 변경 불필요.

---

## e) Menu bar quick-switch

**위치: 기존 `MenuBarExtraController` 메뉴 확장** (신규 NSStatusBar item 추가 불필요)

`buildMenu()` 내 `checkForUpdatesItem` 위에 "CLI Profile" submenu 삽입:
```swift
// MenuBarExtraController.buildMenu() 추가 위치
let profileMenu = NSMenu(title: "CLI Profile")
let profileItem = NSMenuItem(title: "CLI Profile", action: nil, keyEquivalent: "")
profileItem.submenu = profileMenu
menu.insertItem(profileItem, at: /* checkForUpdates 위 인덱스 */)

// updateProfileSubmenu() — menuWillOpen에서 호출
func updateProfileSubmenu() {
    profileMenu.removeAllItems()
    for cli in ["claude", "kiro", "codex", "gemini"] {
        let familyItem = NSMenuItem(title: cli.capitalized, action: nil, keyEquivalent: "")
        familyItem.isEnabled = false
        profileMenu.addItem(familyItem)

        let profiles = CLIPathSettings.profiles(for: cli)
        let active = CLIPathSettings.activeProfile(for: cli)
        for profile in profiles {
            let item = NSMenuItem(
                title: "  \(profile.name)",
                action: #selector(switchProfile(_:)),
                keyEquivalent: ""
            )
            item.state = (profile.id == active?.id) ? .on : .off
            item.representedObject = profile
            profileMenu.addItem(item)
        }
        profileMenu.addItem(.separator())
    }
}

@objc func switchProfile(_ item: NSMenuItem) {
    guard let profile = item.representedObject as? CliProfile else { return }
    CLIPathSettings.setActiveProfile(profile, for: profile.family)
    NotificationCenter.default.post(name: .cliActiveProfileChanged, object: profile)
    updateProfileSubmenu()
}
```

**적용 범위 정책**:
- **기본: 새 spawn only** — 프로필 변경은 다음번 `tm-agent create` / `tm-agent attach`부터 적용
- **opt-in: Apply to Active Pane (Restart)** — submenu에 별도 item으로 제공:
  ```
  CLI Profile
    claude
      ✓ Default
        Work
        ─────
        Apply to Active Pane (Restart) →
    kiro
      ...
  ```
  이 item은 `TeamOrchestrator.hardRestartAgent(...)` 를 호출하며 사용자에게 "현재 pane을 종료하고 새 프로필로 재시작합니다" 확인 alert 표시

**`AgentMember.originalSpawnCommand` 활용 (line 37)**:
- hard restart 경로 (`TeamOrchestrator.hardRestartAgent`, line 2689)에서 이미 `originalSpawnCommand`를 재사용
- 프로필 변경 후 hard restart 시: `addAgentPaneToWorkspace`가 최신 `CLIPathSettings.activeProfile`로 `originalSpawnCommand` 재생성 → 프로필 반영됨
- 구현: `hardRestartAgent` 내 `cliPath` 조회를 `agentBinaryPath(cli:)` 재호출로 교체 (line 2826 이미 이렇게 구현됨 → extraArgs/extraEnv만 추가)

---

## f) 리스크

### (i) extraArgs quoting (pane 모드)
- **문제**: pane 모드의 `buildClaudeCommand`는 shell string 연결 방식 → `extraArgs` 원소에 공백/따옴표 있으면 word splitting 발생
- **해결**: `shellQuote(_:)` 헬퍼 함수 추가 (위 c) 코드 참조)
- **헤드리스 모드는 안전**: Rust `Command::arg`는 shell을 거치지 않으므로 quoting 불필요, `OsString::from(arg)` 그대로 사용

### (ii) wrapper script + extraArgs 중복
- **문제**: `cliPath`가 wrapper script이면 이미 `--model`, `--dangerously-skip-permissions` 등을 내부에서 주입할 수 있음 → `extraArgs`로 동일 플래그 추가 시 중복
- **해결**: Settings UI에서 extraArgs 입력 필드 옆에 경고 힌트 표시:
  - 자동 주입 플래그 목록 (`bannedArgs`): `["--model", "--dangerously-skip-permissions", "--session-id", "--resume", "--print", "--append-system-prompt"]`
  - 입력 값이 bannedArgs와 겹치면 노란 경고 아이콘 + "이 플래그는 term-mesh가 자동으로 주입합니다" tooltip
  - Hard block 아님 (power user 허용), 경고만

### (iii) per-team override vs 전역
- **현재 설계**: profile은 앱 수준 전역. team create 시 per-agent model 지정은 이미 가능 (`AgentSpec.model`)
- **modelOverride 우선순위**:
  ```
  1. tm-agent create --model <explicit>  (highest)
  2. CliProfile.modelOverride            (profile level)
  3. team default model                  (lowest)
  ```
- **per-team profile override는 v2 범위** — `AgentSpec.profile_id: Option<UUID>` 추가로 구현 가능, 현재 설계는 forward-compatible (extra_args/extra_env가 이미 per-agent)

### (iv) 기존 cliPath.<cli> 보존
- **dual-write 정책** (b) 섹션에서 정의):
  - `setActiveProfile` 호출 시 `UserDefaults.standard.set(profile.executable, forKey: "cliPath.\(cli)")` 동시 업데이트
  - 마이그레이션 후에도 레거시 키가 유효한 경로를 가리키도록 유지
  - 사용자가 Settings의 기존 CLI Path 텍스트 필드를 직접 수정하면: `CliProfileMigrator.upsertDefaultProfile(path:for:)` 호출 → "Default" 프로필 executable 업데이트 + dual-write

---

## 구현 순서 권고

1. **`CliProfile` struct + `CliProfileStore`** (신규 파일 ~100줄)
2. **`CliProfileMigrator`** (신규 파일 ~50줄)
3. **`CLIPathSettings` 신 API 추가** (기존 메서드 유지, 신규 추가)
4. **`TeamOrchestrator` pane 모드 extraArgs/extraEnv 연결** (~30줄 변경)
5. **Rust daemon `AgentSpec` + `build_*_command` 확장** (~40줄 변경)
6. **`MenuBarExtraController` Profile submenu** (~80줄)
7. **Settings UI 드롭다운 + Profile 관리 뷰** (별도 설계 필요)
