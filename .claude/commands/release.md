# /release — resumable term-mesh release

Release term-mesh through `scripts/release.py`. The script is the execution source of truth: it stores durable receipts in the repository Git common directory, pins candidate SHAs, enforces ordering, and resumes completed steps without repeating them. Do not reimplement its Git/GitHub/artifact workflow in shell commands.

## Arguments

User provided: `$ARGUMENTS`

Accepted forms:

- empty or `<version>`: plan a release; default is the next minor version
- `status <version>`: show durable state
- `resume <version>`: inspect state, then continue after the appropriate approval

## Workflow

1. Run the plan without remote mutation:

   ```bash
   python3 scripts/release.py plan [<version>] --json
   ```

2. Use `latest_tag` and `git log <latest-tag>..origin/develop --no-merges` to draft one changelog section. Include only user-visible changes and contributor credits. The section must start with `## [X.Y.Z] - YYYY-MM-DD`. Write it to a temporary file.

3. Run the required mac-sub relay Project E2E against the pinned develop SHA. It must run create → app restart/adopt → host disconnect/reconnect. A SKIP is a failure. The test holds exact leader attachment and nonzero relay bytes for 15 seconds past each recovery boundary.

   ```bash
   ssh mac-sub 'cd /Users/jinwoo/work/term-mesh && \
     TERMMESH_E2E_REQUIRE_REMOTE_PROJECT=1 \
     TERMMESH_E2E_REATTACH_PHASE=full \
     TERMMESH_E2E_STAGE_REMOTE_FIXTURE=1 \
     TERMMESH_E2E_REMOTE_FIXTURE_SSH_TARGET=root@jw-server \
     TERMMESH_E2E_CANDIDATE_SHA=<pinned-sha> \
     TERMMESH_E2E_RELAY_RECEIPT=<receipt-path> \
     ./scripts/run-tests-v2.sh tests_v2/test_remote_project_restart_reattach.py'
   ```

   All six are required. `STAGE_REMOTE_FIXTURE` and `REMOTE_FIXTURE_SSH_TARGET` are what
   make the run prove the candidate: the runner stages that SHA's daemon on the peer and
   refuses to start without them, so a stale production daemon cannot be mistaken for the
   candidate. `TERMMESH_E2E_REMOTE_LEADER_HOST`, `_DIR` and `_HOST_PROFILE_JSON` are derived
   by the runner once the fixture is up — do not set them by hand.

   The runner's checkout must be detached at the pinned SHA with `daemon` and `Proto` clean,
   or the fixture refuses to stage. The peer host needs the agent CLI already installed.

4. Show the version, pinned develop SHA, changelog, relay receipt, and prepare effects: merge `develop→main`, create/push the release branch, and open the release PR. Ask one explicit confirmation. On approval:

   ```bash
   python3 scripts/release.py prepare <version> --notes-file <temp-file> --relay-e2e-receipt <receipt-path> --yes --json
   ```

5. Report gates and the release PR receipt. Show publish effects: squash merge, exact merge-SHA tag, Release build, dSYM, DMG, GitHub/Linux assets, Homebrew cask, develop resync, and cleanup. Ask one explicit confirmation. On approval:

   ```bash
   python3 scripts/release.py publish <version> --yes --json
   ```

6. On failure, report the JSON error and last completed receipt. Do not improvise raw Git recovery. Fix the stated blocker, then rerun:

   ```bash
   python3 scripts/release.py resume <version> --yes --json
   ```

7. Completion requires `state: complete`, matching `main`/`develop`/tag SHAs, the pinned relay E2E receipt, and all required assets in the `verify` receipt.

8. `cleanup` runs last and reclaims the release checkouts under `~/.cache/term-mesh/release-worktrees` plus the local `chore/release-v*` branches. It is destructive: `git worktree remove --force` discards whatever is in the tree, and `git branch -D` is required because the squash merge leaves the branch unreachable from `main`.

   It claims a version only when that version's own release is settled — the current one, or an older one whose tag shipped, whose lock is free, and whose receipt has `verify` completed. An abandoned or still-running release keeps its checkout, and a branch is deleted only when its tip still equals the commit its own `release_metadata` receipt recorded.

   Because it runs after the release is provably complete, cleanup never fails it: anything it could not reclaim is printed to stderr and recorded in the receipt as `failed_worktrees` / `failed_branches`. Check those before assuming the disk was freed.

   `--keep-worktrees` on publish or resume leaves every claimed checkout in place. For this version's own checkouts the opt-out persists: it drops a `.keep-<name>` sidecar beside each one that later releases honor, listed in the receipt as `kept`. Older checkouts are only deferred to the next release (`deferred`), so keeping one debugging tree does not pin the whole cache. `git worktree lock` is the permanent opt-out for any checkout; delete the sidecar or unlock to hand it back.

## Status

```bash
python3 scripts/release.py status <version> --json
```

Never edit receipts manually. Use `plan <version> --reset` only before remote mutation when the pinned candidate must intentionally be replaced, and explain why first.
