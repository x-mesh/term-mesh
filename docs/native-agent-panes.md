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

**워커 플러그인:** claude 워커(터미널·native·원격·headless)는 `--settings '{"enabledPlugins":{"mgrep@Mixedbread-Grep":false}}'`로 시작한다. mgrep의 SessionStart 훅이 세션마다 작업 트리 전체를 감시하는 `mgrep watch`를 따로 띄워서, 6명 팀이 한 저장소에서 각 60GB 넘게 메모리를 썼기 때문이다. 리더는 사용자 세션이라 그대로 둔다. 목록은 `AgentSession.workerSettingsJSON`과 `daemon/term-meshd/src/headless/cli_builder.rs`의 `WORKER_SETTINGS_JSON` 두 곳에 있으니 함께 바꿀 것. extraArgs에 `--settings`를 넣으면 이 값이 덮일 수 있다.

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
- 진행 중인 turn에는 기본 wall-clock timeout이 없다. 긴 build/test와 `/goal`은 시간이 지났다는 이유만으로 종료되지 않는다. Bridge를 직접 실행하는 진단·자동화에서만 `--turn-timeout <positive-seconds>`로 absolute deadline을 opt-in할 수 있으며, 앱과 CLI profile은 이 값을 주입하지 않는다.
- Native pane은 turn 중 마지막 정상 protocol event 이후 30분간 조용하면 `no activity 30m`를 표시한다. 이는 hang 판정이 아닌 비파괴 경고다. agent, task, `/goal`은 계속 실행되고 후속 event가 오면 경고가 사라진다. 복구가 필요하면 pane header의 `↻` hard restart를 사용하되 conversation context가 지워진다.
- Shell Integration health: native agent pane은 **agentMode**(파란색) — shell integration N/A.

Spike 상세: `docs/spike/agent-pipe-render.md`

### 작업 재개와 후속 지시

기존 작업을 이어서 지시할 때는 task ID를 명시한다.

```bash
tm-agent send executor '실패 원인을 확인했으니 다시 시도해 주세요.' --task <task-id>
```

`--task`는 기존 작업의 담당자와 인스턴스를 확인하고 같은 task ID로 후속
지시를 보낸다. 작업에 worktree가 있으면 경로도 함께 전달한다. task ID 없는
`send`는 독립적인 대화이므로 그 답변의 DONE이 기존 작업을 완료하지 않는다.
인스턴스 소유권을 확인할 수 없는 headless 경로로는 작업 후속 지시를 전송하지 않는다.

Native worker가 BLOCKED 또는 NEEDS_REVIEW를 보고한 뒤 같은 작업을 스스로
재개하면 후속 DONE을 그 작업에 반영한다. 다른 task ID, 사람 입력, 독립적인
leader 대화가 들어오거나 작업이 완료되면 이전 연결은 이어받지 않는다.
BLOCKED 이후 leader가 원인을 알려 주고 재시도를 맡길 때는 `--task`를 쓴다.

Native Codex의 Rust bridge는 task 보드에서 확인한 작업 worktree를 각 실행
요청의 `cwd`로 전달한다. 지시문에 적힌 경로는 실행 경로의 근거로 쓰지 않는다.
worktree 없는 새 작업과 독립적인 대화는 세션 시작 경로로 되돌린다. 진행 중인
턴 뒤에 작업이 대기하더라도 각 작업의 경로는 해당 턴과 함께 전달된다.
도구 호출이 별도로 지정한 `workdir`는 이 경로 전달로 덮어쓰지 않는다.

### 도구 실패와 세션 건강 상태

Native worker의 `tm-agent read`에는 실패한 도구의 짧은 오류 요약이 표시된다.
요약은 길이를 제한하고 credential을 가린다. `tm-agent status`의 각 native
worker에는 `tool_failures`가 있으며 세션 전체 `total`, 현재 또는 마지막 턴의
`turn_failures`와 `consecutive`, `last_error`, `last_tool`, `needs_attention`을 담는다.
같은 턴에서 도구가 3번 연속 실패하면 `health: degraded`와 복구 제안이 표시된다.
성공한 도구 또는 새 턴은 연속 실패 수를 초기화한다.

건강 신호는 작업의 STATUS와 별개다. `NEEDS_REVIEW`는 계속 `review_ready`로
기록하며, 미커밋 변경만으로 실패를 판정하지 않는다. 자동으로 세션을 재시작하지
않으므로 오류를 확인하고 변경을 보존한 뒤 필요하면 `tm-agent restart --hard`를
사용한다. 기존 `recycle`은 활성 작업을 보호하며, `--auto-recycle N`은 completed
작업 수를 기준으로 동작한다.

Codex bridge는 app-server가 전달한 도구 결과를 보존한다. Codex upstream이
이벤트로 노출하지 않은 오류는 이 신호만으로 관측할 수 없다.

### Remote native agent environment

GUI에서 만든 Project도 양쪽 앱이 live-presentation protocol을 지원하면 원격에서
leader와 native worker를 함께 열 수 있다. GUI와 daemon의 Project 목록을 별도로
조회하며, GUI-owned worker는 원래 앱의 현재 대화 snapshot과 실시간 변경분을
공유한다. `App-owned` 표시는 원래 앱이 실행 중이어야 한다는 뜻이다. viewer를
닫아도 원래 worker는 종료되지 않으며, daemon-owned Project로 소유권을 옮기지 않는다.
구버전 viewer에는 native model stream을 노출하지 않는다.

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
rg -n 'agentPipeTransport|Agent Panes|Native Agent|cursor-agent|tm-agent-bridge' AGENTS.md CLAUDE.md CHANGELOG.md docs/native-agent-panes.md docs/spike/agent-pipe-render.md
xcodebuild -project GhosttyTabs.xcodeproj -scheme term-mesh-unit -configuration Debug -destination 'platform=macOS' -only-testing:termMeshTests/AgentSessionTests -only-testing:termMeshTests/AgentPipeCompletionTests test
```
