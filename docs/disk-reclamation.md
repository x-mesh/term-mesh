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

A daemon keeps one durable record per published Project in
`peer-project-presentations.json`. A record remains in the peer roster when its
surfaces are gone so the owning installation can identify the exact Project and
repair its leader. Normal attach UI does not offer a record whose leader is
authoritatively inactive; the raw roster entry is recovery state, not evidence
of an attachable pane. Only the installation that published a record may delete
it over the peer protocol (`not_owner` otherwise). The host-side command is the
path for everything the protocol refuses:

```bash
tm-agent daemon project-presentations list
tm-agent daemon project-presentations prune                     # dry-run
tm-agent daemon project-presentations prune --apply
tm-agent daemon project-presentations prune --project-id team:<uuid> --apply
```

- `list` shows every record with its live/referenced surface counts, owner and
  whether the recorded directory still exists.
- `prune` without `--project-id` considers only records whose directory is gone
  and whose surfaces are all dead. Named records are removed even if their
  directory exists. A record with any live surface is never removed, whichever
  way it was selected.
- `--apply` first copies the file to `peer-project-presentations.<unix>.bak.json`
  beside it, then removes only the selected records. Workspaces, shells and
  files are never touched; restore by copying the backup back and restarting
  the daemon.

New Project's remote-name collision shows the same facts (host, directory,
Project ID, leader state, ownership) and offers "Delete Project record…" for
records this installation owns whose leader is not running. That delete is
the normal protocol delete: it also stops the panes only that manifest
referenced (leader shell, agent panes); the workspace and files stay. Foreign
records and running leaders point here or to the sidebar respectively.

VERIFY:

```bash
(cd daemon && cargo test -p term-meshd prune_removes_only_dead_records \
  && cargo test -p term-meshd project_manifest_without_live_surfaces_remains_discoverable)
```
