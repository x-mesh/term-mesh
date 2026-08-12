# CLI profiles and Native Agent Panes

This document holds implementation and troubleshooting details that are loaded
only when this feature is being changed. The always-on invariants remain in
[`CLAUDE.md`](../CLAUDE.md).

## CLI Profiles

Named CLI profile sets (path + extraArgs + env + modelOverride) stored in `~/Library/Application Support/term-mesh/cli-profiles.json`.

**Settings에서 만들기:** Settings → CLI Paths에서 각 CLI(claude / kiro / codex / gemini / cursor / agy)별로 프로파일을 추가하고 이름, 실행 경로, 추가 인수(extraArgs), 환경 변수, 모델 override를 지정. 경로 필드에는 자동 감지된 경로와 최근 사용 경로가 dropdown으로 표시됨.

**메뉴바에서 전환:** 메뉴바 아이콘 → CLI Profile 서브메뉴에서 CLI별 프로파일을 라디오 버튼으로 즉시 전환. "Apply to Active Pane (Restart)"를 선택하면 현재 pane을 새 프로파일로 hard restart.

**마이그레이션:** 기존 `cliPath.<cli>` 값은 앱 시작 시 자동으로 "Default" 프로파일로 변환되며 원본 UserDefaults 키도 dual-write로 유지됨(구버전 빌드 호환).

**extraArgs 주의:** `--model`, `--resume`, `--session-id`, `--dangerously-skip-permissions`, `--print`, `--append-system-prompt`는 term-mesh가 자동으로 주입하므로 extraArgs에 넣지 말 것(경고 표시됨).

**헤드리스 모드:** `tm-agent create` / `tm-agent attach` 시에도 활성 프로파일의 extraArgs / env / modelOverride가 동일하게 적용됨.

**cursor / agy:** Settings → CLI Paths에는 항상 경로 필드가 있다(`cursor-agent`, `agy`). 에이전트 role/attach CLI picker에는 **Native Agent Panes**가 켜져 있을 때만 나타난다 — 둘 다 대화형 TUI·stdin 채널이 없어 터미널 pane으로는 실행할 수 없다.

## Native Agent Panes (experimental)

기본값은 **Native**다. Settings → Agent Teams → **Agent Panes**에서 기존 Ghostty pane이 필요하면 **Terminal**로 바꿀 수 있다. Native에서는:

- pipe transport(`agentPipeTransport.enabled`)와 native panel(`agentPipeTransport.nativePanel`)이 함께 켜진다. 하나만 켜는 UI는 없다.
- 에이전트 UI는 `AgentPanelView`(SwiftUI) — 지시문, streaming 답변, 접을 수 있는 tool row, 턴 종료 cost/시간.
- 파일 편집은 `ChangeRow`가 diff로 그린다: 접힌 줄에 `경로 +N −M`, 펼치면 `+`/`−` 색상 diff. 파싱은 `Sources/Panels/AgentDiff.swift`(순수 함수, `CollectionDifference` 기반)가 `tool_use.input`에서 하며 **뷰 body에서는 절대 계산하지 않는다**. 인식하는 input 모양은 `unified_diff`(브리지 정본, `@@` 헤더의 라인 번호 유지) / `old_string`+`new_string` / `edits[]` / `content`. tool 이름이 아니라 input 모양으로 분기한다. 브리지는 `input`에 `command` 키를 넣으면 안 된다 — `AgentSession.openTool()`이 그걸 먼저 골라 `file_path`를 가린다.
- `tm-agent delegate` / `send` / `broadcast`는 CLI 이름 그대로; delivery만 paste+Return → pipe/native stdin으로 바뀐다.
- 턴 완료는 `AgentPipeCompletion`이 `<fifo>.events`의 `{"type":"result"}`를 읽는다. Standard Reply Header(5-field) 계약은 동일.
- 지원 CLI: claude(직접 NDJSON), codex/kiro/cursor/agy(기본: compiled Rust `tm-agent-bridge`; `TERMMESH_BRIDGE_IMPL=python`은 compatibility fallback).
- Shell Integration health: native agent pane은 **agentMode**(파란색) — shell integration N/A.

Spike 상세: `docs/spike/agent-pipe-render.md`

### Remote native agent environment

Remote native agents start through the account's Bourne-compatible login shell.
For daemon-owned agents, `/etc/passwd` is authoritative; a systemd-inherited
`SHELL=/bin/sh` must not override an account that uses zsh. Change the account
shell with `chsh`; the Project creation screen and Peer Host doctor show the
resolved shell and `agent-env` status.
The load order is:

1. the shell's normal login profile;
2. `~/.profile` when Bash or zsh would otherwise skip that literal file;
3. optional `~/.config/term-mesh/agent-env`;
4. explicit environment values configured for the peer host.

`agent-env` is sourced as a Bourne-compatible shell fragment. Prefer simple
`KEY=value` or `export KEY=value` entries and do not print output from it.
Explicit peer-host values win over profile and `agent-env` values. A profile or
`agent-env` load failure is reported in the native agent pane without including
environment values.

`PATH` is the one key that **adds** rather than replaces. term-mesh keeps a
baseline (`tm_agent_bridge::location::REMOTE_PATH`) so the CLIs it installs stay
reachable whatever a host configures, and a `PATH` saved for a peer host is
appended to it — in agent launches and in terminal panes alike, so the same
value cannot mean two things in two panes. **After**, not before: the order is
the safety property, since a host setting searched first could shadow
`/usr/bin` or a term-mesh CLI with a same-named file. To pin a particular
binary, set that CLI's absolute path instead. List directories plainly
(`/opt/foo/bin:$HOME/bin`); **do not write `$PATH`** there. Nothing is being
replaced, so there is nothing to preserve by hand, and the value reaches the
launch without a shell expanding it — `$PATH` would arrive as four literal
characters and break the search path outright.

That baseline is narrower than the readiness probe's search path
(`RemoteShellPath.binDirs` plus the login shell's own `PATH`). A CLI in
`~/.npm-global/bin`, `~/bin` or a pyenv shim therefore probes as present while
the launch cannot reach it — the pane opens and the agent never starts. Adding
that directory here is the fix.

VERIFY (stale CLI 이름·동작 불일치):

```bash
rg -n 'agentPipeTransport|Agent Panes|Native Agent|cursor-agent|tm-agent-bridge' AGENTS.md CLAUDE.md CHANGELOG.md docs/spike/agent-pipe-render.md
xcodebuild -project GhosttyTabs.xcodeproj -scheme term-mesh-unit -configuration Debug -destination 'platform=macOS' -only-testing:termMeshTests/AgentSessionTests -only-testing:termMeshTests/AgentPipeCompletionTests test
```

