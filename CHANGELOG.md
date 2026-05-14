# Changelog

All notable changes to term-mesh are documented here.

## [0.116.0] - 2026-05-15

### Fixed
- **IME 입력 박스 높이 확대** — 입력 박스가 너무 낮아 `@`(에이전트 멘션) / `/`(슬래시 커맨드) 자동완성 팝업이 잘리던 문제. 기본 높이를 2배로 늘려 팝업이 온전히 보이며, 이전에 직접 키워 둔 사용자 설정은 그대로 유지.
- **에이전트에 보낸 Return이 씹히던 문제** — 리더가 `tm-agent send`/`delegate`로 에이전트 pane에 빠르게 연속 전송할 때 paste와 Return이 겹쳐 매 두 번째 입력이 통째로 누락되던 버그. pane별로 전송을 직렬화하고 Return 재시도 간격을 조정해 해소.
- **에이전트/패널을 닫아도 자식 CLI 프로세스가 고아로 남던 문제** — claude / codex / gemini 등 에이전트 CLI 프로세스가 패널 종료 후에도 백그라운드에 살아 있던 문제를 수정.
- **에이전트 종료 시 관련 없는 프로세스가 함께 종료되던 문제** — 에이전트를 종료할 때 프로세스 그룹 처리가 부정확해 같은 부모를 공유하는 다른 프로세스까지 영향을 받을 수 있던 문제를 수정.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.115.0] - 2026-05-14

### Added
- **`/tm` 슬래시 커맨드 — 팀 일괄 dispatch** — 한 줄 instruction을 활성 팀의 모든 idle agent에게 동시에 위임하고 결과를 `[결론] / [충돌] / [다음]` 3줄로 수렴. `/tm-op`(10+ 전략)의 경량 진입점으로, 라운드·전략 선택 없이 "지금 전원 동원" 한 가지만 한다. `/team`과 양방향으로 연결되어 New 사용자가 `/tm`만 알아도 `/team`의 low-level 명령을 자연스럽게 발견.
- **Gemini CLI agent 지원** — 팀 구성 시 claude / codex / kiro에 더해 gemini agent를 띄울 수 있음.
- **New Agent Team 다이얼로그 — Smart Preset 추가/삭제** — preset 목록 끝의 점선 "+" 카드로 새 preset을 그 자리에서 즉석 생성(이름 입력 후 자동 저장), 카드에 hover하면 "×"로 삭제. built-in preset은 🔒로 보호되어 삭제 대신 Reset만 가능. preset이 하나도 없을 땐 "+" 카드가 전체 폭으로 확장.
- **Pane mode agent 사이드바 토큰 표시** — 이전엔 headless agent만 토큰 카운터가 보였으나, 이제 사용자가 직접 split에 띄운 Claude / Codex agent도 input·output 토큰이 사이드바에 표시됨. 같은 작업 디렉토리를 공유하는 여러 agent도 프로세스 시작 시각으로 각자의 세션을 구분해 정확히 귀속. Codex는 rollout 로그를 직접 파싱해 input / output / cached를 정확히 분리.
- **작업 중 agent 스피너** — task가 `in_progress`인 agent row에 정적 dot 대신 애니메이션 스피너가 표시되어 지금 일하는 agent를 한눈에 구분.

### Fixed
- **Enter 씹힘 — 두 개의 별개 경로 모두 수정** — (1) IME 조립 중 Enter를 누르면 Ghostty의 composing 가드가 `\r`을 삼키던 문제, (2) 리더가 `tm-agent send`/`delegate`로 pane에 메시지를 주입할 때 paste watchdog 타임아웃 후 Return 재시도가 통째로 skip되던 문제. 두 경로 다 막혀 텍스트는 들어가는데 실행이 안 되던 증상을 해소.
- **슬립에서 깨어난 후 검은 pane** — wake 이벤트를 합쳐 agent surface를 다시 그리도록 수정.
- **New Agent Team — leader 모델 선택이 저장되지 않던 문제** — leader 모델 / 모드가 팀 생성 성공 직후에만 저장되도록 변경. 이전 세션의 다른 CLI 모델이 남아 모델 셀렉트 박스가 빈 상태로 보이던 문제도 함께 해소. 미완성·중복 Smart Preset은 실행 시 자동 정리.
- **사이드바 토큰 카운터가 누적 합계를 표시하던 문제** — 같은 작업 디렉토리의 과거 세션 전체가 합산돼 수치가 부풀던 문제를 현재 세션만 표시하도록 수정. Codex 토큰은 전체 합(total)을 output 칸에 잘못 넣던 것을 input / output / cached로 정확히 분리.

### Changed
- **사이드바 토큰 라벨 간결화** — `13 in · 1.1k out` → `13↑ 1.1k↓`로 축약, 상세는 hover tooltip으로 이동.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.114.0] - 2026-05-13

### Added
- **Smart Preset v3 — built-in 위에 사용자 편집 inline 적용** — Smart preset 카드를 그 자리에서 직접 편집할 수 있게 됨. 변경한 카드에는 `(Modified)` 배지가 뜨고, 클릭하면 built-in 기본값으로 즉시 복원. 새 Preview Panel로 카드를 클릭하면 agent / model / instructions를 미리 볼 수 있고, 마지막에 사용한 preset의 override가 다음 New Agent Team 다이얼로그에서 자동 복원됨.
- **Headless agent 모드 + 세션 재개 (Phase 2)** — daemon이 GUI pane 없이 agent CLI를 subprocess로 관리. 워크스페이스 닫고 다시 열어도 진행 중이던 세션이 그대로 재개되며, 사이드바에 agent별 input/output 토큰 카운터가 1초 간격으로 갱신.
- **사이드바 agent 가시화 (Phase 2.5)** — agent별 상태 dot (running / idle / parked / error), 인라인 펼침으로 토큰 사용량과 status label, per-agent 우클릭 메뉴, footer에 재개 가능한 세션 카운터.
- **`tm-agent restart <agent>` 명령** — agent CLI가 응답 없을 때 재시작. Soft mode (⌥-click)는 Ctrl-C + launch command 재타이핑, Hard mode (기본 click)는 패널을 닫고 같은 자리에 새 split으로 재spawn하여 stuck 상태 회복.
- **Agent pane 헤더에 ↻ 재시작 버튼** — agent 터미널 pane 우상단에 항상 표시. agent pane에만 노출되어 browser / debug pane은 영향 없음.
- **`tm-agent doctor` 명령 (초기 골격)** — 환경 변수, daemon socket, 살아있는 process를 한 번에 진단 (WIP).
- **xm/op override 파일 안내 토스트** — `~/.xm/op/agent-role-presets-override.json`이 외부 도구(xm:op) 전용임을 첫 실행 시 1회 안내.

### Changed
- **Smart Preset — v2 Force-Copy 흐름 폐기, v3 inline 편집 채택** — v2의 "Customize → 새 custom 복제" 흐름이 발견성 결여로 사용자 의도와 불일치. v3에서는 built-in 카드를 그 자리에서 편집하고 디스크에 override만 저장, 다음 사용 시 `(Modified)` 표시.
- **Agent pane ↻ 버튼 default 동작** — 단순 click이 hard restart (close + respawn)로 변경됨. soft mode (text retype만)는 ⌥-click. 사용자가 ↻를 누르는 거의 모든 상황 = stuck 회복이므로 default를 더 강력한 동작으로.

### Fixed
- **`tm-agent send` Return이 silent drop되던 race condition (Enter swallow)** — agent 패널에 텍스트는 들어가는데 Enter가 적용 안 되던 문제. surface attach 재구성 중 `ghostty_surface_key`가 false 반환하면 Rust CLI retry가 활성화되도록 RPC 응답에 `delivery_failed` 전파. KeyDeliveryToken + attachGeneration으로 stale callback 무효화, 10ms~3s exponential backoff retry. broadcast 후 응답 누락이 거의 사라짐.
- **Hard restart 시 pane 위치 보존** — agent pane을 닫고 새로 spawn할 때 원래 자리가 아닌 다른 곳에 떨어지던 결함. `paneLayoutSnapshot`의 walk를 pre-order에서 post-order로 변경하여 root가 아닌 immediate parent split을 정확히 매치하도록 fix. nested split layout에서도 정확한 슬롯에 재spawn.
- **Headless agent 사이드바 토큰 표시 안 되던 결함** — Swift이 headless member에 placeholder UUID를 panelId로 sync해서 daemon이 pane mode agent로 잘못 분류하던 결함. `AgentMember.panelId`를 `Optional<UUID>`로 변경 + JSON 직렬화 시 nil이면 omit하여 daemon이 진짜 headless로 인식하도록 fix. stream-json 토큰 캐치 + 1초 coalesced broadcast 정상 동작.
- **Smart Preset various** — schema:1 → schema:2 자동 migration, custom store eager seed (첫 실행 시 빈 파일 생성), 마지막 선택한 preset의 override 자동 복원, `(Modified)` 배지 클릭 영역 확장, leader_mode resolution 순위 (pinned preset → AppStorage fallback).
- **Restart 시 풀 spawn invocation 복원** — agent를 처음 spawn할 때 사용한 model flag, system prompt, MCP config, worktree cd 등을 보존했다가 restart 시 그대로 재실행. 기존엔 `claude` / `codex` 같은 binary 이름만 retype해서 system prompt가 누락되던 문제 회복.

### Removed
- **v2 Force-Copy "Customize" 버튼** — Smart Preset v3 inline edit 채택으로 UI에서 제거 (코드는 보존, 추후 "Save as new" 액션으로 부활 가능).

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.113.0] - 2026-05-13

### Fixed
- **Team leader pane no longer launches as a blank shell when the CLI binary lives outside `~/.local/bin`** — `claude`, `codex`, and `gemini` are now also auto-detected at `/opt/homebrew/bin`, `/usr/local/bin`, `~/.npm-global/bin`, `~/.volta/bin`, and `/opt/homebrew/opt/node/bin`. Previously a Homebrew/npm/Volta install would silently fall back to a bare shell with the title still showing "👑 Leader (Claude)".
- **Missing CLI binary is now surfaced as a visible error in the leader pane** instead of silently dropping into a blank shell. The pane prints a red `term-mesh: '<cli>' binary not found …` message pointing to Settings → Agent Teams → CLI Paths.
- **Korean IME no longer doubles the leading jamo of the next syllable** in raw-mode TUI panes such as `codex` and `kiro-cli`. When the IME committed the previous syllable and started a new marked syllable in the same `keyDown` (e.g. typing "정진우"), the physical key was replayed on top of the new preedit, producing "정ㅈ진ㅇ우 나ㅡ는 뭔ㄱ가". Term-mesh now skips the physical-key replay whenever a CJK IME starts a fresh composition right after committing prior text.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.112.0] - 2026-05-12

### Fixed
- **CJK IME no longer doubles punctuation when used as a commit trigger** — Korean, Chinese, and Japanese input methods often commit composed text when the user presses a punctuation key (`.`, `/`, `?`, `!`, `-`, `=`, `[`, `]`, `'`, `;`, `,`, and their Shift variants). The physical key was then replayed on top of the composed text, inserting the punctuation character twice (e.g. "완료.." instead of "완료."). Term-mesh now detects when the text-input layer already included the trigger character as part of the IME commit and skips the redundant replay.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.111.0] - 2026-05-12

### Fixed
- **Korean IME no longer doubles the separator space** — some Korean input methods (e.g. Korean 2-bulsik) deliver the trigger Space that commits a syllable as part of the accumulated `insertText` buffer (either as a trailing space on the last chunk or as a separate `" "` chunk). The physical Space key was then replayed on top of it, inserting two spaces instead of one. Term-mesh now detects when the text-input layer has already included the Space and skips the replay.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.110.0] - 2026-05-12

### Fixed
- **Spacebar no longer inserts two spaces** — the v0.109.0 key-handling change caused space (and other plain text keys) to be processed twice: once by the explicit `keyDown` call added in that release, and again by AppKit's normal responder-chain dispatch. The dispatch logic is simplified back to returning `performKeyEquivalent`'s result directly so AppKit handles the single `keyDown` dispatch as before.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.109.0] - 2026-05-11

### Fixed
- **Plain ASCII characters no longer double when typing in TUI applications such as claude code** — the `termMesh_performKeyEquivalent` window swizzle forwarded non-Command key events to the Ghostty surface but returned the surface's raw result. When that came back `false` (which it does for ordinary letters that aren't a keyboard binding), AppKit re-dispatched the same `NSEvent` through `keyDown`, firing `ghostty_surface_key` twice and producing duplicated characters. The swizzle now snapshots the first responder, calls `keyDown` itself exactly once on a `false` return, and tells AppKit the event was consumed — except when `performKeyEquivalent` moved focus (e.g. into the IME bar), in which case the original `false` return is preserved so the new responder still receives the key. The Cmd-modifier, font-zoom, and IME `markedText` paths are unchanged.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.108.0] - 2026-05-11

### Fixed
- **Terminal typing no longer duplicates plain characters after the v0.107.0 IME fix** — the IME text accumulator is used by normal AppKit text input too, not only by active CJK composition. v0.107.0 correctly split committed IME text into a keycode-free UTF-8 event, but then replayed the physical key for every accumulated-text path. Plain ASCII input could therefore arrive as both `insertText("a")` and a replayed physical `a`, showing up as doubled characters in Claude Code, shells, and other terminal apps. Term-mesh now replays the physical key only when it is still needed: actual IME composition commits and control/special keys whose accumulated text was not sent as printable text. Plain left-arrow remains suppressed for macOS IME finalization.
- **Opening a sheet no longer sends portal geometry sync into a CPU/log loop** — terminal and browser portal windows defer geometry synchronization while an `NSSheet` is attached, but the retry was being scheduled back onto the main queue immediately. If the sheet stayed open, DEBUG builds could emit `portal.sync.deferSheet reason=attachedSheetActive` hundreds of times per second, trigger the debug log circuit breaker, and drive the app above 100% CPU. The retry is now delayed while the sheet remains attached, preserving the hang avoidance without spinning.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.107.0] - 2026-05-11

### Fixed
- **Korean/Japanese/Chinese IME input is now reliable in kitty-protocol terminals** — typing CJK characters in zsh inside term-mesh used to occasionally lose the composed text or emit the bare physical key (e.g., `d` instead of `ㄴ`) because the kitty keyboard protocol encoded the physical key code instead of the composed UTF-8 text. Two layers were fixed:
  - The bundled Ghostty now sends the committed composed text directly as UTF-8 when the key has no physical mapping (cherry-pick of upstream `fdfc9fea2`).
  - The terminal view now emits the IME-committed text as a separate keycode-free event before replaying the physical key, so a Korean syllable followed by a physical arrow no longer mixes its character with the arrow's keycode. Plain left-arrow that macOS sends to finalize composition is dropped; other navigation keys still replay so cursor movement after committing works.
- **Return/Tab no longer swallowed when the notifications popover is empty** — an internal popover would consume every plain keyDown event with no modifier while it was shown, including Return and Tab. The empty-popover guard now explicitly lets keyCode 36 (Return) and 48 (Tab) through, so pressing Enter to send a line or Tab to autocomplete works even if the popover is open and empty.
- **`team.delegate` no longer races Return ahead of the pasted instruction** — three independent races in the IME paste pipeline are addressed; together they eliminate the "Enter intermittently dropped" symptom observed when chaining `tm-agent delegate` commands. `processPaste()` no longer leaves the paste queue blocked when the surface is momentarily nil during peer workspace transitions, the Rust CLI now waits for an actual paste-completion ack from Swift before sending Return (instead of a hard-coded 150 ms sleep, now 20 ms safety margin), and the ack timeout is aligned with the paste watchdog so a stale paste can't be left behind a suppressed Return.

### Added
- **`tm-agent` agent routing now distributes work across same-named workers** — previously, teams with two agents of the same name (e.g. two `executor`) routed every `tm-agent delegate executor` call to the first matching pane, leaving the second one permanently idle. `selectAgent()` now round-robins across duplicate-named workers, `tm-agent broadcast` reaches every pane (not just the first match per name), and `tm-agent claim` automatically pushes the claimed task to the worker so autonomous claim-and-work patterns can run without leader intervention. A new `scripts/test-parallel.sh` exercises all four behaviours as a regression check.
- **Atomic appends to research/swarm board.jsonl** — multi-agent research, solve, consensus, and swarm modes used a plain `echo >> board_path` to record observations, so concurrent writers could interleave JSON lines and break downstream parsing. Writes now go through a `python3 fcntl.flock` exclusive-lock append, so the board file stays line-valid under parallel agents.
- **Debug log signals for diagnosing Enter/IME issues** — DEBUG builds now emit `key.PRESS_ignored`/`RELEASE_ignored` when Ghostty reports a synthetic keypress wasn't handled, and `ime.return_with_markedText`, `ime.resignFirstResponder`, `ime.becomeFirstResponder`, and `ime.ghosttyKey path=accumulated.text` to trace IME state and composed-text delivery. Useful for narrowing down "Enter intermittently doesn't fire" reports — see `CLAUDE.md` "Debug event log" for the grep patterns.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.106.0] - 2026-05-11

### Added
- **Peer Workspace inner sidebar** — opening a Peer Workspace window now shows a host-workspaces sidebar inside the window itself, so you can switch between a peer host's workspaces without going back to the main window. The main window also gains a "Remote Hosts" section in its sidebar listing all peers you have configured.
- **Keychain-backed Peer ID with Settings UI** — your peer identity is now stored in the macOS Keychain and surfaced in a dedicated Settings panel; previously the ID lived only in plaintext on disk and there was no in-app way to inspect or rotate it.
- **`tm-agent watch` CLI for live agent events** — a new CLI subcommand streams JSONL events (task status changes, agent replies, stale heartbeats) from the daemon as they happen, replacing the previous "poll `tm-agent status` every few seconds" workflow that leader sessions had to use. Backed by a new `events.subscribe` RPC and a 30s stale-heartbeat scanner that broadcasts a `heartbeat_stale` event when an agent stops checking in.
- **`xm-build` reply bridge for tm-agent tasks** — when an agent's reply includes a `XMB_TASK:` line in its Standard Header, the daemon now writes the status straight into the matching `xm-build` `tasks.json`, so dogfooding tm-agent with xm-build no longer requires the leader to hand-edit task files.

### Fixed
- **Enter key intermittently swallowed during workspace transitions and after `tm-agent delegate`** — three independent races in the paste/Return pipeline are addressed:
  - `processPaste()` no longer leaves `pasteInFlight = true` when the surface is momentarily nil (e.g., during peer workspace split or close), which used to block every subsequent paste/Enter for up to 8 seconds until the watchdog fired. The flag is now cleared on the surface-nil path so the next trigger drains the queue immediately.
  - `team.delegate` now waits for an actual paste-completion ack before responding to the Rust CLI, instead of letting the CLI rely on a hard-coded 150 ms sleep. The CLI also drops its post-ack delay from 150 ms to 20 ms now that ordering is guaranteed at the Swift layer.
  - The new ack timeout is aligned with the paste watchdog (12 s ≥ 8 s watchdog + retry budget + margin) so a timeout firing first can no longer leave a stale paste queued behind a Return that the CLI already suppressed — the bug-the-fix-introduced regression that the original ack patch shipped with.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.105.0] - 2026-05-10

### Added
- **Cost-aware bulk action buttons in team creation** — three new buttons (💎 최대 성능 / ⚖️ 균형 / 💰 최소 비용) above the Agents list set every agent's tier in one click. "최대 성능" pushes everyone to `opus`, "최소 비용" drops everyone to `haiku`, and "균형" re-applies the currently selected Smart Preset's per-role tier distribution (or falls back to `sonnet` when no Smart Preset is active). Useful for dialing the session's compute budget without editing each agent row by hand.
- **Compact agent runbook digest** — `tm-agent runbook digest` returns a token-efficient role brief instead of the full runbook source, and the default agent init prompt now uses the digest. Set `TERMMESH_RUNBOOK_MODE=full` to opt back into the full source for debugging role behaviour.

### Changed
- **Codex agents now default to GPT-5.5 with tier-based reasoning effort** — the previous `gpt-5.4` and `gpt-5.1-codex-mini` identifiers are no longer accepted by current ChatGPT accounts. All three short tiers (`opus` / `sonnet` / `haiku`) now map to `gpt-5.5` and dispatch the reasoning level separately as `high` / `medium` / `low` via `-c model_reasoning_effort=…`, so tier ordering is meaningful even though the underlying model is the same.
- **Gemini agents use Gemini 3 series previews** — `gemini-3.1-pro-preview` (opus), `gemini-3-flash-preview` (sonnet), `gemini-3.1-flash-lite-preview` (haiku) replace the previously hard-coded `gemini-3.1-pro` / `gemini-3-flash` identifiers that 404'd against current accounts. The Gemini 2.5 family stays selectable as a fallback in the model picker.
- **Kiro agents use the dotted model identifier format** — `claude-opus-4.7` / `claude-sonnet-4.6` / `claude-haiku-4.5` replace the previous `claude-opus-4-6-20250618` style strings that `kiro-cli` no longer accepts.
- **Smart Presets prefer Claude over Kiro for `architect` and `infra` roles** — when both CLIs are available, Claude is the safer default; Kiro stays available as a manual choice in the picker. Affected presets: `architect`, `quality`, `aws`, `idea`, `security-audit`, `api-factory`.
- **Smart Presets' `reviewer` role is now codex/opus (high reasoning)** — code review is where the extra reasoning budget pays off the most. Affected presets: `standard`, `architect`, `fullstack`, `refactor`, `quality`, `security-audit`, `migration`.
- **Codex and Gemini model pickers show CLI-native labels** — picking the `opus` tier under codex now displays as `gpt-5.5 (high)`, under gemini as `gemini-3.1-pro-preview`. Internal storage still uses the tier name so Smart Presets and saved roles round-trip without breakage.
- **Compact task capsule protocol for `tm-agent delegate`** — delegated tasks now ship a `TM-PROTOCOL-v1` capsule instead of re-stating the full lifecycle instructions per task, freeing context budget for the actual work.

### Fixed
- **Codex reasoning effort flag is no longer injected for non-tier model identifiers** — selecting `gpt-5.3-codex` (or any other passthrough name) used to add an unwanted `-c model_reasoning_effort=medium` argument on the headless daemon spawn path. The flag is now only added for tier names that actually map to a reasoning level, matching the Swift app's existing behaviour.
- **Reviewer agent's codex model picker no longer renders empty** — Smart Presets now write `primaryModel="opus"` for the codex reviewer, the picker recognises that selection, and the row shows `gpt-5.5 (high)` instead of an empty box.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.104.1] - 2026-05-10

### Fixed
- **Stale running binary now surfaces a "Restart and Update" pill within seconds of launch** — when `brew upgrade --cask term-mesh` runs externally (manual brew CLI, multi-machine sync, the cask smoke-test that publishes a release) the disk bundle is replaced but macOS keeps the old binary mapped into any still-running term-mesh process. The 30-minute `brew outdated` poll then reports "up-to-date" (disk version equals tap latest) and the running app silently keeps executing stale code with no pill. On startup the app now compares `Bundle.main`'s cached `CFBundleShortVersionString` (frozen when the process launched) against the on-disk `Info.plist` (re-read fresh) and immediately publishes `.readyToInstall(running → disk)` when they differ — so a relaunch into the new binary is one click away regardless of how the bundle was replaced.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.104.0] - 2026-05-10

### Added
- **Agent Runbooks — per-role behavior reference for term-mesh teams** — `.agent-runbooks/<role>.md` files are now the source of truth for what each role does (architect, executor, reviewer, security, …). The `tm-agent runbook` CLI manages them: `init` writes the 23 default templates into the current project, `install --tool claude|codex|opencode|all` projects them as tool-specific skill files (e.g. `.claude/skills/term-mesh-<role>/SKILL.md`), and `status` reports whether each projection is in sync. A new "Agent Runbooks" panel in Settings exposes the same flow with one-click Init / Install / Force Repair, and team agents created via the GUI or CLI automatically receive the relevant runbook content as part of their init prompt — an `executor` agent now knows it's an executor without you reminding it every session.
- **Workflow presets in team creation** — Settings → Team Presets now offers "workflow" presets alongside the existing "smart" presets. Workflow presets bundle a role list, task templates, and review checkpoints that the dashboard auto-creates when you start a team — useful for canned multi-agent flows (build/review/ship loops). The dropdown is wider so the new presets fit without truncation.

### Fixed
- **Dark mode no longer flips back to light after a slow brew upgrade** — v0.103.3 added a `GhosttyApp` color-scheme sync at startup, but its retry budget (5 × 100 ms) ran out on sluggish brew-upgrade relaunches, leaving the terminal rendering with the light theme even though the saved appearance was Dark. The retry now schedules one final long-delay attempt (3 s) before giving up, so the slow-startup case the original fix targeted actually closes.
- **Sidebar tint follows the saved appearance from the first frame** — when SwiftUI's environment color scheme had not yet propagated (the same brew-upgrade window where the terminal was light), the sidebar would render with the configured white tint while everything else was already dark. The sidebar now reads the user's explicit appearance preference directly and only falls through to SwiftUI's environment when the user has chosen "System".
- **`tm-agent team create` agents finally receive their runbook content** — the socket parameter that carried the "include runbook in init prompt" intent was wired to its own inverse on the Swift side, so CLI-created teams were silently spawning with bare instructions and no role context. The wiring now matches the parameter name, so `tm-agent team create` actually injects the runbook into the agent's first prompt.
- **Editing a managed `.agent-runbooks/<role>.md` file no longer gets clobbered on `tm-agent runbook install`** — the installer was treating the marker line at the top of each file as "still default, regenerate", so any edits below it were silently overwritten by the built-in defaults the next time you ran install. The installer now reads the on-disk content (the same way `tm-agent runbook status` does), so edits propagate into the projected skill files instead of looping "outdated → install → still outdated" without `--force`.

### Security
- **`tm-agent` binary lookup no longer searches the project's working directory in Release builds** — the runbook installer used to prefer `<projectRoot>/daemon/target/release/tm-agent` over the signed app bundle. A repository with a planted binary at that path would have been executed under the term-mesh app's privileges the moment the user clicked Init / Install / Force Repair in runbook Settings. Release builds now resolve only from the bundled `Contents/Resources/bin/tm-agent` and Homebrew/system paths; the project-relative candidates are kept only in DEBUG builds for development convenience. The `/usr/bin/env tm-agent` PATH-search fallback was also removed — when no known binary is found, the UI surfaces an explicit error instead of silently following `$PATH`.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.103.3] - 2026-05-10

### Added
- **Cmd+Shift+Return zooms a single pane to fill the relay window** — peer-relay workspace windows now honour the same "Zoom Pane" shortcut as local windows. The focused pane expands to occupy the full relay window, hiding all the other panes; pressing Cmd+Shift+Return again restores the original split tree. The zoom is purely local — the host workspace and any other relay clients are untouched. Useful when a remote split has too many panes to read comfortably and you want to focus on one without resizing the window or asking the host to rearrange.

### Fixed
- **Shift+Return inserts a real newline in remote multi-line input fields (codex, Claude Code, jupyter, …)** — when the local Ghostty has the Kitty keyboard protocol enabled it encodes Shift+Return as `CSI 13 ; 2 u`. The remote shell / TUI rarely shares that mode and was printing `[13;2u` verbatim into whatever multi-line input field was open. The peer-relay filter now translates Shift+Return to a literal LF (`\n`) before forwarding, which every text-input field treats as "insert newline".

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.103.2] - 2026-05-10

### Fixed
- **Codex (and other Kitty-keyboard TUIs) no longer receive ghost double-fire keystrokes through the peer relay** — when the local relay terminal had Kitty's keyboard protocol enabled in "report all events" mode, every key press was followed by a release event encoded as `CSI <key>;<mods>:3 <final>` (e.g. `\x1B[97;1:3u` for `a` release, `\x1B[1;1:3B` for ↓ release). The relay's filter only understood event-type-1 (press) and was forwarding the release events as a second keystroke, so menu selections in `codex` jumped two rows per keypress, Esc closed dialogs twice, and Ctrl-C arrived as `^C` plus a literal `[27;1:3u`. The relay now parses the `:event_type` field on both `CSI ... u` and Kitty special-key sequences (arrows, Page/Home/End, function keys) and drops release events while still translating presses and auto-repeats correctly.
- **Kitty keyboard protocol state reports stop polluting the host shell** — when a remote TUI queried the local relay terminal's keyboard mode with `CSI ? u`, Ghostty answered with `\x1B[?7u` (or similar) and the relay forwarded the answer back to the remote shell as typed input, so users saw stray `[?7u` literals appear in their `codex` prompt or the host's zsh after closing a TUI. The filter now classifies the `CSI ? <flags> u` response as terminal-generated and drops it, including when the response is split across two reads (`\x1B` then `[?7u`).
- **Connections panel now lists every active peer connection, not just workspace windows** — opening a peer console (debug socket) or a single-pane peer attach left the Connections panel empty even though the connection was live, so there was no UI affordance to disconnect it without closing the window manually. The panel now shows Console, Pane, and Workspace connections in one open-order list and the "Disconnect" button works for all three.

### Changed
- **Peer windows have a coloured titlebar accent** — peer relay panes, workspace windows, and the debug console now render a pink-to-blue gradient strip across the titlebar so they're visually distinct from local Ghostty windows at a glance. The accent reinstalls itself on `show()` so it survives window-merge / fullscreen transitions.
- **Connections panel grew a "Type" column and a wider Host column** — host display now prefixes SSH targets with `SSH ·` and falls back to the peer's advertised display name before the raw socket path, so it's easier to tell apart multiple peers at a glance. Window default width is 660 pt to fit the new layout.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.103.1] - 2026-05-09

### Fixed
- **Tab, Enter, Escape, and Backspace work in peer relay panes when Ghostty's keyboard protocol is active** — Ghostty encodes some unmodified control keys as `CSI <codepoint> u` (e.g. `\x1B[9u` for Tab, `\x1B[27u` for Escape) instead of the bare control byte. The relay was passing these through verbatim, so the remote shell saw `\x1b[9u` as literal text instead of a tab character; navigation in `vim`, `less`, and any TUI that reads raw stdin was broken. The relay now translates `CSI 9u` / `CSI 13u` / `CSI 27u` / `CSI 127u` to `\t` / `\r` / `\x1b` / `\x7f` before forwarding.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.103.0] - 2026-05-09

### Fixed
- **TUIs in peer relay panes no longer leak terminal-control responses to the remote shell** — `gk`, `vim`, `less`, etc. probe the terminal at startup with OSC/CSI queries (background colour, cursor position, device attributes). The local Ghostty answered those queries per spec, but the relay was forwarding the answers as user keystrokes — they arrived at the remote shell *after* the originating program had already exited and zsh treated them as commands (`zsh: command not found: 11`, `no such file or directory: rgb:0d0d/1111/17177`). The relay now runs a stateful filter on its stdin that drops OSC 4/10–19 (colour reports), OSC 52/5522 (clipboard reads), CSI cursor-position / status / device-attribute / focus replies, and translates Kitty CSI-u Ctrl-letter sequences (including Korean IME jamo) to the proper control byte before forwarding to the host.
- **OSC 52 clipboard contents no longer leak to peer hosts** — a malicious or compromised peer host could emit `OSC 52 ; c ; ?` to query the local terminal's clipboard; Ghostty would answer with the BASE64 contents, which the previous filter happily forwarded as typed input. The relay now drops every OSC 52 reply unconditionally.
- **Terminal replies split across read boundaries no longer slip through the relay filter** — when stdin returned `\x1B` and `[2;1R` in two separate reads (normal under PTY chunking), the filter used to flush the lone ESC and forward the rest as ordinary input. The state machine now holds pending escapes across reads, with a 100 ms `poll(2)` timeout so a user-typed Escape with no follow-up still reaches the host promptly.
- **Focus-tracking events stop polluting the host shell** — when a remote full-screen app turned on focus tracking, the local terminal's `\x1B[I` / `\x1B[O` events were forwarded as `[I` / `[O` literals into the remote prompt. The relay now classifies these as terminal-generated and drops them.
- **Korean Ctrl-key presses reach the remote shell as the right control byte** — when the Korean 2-set IME was active, Ctrl-C / Ctrl-A / etc. arrived at the relay as Kitty CSI-u sequences with Hangul jamo codepoints (`\x1B[12618;5u` for ㅊ on the C key) and were passed through unchanged; the remote shell saw the raw escape instead of `^C`. The relay now translates these to the QWERTY-equivalent control byte before forwarding.
- **Peer relay panes keep host-window keyboard focus** — peer focus pushes from the host used to steal the user's keyboard focus into the relay window even when they were typing in another app. The provider now updates the visual focus indicator without calling `makeFirstResponder`.
- **Pane focus follows the click in workspace relay windows** — clicking a pane in a multi-pane relay used to keep focus on whichever pane was last attached. The workspace controller now hit-tests the click against the actual pane geometry and restores focus after layout swaps.

### Changed
- **Peer host menu prefills the connect dialog with the current socket path** — if you've changed the daemon socket path away from the default, the connect / configure dialogs now start from the value already in use instead of always showing the default. Custom socket paths persist across app launches.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.102.9] - 2026-05-09

### Fixed
- **Peer relay panes no longer hang silently when the remote machine sleeps, the daemon pauses, or the network drops** — v0.102.8's reconnect overlay only fired when the SSH tunnel itself died. That left a much bigger gap: a remote laptop sleeping with its lid closed (the most common case), a paused/deadlocked daemon, or a Wi-Fi/VPN switch where the kernel hadn't yet seen a TCP RST all left the kernel believing the connection was alive — `read()` would block forever and macOS's default 2-hour TCP keepalive was the only thing that would eventually notice. Term-mesh now sends an application-level Ping every 10 s on every active peer session, expects a Pong back within 30 s, and on miss closes the transport so the existing reconnect overlay fires within seconds instead of leaving the user staring at an unresponsive terminal.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.102.8] - 2026-05-09

### Fixed
- **Peer relay over SSH no longer pollutes the remote shell with `command not found: 11` and similar nonsense after running TUIs like `gk`, `vim`, or `less`** — TUIs probe the terminal at startup with control sequences such as `CSI 6n` (cursor position) and `OSC 11 ?` (background colour). Until now the bytes flowed straight through to the local Ghostty, which answered per spec; the answer then made the round trip back over SSH and arrived at the remote PTY *after* the querying program had already exited, so it landed in zsh's prompt and zsh tried to execute it ("`zsh: command not found: 11`", "`no such file or directory: rgb:0d0d/1111/17177`"). The daemon now intercepts the queries (DA1/DA2/DA3, DSR-status, DSR-CPR, OSC 10/11) at the PTY boundary, writes a synthesised reply straight back to the PTY master so the originating program reads it on stdin without a relay round trip, and strips the query from the broadcast so the local terminal never sees it ([#20](https://github.com/x-mesh/term-mesh/pull/20)).
- **Peer relay panes no longer go silent after the remote daemon restarts, the remote machine sleeps/wakes, or the SSH session closes** — when the peer session ended while the SSH tunnel itself was still up (the common "Mac slept and woke", "remote daemon restarted", "vpn flapped" cases), the workspace window quietly displayed nothing with no indication that the connection was gone. A status overlay now appears for `down` / `reconnecting` / `failed` transitions with a Reconnect action; in the session-ended-while-tunnel-alive case the workspace also tears the SSH tunnel down and re-establishes it via the normal reconnect loop, so a sleeping laptop reattaching is handled automatically.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.102.7] - 2026-05-09

### Fixed
- **Peer host menu no longer stacks duplicate "Start Peer Server…" sheets when clicked twice** — clicking Start (or hitting the hotkey) while the start sheet was already up could either present a second sheet underneath the first or silently drop the action. The menu actions now track whether a sheet is up and bail out cleanly instead of stacking, and any "info" alert (already running / starting / stopping / no server) is also de-duplicated.
- **Stopping the peer server while it was still finishing startup no longer leaves the coordinator in a wedged state** — race between menu Stop and the in-flight `bringUp` could leave `server` as `nil` while the bonjour publisher and layout bridge stayed installed. The coordinator is now driven by an explicit `.stopped/.starting/.running/.stopping` lifecycle so every transition cleans up the same way and a stop in the middle of starting just no-ops with a sheet asking the user to wait.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.102.6] - 2026-05-09

### Fixed
- **Ctrl-C now interrupts foreground commands inside a peer relay pane** — pressing Ctrl-C in a remote peer pane (the kind opened from another machine over SSH) was sometimes leaving the foreground process running. The Ghostty key encoder, in some host states, was turning the ETX byte (`0x03`) into keyboard-protocol text that the remote PTY's line discipline never recognised as SIGINT, so `sleep`, `tail -f`, REPLs, etc. kept running until you closed the pane. The relay path now forwards `0x03` raw to the PTY, bypassing the encoder, so Ctrl-C reaches the foreground process the way the local terminal does ([#17](https://github.com/x-mesh/term-mesh/pull/17)).
- **Peer relay over SSH no longer reports "connection lost" while the connection is actually fine** — when an OpenSSH `ControlMaster` was already running for the same host, the forwarded Unix-socket request would be answered by the master and the spawned `ssh` process would exit immediately. The local socket appeared, so the upper layer thought the tunnel was up, but a few seconds later it would tear down and retry, surfacing as a flapping "reconnecting…" banner. Managed peer tunnels now pass `-S none -o ControlMaster=no -o ControlPersist=no` to opt out of multiplexing, and the tunnel is only marked healthy after the spawned `ssh` process is confirmed alive *after* the local socket appears, so a stale-socket scenario surfaces as a clean spawn failure instead of a phantom reconnect ([#17](https://github.com/x-mesh/term-mesh/pull/17)).
- **Attaching to an existing peer pane no longer shows a blank terminal until you press a key** — when a second client attached to a surface that had already produced output (a shell prompt, a long-running `tail`, a previous command's result), the new client would see nothing until fresh bytes arrived, because the daemon only broadcast newly-written PTY bytes. The daemon now keeps a 64 KB ring buffer of recent PTY output per surface and replays the snapshot on attach (deduped against live broadcast via byte-sequence numbers), so the new pane shows the current screen state immediately ([#17](https://github.com/x-mesh/term-mesh/pull/17)).

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.102.5] - 2026-05-09

### Fixed
- **Peer relay no longer fails with "relay binary not found" on any machine other than the developer's** — `term-mesh-peer-relay` (the Ghostty PTY shim spawned for every remote peer pane) was never actually copied into the shipped `.app` bundle: every `make deploy` / `make dmg` target only copied `term-meshd`, `term-mesh-run`, and `tm-agent`. Worse, `PeerRelaySession.findRelayBinary()` carried a hardcoded `/Users/jinwoo/...` dev fallback, so the developer's machine masked the bug while every brew user hit it the moment they tried to open a peer pane (locally or over SSH). Fix: bundle the relay binary alongside the other Rust binaries under `Contents/Resources/bin/`, switch the Swift lookup to that location (with a DerivedData-derived dev fallback that works for any contributor), drop the hardcoded user path, and add `verify-daemon-binaries` + `scripts/check-bundle-binaries.sh` guards to the build so the next workspace member that gets added can't be silently dropped from the bundle the same way.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.102.4] - 2026-05-08

### Changed
- Release pipeline verification build — exercises the full in-app update path end-to-end (brew outdated detection, helper-driven `brew upgrade --cask`, relaunch) on top of the v0.102.3 ghostty rollback. No code changes other than the version bump.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.102.3] - 2026-05-08

### Fixed
- **App no longer crashes on launch with `KERN_INVALID_ADDRESS` in `ghostty_config_get`** — v0.102.2 bumped the ghostty submodule to a SHA cherry-picked onto a much newer fork/main (1298 commits ahead of the prior base). The resulting GhosttyKit ABI was incompatible with our Swift bindings and any first window that became first responder crashed in `ghostty_config_get` during `ensureSurfaceReadyForInput`, blocking app launch entirely. Roll the submodule back to the SHA shipped with v0.102.1 (`c6e5476a`) where the PTY tap callback works without ABI drift; the PeerSSHTunnel ghost-socket fix and BrewSelfUpdater outdated-exit fix from v0.102.1 / v0.102.2 are preserved on top of this base.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.102.2] - 2026-05-08

### Fixed
- **In-app "Check for Updates" no longer fails with "Update Failed" when an update is actually available** — `brew outdated --cask --json=v2 <token>` exits with code 1 (with valid JSON on stdout) when the cask is outdated and 0 when up-to-date. The previous Process wrapper treated any non-zero exit as failure, so users on 0.102.0 saw "Update Failed" with the JSON payload bleeding through as the error message — exactly the condition the check was trying to detect, mistaken for a runtime error. The wrapper now accepts `{0, 1}` for the outdated check and relies on the JSON shape for the actual decision.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.102.1] - 2026-05-08

### Fixed
- **Peer relay/socket connect no longer silently fails after a previous app crash** — If the app exited abnormally while a peer SSH tunnel was up, the local listen socket file at `/tmp/tm-peer-ssh-*.sock` could end up unlinked while the ssh subprocess (now reparented to launchd) kept the unix socket bound in the kernel. New connect attempts saw `ENOENT` even though `lsof` still listed the socket — relay and direct socket connects both failed with no error surfaced. Term-mesh now (a) waits for ssh to actually exit before unlinking the socket file in `stop()`, with a 2 s SIGTERM grace and 1 s SIGKILL escalation, (b) sweeps `/tmp/tm-peer-ssh-*.sock` and orphan ssh subprocesses on launch using owner-PID gating so sibling app instances (DEV / STAGING / Release running side-by-side) never reap each other's live tunnels, and (c) embeds the owning app's PID in the listen socket filename to make that gate possible.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.102.0] - 2026-05-08

### Removed
- **Sparkle is gone** — the appcast feed has been 404 for some time and was producing `SUDownloadError (2001)` dialogs every time the user clicked `Check for Updates…`. The Sparkle SDK is no longer linked, the Sparkle public key and feed URL are out of `Info.plist`, and the three SPUUpdater shim files (`UpdateController.swift`, `UpdateDelegate.swift`, `UpdateDriver.swift`, ~720 lines combined) are gone. brew has been the actual update channel since 0.100.0; this just makes that explicit. No user action needed.

### Changed
- **`Check for Updates…` now gives you an actual answer** — the manual click was running silently in the background; you'd only see a pill if there was already an update sitting around. The titlebar pill now shows `Checking…` the moment you click, holds for at least 0.8 seconds so you can register that something happened, then transitions to either `Up to date` (which fades after 5 seconds) or `Update Available: X.Y.Z`. The 30-minute background poll is unchanged.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.101.2] - 2026-05-08

### Fixed
- **`Check for Updates…` no longer surfaces a Sparkle download error** — the manual menu click was firing both Sparkle and the brew self-updater. Sparkle's appcast feed has been unreachable for a while (the configured host returns 404), so each click produced a `SUDownloadError (2001)` dialog even though brew was happily picking up the new version in the background. The manual click now only runs the brew check; Sparkle's install path (`applyUpdateIfAvailable`) is left in place for the rare case its feed comes back online.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.101.1] - 2026-05-08

### Fixed
- **`Check for Updates…` menu now actually finds new versions** — the manual click was calling the brew updater's `checkNow()` path, which runs `brew outdated` against the locally cached tap state and skips `brew update`. If the tap was stale (the common case right after a release that the user wants to install), no new version was visible and the click silently did nothing. Manual click now goes through `refreshNow()` so the tap is refreshed before the version comparison. The 30-minute background poll is unchanged — it still uses `checkNow()` to avoid `brew update` thrashing.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.101.0] - 2026-05-08

### Fixed
- **Peer relay SSH first-connect no longer hangs** — Connecting a relay to a Mac whose host key isn't in `~/.ssh/known_hosts` previously stopped at the SSH "Are you sure you want to continue connecting (yes/no/[fingerprint])?" prompt with no way to answer from inside term-mesh. The tunnel now passes `-o StrictHostKeyChecking=accept-new` so brand-new hosts are auto-registered (TOFU) while changed keys are still rejected, and `-o BatchMode=no` keeps password fallback available when public-key auth isn't.
- **Peer relay window split (Cmd+D) actually splits now** — Three silent-fail paths were eating the keypress: `dispatchSplit` returned with no log when the subscription session was still nil, `GHOSTTY_ACTION_NEW_SPLIT` routed relay surfaces through `tabManager.newSplit(tabId: UUID())` (random UUID, no matching tab), and the relay window's keyMonitor only installed after the subscription handshake. Cmd+D during the handshake now stays inside the relay controller, the GhosttyApp action short-circuits for relay windows so the split goes through `dispatchSplit`, and a DEBUG `relay.split.skip` dlog surfaces a refusal when a split is genuinely unavailable.
- **Multi-pane broadcasts no longer strand peers at `[Pasted text #1]`** — When `tm-agent broadcast` (or any 3+ simultaneous deliveries) arrived faster than the previous Return retry could finish, four out of five surfaces could end up with the pasted text but no Enter — a `sendIMEText` reentrancy where the second paste hit `false` and the daemon's Return RPC was skipped. Replaced with a per-surface FIFO paste queue (depth 16, oldest-drop with a Sentry breadcrumb) that drains on the main actor, a `pasteGeneration` cancellation token that prevents async retry double-completion, and a finalize watchdog so a wedged surface never holds the queue forever. Return retry shortened from `[0.2, 0.5, 1.0, 5.0, 25.0]s` to `[0.2, 0.5, 1.0, 2.0, 3.0]s` so one bad delivery no longer parks the queue for 25 seconds.

### Security
- **Daemon control socket is now owner-only** — `daemon/term-meshd` previously bound the local control socket without a tight umask, so the file could end up at 0o660 (group-readable/writable). The bind now runs under `umask 0o077`, the socket is force-set to 0o600 after creation, and the accept loop adds a `LOCAL_PEERCRED` (macOS) / `SO_PEERCRED` (Linux) UID match — connections from a different UID are dropped with a warn log instead of being served. Mirrors the hardening already applied to the peer relay socket in 0.99.0.
- **Peer relay handshake gets bounded reads** — `acceptRelay()` now sets `SO_RCVTIMEO = 5s` after the non-blocking accept polls finish, so a peer that opens the socket and never sends bytes can't park a relay handshake task indefinitely. The auth-frame size is capped at 256 bytes (down from the 1 MiB read-frame ceiling) before `verifyRelaySecret`, blocking pre-auth allocation amplification.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.100.0] - 2026-05-08

### Added
- **Homebrew cask self-updater** — installs done via `brew install --cask x-mesh/tap/term-mesh` now check for new cask versions every 30 minutes, pre-fetch the next release in the background via `brew fetch`, and surface an "Update Available" pill in the right side of the titlebar. A matching "Restart and Update term-mesh" entry appears in the menu bar once the download is ready. Confirming the update opens an alert that renders the GitHub release notes inline (headings, bullets, links); accepting it quits the app, runs `brew upgrade --cask --force term-mesh` via a detached helper script, and relaunches automatically with focus restored. The standard `Check for Updates…` menu item now triggers a brew check alongside Sparkle in the same click.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.99.1] - 2026-05-07

### Fixed
- **App Hang false positives gone** — the 3-second titlebar refresh timer no longer trips Sentry's hang detector during foreground/background transitions. The timer now skips entirely when the app isn't active, coalesces with other titlebar-relevant events, and snapshots the workspace's published state in a single pass instead of repeatedly entering each `@Published` keypath under the runtime exclusivity check.
- **Modal alerts no longer block the main run loop** — peer-federation, browser, workspace, and tab dialogs that still used `NSAlert.runModal()` now present as window-attached sheets via `presentAsSheet`. The main thread keeps ticking while a dialog is up, so legitimate user interaction doesn't show up in Sentry as a fake App Hang.
- **Hang detector tolerates legitimate AppKit waits** — Sentry's `appHangTimeoutInterval` raised to 10s in DEBUG / 5s in Release so brief filesystem / Bonjour / SwiftUI rebuild stalls don't get reported as hangs.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.99.0] - 2026-05-07

### Added
- **Peer Federation** — attach another Mac's term-mesh from the status-bar menu (SSH or local Unix socket), mirror its workspace's split layout in a Ghostty relay window, and drive everything from your client: Cmd+D / Cmd+Shift+D split, Cmd+W close, Cmd+T new tab, divider drag, click-to-focus, in-relay tab strip for switching between tabs of the same pane. Supports multiple concurrent clients per host pane (count badge on the teal ring shows how many are attached). New "Show Peer Connections…" panel lists active relay windows with per-row Disconnect.
- **SSH transport with auto-reconnect** — `ssh -L`-tunneled relay survives sleep/wake, server reboots, and transient network blips with exponential backoff (1s → 30s, 12-attempt cap before a Retry-banner stop). The relay window's title and an in-window banner show live state: 🔌 Disconnected / Reconnecting (try N…) / Reconnected.
- **Bonjour LAN discovery** — hosts with the peer server enabled advertise themselves; the connect dialog has a live "Discovered on LAN" picker plus a recent-hosts dropdown so reconnecting is one keystroke.
- **Settings → Peer Federation** — toggle the local peer server, enable auto-start at app launch, override the socket path / display name, and opt in to "Force TUI redraw on attach" (sends Ctrl-L when a peer attaches so vim / htop / less repaint with full color).
- **Status-bar peer indicator** — small blue dot on the menu-bar icon when the local peer server is running.

### Security
- Local peer socket gated by `LOCAL_PEERCRED` (Darwin) / `SO_PEERCRED` (Linux) UID match on accept; bind runs under `umask 0o077` so the socket is created at 0600 with no TOCTOU window. Parent directory is forced to 0700 and ownership-checked, with sticky-bit world-writable parents (`/tmp`) explicitly accepted as a special case. SSH target / remote-socket validation rejects option-injection inputs (leading `-`, embedded `:`) before they reach `Process`. Relay handshake secret compared in constant time, auth nonces from a CSPRNG (`SecRandomCopyBytes` / `getrandom`) instead of UUIDv4 concatenation.

### Fixed
- **Connect dialogs no longer trip the App-Hang detector** — the SSH connect, workspace picker, surface picker, and error dialogs now present as window-attached sheets via `beginSheetModal(for:)` instead of `NSAlert.runModal()`. The main run loop is no longer parked in `mach_msg2_trap` while a dialog is up, eliminating the false-positive "App Hanging" Sentry events that the modal pattern produced.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.98.2] - 2026-04-22

No user-visible changes. Release-flow validation build — exercises the end-to-end `/release` pipeline introduced in v0.98.1 (DMG build → GitHub Release asset upload → Homebrew cask auto-update in `x-mesh/homebrew-tap`) and verifies `brew upgrade --cask term-mesh` picks up the new version without manual intervention.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.98.1] - 2026-04-22

### Added
- **Homebrew cask install path** — term-mesh is now available via the `x-mesh/tap` Homebrew tap. Install with `brew install --cask x-mesh/tap/term-mesh`; upgrade with `brew upgrade --cask term-mesh`. The cask strips the Gatekeeper quarantine attribute automatically on install and upgrade, so the unsigned DMG launches without a manual `xattr` step.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.98.0] - 2026-04-20

No user-visible changes. Internal release-tooling update only: `/release` now tags the squash-merge SHA on `main` and checks out that tag before building the dSYM, so Sentry debug symbols always match the released binary (previously a divergent local `main` could let an older build upload its dSYMs under the new tag's name).

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.97.0] - 2026-04-20

### Fixed
- **Restored sessions no longer collapse every pane to the same working directory** — when multiple split panes were open in different directories, quitting and relaunching term-mesh used to reopen every pane in a single shared cwd (the last-focused pane's directory). Per-pane working directories are now snapshotted at save time and each restored pane's shell launches in its original directory. Paths that no longer exist fall back to the workspace directory (or `$HOME`) so the shell still opens cleanly.
- **Secondary windows' titlebar no longer freezes in dark mode under light system appearance** — windows opened via Cmd+N or the app menu did not inject the current ghostty background theme into their SwiftUI environment, so their chrome used `GhosttyTheme.default` (hardcoded black) and ignored later light/dark transitions. Secondary windows now own a live `@State ghosttyTheme` and subscribe to `ghosttyDefaultBackgroundDidChange`, matching the primary window's behavior.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.96.0] - 2026-04-19

### Fixed
- **New windows no longer duplicate the primary window's restored session** — `TabManager.init` used to re-run session restore for every new window whose `initialWorkingDirectory` was `nil`, so opening a second term-mesh window brought up the same workspaces as the first one (the saved session, restored twice). Session restore is now an explicit opt-in: only the primary window created at launch by `TermMeshApp` passes `restoreSavedSession: true`. Secondary windows opened via the app menu, Cmd+N, or the dock start with a single fresh workspace, so they no longer shadow the primary window's tabs.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.95.0] - 2026-04-17

### Fixed
- **Ctrl+C no longer leaks `9;5u` text after a TUI app crashes or is killed** — TUI apps (Claude Code CLI, nvim, helix, etc.) enable the kitty keyboard protocol's "disambiguate escape codes" mode via `CSI > 1 u` on startup and are expected to disable it via `CSI < u` on exit. If the app crashed, was force-quit, or exited abnormally (for example after an API error during `/compact`), the flags remained on the terminal's protocol stack, causing the next Ctrl+C at the shell prompt to be encoded as `\e[99;5u` — which the shell would then echo to the screen as `9;5u9;5u9;5u…` instead of delivering SIGINT. term-mesh's zsh and bash shell integration now automatically pops any leftover kitty keyboard flags on every prompt render, so Ctrl+C recovers cleanly on the very next prompt without any user configuration or terminal restart. Running TUIs are unaffected because they re-push their flags on each prompt cycle.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.94.0] - 2026-04-17

### Fixed
- **Observer/NSAlert leak when two deferred alerts race for the same key-window transition** — the v0.93.3 fix for the notification-permission App Hanging warning (Sentry TERM-MESH-18) installed a one-shot `NSWindow.didBecomeKeyNotification` observer to wait for a key window before presenting the sheet. If two alerts queued before any window was focused (e.g. permission prompt + quit warning while the app was activated from the menu bar) and a window then became key, the first observer would attach its sheet and the second observer fell through its guard without deregistering — leaking the observer, the `NSAlert`, and its completion closure for the remainder of the session. A Settings/About window with an attached sheet could also silently swallow an alert intended for a terminal window. The observer now re-registers cleanly when the key window already has a sheet attached, so the alert still surfaces on the next key-window transition without leaking.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.93.3] - 2026-04-17

### Fixed
- **App hang when opening a terminal whose last working directory is on a stalled filesystem** — if the previous working directory (OSC 7 / session snapshot) pointed at an unmounted network share, a spun-down external drive, or a broken SSHFS, Ghostty's internal `openat(workingDir)` during surface creation blocked the main thread for 2 s+ and tripped macOS's App Hanging watchdog (Sentry TERM-MESH-17). The working directory is now probed on a background queue with a 300 ms timeout before handing it to Ghostty; an unreachable path falls back to `$HOME` so a new terminal always opens immediately.
- **App hang when the notification-permission prompt appeared without a focused window** — `TerminalNotificationStore.promptToEnableNotifications` falls through `NSAlert.presentAsSheet` to a fallback path when no key/main window is available. That fallback used `runModal()`, which spins a nested modal event loop on the main thread and trips the App Hanging watchdog if the app is activated from the menu bar / background with no visible window (Sentry TERM-MESH-18). The fallback now defers presentation via a one-shot `NSWindow.didBecomeKeyNotification` observer — the sheet shows as soon as any window becomes key, without ever blocking main.
- **Possible app hang during SwiftUI layout involving drag-and-drop** — `FileDropOverlayView.hitTest` used to read `NSPasteboard(name: .drag).types` on every AppKit hit test, including idle-layout probes that run outside any active drag. If a prior external (Finder) drag left an `NSFilePromiseReceiver` on the drag pasteboard, macOS could wake the receiver during that probe and stall the main thread (Sentry TERM-MESH-19). The pasteboard read is now gated on an active drag-motion event; idle layout no longer touches the drag pasteboard at all. No behavior change for real drags.
- **New windows no longer stack on top of the previously-focused window** — `LastWindowPosition.restore()` used to apply the saved window position to every new window, so each new window jumped to the position of the most recently focused window and the cascade logic only offset it slightly. It now restores only the first window per app launch; subsequent new windows cascade from fresh positions. (ghostty submodule)

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.93.2] - 2026-04-16

### Fixed
- **`claude` wrapper `stop` / `notification` hooks no longer surface "Tab not found" errors to Claude Code's Stop hook log** — `term-mesh claude stop` / `claude notification` are best-effort telemetry auto-injected by the wrapper; stale session mappings (tab closed/renamed between launches, or `claude -p` subprocesses with stale workspace IDs) previously bubbled up as hook failures and spammed Claude Code's hook log. Workspace resolve failures and `notify_target` errors in the `stop`, `idle`, and `notification` subcommands are now caught and the hook returns `OK` instead of throwing. (`CLI/term-mesh.swift`)
- **`make dmg` no longer fails on stale `/Volumes/term-mesh` mounts or leftover `rw.*.dmg` intermediates** — repeated DMG builds in the same session could hit "resource busy" when a previous `/Volumes/term-mesh` mount hadn't been detached, and `create-dmg` occasionally leaves the read-write intermediate behind when Finder's detach is slow. `make dmg` now force-detaches any lingering `/Volumes/term-mesh` before and after `create-dmg` and removes `rw.*.term-mesh.dmg` intermediates so only the final UDZO image remains. (`Makefile`)

## [0.93.1] - 2026-04-15

### Fixed
- **App hang during periodic session save** — `TabManager.saveSessionState()` is called every 30 s and on tab/split churn; previously it ran JSON encoding and an `atomicWrite` on the main thread. The `rename()` behind `atomicWrite` triggers FSEvents/Darwin notify, and under file-watcher pressure this could block main for 2 s+ (Sentry TERM-MESH-2). Session snapshot is still captured on main (required by `@MainActor` isolation), but encoding and the disk write now run on a dedicated serial background queue.
- **Garbled terminal output when SSHing to servers without `xterm-ghostty` terminfo** — Ghostty defaults `TERM=xterm-ghostty`, which most remote hosts don't have. Shell redraw sequences were mis-interpreted, making every keystroke look like it echoed the previous autosuggestion. term-mesh now writes a baseline Ghostty config that enables `shell-integration-features = ssh-env,ssh-terminfo` out of the box; this installs the terminfo on the remote the first time you connect (falls back to `xterm-256color` if `tic` is unavailable). The baseline is loaded before the user config, so `~/.config/ghostty/config` can still override it.

### Changed
- **CLI symlinks moved from `~/bin` to `~/.local/bin`** — `make deploy` / `make deploy-prod` used to fail on machines without `~/bin` (the directory isn't created by default on macOS, and isn't on PATH in most default shell setups). Symlinks now go to `~/.local/bin`, which matches the XDG convention and is already on PATH for common setups. The Makefile creates the directory if it's missing.
- **Sentry dSYM upload is automatic on Release builds** — `make prod` / `make deploy-prod` / `make dmg` now run `sentry-cli debug-files upload --include-sources` at the end of the build. No-ops gracefully if `sentry-cli` is missing, unauthenticated, or no dSYMs are present, so unsigned-in contributors aren't blocked. Crash/hang reports from here on will be symbolicated with Swift file:line + source snippets.

## [0.93.0] - 2026-04-09

### Added
- **`tm-agent attach` / `tm-agent detach` — workspace-local agent management** — Add or remove agent panes inside the caller's current workspace without spawning a new one. First `attach` auto-creates a workspace-local team (`ws-<first8hex>` derived from the workspace UUID) and adopts the caller's pane as the team leader; subsequent attaches append agents to the same team. `detach <agent_name>` closes that agent's pane and removes it from the team; the last detach destroys the team while preserving the leader pane. Rejected if the workspace already hosts a `tm-agent create`-based team, so workspace-local and create-spawned teams never mix. `tm-agent create` behavior is unchanged.
- **`buildAgentPaneEnv` helper (single source of truth for agent pane env)** — Extracted from `createTeam` into `TeamOrchestrator.buildAgentPaneEnv(teamName:agentName:agentCli:windowId:workspaceId:)` so the workspace-local attach path and the existing create path construct the exact same agent environment. Guards against the 2026-03-19 regression where `TERMMESH_WINDOW_ID` / `TERMMESH_WORKSPACE_ID` went missing on spawned panes.
- **`addAgentPaneToWorkspace` helper (shared pane construction)** — Also extracted from `createTeam`, encapsulates the full CLI-specific invocation build (claude/codex/gemini/kiro), shell wrapping with worktree `cd`, env injection, split pane spawn, pane title, and `AgentMember` construction. Used by both `createTeam`'s agent loop and the new `attachToWorkspace`.
- **New JSON-RPC methods `team.attach` / `team.detach`** — Route through `dispatchTeamCommandAsync` and reuse `asyncTeamCreate`'s TabManager resolution precedence (`window_id` → `surface_id` → `workspace_id` → keyWindow) to prevent the 2026-03-17 multi-window routing regression. Both handlers run off-main with minimal `await MainActor.run` blocks and contain no `DispatchQueue.main.sync`.
- **Rust CLI `Commands::Attach` / `Commands::Detach`** — Auto-derive the team name from `TERMMESH_WORKSPACE_ID` via `resolve_workspace_team_name` when `TERMMESH_TEAM` is unset, validate agent names against `^[a-zA-Z0-9_-]{1,32}$` via `validate_agent_name`, and require `TERMMESH_PANEL_ID` / `TERMMESH_WORKSPACE_ID` context via `require_termmesh_context`. Errors surface with structured codes: `existing_gui_team`, `agent_name_conflict`, `team_not_found`, `agent_not_found`, `not_in_workspace`.
- **`tm-agent` Claude Code skill bundle** — `skills/tm-agent/SKILL.md` (328 lines) ships alongside `term-mesh`, `term-mesh-browser`, `term-mesh-debug-windows`, and `release`. Covers the full `tm-agent` CLI surface (create/attach/detach, messaging, task board, autonomous research/solve/consensus/swarm) with four end-to-end workflow examples, an invariants-and-gotchas section (socket focus policy, main-thread policy, adopted leader, send stagger, reply truncation), and a raw-RPC escape hatch.
- **CLAUDE.md `attach` / `detach` quick reference** — "Team agent system" section gains `tm-agent attach <type>` / `tm-agent detach <name>` examples noting the current-workspace-only semantics.

## [0.92.0] - 2026-04-09

### Added
- **`term-mesh-cli` Claude Code skill** — bundled skill teaches Claude (when running inside term-mesh) how to open browser splits, evaluate JavaScript in browser panels, navigate/click pages, and manage workspaces/panes via the `term-mesh` CLI. Build phase copies the skill into `Resources/claude-skills/` with a managed-file marker; `ClaudeCommandInstaller` installs it to `~/.claude/skills/` on launch and respects user-customized files.
- **README CLI usage section** — full command reference for window, workspace, surface, pane, browser, and team subcommands with worked examples.

### Changed
- **Slash command documentation refinements** — `.claude/commands/tm-op.md` extracted shared Result Collection block, added precedence rule for `--preset`/`--timeout`/`--rounds`, documented `tm-agent` binary fallback, added Autonomous Mode error-recovery subsection, defined stigmergy concept, and replaced literal `my-team` placeholders with `<team>`. `team-up.md` deduplicated command tables (links to `team.md` as canonical reference) and hoisted CRITICAL warning to top. `tm-bench.md` added explicit "Argument Parsing Precedence" section with worked examples for `agent N` + flag combinations.
- **Settings dashboard no longer auto-restarts daemon** — toggle/bind/port/password changes no longer auto-restart the daemon (reverts the auto-restart behavior introduced in 0.91.0; was causing UX friction).

### Fixed
- **Shell-integration path security** — escape shell-integration paths and sanitize temp file names across `DashboardController`, `SettingsView`, `TabManager`, and `TeamOrchestrator` to prevent shell injection through path interpolation.
- **TabManager refactor** — removed unnecessary `[weak self]` capture in `setTitle` closure (closure does not outlive `self`), added version-guard comment explaining the format compatibility strategy.

## [0.91.1] - 2026-04-08

### Fixed
- **Sleep/wake white-screen regression** — Removed the stale `suppressLayoutDuringDisplayReconfiguration` workaround (TERM-MESH-2). It was added to dodge a 2 s main-thread block from `NSHostingView.layout → CVDisplayLinkCreateWithCGDisplays`, but upstream Ghostty's 2025-06-16 renderer rework (`371d62a82`) moved macOS rendering to `IOSurfaceLayer`, so that blocker no longer exists. The leftover `contentView.isHidden = true/false` dance instead detached descendant `IOSurfaceLayer` contents on wake, leaving windows white until the user clicked. Removing the mechanism restores correct behavior with no measurable hang on current Ghostty.

## [0.91.0] - 2026-04-08

### Added
- **Dashboard preset switcher** — Overview / Team Ops / DevOps / Cost views with section visibility
- **Process Monitor tree view** — parent-child hierarchy with collapsible UI and Expand All/Collapse All
- **System Extended card** — Load Average bars, Swap usage, collapsible Network I/O (total + per-interface detail)
- **Per-Core CPU Heatmap** — color-coded grid showing per-core utilization
- **Anomaly detection** — high CPU sustained, repeated failure, no-heartbeat detection in daemon
- **Dashboard keyboard shortcut** — Cmd+Shift+D toggles the dashboard window
- **CLI: `new-split --type browser --url`** — one-step browser split creation
- **CLI: `close-surface --close-pane`** — collapse pane after closing all surfaces
- **CLI: `browser eval` scalar output** — string/number/bool printed directly without `--json`
- **Side-by-side card layout** — Watched Projects + Agent Status, Agent Sessions + Needs Attention, Daemon Tasks + Team Tasks

### Changed
- Settings dashboard toggle/bind/port/password now auto-restart the daemon (with debounce for port/password)
- WKWebView polling skip narrowed to dedicated dashboard window (split browser panels now poll correctly)
- Tagged builds (`./scripts/reload.sh --tag`) disable HTTP server to avoid port conflict with main app
- ProcessSnapshot now includes `ppid` for tree rendering

### Fixed
- **Initial cursor-in-middle-of-prompt bug** — terminal surfaces now force-refresh at 0.3s/0.8s/1.5s after launch to correct column count after SwiftUI layout settles (re-applies the c580530 fix that was reverted in c32830e)
- **Browser dashboard "disconnected"** — restored missing JS helpers (togglePid, toggleAllProcesses, updateProcessTree) that were accidentally deleted during section reorder
- **Mobile layout horizontal scroll** — reset `grid-column` on `#agents-card`/`#tasks-card`/`#team-tasks-card`/`#team-attention-card` in mobile media query, force inner grids to single/dual column
- **Card layout collapse to single column on Overview** — added agent/team cards to overview preset so paired cards stay side-by-side
- **Chart.js double-init error** — `cpuChart`/`timelineChart` initialized only in `window.onload` with destroy guards
- **Display type override** — `switchPreset` now uses `style.display = ''` instead of `'block'` so CSS grid/flex layouts are preserved
- **Sidebar Environment card visibility** — replaced hardcoded white background with theme-aware CSS variables

## [0.89.1] - 2026-04-07

### Changed
- Default Gemini model updated from `gemini-3.1-pro-preview` to `gemini-3.1-pro` (GA release)

## [0.88.1] - 2026-04-07

### Added
- `/tm-op research` strategy — invoke autonomous multi-agent research from the tm-op command palette

## [0.88.0] - 2026-04-07

### Added
- `tm-agent research <topic>` — autonomous multi-agent research with board.jsonl stigmergy coordination
  - Idle agent detection with graceful degradation (uses available agents, warns on shortfall)
  - Configurable depth (shallow/deep/exhaustive), round budget, timeout, web search toggle
  - Staggered dispatch with 3s intervals to reduce board write contention
  - Structured synthesis output with per-agent finding statistics

## [0.87.1] - 2026-04-07

### Fixed
- Dashboard metric cards (Teams, Agents, Open Tasks, Attention) now visible in dark theme — replaced hardcoded white background with theme-aware colors

## [0.87.0] - 2026-04-07

### Added
- Split pane layouts are now saved and restored across app restarts — no more manual re-splitting after relaunch
- Periodic session auto-save every 30 seconds for crash and force-quit resilience

### Fixed
- Memory growth in long-running agent teams — message history now capped at 500 per team with FIFO pruning

## [0.86.5] - 2026-04-07

### Fixed
- Terminal screen turning white after waking from sleep or monitor connect/disconnect — clicking was required to restore display

## [0.75.0] - 2026-03-21

### Added
- Default light theme for terminal — fresh installs now have proper light colors out of the box
- Auto-detect macOS system appearance and apply matching terminal theme in "System" mode
- Light/Dark theme pickers now show only matching themes (light themes for Light, dark themes for Dark)
- IME slash command picker discovers project-local commands from `.claude/commands/` (e.g. `/squash`)
- IME font zoom with Cmd+Plus/Minus shortcuts
- Plain arrow key pass-through when IME input is empty
- Stop/interrupt command for team agents

### Fixed
- Terminal always showing dark theme regardless of appearance setting
- IME Cmd+Z crash caused by stale undo stack after view teardown
- Option+Arrow keys in IME now send plain arrows instead of Alt-modified sequences
- Agent panels no longer counted in shell health assessment

## [0.74.0] - 2026-03-20

### Added
- Terminal settings GUI — configure font family, font size, light/dark theme, cursor style, cursor color, unfocused split opacity, and scrollback limit from Settings without editing config files
- 459 bundled ghostty themes available in theme picker
- System monospace fonts listed first in font picker with all fonts available

### Fixed
- Metal terminal surfaces no longer bleed through browser panels during pane zoom
- Infinite layout loops in portal sync and focus chains resolved
- IME command highlighting no longer triggers at line start — only after pipe/separator
- Worktree creation from an existing worktree now correctly resolves the main repo
- Agent Enter key delivery made reliable with atomic IME-style press/release pairs
- Worktree deletion now checks for uncommitted changes by default — dirty worktrees are protected unless explicitly force-removed
- Stale worktree cleanup during branch re-creation refuses to prune dirty worktrees

### Changed
- `worktree.remove` RPC now defaults to safe mode (rejects dirty worktrees); pass `force=true` to override

## [0.69.0] - 2026-03-17

### Fixed
- IME composition no longer strips trailing newline on Enter submit
- Team creation now routes to the correct window instead of always targeting the last active window
- Team name uniqueness is now enforced across all windows, not just the current one
- Agents in shared/isolated worktree mode now correctly start in the worktree directory

## [0.64.2] - 2026-03-16

### Fixed
- **tm-agent socket detection**: `detect_socket()` now checks `/tmp/term-mesh-last-socket-path` before glob fallback, avoiding ambiguity with multiple tagged debug sockets
- **tm-agent wait infinite loop**: `--interval 0` no longer causes an infinite loop (clamped to minimum 1 second)
- **tm-agent prompt consistency**: `agent_init_prompt` now instructs agents to use `tm-agent reply` (unified with `REPORT_SUFFIX` and `BROADCAST_SUFFIX`)
- **tm-agent RPC error surfacing**: `run_wait` and `run_create` now print warnings to stderr on RPC failures instead of silently ignoring them
- **tm-agent.sh reply**: Shell fallback `reply` command now correctly sends both `message.post` (type=report, to=leader) and `team.report`, matching Rust binary behavior

### Added
- `tests/test_tm_agent.py` — 34-test automated suite covering task lifecycle, messaging, reply integration, wait modes, and edge cases (`python3 tests/test_tm_agent.py --rounds 3`)
- `docs/tm-agent-architecture-review.md` — Architecture review with 6 identified issues and prioritized recommendations

### Changed
- `.claude/commands/team.md` — Added missing `task block`, `inbox`, `create` flags documentation; fixed `task review` signature

## [0.60.0] - 2026-02-21

### Added
- Tab context menu with rename, close, unread, and workspace actions ([#225](https://github.com/manaflow-ai/term-mesh/pull/225))
- Cmd+Shift+T reopens closed browser panels ([#253](https://github.com/manaflow-ai/term-mesh/pull/253))
- Vertical sidebar branch layout setting showing git branch and directory per pane
- JavaScript alert/confirm/prompt dialogs in browser panel ([#237](https://github.com/manaflow-ai/term-mesh/pull/237))
- File drag-and-drop and file input in browser panel ([#214](https://github.com/manaflow-ai/term-mesh/pull/214))
- tmux-compatible command set with matrix tests ([#221](https://github.com/manaflow-ai/term-mesh/pull/221))
- Pane resize divider control via CLI ([#223](https://github.com/manaflow-ai/term-mesh/pull/223))
- Production read-screen capture APIs ([#219](https://github.com/manaflow-ai/term-mesh/pull/219))
- Notification rings on terminal panes ([#132](https://github.com/manaflow-ai/term-mesh/pull/132))
- Claude Code integration enabled by default ([#247](https://github.com/manaflow-ai/term-mesh/pull/247))
- HTTP host allowlist for embedded browser with save and proceed flow ([#206](https://github.com/manaflow-ai/term-mesh/pull/206), [#203](https://github.com/manaflow-ai/term-mesh/pull/203))
- Setting to disable workspace auto-reorder on notification ([#215](https://github.com/manaflow-ai/term-mesh/issues/205))
- Browser panel mouse back/forward buttons and middle-click close ([#139](https://github.com/manaflow-ai/term-mesh/pull/139))
- Browser DevTools shortcut wiring and persistence ([#117](https://github.com/manaflow-ai/term-mesh/pull/117))
- CJK IME input support for Korean, Chinese, and Japanese ([#125](https://github.com/manaflow-ai/term-mesh/pull/125))
- `--help` flag on CLI subcommands ([#128](https://github.com/manaflow-ai/term-mesh/pull/128))
- `--command` flag for `new-workspace` CLI command ([#121](https://github.com/manaflow-ai/term-mesh/pull/121))
- `rename-tab` socket command ([#260](https://github.com/manaflow-ai/term-mesh/pull/260))
- Remap-aware bonsplit tooltips and browser split shortcuts ([#200](https://github.com/manaflow-ai/term-mesh/pull/200))

### Fixed
- IME preedit anchor sizing ([#266](https://github.com/manaflow-ai/term-mesh/pull/266))
- Cmd+Shift+T focus against deferred stale callbacks ([#267](https://github.com/manaflow-ai/term-mesh/pull/267))
- Unknown Bonsplit tab context actions causing crash ([#264](https://github.com/manaflow-ai/term-mesh/pull/264))
- Socket CLI commands stealing macOS app focus ([#260](https://github.com/manaflow-ai/term-mesh/pull/260))
- CLI unix socket lag from main-thread blocking ([#259](https://github.com/manaflow-ai/term-mesh/pull/259))
- Main-thread notification cascade causing hangs ([#232](https://github.com/manaflow-ai/term-mesh/pull/232))
- Favicon out-of-sync during back/forward navigation ([#233](https://github.com/manaflow-ai/term-mesh/pull/233))
- Stale sidebar git branch after closing a split
- Browser download UX and crash path ([#235](https://github.com/manaflow-ai/term-mesh/pull/235))
- Browser reopen focus across workspace switches ([#257](https://github.com/manaflow-ai/term-mesh/pull/257))
- Mark Tab as Unread no-op on focused tab ([#249](https://github.com/manaflow-ai/term-mesh/pull/249))
- Split dividers disappearing in tiny panes ([#250](https://github.com/manaflow-ai/term-mesh/pull/250))
- Flaky browser download activity accounting ([#246](https://github.com/manaflow-ai/term-mesh/pull/246))
- Drag overlay routing and terminal overlay regressions ([#218](https://github.com/manaflow-ai/term-mesh/pull/218))
- Initial bonsplit split animation flicker
- Window top inset on new window creation ([#224](https://github.com/manaflow-ai/term-mesh/pull/224))
- Cmd+Enter being routed as browser reload ([#213](https://github.com/manaflow-ai/term-mesh/pull/213))
- Child-exit close for last-terminal workspaces ([#254](https://github.com/manaflow-ai/term-mesh/pull/254))
- Sidebar resizer hitbox and cursor across portals ([#255](https://github.com/manaflow-ai/term-mesh/pull/255))
- Workspace-scoped tab action resolution
- IDN host allowlist normalization
- `setup.sh` cache rebuild and stale lock timeout ([#217](https://github.com/manaflow-ai/term-mesh/pull/217))
- Inconsistent Tab/Workspace terminology in settings and menus ([#187](https://github.com/manaflow-ai/term-mesh/pull/187))

### Changed
- CLI workspace commands now run off the main thread for better responsiveness ([#270](https://github.com/manaflow-ai/term-mesh/pull/270))
- Remove border below titlebar ([#242](https://github.com/manaflow-ai/term-mesh/pull/242))
- Slimmer browser omnibar with button hover/press states ([#271](https://github.com/manaflow-ai/term-mesh/pull/271))
- Browser under-page background refreshes on theme updates ([#272](https://github.com/manaflow-ai/term-mesh/pull/272))
- Command shortcut hints scoped to active window ([#226](https://github.com/manaflow-ai/term-mesh/pull/226))
- Nightly and release assets are now immutable (no accidental overwrite) ([#268](https://github.com/manaflow-ai/term-mesh/pull/268), [#269](https://github.com/manaflow-ai/term-mesh/pull/269))

## [0.59.0] - 2026-02-19

### Fixed
- Fix panel resize hitbox being too narrow and stale portal frame after panel resize

## [0.58.0] - 2026-02-19

### Fixed
- Fix split blackout race condition and focus handoff when creating or closing splits

## [0.57.0] - 2026-02-19

### Added
- Terminal panes now show an animated drop overlay when dragging tabs

### Fixed
- Fix blue hover not showing when dragging tabs onto terminal panes
- Fix stale drag overlay blocking clicks after tab drag ends

## [0.56.0] - 2026-02-19

_No user-facing changes._

## [0.55.0] - 2026-02-19

### Changed
- Move port scanning from shell to app-side with batching for faster startup

### Fixed
- Fix visual stretch when closing split panes
- Fix omnibar Cmd+L focus races

## [0.54.0] - 2026-02-18

### Fixed
- Fix browser omnibar Cmd+L causing 100% CPU from infinite focus loop

## [0.53.0] - 2026-02-18

### Changed
- CLI commands are now workspace-relative: commands use `TERMMESH_WORKSPACE_ID` environment variable so background agents target their own workspace instead of the user's focused workspace
- Remove all index-based CLI APIs in favor of short ID refs (`surface:1`, `pane:2`, `workspace:3`)
- CLI `send` and `send-key` support `--workspace` and `--surface` flags for explicit targeting
- CLI escape sequences (`\n`, `\r`, `\t`) in `send` payloads are now handled correctly
- `--id-format` flag is respected in text output for all list commands

### Fixed
- Fix background agents sending input to the wrong workspace
- Fix `close-surface` rejecting cross-workspace surface refs
- Fix malformed surface/pane/workspace/window handles passing through without error
- Fix `--window` flag being overridden by `TERMMESH_WORKSPACE_ID` environment variable

## [0.52.0] - 2026-02-18

### Changed
- Faster workspace switching with reduced rendering churn

### Fixed
- Fix Finder file drop not reaching portal-hosted terminals
- Fix unfocused pane dimming not showing for portal-hosted terminals
- Fix terminal hit-testing and visual glitches during workspace teardown

## [0.51.0] - 2026-02-18

### Fixed
- Fix menubar and right-click lag on M1 Macs in release builds
- Fix browser panel opening new tabs on link click

## [0.50.0] - 2026-02-18

### Fixed
- Fix crashes and fatal error when dropping files from Finder
- Fix zsh git branch display not refreshing after changing directories
- Fix menubar and right-click lag on M1 Macs

## [0.49.0] - 2026-02-18

### Fixed
- Fix crash (stack overflow) when clicking after a Finder file drag
- Fix titlebar folder icon briefly enlarging on workspace switch

## [0.48.0] - 2026-02-18

### Fixed
- Fix right-click context menu lag in notarized builds by adding missing hardened runtime entitlements
- Fix claude shim conflicting with `--resume`, `--continue`, and `--session-id` flags

## [0.47.0] - 2026-02-18

### Fixed
- Fix sidebar tab drag-and-drop reordering not working

## [0.46.0] - 2026-02-18

### Fixed
- Fix broken mouse click forwarding in terminal views

## [0.45.0] - 2026-02-18

### Changed
- Rebuild with Xcode 26.2 and macOS 26.2 SDK

## [0.44.0] - 2026-02-18

### Fixed
- Crash caused by infinite recursion when clicking in terminal (FileDropOverlayView mouse event forwarding)

## [0.38.1] - 2026-02-18

### Fixed
- Right-click and menubar lag in production builds (rebuilt with macOS 26.2 SDK)

## [0.38.0] - 2026-02-18

### Added
- Double-clicking the sidebar title-bar area now zooms/maximizes the window

### Fixed
- Browser omnibar `Cmd+L` now reliably refreshes/selects-all and supports immediate typing without stale inline text
- Omnibar inline completion no longer replaces typed prefixes with mismatched suggestion text

## [0.37.0] - 2026-02-17

### Added
- "+" button on the tab bar for quickly creating new terminal or browser tabs

## [0.36.0] - 2026-02-17

### Fixed
- App hang when omnibar safety timeout failed to fire (blocked main thread)
- Tab drag/drop not working when multiple workspaces exist
- Clicking in browser WebView not focusing the browser tab

## [0.35.0] - 2026-02-17

### Fixed
- App hang when clicking browser omnibar (NSTextView tracking loop spinning forever)
- White flash when creating new browser panels
- Tab drag/drop broken when dragging over WebView panes
- Stale drag timeout cancelling new drags of the same tab
- 88% idle CPU from infinite makeFirstResponder loop
- Terminal keys (arrows, Ctrl+N/P) swallowed after opening browser
- Cmd+N swallowed by browser omnibar navigation
- Split focus stolen by re-entrant becomeFirstResponder during reparenting

## [0.34.0] - 2026-02-16

### Fixed
- Browser not loading localhost URLs correctly

## [0.33.0] - 2026-02-16

### Fixed
- Menubar and general UI lag in production builds
- Sidebar tabs getting extra left padding when update pill is visible
- Memory leak when middle-clicking to close tabs

## [0.32.0] - 2026-02-16

### Added
- Sidebar metadata: git branch, listening ports, log entries, progress bars, and status pills

### Fixed
- localhost and 127.0.0.1 URLs not resolving correctly in the browser panel

### Changed
- `browser open` now targets the caller's workspace by default via TERMMESH_WORKSPACE_ID

## [0.31.0] - 2026-02-15

### Added
- Arrow key navigation in browser omnibar suggestions
- Browser zoom shortcuts (Cmd+/-, Cmd+0 to reset)
- "Install Update and Relaunch" menu item when an update is available

### Changed
- Open browser shortcut remapped from Cmd+Shift+B to Cmd+Shift+L
- Flash focused panel shortcut remapped from Cmd+Shift+L to Cmd+Shift+H
- Update pill now shows only in the sidebar footer

### Fixed
- Omnibar inline completion showing partial domain (e.g. "news." instead of "news.ycombinator.com")

## [0.30.0] - 2026-02-15

### Fixed
- Update pill not appearing when sidebar is visible in Release builds

## [0.29.0] - 2026-02-15

### Added
- Cmd+click on links in the browser opens them in a new tab
- Right-click context menu shows "Open Link in New Tab" instead of "Open in New Window"
- Third-party licenses bundled in app with Licenses button in About window
- Update availability pill now visible in Release builds

### Changed
- Cmd+[/] now triggers browser back/forward when a browser panel is focused (no-op on terminal)
- Reload configuration shortcut changed to Cmd+Shift+,
- Improved browser omnibar suggestions and focus behavior

## [0.28.2] - 2026-02-14

### Fixed
- Sparkle updates from `0.27.0` could fail to detect newer releases because release build numbers were behind the latest published appcast build number
- Release GitHub Action failed on repeat runs when `SUPublicEDKey` / `SUFeedURL` already existed in `Info.plist`

## [0.28.1] - 2026-02-14

### Fixed
- Release build failure caused by debug-only helper symbols referenced in non-debug code paths

## [0.28.0] - 2026-02-14

### Added
- Optional nightly update channel in Settings (`Receive Nightly Builds`)
- Automated nightly build and publish workflow for `main` when new commits are available

### Changed
- Settings and About windows now use the updated transparent titlebar styling and aligned controls
- Repository license changed to GNU AGPLv3

### Fixed
- Terminal panes freezing after repeated split churn
- Finder service directory resolution now normalizes paths consistently

## [0.27.0] - 2026-02-11

### Fixed
- Muted traffic lights and toolbar items on macOS 14 (Sonoma) caused by `clipsToBounds` default change
- Toolbar buttons (sidebar, notifications, new tab) disappearing after toggling sidebar with Cmd+B
- Update check pill not appearing in titlebar on macOS 14 (Sonoma)

## [0.26.0] - 2026-02-11

### Fixed
- Muted traffic lights and toolbar items in focused window caused by background blur in themeFrame
- Sidebar showing two different textures near the titlebar on older macOS versions

## [0.25.0] - 2026-02-11

### Fixed
- Blank terminal on macOS 26 (Tahoe) — two additional code paths were still clearing the window background, bypassing the initial fix
- Blank terminal on macOS 15 caused by background blur view covering terminal content

## [0.24.0] - 2026-02-09

### Changed
- Update bundle identifier to `com.termmesh.app` for consistency

## [0.23.0] - 2026-02-09

### Changed
- Rename app to term-mesh — new app name, socket paths, Homebrew tap, and CLI binary name (bundle ID remains `com.termmesh.app` for Sparkle update continuity)
- Sidebar now shows tab status as text instead of colored dots, with instant git HEAD change detection

### Fixed
- CLI `set-status` command not properly quoting values or routing `--tab` flag

## [0.22.0] - 2026-02-09

### Fixed
- Xcode and system environment variables (e.g. DYLD, LANGUAGE) leaking into terminal sessions

## [0.21.0] - 2026-02-09

### Fixed
- Zsh autosuggestions not working with shared history across terminal panes

## [0.17.3] - 2025-02-05

### Fixed
- Auto-update not working (Sparkle EdDSA signing was silently failing due to SUPublicEDKey missing from Info.plist)

## [0.17.1] - 2025-02-05

### Fixed
- Auto-update not working (Sparkle public key was missing from release builds)

## [0.17.0] - 2025-02-05

### Fixed
- Traffic lights (close/minimize/zoom) not showing on macOS 13-15
- Titlebar content overlapping traffic lights and toolbar buttons when sidebar is hidden

## [0.16.0] - 2025-02-04

### Added
- Sidebar blur effect with withinWindow blending for a polished look
- `--panel` flag for `new-split` command to control split pane placement

## [0.15.0] - 2025-01-30

### Fixed
- Typing lag caused by redundant render loop

## [0.14.0] - 2025-01-30

### Added
- Setup script for initializing submodules and building dependencies
- Contributing guide for new contributors

### Fixed
- Terminal focus when scrolling with mouse/trackpad

### Changed
- Reload scripts are more robust with better error handling

## [0.13.0] - 2025-01-29

### Added
- Customizable keyboard shortcuts via Settings

### Fixed
- Find panel focus and search alignment with Ghostty behavior

### Changed
- Sentry environment now distinguishes between production and dev builds

## [0.12.0] - 2025-01-29

### Fixed
- Handle display scale changes when moving between monitors

### Changed
- Fix SwiftPM cache handling for release builds

## [0.11.0] - 2025-01-29

### Added
- Notifications documentation for AI agent integrations

### Changed
- App and tooling updates

## [0.10.0] - 2025-01-29

### Added
- Sentry SDK for crash reporting
- Documentation site with Fumadocs
- Homebrew installation support (`brew install --cask term-mesh`)
- Auto-update Homebrew cask on release

### Fixed
- High CPU usage from notification system
- Release workflow SwiftPM cache issues

### Changed
- New tabs now insert after current tab and inherit working directory

## [0.9.0] - 2025-01-29

### Changed
- Normalized window controls appearance
- Added confirmation panel when closing windows with active processes

## [0.8.0] - 2025-01-29

### Fixed
- Socket key input handling
- OSC 777 notification sequence support

### Changed
- Customized About window
- Restricted titlebar accessories for cleaner appearance

## [0.7.0] - 2025-01-29

### Fixed
- Environment variable and terminfo packaging issues
- XDG defaults handling

## [0.6.0] - 2025-01-28

### Fixed
- Terminfo packaging for proper terminal compatibility

## [0.5.0] - 2025-01-28

### Added
- Sparkle updater cache handling
- Ghostty fork documentation

## [0.4.0] - 2025-01-28

### Added
- term-mesh CLI with socket control modes
- NSPopover-based notifications

### Fixed
- Notarization and codesigning for embedded CLI
- Release workflow reliability

### Changed
- Refined titlebar controls and variants
- Clear notifications on window close

## [0.3.0] - 2025-01-28

### Added
- Debug scrollback tab with smooth scroll wheel
- Mock update feed UI tests
- Dev build branding and reload scripts

### Fixed
- Notification focus handling and indicators
- Tab focus for key input
- Update UI error details and pill visibility

### Changed
- Renamed app to term-mesh
- Improved CI UI test stability

## [0.1.0] - 2025-01-28

### Added
- Sparkle auto-update flow
- Titlebar update UI indicator

## [0.0.x] - 2025-01-28

Initial releases with core terminal functionality:
- GPU-accelerated terminal rendering via Ghostty
- Tab management with native macOS UI
- Split pane support
- Keyboard shortcuts
- Socket API for automation
