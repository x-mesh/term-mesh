# term-mesh agent guide

Keep this file limited to project-wide invariants and routing. Follow the
nearest directory-level `CLAUDE.md` and the linked runbooks for detailed
procedures. `AGENTS.md` is a symlink to this file.

## Setup and verification

- On a fresh checkout, run `./scripts/setup.sh`. It initializes submodules,
  installs the Metal toolchain, builds or restores GhosttyKit, and enables the
  repository hooks.
- After code changes, run the narrowest relevant test plus the full Debug build,
  then launch an isolated app with `./scripts/reload.sh --tag <task>`. Clean it
  up afterward with the same command plus `--cleanup`.
- Swift unit tests use the `term-mesh-unit` scheme. Register new test files in
  `GhosttyTabs.xcodeproj/project.pbxproj` and confirm that tests actually ran;
  Xcode can succeed after running zero tests.
- Build the daemon with `(cd daemon && cargo build --release)`. Preserve the
  real exit status of builds and tests; use `set -o pipefail` with pipelines.

Detailed build, reload, socket-driving, screenshot, log, and performance
workflows: [`docs/development-workflows.md`](docs/development-workflows.md).

## Project invariants

### Ghostty and UI

- Never add an environment variable after `ghostty_init`. Put all writes in
  `GhosttyEnvironment` in `Sources/GhosttyApp.swift` and use
  `GhosttyEnvironment.setValue(_:forName:)`. The late
  `ghostty_sync_environ()` repair is a safety net, not permission to write late.
- Do not add an app-level display link or call `ghostty_surface_draw` manually;
  rely on Ghostty wakeups and its renderer.
- Mount `SurfaceSearchOverlay` from `GhosttySurfaceScrollView` in
  `Sources/GhosttyTerminalView.swift`, never from a SwiftUI panel container.
- Declare custom drag-and-drop UTTypes in `Resources/Info.plist` under
  `UTExportedTypeDeclarations`.
- `vendor/bonsplit` is tracked vendored code, not a submodule.

The environment failure history and fork contract live in
[`docs/ghostty-fork.md`](docs/ghostty-fork.md).

### Socket command threading policy

- Parse, validate, dedupe, and coalesce telemetry off-main. Never use
  `DispatchQueue.main.sync` for hot paths such as `report_*`, `ports_kick`, or
  status/progress/log updates.
- Schedule only the minimal model/UI mutation with `DispatchQueue.main.async`.
  Direct AppKit/Ghostty UI operations and exact synchronous UI snapshots may
  run on the main actor.
- New socket commands default to off-main; document any main-thread exception
  in code.

### Socket focus policy

- Socket and CLI commands must not activate the app, raise a window, or steal
  macOS focus.
- Only explicit focus-intent commands may change in-app selection: `window.focus`,
  `workspace.select/next/previous/last`, `surface.focus`, `pane.focus/last`,
  browser focus commands, and their v1 equivalents.
- Every other command must preserve the current focus context.

### Ghostty submodule

`ghostty` is the only submodule and points to `JINWOO-J/ghostty`. Work on its
`main` branch, push the submodule commit to `origin/main`, and verify
`git merge-base --is-ancestor HEAD origin/main` before committing the parent
pointer. Never leave a submodule commit detached or reachable only from a
temporary branch. Update [`docs/ghostty-fork.md`](docs/ghostty-fork.md) with
fork changes.

After pulling a changed submodule pointer or `.gitmodules`, run
`./scripts/sync-submodules.sh`.

## Testing

- Default to socket E2E for app behavior. New tests go in `tests_v2/`.
- Run socket E2E only through the `mac-sub` runner, never on the development
  host. The runner can terminate locally running term-mesh apps.
- Reserve XCUITest on `term-mesh-vm` for OS key routing, menu equivalents,
  system dialogs, Accessibility interaction, and pixels the socket cannot test.
- Reproduce UI bugs with a tagged Debug app and verify both socket state and a
  full-screen screenshot. For performance issues, measure A/B/A2 with
  `./scripts/perf-sample.sh`; do not infer from feel.

Commands and test-authoring rules: [`tests/CLAUDE.md`](tests/CLAUDE.md).

## Team operations

When term-mesh is active (`TERMMESH_SOCKET` is set or a
`/tmp/term-mesh*.sock` exists), use the Rust `tm-agent` CLI for every team
operation. Do not use OMC `TeamCreate`, `SendMessage`, `Task*`, or `TeamDelete`;
they create team state the app cannot see. If OMC requests TEAM mode, use
`/team`, never `/oh-my-claudecode:team`.

- `/team-up`: adopt the current pane and create the first team.
- `/team`: change or inspect team membership.
- `/tm`: dispatch and collect work; it changes membership only with `--ensure`.
- `/tm-op`: run a structured strategy on an existing team.
- Wait with `tm-agent wait --timeout <seconds> --mode any`; do not poll with
  `sleep` plus `tm-agent read`. A timeout is not success.
- Concurrent writers need disjoint file ownership or isolated worktrees. Name
  owned and forbidden paths in each task capsule. Only one owner may push a
  branch.
- Verify a worker's real host and path before assigning checks. Linux workers
  cannot run Xcode; Swift changes still need local macOS integration testing.
- Workers must use the reply contract in `.agent-runbooks/_common.md`. Read
  `tm-agent collect --headers` or `tm-agent reports --summary` before opening a
  referenced full report.

Canonical details: [team lifecycle](.claude/commands/team.md),
[dispatch and synthesis](.claude/commands/tm.md),
[worker replies](.agent-runbooks/_common.md), and
[x-kit routing](docs/x-kit-integration.md). Current flags come from
`tm-agent --help`.

## Operational routing

- Native agent profiles, bridge selection, remote environment, and PATH rules:
  [`docs/native-agent-panes.md`](docs/native-agent-panes.md).
- Reclaim agent worktrees, results, logs, and build caches with `tm-agent gc`;
  never delete those directories directly. `sweep` is a dry-run unless
  `--apply` is supplied, and safety blockers still win. See
  [`docs/disk-reclamation.md`](docs/disk-reclamation.md).
- Release only through `/release`. `CHANGELOG.md` is the sole changelog; cover
  every commit since the last tag in user-facing language and upload the dSYM.
  The complete workflow is [`.claude/commands/release.md`](.claude/commands/release.md).
- When adding a leader command, update its Claude command, Codex prompt,
  Codex skill (`Resources/CodexSkills/<name>/SKILL.md`, so `$<name>` works in
  Codex), installer managed-name lists, and IME alias map together.

## Lessons (x-humble)
<!-- Section managed by x-humble. Manual editing allowed. -->

- STOP: 같은 가설이 2회 실패해도 계속 밀어붙이는 것 — 가설 자체를 폐기하고 다른 방향(데이터/호스트/회귀)으로 전환. (L3, confirmed 4 times, 2026-08-20)
- STOP: 원격 E2E host에서 Release·Debug·build·daemon 교체·복수 project를 겹쳐 실행하는 것 — 한 번에 한 topology만 실행하고 CPU/RSS/process baseline 이탈 시 즉시 중단. (L9, confirmed 1 times, 2026-08-20)
- START: UI/렌더링 버그 디버깅 시 코드·아키텍처 추론 전에 런타임 ground-truth(계측·바이트 단위 로그)부터 확인. (L2, confirmed 3 times, 2026-07-20)
- START: 검증 전에 실행 topology를 고정하고 PID·binary path·socket owner·state directory·project 생성 위치를 기록 — Release/Debug와 local/relay 결과를 섞지 않기. (L4, confirmed 2 times, 2026-08-20)
- START: 실패한 기능에 "동작하는 선례"(플러그인·유사 구현)가 있으면 내 가설 실험 전에 그 구현 전체를 독해 — source된 파일 포함. 부분 독해는 답을 옆에 두고 우회하게 만든다. (L5, confirmed 1 times, 2026-07-20)
- START: 같은 결함 클래스가 2회째 나타나면 지점 수정 전에 클래스 인벤토리부터 — 관련 상태 전이 목록과 불변식(고아 프로세스 0, 기록 소실 0 등)을 명시하고, 수정은 그 불변식을 검증하는 테스트와 함께. (L6, confirmed 1 times, 2026-08-19)
- START: relay E2E는 production socket owner → 외부 project 생성 → exact project.presentation → exact workspace/pane → A/B/A2 순서의 hard gate로 실행 — 한 단계라도 실패하면 성공 판정과 다음 단계 금지. (L8, confirmed 1 times, 2026-08-20)
- START: daemon/Project health는 control socket ping만 보지 말고 peer socket pathname의 실제 connect, 단일 owner, exact Project manifest, leader pane attachment까지 함께 검증 — 기존 relay fd가 살아 있어도 새 연결은 이미 죽었을 수 있다. (L10, confirmed 1 times, 2026-08-22)

<!-- gk:agents:begin v26 — managed by `gk agents install`; edit outside this block -->
## Git workflow (git-kit)

### Reach for git-kit first — raw git that has a git-kit path

| Don't (raw git) | Do (git-kit) |
| --- | --- |
| git status / log / diff --stat (orienting: where am I) | git-kit context — one call; add --include=diff,log,precheck,remotes for more |
| git log --grep / -S / --follow / -- <path> (searching history) | git-kit find <query> — messages, changed content and paths in ONE call, across every ref |
| git branch -a / --merged (surveying branches) | git-kit branch list --merged/--unmerged/--gone/--stale --json |
| git add + git commit | git-kit commit (AI groups) — or git-kit commit --plan - to group it yourself |
| git checkout / git switch (to a branch) | git-kit switch |
| git worktree … | git-kit worktree … |
| git pull / fetch / merge / rebase | git-kit pull / sync / merge / rebase (paused states stay in the envelope) |
| git tag + git push (cutting a release) | git-kit ship -y |
| git diff (the full patch) | git-kit diff --raw-patch --json — or --digest for a summary |
| git … && git … && git … (multi-step chains) | git-kit batch --plan - (one transaction) |
| the short gk (shadowed by shell aliases) | git-kit (always the full name) |

Read-only plumbing stays raw — git-kit does not wrap git rev-parse, git config --get, git cat-file, git ls-files, and the like. Use raw git too whenever no git-kit verb matches the exact task: `git show <object>` is object inspection, and the `git log` shapes git-kit log has no flag for (`--stat`, `--name-only`, `--until`) have no replacement. But do not read that as "log is raw territory": a log question that is not "what is recent on this branch" belongs to `git-kit log`, not to `git-kit context`. Context returns a fixed newest-first slice of the CURRENT branch with no formatting control, so another ref, more commits than that slice, or a format/date window is `git-kit log <rev>` / `-n` / `--since` / `--format` — and a two-ref range is `git-kit log A..B`. Do not replace object inspection with `git-kit context`.

### Detail

This repository is driven with git-kit, an agent-native git CLI. Always invoke it as `git-kit` — the short name `gk` is the same binary but is commonly shadowed by shell aliases (oh-my-zsh maps `gk` to gitk), so it is not reliable from an agent shell. Prefix every agent tool call with `GK_AGENT=1 git-kit …` — an agent shell does not persist environment between tool calls, so setting it just once would silently lapse to human-readable prose on the next call (a human at an interactive shell can `export GK_AGENT=1` once instead). With it set, every command emits a uniform envelope — `{state, ok, result}` on success, `{state:"error", ok:false, error:{code, message, remedies:[{command,safety}]}}` on failure — so you branch on fields, never parse prose. `state` is the dispatch key: `ok` (done) · `paused` (a conflict/operation is mid-flight — resume or abort it) · `blocked` (a precondition like a diverged base failed — run the remedy) · `error` (the command failed); `ok` is kept as a derived alias (`ok == state=="ok"`). **Quick start — most agent sessions are three turns:** `git-kit context` (orient) → make your edits → `git-kit land` (commit + pull + push in one transaction); add `git-kit ship -y` to cut a release. Prefer git-kit over raw git — each verb below collapses several git calls into one:

- **Orient first**: `git-kit context` — one call returns branch, upstream, ahead/behind, dirty counts, any in-progress rebase/merge (with resume/abort commands), base-branch drift, worktrees, and `next_actions`. Add `--include=diff,log,precheck,remotes,release` (or `--include=all`) to fuse the uncommitted-change digest (untracked included), the last 5 commits, the next-pull conflict forecast, per-remote drift, and the commits since the latest tag (what is still unreleased) into the same document — one call instead of six; a section that cannot be collected degrades to a `notes` entry, never an error. Never split orientation across separate tool calls (raw git status, then log, then diff): probes spread across turns are the single biggest source of avoidable turns — `git-kit context` collapses them into one, so make it the first action of a session, not a sequence of probes. When re-orienting later in the same session, add `--delta` — the response carries only the fields that changed since your last context call in this worktree (`unchanged: true` when nothing did), so a repeat probe costs a few tokens instead of the full document; `--include` sections always arrive fresh.
- **Wrap up**: `git-kit land` — commit (AI-grouped), pull --with-base, push as one transaction with per-step results; on failure the result names `failed_step` and the resume command. Add `--to parent|base|<branch>` to also forward-merge the current branch: `parent` = one hop to the gk-parent (base fallback), `base` = straight into the base, `<branch>` = chain-walk the parent links hop by hop up to that branch. Make it the default via `land.promote` config or `GK_LAND_PROMOTE` env (value `parent` or a branch name — for the base use its real name, not the word `base`); `--no-push` makes the run local (commit + pull + local merge, no push). `--cleanup` also reclaims fully-merged branches and their worktrees. (`--promote` is the deprecated alias for `--to`; use `git-kit promote <branch>` for the multi-hop parent-chain walk.)
- **Local wrap-up (no network)**: `git-kit promote` — commit, then forward-merge the current branch into its parent/base (gk-parent metadata, trunk fallback); `git-kit promote <branch>` walks the parent chain hop by hop. Nothing is pushed without `--push` — use it when integration is local and land would push too early. Same per-step result contract as land.
- **Batch any sequence**: `git-kit batch --plan -` — run several git-kit commands as one transaction from a JSON plan on stdin: `{"steps":[{"args":["pull","--with-base"]},{"args":["push"]}]}`, optional per-step `on_failure: "abort"|"continue"`. The result reports per-step outcomes plus `failed_step`/`resume`; a gating failure skip-marks the remaining steps. Draft a plan with `--plan-template`, preview with `--dry-run`. N calls → 1.
- **Sync**: `git-kit pull` (add `--with-base` to also fast-forward the local base branch, FF-only). On conflict the result lists the files plus the exact resume/abort commands. `--from <remote>[/<branch>]` integrates from a secondary remote (mirror, org fork) that the upstream chain never fetches — tracking config stays untouched.
- **Forecast before integrating**: `git-kit precheck [target]` — read-only merge-tree simulation (no target = the next pull). Clean → integrate; conflicts listed → pick a strategy first instead of try→abort.
- **Search history**: `git-kit find <query>` — one call searches commit MESSAGES, changed CONTENT (the pickaxe) and PATHS at once, across every ref, and each result says which of the three matched. The turn cost of raw archaeology is not one query — it is that you cannot know which query will hit: `git log --grep` (miss) → `git log -S` (miss) → `git log -- <path>` (hit) is three turns for one answer. Narrow with `--path`/`--since`/`--author`/`--ref`; `--no-content` drops the pickaxe, the slow mode on large repos. It does NOT answer "what is in B that is not in A" — that is a range comparison; use `git-kit log --ahead/--behind --base` for the upstream/base cases.
- **Inspect changes**: `git-kit diff --digest` — per-file change kind, ±lines, hunk count, and the changed symbols, without the patch body. Same ref/path arguments as plain diff (`--staged`, `HEAD~3`, `main..feature`). Read the full patch only for the files the digest makes interesting.
- **Agent worktree lifecycle**: for multi-turn isolated work, acquire a ready worktree first with `git-kit worktree acquire <branch> --json`, then use `result.path` as the cwd for later tool calls; `worktree.init` runs by default, and `--no-init` skips it. Finish from inside that worktree with `git-kit worktree finish --to parent --cleanup` (local promote + remove the linked worktree); add `--push` to use `land --to`, and `--delete-branch` when the finished branch should also be removed. Reclaim old finished worktrees with `git-kit worktree cleanup --merged --stale 7d --json`, then rerun with `-y` after reviewing candidates.
- **Isolated one-shot worktree task**: `git-kit worktree run <branch> --init -- <command>` — create (or reuse) a worktree for `<branch>`, bootstrap it (including reused worktrees), run `<command>` as the cwd, and exit with the command's own exit code. `--cleanup` reclaims success (and deletes the branch if this call created it); failing commands leave the worktree for inspection. `--from <ref>` bases a new branch elsewhere, and `--no-init` skips bootstrap. To find which worktree holds unfinished work without a per-path probe, `git-kit worktree list --json` reports each worktree's branch, ahead/behind, parent, lock state, and dirty counts in one call.
- **Commit / push**: `git-kit commit -f` groups changes into conventional commits; `git-kit push` scans for secrets before pushing.
- **Curated multi-commit**: when YOU decide the grouping instead of the AI, `git-kit commit --plan-template` emits the dirty files as a JSON draft; split it into `{"commits":[{"message":"feat(x): ...","files":[...]}]}` and run `git-kit commit --plan -` — N curated commits in one deterministic call (no AI, secret scan included, backup ref behind `gk commit --abort`). Duplicate/unknown files and malformed messages are rejected up front; files the plan does not cover stay dirty. Use this instead of chaining raw `git add` + `git commit` pairs.
- **History editing**: never open `git rebase -i` (the editor session is unusable for you). Instead: `git-kit rebase --plan-template` emits the commit range as JSON (action/commit/subject/pushed), you decide each commit's fate (pick/squash/fixup/reword/drop), then `git-kit rebase --plan -` validates it (every commit addressed, pushed commits guarded) and drives git's own rebase with a backup ref.
- **Conflicts**: `git-kit resolve` is the conflict-resolution surface; use it only when the user explicitly asks you to resolve conflicts. Mechanical strategies (`--strategy ours|theirs`) resolve and continue the operation, re-resolve later picks with the same strategy, auto-skip emptied picks, and handle delete/modify plus markerless conflicts from index stages. `--no-continue` stops after resolving; `git-kit continue` remains for manually edited resolutions. A paused state is a result — `state:"paused"`, `ok:false`, exit 3 — not an error; resume or abort it rather than running an error remedy.
- **Release**: read the plan first — `git-kit ship --dry-run --json` emits the full release plan (inferred version, CHANGELOG draft, the preflight/watch/verify step lists, and `merge_to_base`). When it looks right, `git-kit ship -y` runs the whole pipeline — preflight (lint/test) → version/CHANGELOG → tag → push → CI watch → artifact verify — and works under GK_AGENT: human progress streams to stderr while stdout stays a clean result envelope `{tag, branch, base, merged_to_base, pushed, shipped_on}` (no `env -u GK_AGENT` dance needed). Preflight (lint/test) gates the release, so validate up front with `git-kit ship --preflight` (runs the configured checks on the working tree — dirty is fine — and never tags or pushes; `{result, steps, failed_step}` under GK_AGENT) and get them green before `-y`; `git-kit commit` also warns on gofmt before it reaches preflight. From a non-base branch (e.g. develop) ship fast-forwards the base (main) and tags there; if history diverged it stops with `state:"blocked"` and the remedy `git-kit sync` (rebase the branch onto its base so base can fast-forward), then ship again. `--wait=false` (or `ship.wait`) skips the CI watch; `ship.auto_confirm` makes `-y` the default. What's still unreleased: `git-kit context --include=release`.
- **Stuck repo** (stale index.lock, orphan merge, prunable worktrees, asymmetric push-only remotes whose merged work never comes down): `git-kit doctor --fix`.
- On any failure run the first entry of `error.remedies` (check `safety` first) instead of retrying variations.
<!-- gk:agents:end -->
