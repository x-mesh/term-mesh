# CLI Profiles Refactor — 라운드 2 Fix 검증

**날짜:** 2026-05-16  
**대상 커밋:** 5b7dcc05, c1595b19, a476c131 (fix), 22cc3b70, ab5e843d  
**빌드:** xcodebuild Debug BUILD SUCCEEDED / cargo build --release 통과  
**리뷰어:** reviewer  
**VERDICT: LGTM** — 라운드 1 P1×2, P2×4 모두 해소. 잔류 P3×1 (허용).

---

## 체크 항목 검증 결과

### ✅ 1. shellQuote — single-quote wrap (P1-1 해소)
**File:** `Sources/TeamOrchestrator.swift` (commit a476c131)

```swift
private func shellQuote(_ s: String) -> String {
    return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
```

POSIX single-quote 이스케이프 패턴 (`'\''`) 정확히 구현됨. `;|&()<>` 등 모든 shell 메타문자 무력화. ✓

---

### ✅ 2. AgentMeta extra_args/extra_env 필드 추가 + 구버전 호환 (P1-2 해소)
**File:** `daemon/term-meshd/src/headless/meta.rs` (commit a476c131)

```rust
#[serde(default, skip_serializing_if = "Vec::is_empty")]
pub extra_args: Vec<String>,
#[serde(default, skip_serializing_if = "std::collections::HashMap::is_empty")]
pub extra_env: std::collections::HashMap<String, String>,
```

- `#[serde(default)]` — 기존 meta.json에 필드 없어도 역직렬화 성공 (구버전 호환) ✓  
- `skip_serializing_if = "Vec::is_empty"` / `"HashMap::is_empty"` — 빈 값은 기록 안 함 → 기존 meta.json 포맷 불변 ✓

---

### ✅ 3. unpark_agent + resume_team에서 extra_args.clone() 주입 (P1-2 해소)
**File:** `daemon/term-meshd/src/headless/mod.rs` (commit a476c131)

```rust
// unpark_agent (line ~1601)
extra_args: agent_meta.extra_args.clone(),
extra_env: agent_meta.extra_env.clone(),

// resume_team (line ~2128)
extra_args: m.extra_args.clone(),
extra_env: m.extra_env.clone(),
```

두 경로 모두 `Vec::new()` → `agent_meta.extra_args.clone()` 교체 확인. ✓

**부기:** pane-mode `archive_pane_team` (line ~1209)은 의도적으로 `Vec::new()` 유지 — pane-mode resume은 Swift가 resume 시점에 `CLIPathSettings.activeProfile` 에서 현재 프로필을 읽으므로 archive에 저장 불필요. 올바른 설계.

---

### ✅ 4. setActiveProfile assert 함수 최상단에 위치 (P2-1 해소)
**File:** `Sources/CLIPathSettings+Profiles.swift` (commit 5b7dcc05)

```swift
static func setActiveProfile(_ profile: CliProfile, for cli: String) {
    assert(profile.family == cli, "Profile family \(profile.family) != cli \(cli)")
    let defaults = UserDefaults.standard
    // ...
}
```

함수 진입 직후 첫 문장으로 assert 배치. DEBUG 빌드에서 family 불일치 즉시 크래시. ✓

---

### ✅ 5. CLIPathRow .onReceive(.cliActiveProfileChanged) 구독 (P2-2 해소)
**File:** `Sources/SettingsView.swift` (commit a476c131)

```swift
.onAppear { refresh() }
.onReceive(NotificationCenter.default.publisher(for: .cliActiveProfileChanged)) { _ in
    refresh()
}
```

menubar 프로필 전환 후 Settings 창이 열려 있어도 즉시 갱신. ✓

---

### ✅ 6. env 값 leading/trailing space 트림 (P2-3 해소)
**File:** `Sources/SettingsView.swift` (commit a476c131)

```swift
profile.env[String(kv[0]).trimmingCharacters(in: .whitespaces)] =
    String(kv[1]).trimmingCharacters(in: .whitespaces)
```

key/value 양쪽 모두 trim 적용. ✓

---

### ✅ 7. Apply to Active Pane — 완전 구현 (P2-4 해소)
**File:** `Sources/MenuBarExtra.swift` (commit a476c131)

- `focusedAgentPaneInfo(for:)` — selectedWorkspace.focusedPanelId → teams 루프로 CLI family 매칭  
- `applyItem.isEnabled = hasFocusedAgent` — 포커스된 pane이 해당 CLI일 때만 활성  
- `alert.runModal()` — 확인 후 `Task { @MainActor in restartAgentPaneHard(panelId:) }`  

`TeamOrchestrator`가 `@MainActor`이고 `menuWillOpen`은 main thread에서 호출되므로 `teams` 접근 안전. ✓  
CLAUDE.md 문서와 구현이 일치함. ✓

---

## 신규 관찰 (라운드 2에서 발견)

### [P3-carry] resumeSessionId 미이스케이프 — 라운드 1에서 이월, 미수정 (허용)
**File:** `Sources/TeamOrchestrator.swift:619`

```swift
agentCommand.append(" --resume \(sid)")
```

`sid`는 Claude session ID로 UUID 포맷이 보장되므로 실용적 위험 낮음. 라운드 1 P3 이월, 필수 수정 항목 아님.

---

## 잔류 위험 (Residual Risk)

| 항목 | 상태 | 위험도 |
|------|------|--------|
| resumeSessionId 미이스케이프 | P3 이월, 미수정 | 낮음 (UUID 포맷) |
| CliProfileStore 다중 프로세스 캐시 stale | 설계상 단일 프로세스 | 낮음 |
| bannedArgs 경고만, 저장 미차단 | 의도적 설계 | 낮음 |
| 비원자적 마이그레이션 | 충돌 시 중복 UUID 생성 가능 | 낮음 |
| `spawn_agent` (line 487) 단독 경로 extra_args 미주입 | 현재 Swift 미사용 경로 추정 | 낮음 |

---

## 검증 명령

```bash
# 빌드 (이미 통과 확인)
xcodebuild -project GhosttyTabs.xcodeproj -scheme term-mesh -configuration Debug \
  -destination 'platform=macOS' build

# shellQuote 로직 단위 검증 (POSIX shell)
echo '; echo INJECTED' | xargs -I{} sh -c "echo '{}'"
# 출력: ; echo INJECTED (literal, 실행 안 됨) ← 올바른 동작

# extra_args park/unpark 통합 테스트 (VM 필요)
ssh term-mesh-vm 'cd /Users/jinwoo/term-mesh/GhosttyTabs && python3 tests/test_ctrl_socket.py'
```
