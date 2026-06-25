# term-mesh agent notes

## Initial setup

Run the setup script to initialize submodules, install Metal Toolchain, and build GhosttyKit:

```bash
./scripts/setup.sh
```

This handles: submodule init, Metal Toolchain download, xcframework-* tag cleanup, GhosttyKit build (cached per ghostty SHA), and symlink creation.

`setup.sh` activates the project git hooks automatically (the `commit-msg` hook
strips fenced code-block markers that agents tend to wrap commit messages in).
If you skip `setup.sh`, activate them manually once per clone:

```bash
git config core.hooksPath .githooks
```

## Syncing submodules on a fresh pull (multi-machine)

**IMPORTANT:** The `ghostty` submodule is pinned to `JINWOO-J/ghostty` (personal fork).
Whenever you `git pull` on any machine and see ` m ghostty` in `git status`, or the
pulled commit updated the submodule SHA / `.gitmodules` URL, run:

```bash
./scripts/sync-submodules.sh
```

This propagates `.gitmodules` URL changes into `.git/config` (`git submodule sync`)
and checks each submodule out at the SHA the parent pins (`git submodule update --init`).
Without this step the working tree keeps showing a "dirty" submodule and builds
may use a stale ghostty.

One-time convenience on each machine (optional, recommended):

```bash
git config --global submodule.recurse true   # auto-sync on future pull/checkout
```

## Local dev

After making code changes, always run the reload script with a tag to launch the Debug app:

```bash
./scripts/reload.sh --tag fix-zsh-autosuggestions
```

After making code changes, always run the build:

```bash
xcodebuild -project GhosttyTabs.xcodeproj -scheme term-mesh -configuration Debug -destination 'platform=macOS' build
```

When rebuilding GhosttyKit.xcframework, always use Release optimizations.
Clean any xcframework-* tags first to avoid zig build crashes:

```bash
cd ghostty && git tag -l 'xcframework-*' | while read -r t; do git tag -d "$t"; done 2>/dev/null; zig build -Demit-xcframework=true -Doptimize=ReleaseFast
```

When rebuilding term-meshd (the Rust daemon):

```bash
cd daemon && cargo build --release
```

`reload` = kill and launch the Debug app only (tag required):

```bash
./scripts/reload.sh --tag <tag>
```

`reloadp` = kill and launch the Release app:

```bash
./scripts/reloadp.sh
```

`reloads` = kill and launch the Release app as "term-mesh STAGING" (isolated from production term-mesh):

```bash
./scripts/reloads.sh
```

`reload2` = reload both Debug and Release (tag required for Debug reload):

```bash
./scripts/reload2.sh --tag <tag>
```

For parallel/isolated builds (e.g., testing a feature alongside the main app), use `--tag` with a short descriptive name:

```bash
./scripts/reload.sh --tag fix-blur-effect
```

This creates an isolated app with its own name, bundle ID, socket, and derived data path so it runs side-by-side with the main app. Important: use a non-`/tmp` derived data path if you need xcframework resolution (the script handles this automatically).

Before launching a new tagged run, clean up any older tags you started in this session (quit old tagged app + remove its `/tmp` socket/derived data).

## CLI Profiles

Named CLI profile sets (path + extraArgs + env + modelOverride) stored in `~/Library/Application Support/term-mesh/cli-profiles.json`.

**Settings에서 만들기:** Settings → CLI Paths에서 각 CLI(claude / kiro / codex / gemini)별로 프로파일을 추가하고 이름, 실행 경로, 추가 인수(extraArgs), 환경 변수, 모델 override를 지정. 경로 필드에는 자동 감지된 경로와 최근 사용 경로가 dropdown으로 표시됨.

**메뉴바에서 전환:** 메뉴바 아이콘 → CLI Profile 서브메뉴에서 CLI별 프로파일을 라디오 버튼으로 즉시 전환. "Apply to Active Pane (Restart)"를 선택하면 현재 pane을 새 프로파일로 hard restart.

**마이그레이션:** 기존 `cliPath.<cli>` 값은 앱 시작 시 자동으로 "Default" 프로파일로 변환되며 원본 UserDefaults 키도 dual-write로 유지됨(구버전 빌드 호환).

**extraArgs 주의:** `--model`, `--resume`, `--session-id`, `--dangerously-skip-permissions`, `--print`, `--append-system-prompt`는 term-mesh가 자동으로 주입하므로 extraArgs에 넣지 말 것(경고 표시됨).

**헤드리스 모드:** `tm-agent create` / `tm-agent attach` 시에도 활성 프로파일의 extraArgs / env / modelOverride가 동일하게 적용됨.

## Debug event log

All debug events (keys, mouse, focus, splits, tabs) go to a unified log in DEBUG builds:

```bash
tail -f "$(cat /tmp/term-mesh-last-debug-log-path 2>/dev/null || echo /tmp/term-mesh-debug.log)"
```

- Untagged Debug app: `/tmp/term-mesh-debug.log`
- Tagged Debug app (`./scripts/reload.sh --tag <tag>`): `/tmp/term-mesh-debug-<tag>.log`
- `reload.sh` writes the current path to `/tmp/term-mesh-last-debug-log-path`

- Implementation: `vendor/bonsplit/Sources/Bonsplit/Public/DebugEventLog.swift`
- Free function `dlog("message")` — logs with timestamp and appends to file in real time
- Entire file is `#if DEBUG`; all call sites must be wrapped in `#if DEBUG` / `#endif`
- 500-entry ring buffer; `DebugEventLog.shared.dump()` writes full buffer to file
- Key events logged in `AppDelegate.swift` (monitor, performKeyEquivalent)
- Mouse/UI events logged inline in views (ContentView, BrowserPanelView, etc.)
- Focus events: `focus.panel`, `focus.bonsplit`, `focus.firstResponder`, `focus.moveFocus`
- Bonsplit events: `tab.select`, `tab.close`, `tab.dragStart`, `tab.drop`, `pane.focus`, `pane.drop`, `divider.dragStart`
- Enter-swallow / IME instrumentation patterns:
  - `key.PRESS_ignored keycode=36` — synthetic send_key rejected by Ghostty (from sendKeyEvent); Rust retry not triggered
  - `ime.return_with_markedText` — Return pressed during IME composition (not swallowed)
  - `ime.resignFirstResponder hadMarkedText=true` — normal IME resign on focus loss
  - `ime.ghosttyKey path=accumulated.text keycode=0` — composed text sent via UTF-8 fallback

## Pitfalls

- **Custom UTTypes** for drag-and-drop must be declared in `Resources/Info.plist` under `UTExportedTypeDeclarations` (e.g. `com.splittabbar.tabtransfer`, `com.termmesh.sidebar-tab-reorder`).
- Do not add an app-level display link or manual `ghostty_surface_draw` loop; rely on Ghostty wakeups/renderer to avoid typing lag.
- **Terminal find layering contract:** `SurfaceSearchOverlay` must be mounted from `GhosttySurfaceScrollView` in `Sources/GhosttyTerminalView.swift` (AppKit portal layer), not from SwiftUI panel containers such as `Sources/Panels/TerminalPanelView.swift`. Portal-hosted terminal views can sit above SwiftUI during split/workspace churn.
- **Submodule safety:** `ghostty` is the only git submodule. When modifying it, always push the submodule commit to its remote `main` branch BEFORE committing the updated pointer in the parent repo. Never commit on a detached HEAD or temporary branch — the commit will be orphaned and lost. Verify with: `cd ghostty && git merge-base --is-ancestor HEAD origin/main`.
- **`vendor/bonsplit` is vendored code, not a submodule** (converted in `c56fdbe1`). Its files are tracked directly by this repo — edit and commit them like any other source file; no submodule push/pointer dance.

## Socket command threading policy

- Do not use `DispatchQueue.main.sync` for high-frequency socket telemetry commands (`report_*`, `ports_kick`, status/progress/log metadata updates).
- For telemetry hot paths:
  - Parse and validate arguments off-main.
  - Dedupe/coalesce off-main first.
  - Schedule minimal UI/model mutation with `DispatchQueue.main.async` only when needed.
- Commands that directly manipulate AppKit/Ghostty UI state (focus/select/open/close/send key/input, list/current queries requiring exact synchronous snapshot) are allowed to run on main actor.
- If adding a new socket command, default to off-main handling; require an explicit reason in code comments when main-thread execution is necessary.

## Socket focus policy

- Socket/CLI commands must not steal macOS app focus (no app activation/window raising side effects).
- Only explicit focus-intent commands may mutate in-app focus/selection (`window.focus`, `workspace.select/next/previous/last`, `surface.focus`, `pane.focus/last`, browser focus commands, and v1 focus equivalents).
- All non-focus commands should preserve current user focus context while still applying data/model changes.

## tm-op 전략 커맨드

활성 에이전트 팀에게 구조화된 전략(발산·수렴·경쟁·파이프라인·분배·숙의·토론·공격방어·브레인스토밍·자율탐색)을 지시한다.
`tm-agent create`로 팀이 먼저 구성되어 있어야 한다.

```bash
/tm-op                                    # 인터랙티브 (전략 선택)
/tm-op refine "결제 API 설계" --rounds 4  # 라운드 기반 정제
/tm-op tournament "로그인 구현"           # 경쟁 투표
/tm-op chain "보안 점검" --steps "explorer:분석,security:식별,reviewer:종합"
/tm-op review --target src/pay.ts         # 코드 다각도 리뷰
/tm-op debate "모놀리스 vs 마이크로서비스" # 정반합 토론
/tm-op red-team --target src/auth.ts      # 적대적 공격/방어
/tm-op brainstorm "v2 기능 아이디어" --vote # 자유 발산 + 투표
/tm-op distribute "6개 Sentry 이슈 분석"  # 병렬 분배 실행
/tm-op council "ECS vs K8s" --rounds 4    # 다자간 숙의 회의
/tm-op research "Rust error handling"     # 자율 multi-agent 탐색 (board.jsonl stigmergy)
```

| 전략 | 설명 |
|------|------|
| **refine** | 라운드 기반 발산→수렴→검증. 전원 독립 답변 후 종합·투표·검증 반복. `--rounds N` |
| **tournament** | 전원 동시 경쟁 후 익명 투표로 최고 결과 채택. `--judge <agent>` 지정 가능 |
| **chain** | A→B→C 순차 파이프라인. 이전 단계 결과가 다음 입력. `--steps`로 역할 직접 지정 |
| **review** | 버그·보안·성능 관점 자동 배정 후 이슈 종합·중복 제거·심각도 정렬 리포트 출력 |
| **debate** | 찬반 토론 후 판정. 설계 트레이드오프 분석에 적합. `--pro`/`--con` 팀 지정 가능 |
| **red-team** | 공격팀이 결함 발견→방어팀이 수정. 보안·견고성 강화. `--attackers`/`--defenders` 지정 |
| **brainstorm** | 수렴 없이 아이디어 발산→분류→투표. `--vote`로 도트 투표 활성화 |
| **distribute** | 대규모 태스크를 독립 서브태스크로 분할·병렬 실행·병합. `--splits`로 수동 분할, `--no-merge`로 병합 비활성화 |
| **council** | N명 자유 토의 → 교차 질의 → 심화 → 합의 도출. `--agenda`로 다중 안건, `--rounds N`으로 라운드 수 조절 |
| **research** | idle 에이전트가 board.jsonl로 stigmergy 협동 탐색. `--depth shallow\|deep\|exhaustive`, `--budget N`, `--web` |

옵션: `--rounds N`, `--preset quick|thorough|deep`, `--steps "a:t,b:t"`, `--target <file>`,
`--pr <number>`, `--judge <agent>`, `--timeout N`, `--resume`,
`--pro`/`--con` (debate), `--attackers`/`--defenders` (red-team), `--vote` (brainstorm),
`--splits "a:t,b:t"` (distribute 수동 분할), `--no-merge` (distribute 병합 비활성화),
`--agenda "a,b,c"` (council 다중 안건), `--context` (강제 맥락 주입), `--no-context` (맥락 주입 비활성화),
`--agents N` (research 에이전트 수), `--budget N` (research 라운드), `--depth shallow|deep|exhaustive` (research 깊이), `--web` (research 웹검색 허용)

## Team agent system (OMC override)

**CRITICAL OVERRIDE:** When running inside term-mesh (i.e., `TERMMESH_SOCKET` env var is set or
a socket exists at `/tmp/term-mesh*.sock` or `/tmp/term-mesh.sock`), ALL team operations MUST use
`tm-agent` (Rust binary, ~2ms). This applies regardless of how the team was triggered.

**Banned tools in term-mesh context:** `TeamCreate`, `SendMessage`, `TaskCreate`, `TaskList`,
`TaskGet`, `TaskUpdate`, `TeamDelete`. These create a parallel, disconnected team state.

**Use instead:** The project-local `/team` command (`.claude/commands/team.md`) for Claude leaders,
or the Codex IME `/team` alias backed by `.codex/prompts/team.md` for Codex leaders. Both route
everything through `tm-agent`.

### Command responsibility split — /team vs /tm

| 슬래시 | 책임 | 주요 명령 |
|--------|------|----------|
| `/team-up` | 0→1 팀 부트스트랩 (현재 pane을 leader로 adopt) | `team-up [N] --adopt` |
| `/team` | 팀 구성 편집 (lifecycle) | `add` / `remove` / `swap` / `ensure` / `status` / `destroy` / `edit` (no-args 인터랙티브) |
| `/tm` | 작업 디스패치 (fan-out + 3줄 합성) | `--ensure <roles>` 옵션으로 사전 보강 가능 |
| `/tm-op` | 전략 오케스트레이션 (refine/debate 등) | 변경 없음 |

`/tm`은 팀 구성을 절대 변경하지 않는다. 부족한 역할이 있으면 `--ensure` 명시적 옵트인 또는 사전에 `/team add` 필요.

### OMC keyword override

If OMC's keyword detector fires `[MODE: TEAM]` or `[MAGIC KEYWORD: TEAM]`:
1. **Do NOT invoke `/oh-my-claudecode:team`** — it uses Claude Code native teams
2. **Instead invoke `/team`** (the project-local command) or use `tm-agent` directly

### Codex leader prompt shims

Codex does not use Claude's `.claude/commands` slash-command format, and current Codex TUI builds
do not accept `/prompts:<name>` as an interactive slash command. Project-local Codex prompt shims
live under `.codex/prompts/`.

In the term-mesh IME box, Codex panes get short aliases that expand on submit into a normal Codex
message: "read `.codex/prompts/<name>.md` and execute it with these arguments." Claude panes keep
the original Claude slash commands.

| Claude leader | Codex leader | Purpose |
|---------------|--------------|---------|
| `/team ...` | `/team ...` via IME alias | Low-level `tm-agent` primitive wrapper |
| `/team-up ...` | `/team-up ...` via IME alias | Create a team with the current pane adopted as leader |
| `/tm "..."` | `/tm "..."` via IME alias | One-shot fan-out to all idle agents + synthesis |
| `/tm-op ...` | `/tm-op ...` via IME alias | Strategy orchestration |
| `/tm-bench ...` | `/tm-bench ...` via IME alias | Agent team communication benchmark |
| `/watch ...` | `/watch ...` via IME alias | Stateless drift oversight toggle/review |

The IME alias map lives in `imeSlashCommandAliases()` (`Sources/GhosttySurfaceScrollView.swift`);
each alias points at a `.codex/prompts/<name>.md` shim, read live from the repo. Both the Claude
commands AND the Codex prompts are bundled + installed by `scripts/copy-claude-commands.sh`
(build phase: `COMMANDS`/`SKILLS`/`CODEX_PROMPTS` arrays) and `ClaudeCommandInstaller.swift`
(runtime: `managedCommandNames` → `~/.claude/commands/`, `managedCodexPromptNames` →
`~/.codex/prompts/` for native Codex `/<name>`). Install is version-gated, so new prompts land on
the next version bump. Adding a leader command means touching all of these in lockstep — see the
6-point checklist in `scripts/copy-claude-commands.sh`.

For Codex as the current leader, prefer:

```bash
tm-agent create 3 --adopt
tm-agent attach reviewer --cli codex
```

Use `--claude-leader` only when creating a Claude Code leader pane.

### Agent context lifecycle

Agent panes are reusable workers, not long-term memory stores. Durable project
state must live in the task board, result files, runbook digests, and task
capsules rather than in an individual pane transcript. A restarted agent must be
able to recover its role, constraints, and current assignment from the runbook
digest plus the next `TM-PROTOCOL-v1` task capsule alone.

After an agent completes a task and reports with the Standard Reply Header, the
leader may recycle the idle pane to avoid context compaction and transcript
drift:

```bash
tm-agent recycle <agent>
```

`recycle` is a guarded hard restart. It rejects active non-terminal tasks by
default; checkpoint long-running work first with `tm-agent heartbeat`,
`tm-agent task block`, `tm-agent task review`, or `tm-agent reply` so another
worker can resume from the task board or `~/.term-mesh/results/`. Use compaction
only for a long single task that genuinely must continue in the same pane
context. Use `tm-agent restart <agent> --hard` as the lower-level recovery
escape hatch.

### XM skill agent fan-out routing

xm 스킬(`/xm:build`, `/xm:solver`, `/xm:op`, `/xm:agent` 등)의 SKILL.md가 *Claude Code native Agent tool*을 통한 fan-out을 지시하는 경우(예: x-build research의 4-perspective spawn, x-solver iterate test phase 가설별 spawn), term-mesh 컨텍스트(`TERMMESH_SOCKET` env 또는 `/tmp/term-mesh*.sock` 존재)에서는 **반드시 `tm-agent delegate` × N로 자동 치환**한다.

이유: xm 스킬은 Claude Code native multi-agent를 가정하지만 term-mesh의 OMC override는 native Agent tool 사용 금지. 한 메시지에 모든 delegate를 발사해 진짜 병렬 확보.

#### Substitution rules

| xm 스킬 지시 | term-mesh 대치 |
|------------|---------------|
| "Spawn N Agent tools in parallel" (Research/Plan-check/Test) | 단일 Bash 메시지에서 `tm-agent delegate <agent> "$INSTR" &` × N + `wait` |
| "Spawn one Agent tool per perspective" (4 perspectives 등) | idle agent 중 4–6에 1 INSTR 동시 발사. agent role lens가 perspective 역할 자연 수행 |
| `model: "sonnet"` (Agent tool 옵션) | 무시 — 각 agent의 model은 `tm-agent create` 시 결정됨 |
| "fan-out", "broadcast", "swarm" 원시 | `/tm "<instruction>"` 또는 `tm-agent delegate` × N (broadcast는 claude-CLI 전용; mixed CLI는 delegate) |

#### 4-perspective → role mapping (xm:build research용)

xm:build research 표준 4 perspectives의 role 매핑:

| xm perspective | 권장 agent role |
|---------------|----------------|
| stack | reviewer |
| features | frontend |
| architecture | architect |
| pitfalls | security |

여분의 idle agents(tester / refactorer 등)는 보너스 관점으로 추가 동원해도 됨 — 정보량 +50%, 비용 ~0(단일 Bash 메시지).

#### 결과 합성

xm 스킬은 일반적으로 raw agent output을 직접 보여줄 것을 요구. /tm은 3-line synthesis 강제. **둘 다 한다**:
1. `tm-agent collect --headers` → STATUS/NEXT 표 출력
2. `[결론][충돌][다음]` 3줄 synthesis 출력
3. 각 agent의 task_id.md path를 `xm build save research-notes --agent <name>` 등 xm 스킬 cli에 저장

이 패턴은 `/tm` Workflow Step 4와 같음. xm 스킬의 phase 통과 검증 (`gate pass`, `phase next`)은 정상 진행.

#### Worktree lifecycle (xm:build implement용)

xm:build가 implementation/fix 단계 task를 분배할 때는 `tm-agent delegate ... --worktree auto`가 기본이다. `auto`는 mutating role(executor/frontend/backend) 또는 구현·수정·리팩터 키워드에서만 `git-kit wt acquire <branch>`를 실행하고, review/research/plan 계열은 기존 cwd를 쓴다. 강제 격리는 `--worktree always`, 비활성화는 `--worktree off`, base ref 지정은 `--from <ref>`를 쓴다.

worktree task capsule에는 `WORKTREE_PATH`, `WORKTREE_BRANCH`, `WORKDIR_INSTRUCTION`이 들어간다. agent는 반드시 해당 path를 cwd로 사용하고, 완료 보고 후 leader가 다음을 실행한다:

```bash
tm-agent task finish-worktree <task_id> --to parent --cleanup
```

push까지 필요한 land 흐름은 `--push`를 붙인다. stale/merged 정리는 필요 시 leader가 `git-kit wt cleanup --merged --stale 7d` dry-run 후 `-y`로 확정한다.

#### Bypass (드물게 native가 더 적합한 경우)

native Agent tool이 더 적합한 경우(예: 단일 isolated investigation, 외부 worktree 격리 필요)는 위 규칙 미적용. 이 경우 CLAUDE.md의 "DELEGATE-FIRST PRINCIPLE" 자체는 여전히 유효하며, `tm-agent` 외 다른 본인 도구 사용 가능.

### Quick CLI reference

**All operations** use `tm-agent` (Rust, ~2ms; fallback `./scripts/tm-agent.sh` ~10ms):

```bash
# Lifecycle (/team)
/team                      # interactive editor
/team status               # formatted team table
/team add reviewer         # attach default claude/sonnet reviewer
/team add executor --model opus  # attach with opus model
/team add reviewer --cli codex   # attach codex-backed reviewer
/team remove writer        # detach writer
/team swap executor opus   # change executor model
/team ensure reviewer security  # idempotent — add only if missing
/team destroy              # 2-step confirm then teardown

# Dispatch (/tm)
/tm "이 PR 보안 리뷰"                              # fan-out to all idle
/tm --ensure reviewer,security "이 PR 보안 리뷰"   # auto-add missing roles first
```

```bash
# Team lifecycle (tm-agent raw)
tm-agent create [N] [--claude-leader]          # creates a new workspace with agents
tm-agent create [N] --adopt                    # adopt current pane as leader (Codex/Claude/Kiro/Gemini)
tm-agent destroy
tm-agent status
tm-agent list

# Agent runbooks (repo-local role behavior)
tm-agent runbook status
tm-agent runbook init [--dry-run] [--force]
tm-agent runbook digest [--agent <role>]       # compact prompt-efficient role brief
tm-agent runbook install --tool claude|codex|opencode|all [--agent <role>] [--dry-run] [--force]

# Team-scoped add/remove (works for headless AND GUI teams — no workspace ID required)
tm-agent add <role> [--name N] [--model M] [--cli claude|codex|kiro|gemini]
tm-agent remove <agent_name> [--force]
# Examples:
#   tm-agent add reviewer                   # add reviewer to current team (any team type)
#   tm-agent add executor --model opus      # add executor with opus model
#   tm-agent remove reviewer               # remove agent from team (--force default: true)
# `add` routes to team.add_agent Swift RPC; rejects duplicate name within team.
# `remove` routes to team.detach Swift RPC; team-name–scoped (not workspace-panel–scoped).

# Workspace-local attach/detach (NO new workspace — uses the caller's current one)
tm-agent attach <agent_type> [--name N] [--model M] [--cli claude|codex|kiro|gemini]
tm-agent detach <agent_name>
# Examples:
#   tm-agent attach reviewer                    # split reviewer pane into current workspace
#   tm-agent attach executor --model opus       # opus-backed executor
#   tm-agent attach security --name sec1        # custom agent name
#   tm-agent detach reviewer                    # close reviewer pane, keep leader pane
# First attach auto-creates team `ws-<first8hex>` from the current workspace UUID.
# The calling pane becomes the leader (adopted). Last detach destroys the team but
# preserves the leader pane. Rejected if the workspace already hosts a `create`-based team.

# Leader → agent communication
tm-agent send <agent> '<instruction>'
tm-agent delegate <agent> '<instruction>' [--context '<prior context>']
tm-agent delegate executor 'implement T1' --worktree auto
tm-agent delegate executor 'implement T1' --worktree always --from develop
tm-agent broadcast '<instruction>'
tm-agent fan-out 'implement phase tasks' --worktree auto
tm-agent read <agent> --lines 100
tm-agent collect --lines 100
tm-agent collect --headers                    # header-only result collection for token-efficient synthesis
tm-agent reports --summary                    # headers + concise summaries, full files lazy-read via FULL_REPORT
tm-agent wait --timeout 120 --mode any        # ALWAYS use this to wait; NEVER use `sleep N && tm-agent read`
tm-agent recycle <agent>                      # guarded hard restart for idle/stopped workers; drops transcript context
tm-agent brief <agent>

# Parallel delegation pattern — round-robin routing (active since d69c9d0c)
# Sequential delegate routes to DIFFERENT panels automatically:
#   1. tm-agent delegate executor 'task A'   # → executor panel 1
#   2. tm-agent delegate executor 'task B'   # → executor panel 2 (round-robin)
# Both-idle race: if both panels are idle simultaneously, add a 0.5–1s gap or
# use the work-pool pattern (unassigned task create + tm-agent claim).
# Do NOT delegate the same task twice — that always produces duplicate work.
#
# Work-pool / autonomous claim pattern (GAP-4 claim-push active since 3b312b7a):
#   tm-agent task create 'task A'            # unassigned — enters pool
#   tm-agent task create 'task B'            # unassigned — enters pool
#   tm-agent broadcast 'tm-agent claim'       # Option A: all panels claim simultaneously (preferred)
#   tm-agent send executor 'tm-agent claim'; sleep 0.5; tm-agent send executor 'tm-agent claim'  # Option B: round-robin sequential
#   tm-agent task finish-worktree <task_id> --to parent --cleanup  # finish gk wt attached to a task
#
# AUTO-CLAIM-NEXT (self-draining pool — Tier 1 work-stealing): when an agent
# finishes a task and is NOT being auto-recycled, it AUTOMATICALLY claims the
# next task from the UNASSIGNED pool and is pushed its instruction — no second
# `tm-agent claim` broadcast needed per wave. So for the work-pool pattern you
# now kick it ONCE; idle agents drain the pool on their own until it is empty:
#   tm-agent task create 'task A'; tm-agent task create 'task B'; tm-agent task create 'task C'
#   tm-agent broadcast 'tm-agent claim'   # one kick — each agent then auto-pulls the next on finish
# Scope: only consumes UNASSIGNED tasks, so directed delegate/fan-out (which
# create already-ASSIGNED tasks) are unaffected. Dependency-aware: a pooled task
# is only auto-claimed once every task it `dependsOn` has COMPLETED (a failed dep
# does not release it). Auto-claim is skipped on the recycle wave (the pane hard
# restarts). Duplicate-named agents: the push routes by name (round-robin), so a
# sibling pane may receive it — exact per-pane delivery awaits the panel_id fix.
#
# Broadcast reaches ALL panels including duplicate-named agents (BUG-3 fix d69c9d0c):
#   tm-agent broadcast 'msg'   # every pane receives — no name-based collapse
#
# Regression test: ./scripts/test-parallel.sh --skip-team-create

# Agent task lifecycle
tm-agent task start <task_id>
tm-agent task block <task_id> '<reason>'
tm-agent task review <task_id> '<summary>'
tm-agent task fix-attempt <task_id>   # Record a fix attempt (auto-blocks when budget exhausted)
tm-agent heartbeat '<progress summary>'
tm-agent reply '<STATUS/FILES/VERIFY/NEXT/FULL_REPORT header plus result>'  # auto-reports and completes active task

# Token-efficient protocol
# Agent init uses compact runbook digests by default. Set TERMMESH_RUNBOOK_MODE=full
# only when debugging role behavior or when a task truly needs the full source runbook.
# Delegated tasks should use compact task capsules and `TM-PROTOCOL-v1` instead of
# repeating lifecycle instructions. Leaders should read `collect --headers` or
# `reports --summary` first, then open FULL_REPORT only for BLOCKED/NEEDS_REVIEW
# or failed VERIFY cases.

# Messaging
tm-agent msg send '<text>'                    # to leader
tm-agent msg send '<text>' --to <agent_name>  # to another agent
tm-agent inbox                                # check messages
tm-agent msg list --from-agent <agent>        # list messages
tm-agent msg clear                            # clear queue

# Task board
tm-agent task list                        # list all tasks
tm-agent task create '<title>' --assign <agent>
tm-agent task get <id>
tm-agent task update <id> <status>
tm-agent task reassign <id> <agent>
tm-agent task unblock <id>
tm-agent task clear

# Autonomous behaviors
tm-agent research <topic> [options]       # Multi-agent research with board.jsonl stigmergy

# Options:
#   --agents N          Number of agents (default: 0 = all idle claude agents)
#   --budget N          Round count (default: 5)
#   --timeout N         Max wait seconds (default: 600)
#   --depth <d>         shallow|deep|exhaustive (default: deep)
#   --web               Allow web search
#   --focus "hint"      Focus hint for agents
```

### Leader: reading full agent reports

Agent replies are truncated to 1500 chars over the socket. Full reports are saved to files:

```bash
# Read full report for a specific task
cat ~/.term-mesh/results/<team>/<task_id>.md

# Read an agent's latest reply
cat ~/.term-mesh/results/<team>/<agent>-reply.md

# Example: read architect's full report in my-team
cat ~/.term-mesh/results/my-team/architect-reply.md
```

When `tm-agent collect` or `msg list` returns truncated content (ends with `...`), read the corresponding file from `~/.term-mesh/results/` for the full text. Files are auto-cleaned after 24 hours.

### Auto-Fix Budget protocol

When a task has a fix budget (set via `--auto-fix-budget N` on delegate):
- **Before each fix attempt** (build fix, test fix, error correction), run:
  `tm-agent task fix-attempt <task_id>`
- The daemon tracks attempts. When budget is exhausted, the task is auto-blocked.
- Auto-blocked tasks require leader intervention to unblock.
- If no fix budget is set, fix-attempt is optional (count is still tracked).

### Agent Trigger Routing

특정 작업이 발생했을 때 leader가 직접 처리하지 않고 해당 에이전트에 위임한다.
아래 매트릭스는 brainstorm(2026-05-08) Tier 1·2 합의 결과와 persona run 운영 규칙 R1을 영구화한 것이다.

| 시그널 | → 에이전트 | 근거 |
|--------|-----------|------|
| "X is defined where", "all callers of Y", "find pattern across", "what does M depend on" | **explorer** | 심볼 탐색·파일 위치 확인은 grep-first 전문 역할 |
| Sources/Panels/*, Sources/Splits/*, UTType, performKeyEquivalent, 애니메이션, SwiftUI 레이아웃 | **frontend** | AppKit/SwiftUI 컴포넌트 경계 변경 |
| daemon/, term-meshd, JSON-RPC schema 변경, peer-federation Phase 진행 | **backend** | Rust 데몬·IPC 프로토콜 전담 |
| 신규 IPC 커맨드 설계, 모듈 경계 결정, threading/focus 정책, panel layering 계약 | **architect** | 구조적 결정 — 코드 작성 전에 ADR 필요 |
| Process(), 신규 socket 커맨드, 외부 입력 파싱, allowAll 조건 변경, quoting 코드 | **security** | 취약점 패턴 즉시 탐지 의무 |
| executor diff 완료 직후, submodule 포인터 변경, /release·/ship 직전 | **reviewer** | 코드 품질·포인터 정합성 게이트 |
| 기능 브랜치 머지 후, CLI·DX 변경, Settings UI 신규 옵션 추가, /release Step 4 | **writer** | CHANGELOG·README·CLAUDE.md 단일 소스 관리 |
| 파일 3개 이상 동시 변경, Phase·Stage 의존성 존재, 에이전트 2명+ 관여하는 작업 | **planner** | task 분해·의존성 그래프·Phase gate 설계 |
| socket 커맨드 추가, focus policy 변경, split 레이아웃 변경, PR 직전 smoke test | **tester** | VM 기반 통합 테스트 실행 |
| ghostty 서브모듈 변경, GhosttyKit.xcframework 재빌드, zig 빌드 crash | **backend** + **executor** | xcframework 빌드 = ghostty submodule + zig 의존성 |
| dSYM 업로드, Sentry 이슈 분류, 심볼화 실패 디버깅 | **executor** | scripts/upload-dsym.sh 워크플로우 |
| /xm:op·/team 슬래시 커맨드 자체 수정, tm-agent 옵션 추가, 페르소나 프롬프트 갱신 | **architect** + **writer** | 메타 도구 변경 — 설계+문서 동시 |
| executor 완료 후 build·tests 실패, fix 시도 3회+ 반복 블로킹 상황 | **executor** (재위임) + **reviewer** 동시 | 실패 원인 분류 후 fix-attempt budget 소진 전 에스컬레이션 |

> **Anti-pattern — leader가 절대 직접 처리하지 말 것:**
>
> ```bash
> # BAD — leader가 직접 탐색 후 결과를 직접 사용
> grep -r "PeerRelaySession" Sources/ | head -20
> # → 탐색 결과를 leader 컨텍스트에 적재, 탐색 비용 leader가 부담
>
> # GOOD — 탐색을 explorer에 위임, leader는 결과만 소비
> tm-agent delegate explorer 'Find all call sites of PeerRelaySession.connect() — return path:line format'
> tm-agent wait --timeout 30 --mode any
> tm-agent read explorer --lines 50
> ```

### Reply Truncation Protocol

`tm-agent reply`와 `tm-agent collect`는 소켓 전송을 **1500자로 truncate**한다.
풀 내용은 `~/.term-mesh/results/<team>/<agent>-reply.md`에 자동 저장되며, 24시간 후 자동 정리된다.

#### 에이전트 의무

- **응답이 1000자를 초과할 경우** Standard Header의 `FULL_REPORT`에 결과 파일 경로를 넣는다:

```
FULL_REPORT: ~/.term-mesh/results/<team>/<agent>-reply.md
```

- `<team>`: `tm-agent status`의 team_name 필드
- `<agent>`: 현재 agent name

#### Leader가 풀 내용을 읽는 명령

```bash
# 특정 task 전체 결과
cat ~/.term-mesh/results/my-team/<task_id>.md

# 에이전트의 최신 reply
cat ~/.term-mesh/results/my-team/<agent>-reply.md

# 예시: explorer의 탐색 결과 전문
cat ~/.term-mesh/results/my-team/explorer-reply.md
```

> **BAD/GOOD 예시:**
>
> ```bash
> # BAD — collect 결과가 "..." 로 끊겨 핵심 VERIFY 명령이 누락됨
> tm-agent collect --lines 100
> # → "...확인 필요. VERIFY: xcodebuild -scheme term-mesh ..." (잘림)
>
> # GOOD — truncation 감지 후 파일 직접 읽기
> tm-agent collect --lines 100
> # 결과 끝이 "..." 이거나 FULL_REPORT가 n/a가 아니면:
> cat ~/.term-mesh/results/my-team/executor-reply.md
> ```

### Standard Reply Header

모든 에이전트 reply는 다음 **5필드 헤더**로 시작한다.
이 헤더는 brainstorm(2026-05-08) Tier 1 Cluster D 합의 결과를 영구화한 것이다.

```
STATUS: DONE|BLOCKED|NEEDS_REVIEW
FILES: <변경된 파일 경로, 복수 시 공백 구분, 없으면 "none">
VERIFY: <결과를 확인하는 단일 shell 명령, 해당 없으면 "n/a">
NEXT: <leader가 다음에 실행할 액션 한 줄, 없으면 "NONE">
FULL_REPORT: <전체 결과 파일 경로, 해당 없으면 "n/a">
```

- **모든 task**: 5필드 의무. 해당 없으면 `n/a`/`none`/`NONE` 사용.
- 헤더 다음에 페르소나별 본문 포맷이 이어진다 (아래 참조)

#### 페르소나별 포맷과의 관계

Standard Header가 **첫 블록**, 페르소나 고유 포맷이 **본문**이다. 중복 필드(예: security의 VERIFY 필드)는 헤더 VERIFY와 동일 값을 사용한다.

| 에이전트 | 본문 포맷 |
|---------|----------|
| explorer | `path:line — 역할 한 줄` |
| reviewer | `[P0-P3][file:line] 설명 → patch snippet + VERDICT: LGTM\|CHANGES` |
| security | `[SEVERITY][CWE][FILE:LINE][PoC][FIX][VERIFY]` 6필드 |
| planner | `TASK\|PHASE\|OWNER\|INPUT\|OUTPUT\|DEPS\|ACCEPT + tm-agent task create 라인` |
| architect | ADR 섹션 + Swift/Rust 스텁 + sequence pseudo |
| executor | `STATUS\|FILES\|VERIFY\|NEXT\|FULL_REPORT 헤더 + diff/build 결과` |
| frontend | `STATUS\|FILES\|VERIFY\|NEXT\|FULL_REPORT 헤더 + portal 경계 명시 + dlog 이벤트 목록` |
| backend | `STATUS\|FILES\|VERIFY\|NEXT\|FULL_REPORT 헤더 + RPC 변경 시 첫 줄 Swift 영향 YES/NO + CHANGED_FILES` |
| tester | `STATUS\|FILES\|VERIFY + 테스트 케이스 수 N/M + VM 필요 여부` |
| writer | `STATUS\|FILES\|VERIFY\|NEXT\|FULL_REPORT 헤더 + 삽입 위치 + Self-check 한 줄` |

#### Leader가 STATUS·NEXT를 일괄 추출하는 명령

```bash
# 전체 에이전트 collect 후 STATUS·NEXT만 추출
tm-agent collect --lines 100 | grep -E "^(STATUS|NEXT):"

# 특정 에이전트의 헤더만 확인
cat ~/.term-mesh/results/my-team/<agent>-reply.md | head -5
```

## E2E tests

term-mesh has two e2e layers. **Default to socket e2e**; reserve XCUITest for what the socket can't reach.

- **Socket e2e (`tests_v2/` via `termmesh.py`)** — the standard for app logic, layout, focus, splits, workspaces, browser, notifications, CLI parity, and regressions. Authoring/running rules live in **[`tests/CLAUDE.md`](tests/CLAUDE.md)** (single source of truth; auto-loads when working in `tests/` or `tests_v2/`). New tests go in `tests_v2/`.
- **XCUITest (`termMeshUITests/`)** — only for OS-level key routing, menu key-equivalents, system dialogs, and Accessibility-driven interaction.

Run on the UTM macOS VM (never the host). Always via `ssh term-mesh-vm`:

```bash
# Socket e2e suites (VM-only, guarded to user `term-mesh`)
ssh term-mesh-vm 'cd /Users/jinwoo/term-mesh/GhosttyTabs && ./scripts/run-tests-v2.sh'

# XCUITest example
ssh term-mesh-vm 'cd /Users/jinwoo/term-mesh/GhosttyTabs && xcodebuild -project GhosttyTabs.xcodeproj -scheme term-mesh -configuration Debug -destination "platform=macOS" -only-testing:termMeshUITests/UpdatePillUITests test'
```

## Basic tests

Run basic automated tests on the UTM macOS VM (never on the host machine):

```bash
ssh term-mesh-vm 'cd /Users/jinwoo/term-mesh/GhosttyTabs && xcodebuild -project GhosttyTabs.xcodeproj -scheme term-mesh -configuration Debug -destination "platform=macOS" build && pkill -x "term-mesh DEV" || true && APP=$(find /Users/jinwoo/term-mesh/Library/Developer/Xcode/DerivedData -path "*/Build/Products/Debug/term-mesh DEV.app" -print -quit) && open "$APP" --env TERMMESH_SOCKET_MODE=allowAll && for i in {1..20}; do [ -S /tmp/term-mesh-debug.sock ] && break; sleep 0.5; done && python3 tests/test_update_timing.py && python3 tests/test_signals_auto.py && python3 tests/test_ctrl_socket.py && python3 tests/test_notifications.py'
```

## Ghostty submodule workflow

Ghostty submodule is pinned to `JINWOO-J/ghostty` (personal fork of `manaflow-ai/ghostty`).
Changes must be committed in the submodule and pushed to `origin` (JINWOO-J/ghostty) before
updating the parent pointer.

Keep `docs/ghostty-fork.md` up to date with any fork changes and conflict notes.

```bash
cd ghostty
git remote -v  # origin = JINWOO-J/ghostty (fork), upstream = manaflow-ai/ghostty (READ only)
git checkout -b <branch>
git add <files>
git commit -m "..."
git push origin <branch>
```

To keep the fork up to date with upstream (`manaflow-ai/ghostty`):

```bash
cd ghostty
git fetch upstream
git checkout main
git merge upstream/main
git push origin main
```

Then update the parent repo with the new submodule SHA:

```bash
cd ..
git add ghostty
git commit -m "Update ghostty submodule"
```

## Release

Use the `/release` command to prepare a new release. This will:
1. Determine the new version (bumps minor by default)
2. Gather commits since the last tag and update the changelog
3. Update `CHANGELOG.md` and `docs-site/content/docs/changelog.mdx`
4. Run `./scripts/bump-version.sh` to update both versions
5. Commit, tag, and push
6. Upload dSYM debug symbols to Sentry (`./scripts/upload-dsym.sh --build`)

Running from a non-`main` branch: `/release` cuts the release branch from the current HEAD, so the branch's commits are **folded into the release PR** and squash-merged to `main` together with the version bump (one squash commit). The command first guards a clean tree and that the branch isn't behind `origin/main`. To keep the feature commits as a distinct change, merge the branch to `main` on its own PR first, then run `/release` from `main`.

Version bumping:

```bash
./scripts/bump-version.sh          # bump minor (0.15.0 → 0.16.0)
./scripts/bump-version.sh patch    # bump patch (0.15.0 → 0.15.1)
./scripts/bump-version.sh major    # bump major (0.15.0 → 1.0.0)
./scripts/bump-version.sh 1.0.0    # set specific version
```

This updates both `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` (build number).

Manual release steps (if not using the command):

```bash
git tag vX.Y.Z
git push origin vX.Y.Z
./scripts/upload-dsym.sh --build   # builds Release and uploads dSYM to Sentry
```

Notes:
- Versioning: bump the minor version for updates unless explicitly asked otherwise.
- Changelog: always update both `CHANGELOG.md` and the docs-site version.
- Sentry dSYM: required for symbolicated crash reports (EXC_BAD_ACCESS frames otherwise show `None`). `./scripts/upload-dsym.sh` without `--build` uploads the latest Release dSYM already in DerivedData.

## Lessons (x-humble)
<!-- Section managed by x-humble. Manual editing allowed. -->
- STOP: 같은 가설이 2회 실패해도 계속 밀어붙이는 것 — 가설 자체를 폐기하고 다른 방향(데이터/호스트/회귀)으로 전환. (L3, confirmed 2 times, 2026-06-03)
- START: UI/렌더링 버그 디버깅 시 코드·아키텍처 추론 전에 런타임 ground-truth(계측·바이트 단위 로그)부터 확인. (L2, confirmed 2 times, 2026-06-03)
