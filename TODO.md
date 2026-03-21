# TODO

## Socket API / Agent
- [x] Add window handles + `window.list/current/focus/create/close` for multi-window socket control (v2) + v1 equivalents (`list_windows`, etc) + CLI support.
- [x] Add surface move/reorder commands (move between panes, reorder within pane, move across workspaces/windows).
- [x] Add browser automation API inspired by `vercel-labs/agent-browser`, but backed by term-mesh's WKWebView (wait, click, type, eval, screenshot, etc.).
- [x] Finalize browser parity contract and command mapping decisions in `docs/agent-browser-port-spec.md`.
- [x] Add `term-mesh browser` command surface that mirrors agent-browser semantics and targets explicit `surface_id` handles.
- [x] Add short handle refs (`surface:N`, `pane:N`, `workspace:N`, `window:N`) and CLI `--id-format refs|uuids|both` output control.
- [x] Add v1->v2 compatibility shim for migrated browser/topology commands while v1 remains supported.
- [x] Port browser automation coverage to `tests_v2/` per `docs/agent-browser-port-spec.md` and keep v1 + v2 suites green.
  - Added `tests_v2/test_browser_api_comprehensive.py`, `tests_v2/test_browser_api_p0.py`, `tests_v2/test_browser_api_extended_families.py`, `tests_v2/test_browser_api_unsupported_matrix.py`, and `tests_v2/test_browser_cli_agent_port.py`.
  - Full VM runs: `./scripts/run-tests-v1.sh` and `./scripts/run-tests-v2.sh` passing (v2 visual D12 remains reported as a known non-blocking VM failure, matching v1 policy).
- [x] Fix `term-mesh browser open|open-split|new` URL parsing so routing flags (`--workspace`, `--window`) are removed before URL construction.
- [x] Fix `identify --workspace/--surface` caller parsing to honor ref handles (`workspace:N`, `surface:N`) instead of falling back to current/focused IDs.
- [x] Update `browser.open_split` placement policy: reuse nearest right sibling pane first (nested-aware), only create a new split when caller has no right sibling.
- [x] Upgrade `browser.snapshot` to agent-browser-style output (`snapshot` tree text + `refs`) and make non-JSON CLI output print snapshot content instead of `OK`.
- [x] Add richer selector failure diagnostics (`hint`, counts, sample, snapshot excerpt) with bounded retries for transient `not_found` races.
- [x] Add regression coverage for browser placement policy + snapshot/ref output + diagnostics in v2 tests.
- [x] Allow `browser fill` with empty text (clear input) in CLI + v2 API flows.
- [x] Make legacy `new-pane`/`new-surface` CLI output prefer short `surface:N` refs by default.
- [x] Add optional `--snapshot-after` / `snapshot_after` action feedback to include a fresh post-action browser snapshot.
- [x] Switch CLI `--json` default ID output to refs-first (UUIDs only via `--id-format uuids|both`) and add regression coverage.
- [x] Expand end-user skill docs with deep-linkable term-mesh-browser references/templates plus a new core `skills/term-mesh/` topology skill.

## Command Palette
- [ ] Add cmd+shift+p palette with all commands

## Feature Requests
- [ ] Warm pool of Claude Code instances mapped to a keyboard shortcut

## Claude Code Integration
- [ ] Add "Install Claude Code integration" menu item in menubar
  - Opens a new terminal
  - Shows user the diff to their config file (claude.json, opencode config, codex config, etc.)
  - Prompts user to type 'y' to confirm
  - Implement as part of `term-mesh` CLI, menubar just triggers the CLI command

## Additional Integrations
- [ ] Codex integration
- [ ] OpenCode integration

## Browser
- [ ] Per-WKWebView local proxy for full network request/response inspection (URL, method, headers, body, status, timing)

## Bugs
- [ ] **P0** Terminal title updates are suppressed when workspace is not focused (e.g. Claude Code loading indicator doesn't update in sidebar until you switch to that tab)
- [ ] Sidebar tab reorder can get stuck in dragging state (dimmed tab + blue drop indicator line visible) after drag ends
- [ ] Drag-and-drop files/images into terminal shows URL instead of file path (Ghostty supports dropping files as paths)
- [ ] After opening a browser tab, up/down arrow keys (and possibly other keyboard shortcuts) stop working in the terminal
- [ ] Notification marked unread doesn't get pushed to the top of the list
- [ ] Browser cmd+shift+H ring flashes only once (should flash twice like other shortcuts)

## Test Coverage Gaps
- [ ] **설정 관리** — AppearanceSettings, TerminalSettings, SettingsView 등 설정 변경/저장/로드 테스트
- [ ] **사이드바** — 탭 선택, 드래그 순서 변경, 컨텍스트 메뉴, 접기/펼치기 (현재 리사이즈만 테스트)
- [ ] **워크스페이스** — 생성/삭제/전환/이름변경 전체 라이프사이클 테스트
- [ ] **포커스 라우팅** — 스플릿 간 포커스 이동, 브라우저↔터미널 전환 시 포커스 보존
- [ ] **에러 핸들링** — 소켓 끊김, 잘못된 명령, 타임아웃 등 엣지 케이스
- [ ] **성능 벤치마크** — 렌더링 FPS, 소켓 응답 레이턴시, 메모리 사용량 기준선
- [ ] **에이전트 오케스트레이션** — 팀 생성/소멸, 에이전트 간 메시지 전달, 태스크 보드 상태 전이
- [ ] **다크/라이트 테마 전환** — 테마 전환 시 모든 UI 컴포넌트 올바른 색상 적용 검증
- [ ] **멀티 윈도우** — 윈도우 간 탭 이동, 독립 소켓 상태, 윈도우 닫기 시 정리

## Refactoring
- [x] **P0** Remove all index-based APIs in favor of short ID refs (surface:N, pane:N, workspace:N, window:N)
- [x] **P0** CLI commands should be workspace-relative using CMUX_WORKSPACE_ID env var (not focused workspace) so agents in background workspaces don't affect the user's active workspace. Affected: send, send-key, send-panel, send-key-panel, new-split, new-pane, new-surface, close-surface, list-panes, list-pane-surfaces, list-panels, focus-pane, focus-panel, surface-health
- [x] **P0** Remove `close-workspace` with no args — require explicit workspace short ID or UUID, with clear error message if missing

## UI/UX Improvements
- [ ] Show loading indicator in terminal while it's loading
- [ ] Add question mark icon to learn shortcuts
- [ ] Notification popover: each button item should show outline outside when focused/hovered
- [ ] Notification popover: add right-click context menu to mark as read/unread
- [ ] Right-click tab should allow renaming that workspace
- [ ] Cmd+click should open links in term-mesh (browser panel) instead of external browser
- [ ] "Waiting for input" notification should include custom terminal title if set
- [ ] Close button for current/active tab should always be visible (not just on hover)
- [ ] Add browser icon to the left of the plus button in the tab bar

## Analytics
- [x] Add PostHog tracking (set `PostHogAnalytics.apiKey` in `Sources/PostHogAnalytics.swift`)

### Browser Parity Completion (agent-browser port)
- [x] Implement locator family:
  - `browser.find.role`
  - `browser.find.text`
  - `browser.find.label`
  - `browser.find.placeholder`
  - `browser.find.alt`
  - `browser.find.title`
  - `browser.find.testid`
  - `browser.find.first`
  - `browser.find.last`
  - `browser.find.nth`
- [x] Implement frame/dialog/download:
  - `browser.frame.select`
  - `browser.frame.main`
  - `browser.dialog.accept`
  - `browser.dialog.dismiss`
  - `browser.download.wait`
- [x] Implement session/context state APIs:
  - `browser.cookies.get|set|clear`
  - `browser.storage.get|set|clear`
  - `browser.tab.new|list|switch|close`
  - `browser.state.save|load`
- [x] Implement developer/diagnostic helpers:
  - `browser.console.list|clear`
  - `browser.errors.list`
  - `browser.highlight`
  - `browser.addinitscript`
  - `browser.addscript`
  - `browser.addstyle`
- [x] Add explicit `not_supported` for WebKit/CDP-gap commands:
  - `browser.viewport.set`
  - `browser.geolocation.set`
  - `browser.offline.set`
  - `browser.trace.start|stop`
  - `browser.network.route|unroute|requests`
  - `browser.screencast.start|stop`
  - `browser.input_mouse|input_keyboard|input_touch`
- [x] Extend `term-mesh browser ...` CLI grammar for the new families (including aliases).
- [x] Port/add v2 tests for all newly implemented families.
- [x] Update unsupported matrix tests to assert `not_supported` for hard platform gaps (instead of `method_not_found`).
- [x] Re-run full `run-tests-v1.sh` and `run-tests-v2.sh` on `term-mesh-vm`.
