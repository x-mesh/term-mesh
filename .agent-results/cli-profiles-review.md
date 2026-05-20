# CLI Profiles Refactor — 통합 코드 리뷰

**날짜:** 2026-05-16  
**브랜치:** feature/pane-mode-resume  
**대상 커밋:** ab5e843d, 22cc3b70  
**리뷰어:** reviewer  
**VERDICT: CHANGES_REQUIRED** (P1 × 2)

---

## P1 — Must Fix

### [P1][SECURITY][SHELL_INJECT] `shellQuote` 불완전 — `;|&()<>` 미처리
**File:** `Sources/TeamOrchestrator.swift:3772`

```swift
private func shellQuote(_ s: String) -> String {
    if s.rangeOfCharacter(from: CharacterSet(charactersIn: " \t\"'\\$`!")) != nil {
        return "\"" + s.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    return s
}
```

`extraArgsText`는 공백으로 split 후 각 토큰이 개별 shellQuote된다. `;`, `|`, `&`, `(`, `)`, `<`, `>`, `\n`은 CharacterSet에 없으므로 그대로 통과.

**PoC:** 사용자가 extraArgs에 `; open /Applications/Calculator.app` 입력 →  
split 결과: `[";", "open", "/Applications/Calculator.app"]`  
shellQuote 후: `; open /Applications/Calculator.app`  
최종 shellCommand: `... claude ... ; open /Applications/Calculator.app ; exec $SHELL`  
→ Ghostty가 이를 shell에 넘겨 `open` 실행.

pane-mode에서 `shellCommand`는 Ghostty를 통해 실제 shell로 실행됨 (3637행 참고).  
Rust headless 경로(`cli_builder.rs`)는 OsString argv 직접 push라 안전. Swift 경로만 영향.

**Fix:**

```swift
private func shellQuote(_ s: String) -> String {
    // 단일 인용부호로 감싸면 모든 shell 메타문자를 무력화.
    // 내부의 ' 만 '\'' 로 이스케이프.
    return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
```

**Verify:** `extraArgs = ["; echo INJECTED"]` 설정 후 에이전트 pane 실행 시 `INJECTED`가 출력되지 않아야 함.

---

### [P1][HEADLESS][PERSISTENCE] `unpark_agent` · `resume_team`이 extra_args/extra_env 드롭
**Files:** `daemon/term-meshd/src/headless/mod.rs:1583, 2109`

`AgentMeta`에 `extra_args`/`extra_env` 필드가 없으므로 디스크에 저장되지 않는다.  
두 경로 모두 `Vec::new()` / `HashMap::new()`으로 하드코딩:

```rust
// line 1583 (unpark_agent)
extra_args: Vec::new(),
extra_env: std::collections::HashMap::new(),

// line 2109 (resume_team)
extra_args: Vec::new(),
extra_env: std::collections::HashMap::new(),
```

**영향:** park→unpark, destroy→resume 사이클을 거치면 프로필의 extraArgs/extraEnv가 조용히 사라짐. 특히 `--no-cache`, API 키 환경변수 등 사용자가 설정한 값이 유실됨.

**Fix (2단계):**

① `AgentMeta` 구조체에 필드 추가 (`daemon/term-meshd/src/headless/meta.rs`):
```rust
#[serde(default)]
pub extra_args: Vec<String>,
#[serde(default)]
pub extra_env: std::collections::HashMap<String, String>,
```

② spawn 시 `agent_meta`에 기록, unpark/resume 시 읽어서 `InternalSpawnArgs`에 주입:
```rust
// unpark_agent (line ~1598)
extra_args: agent_meta.extra_args.clone(),
extra_env: agent_meta.extra_env.clone(),

// resume_team (line ~2124)
extra_args: m.extra_args.clone(),
extra_env: m.extra_env.clone(),
```

**Verify:** 프로필에 extraArgs 설정 후 park→unpark 시 agent pane의 CLI 명령에 해당 인수가 포함되는지 확인.

---

## P2 — Should Fix

### [P2][API][FAMILY] `setActiveProfile` family 불일치 무검증
**File:** `Sources/CLIPathSettings+Profiles.swift:19`

```swift
static func setActiveProfile(_ profile: CliProfile, for cli: String) {
    let defaults = UserDefaults.standard
    defaults.set(profile.id.uuidString, forKey: "cliProfiles.active.\(cli)")
    // ... dual-write
}
```

`profile.family`와 `cli` 파라미터가 일치하지 않아도 에러 없이 저장됨. claude 프로필이 gemini용으로 활성화될 수 있음.

**Fix:**
```swift
static func setActiveProfile(_ profile: CliProfile, for cli: String) {
    assert(profile.family == cli, "Profile family '\(profile.family)' != cli '\(cli)'")
    // ...
}
```

**Verify:** 단위 테스트에서 mismatched family로 호출 시 assert 발동.

---

### [P2][UI][STALE] `CLIPathRow` — menubar 프로필 전환 후 갱신 안 됨
**File:** `Sources/SettingsView.swift:2903`

```swift
.onAppear { refresh() }
```

CLIPathRow는 `.onAppear`과 sheet dismiss에만 refresh를 호출. menubar에서 프로필을 전환하면 `cliActiveProfileChanged` Notification이 발행되나(`MenuBarExtra.swift:367`) CLIPathRow는 이를 구독하지 않아 Settings 창이 열려 있는 동안에는 stale 상태 표시.

**Fix:**
```swift
.onAppear { refresh() }
.onReceive(NotificationCenter.default.publisher(for: .cliActiveProfileChanged)) { _ in
    refresh()
}
```

**Verify:** menubar에서 프로필 전환 시 Settings → CLI Paths 패널의 활성 프로필 표시가 즉시 갱신되어야 함.

---

### [P2][ENV_PARSE] env 값 leading space 미트림
**File:** `Sources/SettingsView.swift:3271`

```swift
profile.env[String(kv[0]).trimmingCharacters(in: .whitespaces)] = String(kv[1])
```

`KEY= value` 입력 시 `" value"` (선행 공백 포함)가 저장됨. 값을 trimCharacters해야 함.

**Fix:**
```swift
profile.env[String(kv[0]).trimmingCharacters(in: .whitespaces)] =
    String(kv[1]).trimmingCharacters(in: .whitespaces)
```

---

### [P2][MENUBAR][DOCS] "Apply to Active Pane (Restart)" 항상 비활성화
**File:** `Sources/MenuBarExtra.swift:352`

```swift
applyItem.isEnabled = false  // TODO: Enable when active agent pane lookup is wired up
```

CLAUDE.md에 `"Apply to Active Pane (Restart)"를 선택하면 현재 pane을 새 프로파일로 hard restart`라고 문서화되어 있으나 실제로는 비활성 상태.

**Fix 옵션 A:** 구현 완료 전까지 CLAUDE.md에서 해당 문장 제거 또는 "예정" 표시.  
**Fix 옵션 B:** 해당 메뉴 항목을 아예 숨기기 (`isHidden = true`).

---

## P3 — Info / Nit

### [P3][RESUME_SID] resumeSessionId shell 이스케이프 누락
**File:** `Sources/TeamOrchestrator.swift:619`

```swift
agentCommand.append(" --resume \(sid)")
```

`sid`가 Claude session ID(UUID 포맷)임이 보장되지 않고 shell 이스케이프 없이 직접 삽입됨. 보관된 sid가 오염된 경우 부분적 주입 가능. `shellQuote(sid)` 적용 권장.

---

### [P3][MIGRATOR] 비원자적 마이그레이션
**File:** `Sources/CliProfileMigrator.swift:6`

4개 CLI 루프와 `defaults.set(true, forKey: migratedKey)` 사이에 크래시 시 재실행에서 중복 UUID 프로필 생성. 현재 `save()` 시 기존 id 조회 후 덮어쓰므로 id가 달라 새 프로필 생성됨. 치명적이지 않으나 중복 "Default" 항목 노출 가능.

---

### [P3][BANNED_ARGS] 경고만 표시, 저장 미차단
**File:** `Sources/SettingsView.swift:3127`

`hasBannedArgs`는 ⚠️ 아이콘만 표시하고 저장을 막지 않음. CLAUDE.md에 "경고 표시됨"으로 문서화되어 의도적 설계이나, 최소한 저장 버튼 클릭 시 확인 다이얼로그 추가 권장.

---

## 체크 항목 통과 여부

| 항목 | 결과 | 비고 |
|------|------|------|
| SECURITY extraArgs 셸 주입 | ❌ P1 | shellQuote `;|&()` 미처리 |
| CORRECTNESS CliProfileStore 동시성/직렬 큐 | ✅ | serial queue + cache 일관성 OK |
| CORRECTNESS JSON 부분 디코드 실패 처리 | ✅ | `try? ... else { return [:] }` — 빈 딕셔너리 폴백 OK |
| API dual-write setActiveProfile | ✅ | `cliPath.<cli>` UserDefaults도 업데이트 (line 24) |
| MIGRATION one-shot 플래그 | ✅ | `migratedKey` 체크, 빈 경로 스킵 OK |
| MIGRATION 빈 문자열 스킵 | ✅ | `guard !legacyPath.isEmpty else { continue }` |
| SPAWN 3개 call-site extraArgs/extraEnv | ✅ | createTeam(1013), attach(1420), hardRestart(2864) 모두 주입 |
| SPAWN spawn_agent(487) extraArgs | ⚠️ P3 | Vec::new() — 단독 add 시나리오에서 미주입 |
| RPC AgentSpec extra_args/extra_env serde(default) | ✅ | mod.rs:385,388 적용 확인 |
| HEADLESS unpark/resume extra_args | ❌ P1 | AgentMeta 미저장으로 드롭 |
| UI CLIPathRow activeProfile 갱신 | ❌ P2 | menubar 전환 시 실시간 갱신 없음 |
| BANNED_ARGS 경고 표시 | ✅ | 경고 아이콘 표시됨 |
| MENUBAR 라디오 체크마크 | ✅ | `item.state = .on/.off` 정상 적용 |
| MENUBAR menuWillOpen 갱신 | ✅ | `updateProfileSubmenu()` 호출 확인 |

---

## 미실행 커버리지 (잔류 위험)

- **통합 테스트 없음:** unpark→resume 사이클에서 extraArgs 유지 여부를 검증하는 자동화 테스트 없음. 수동으로 park/unpark 후 pid spawn args 확인 필요.
- **headless `spawn_agent` 직접 호출 경로:** line 487의 단일 에이전트 추가가 실제로 호출되는 시나리오에서 extraArgs가 묵시적으로 버려지는지 UI 경로 확인 필요.
- **CliProfileStore 다중 프로세스 경쟁:** atomic write 사용 중이나, 프로세스 외부에서 파일을 수정하면 인메모리 캐시가 stale됨 (앱 재시작 전까지 유지). 현 아키텍처에서 단일 프로세스 가정이므로 실용적 위험 낮음.
