# Disk reclamation

This document describes `tm-agent gc`, tagged-build cleanup, and the safety
checks around destructive paths. The short operational contract remains in
[`CLAUDE.md`](../CLAUDE.md).

## Disk reclamation (`tm-agent gc`)

Three subsystems create worktrees and none knows about the others — the daemon
(`~/.term-mesh/worktrees/<repo>/term-mesh_wt_<8hex>`), git-kit via
`tm-agent delegate --worktree` (`~/.gk/worktree/...`), and `PeerProjectBootstrap`
agent checkouts (`<root>/<project>-<role>-<yyMMdd>-<hex4>` on an `agent/*`
branch). Plus per-team results, task boards, logs and build caches. `gc` is the
one place that accounts for all of it, locally or on a peer.

```bash
tm-agent gc status                          # size + candidate count per category
tm-agent gc plan [--category X] [--deep]    # every candidate with reasons/blockers
tm-agent gc sweep                           # dry-run — shows what would go
tm-agent gc sweep --apply                   # actually reclaim
```

- **Dry-run is the default.** `sweep` without `--apply` deletes nothing.
- **Blockers beat `--apply`.** Uncommitted changes, commits missing from the
  parent repo, and worktrees an active session or task still points at are
  never removed. `--force` relaxes exactly one blocker (`unopenable`).
- **The daemon's own 6h sweep is narrower still**: only `team_results` (24h),
  `worktree_meta` and `logs`. Team boards require an authoritative live-team
  snapshot and are explicit-only. The unattended sweep never removes a
  worktree or checkout — see `AUTO_CATEGORIES` in
  `daemon/term-meshd/src/gc.rs`.
- Removal goes through git, so the registration is pruned with the directory.
  Deleting the directory alone leaves a `prunable` entry behind.
- **`git worktree remove` refuses any worktree containing a submodule**, and
  every term-mesh worktree has `ghostty` — so that path always fails here. `gc`
  handles it (delete the directory, then prune the registration), but
  `git-kit worktree cleanup -y` **reports the removals and performs none**: it
  swallows git's refusal and still returns `state: ok`. Verify with
  `git worktree list` rather than trusting its output.
- `reload.sh` records the launched PID in a tag-session manifest. The next
  reload immediately removes ended tag sessions; failed managed builds are
  removed on exit, with the 7-day sweep retained as a fallback (override with
  `TERMMESH_RELOAD_TAG_GC_DAYS`, disable with `TERMMESH_RELOAD_TAG_GC=0`). It
  caches under `~/Library/Caches/term-mesh`: SwiftPM dependency checkouts are
  shared by every tag, while the Cargo target directory is **per tag**
  (`cargo-target/<tag>`). Do not collapse the Cargo one into a single shared
  directory — cargo keys its output by package name, so every tag's
  `term-meshd` would land at the same path, and since the daemon build's
  failure is swallowed, a tag whose build broke would ship whichever branch
  last built successfully. `TERMMESH_CARGO_TARGET_DIR` overrides the path and
  takes that collision on itself. Only the binaries the current build produced
  are copied into the bundle — a daemon build that fails is fatal rather than
  falling back to `daemon/target/release`, which this script no longer writes.
  reload refuses to start below 10 GiB free
  (`TERMMESH_BUILD_MIN_FREE_GIB` overrides the threshold). At task completion,
  `./scripts/reload.sh --tag <tag> --cleanup` stops that app and immediately
  reclaims its managed DerivedData, sockets, log, manifest, and Cargo target.
- `tm-agent gc sweep --category build_caches --deep` previews regenerable
  `daemon/target` directories inside inactive worktrees. Add `--apply` to
  remove only those targets while preserving dirty source. Active session/task
  worktrees remain blocked. Shared Cargo/SwiftPM and GhosttyKit caches are
  reported but remain owned by their build scripts; `setup.sh` keeps the 3 most
  recently used GhosttyKit SHAs (`TERMMESH_GHOSTTYKIT_CACHE_KEEP`).
- Peers report free space in `HostStats`, and the sidebar shows a warning badge
  under 5GB or 10%. Run `tm-agent gc` over ssh on that host to reclaim.

VERIFY:

```bash
(cd daemon && cargo test -p term-meshd gc:: && cargo test -p term-meshd host_stats)
./scripts/test-reload-cleanup.sh
```

`bash -n` alone proves the file parses and nothing else, which is not a useful
check on code that runs `rm -rf`. `test-reload-cleanup.sh` sources reload.sh with
`TERMMESH_RELOAD_LIB_ONLY=1` and drives the reclaim helpers against a sandbox:
path-guard rejections, per-tag isolation, and the two cases where reclamation
must refuse — a tag whose app is still running behind a stale manifest PID, and a
rebuild that failed while the previous build is live.

## Stale Project manifests on a host (`tm-agent daemon project-presentations`)

A daemon keeps one durable record per published Project in `peer-project-presentations.json`.

The Host sidebar lists every Project record, including inactive leaders and Projects that are already open.
Use the Project menu to stop and delete an owned Project or remove a stale foreign record.
Project folders and repositories stay on disk.

Only the publisher can delete a live record over the peer protocol.
A host operator can use forced prune for records from any installation.

```bash
tm-agent daemon pp list
tm-agent daemon pp prune                          # preview stale records
tm-agent daemon pp prune --apply
tm-agent daemon pp prune team:<uuid> --apply

tm-agent daemon pp prune --force                  # preview every record
tm-agent daemon pp prune team:<uuid> --force       # preview one record
tm-agent daemon pp prune team:<uuid> --force --apply
```

Without `--force`, unnamed candidates must have no live surfaces and no directory.
Explicit Project IDs bypass the directory check.

With `--force`, candidates include live Projects and records whose directories still exist.
Without Project IDs, forced prune selects every record.

Without `--apply`, prune reports candidates and changes no state.
With `--apply`, prune creates a timestamped backup before it removes records.

Forced prune stops each selected Project's leader and agents, including native CLI descendants.
Surfaces that another Project still references stay alive.
Project folders, repositories, and workspace records stay on disk.

If surface termination fails, the Project record remains available for a retry.
The report names the skipped Project, and the CLI returns a failure status.

Run the same command without `--apply` before each forced removal.
Update both `tm-agent` and `term-meshd` to use `--force`.

VERIFY:

```bash
(cd daemon && cargo test -p term-meshd prune_removes_only_dead_records \
  && cargo test -p term-meshd project_manifest_without_live_surfaces_remains_discoverable)
```
