# Release

Prepare a new release for term-mesh. This command updates the changelog, bumps the version, creates a tag, and pushes.

## Steps

1. **Determine the new version number**
   - Get the current version from `GhosttyTabs.xcodeproj/project.pbxproj` (look for `MARKETING_VERSION`)
   - Bump the minor version unless the user specifies otherwise (e.g., 0.12.0 → 0.13.0)

2. **Pick the base, then create the release branch** *(handles running from a non-main branch)*
   - Sync the remote first so the release sits on top of the latest main:
     `git fetch origin main`
   - Detect the current branch: `BRANCH=$(git rev-parse --abbrev-ref HEAD)`
   - **If on `main`:** fast-forward to `origin/main` (`git merge --ff-only origin/main`), then cut the release branch from it.
   - **If on `develop`: do NOT cut the release branch here.** Run **step 2a** first — it lands `develop` on `main` — then continue this step from `main`.
   - **If NOT on `main` or `develop`** (e.g. a feature branch like `fix/memory-leak`): the current branch's work is **folded into the release PR** and squash-merged to main together with the version bump. Before cutting the branch, run these guards:
     - **Clean tree:** `git status --porcelain` must be empty. Uncommitted changes are NOT included — commit or stash first.
     - **Not behind main:** `git rev-list --count HEAD..origin/main` must be `0`. If non-zero, rebase or merge `origin/main` into the branch and resolve conflicts before continuing — otherwise the release PR will conflict.
     - **Confirm the fold-in set with the user:** `git log --oneline origin/main..HEAD` — every one of these commits gets **squashed into the single `Bump version to X.Y.Z` commit** on main (history is flattened by the squash-merge in step 9). If the user wants the feature commits preserved as a distinct change, stop and merge the feature branch to main on its own PR first, then re-run `/release` from main.
   - Cut the release branch from the current HEAD: `git checkout -b release/vX.Y.Z`
   - The PR → squash-merge → tag-on-main steps below then carry the folded work into `main`.

2a. **Land `develop` on `main`** *(only when step 2 started on `develop`)*

   `develop` is this repo's integration branch: PRs merge into it, so between releases it is
   normally **ahead** of `main`. It is not a mirror of `main`. Two consequences, and both are
   release work — do not hand them back to the user as a prerequisite:

   - Releasing straight from `develop` would squash every accumulated commit into the single
     `Bump version` commit. `main` loses the individual history AND the same changes land
     under a second set of SHAs, after which `develop` and `main` have permanently diverged
     and every later release fights conflicts.
   - Whatever is still unpushed, or still labelled `WIP`, on `develop` is part of this
     release's source. Tidy and push it here — after the tag exists it is too late.

   Run these in order. Stop at the first failure and report it.

   1. **Clean tree:** `git status --porcelain` must be empty. Uncommitted changes are not
      released — commit or stash first.
   2. **Tidy WIP commits.** List what would otherwise ship with a WIP subject:
      ```bash
      git log --oneline origin/main..HEAD --no-merges | grep -Ei ' (wip[(:]|wip )' || echo "no WIP commits"
      ```
      If any exist, show them and ask the user whether to squash — this rewrites history, so
      it is never automatic. On approval run `/squash --by-topic` (preview with `--dry-run`
      first) and confirm `git diff origin/main..HEAD --stat` is unchanged before and after.
      If the user declines, continue; the WIP subjects then land on `main` verbatim.
   3. **Push `develop`:** `git-kit push`, then verify nothing is left behind:
      `git rev-list --count @{u}..HEAD` must be `0`. The PR below is built from the *remote*
      branch, so an unpushed commit silently drops out of the release.
   4. **Open or reuse the `develop → main` PR** (`gh pr create` prints the URL; it has no
      `--json`, so take the number off the end):
      ```bash
      PR=$(gh pr list --repo x-mesh/term-mesh --head develop --base main --state open \
        --json number --jq '.[0].number')
      if [ -z "$PR" ]; then
        PR_URL=$(gh pr create --repo x-mesh/term-mesh --base main --head develop \
          --title "Merge develop into main for vX.Y.Z" --body "<commit summary>")
        PR=${PR_URL##*/}
      fi
      ```
   5. **Merge it with a merge commit, never a squash:**
      `gh pr merge "$PR" --repo x-mesh/term-mesh --merge`
      Squashing here is exactly what causes the divergence described above. Do not pass
      `--delete-branch` — `develop` is a permanent branch.
   6. **Move to `main`:** `git checkout main && git fetch origin main && git merge --ff-only origin/main`
   7. Resume step 2 on `main` and cut `release/vX.Y.Z` from it. The release PR then carries
      only the version bump, which is safe to squash.

3. **Gather changes and contributors since the last release**
   - **API budget preflight** — before any `gh` call, check the GraphQL pool:
     ```bash
     gh api rate_limit --jq '.resources.graphql | "graphql remaining=\(.remaining)/\(.limit)"'
     ```
     If `remaining` < 500, stop and tell the user — do NOT proceed with PR/issue lookups
     until the pool resets (the `reset` epoch is in the same payload).
   - Find the most recent git tag: `git describe --tags --abbrev=0`
   - Get commits since that tag: `git log --oneline <last-tag>..HEAD --no-merges`
   - **Filter for end-user visible changes only** - ignore developer tooling, CI, docs, tests
   - Categorize changes into: Added, Changed, Fixed, Removed
   - **Collect contributors — use REST, not GraphQL.** `gh pr view --json` and
     `gh issue view --json` are GraphQL-backed and burn the 5000/hr GraphQL pool one
     call per PR. Use the REST endpoints instead (separate 5000/hr core pool):
     ```bash
     # PR author (REST):
     gh api repos/x-mesh/term-mesh/pulls/<N> --jq '.user.login'
     # Linked issue reporter (REST):
     gh api repos/x-mesh/term-mesh/issues/<N> --jq '.user.login'
     ```
   - **Prefer zero-API extraction when possible:** `git log <last-tag>..HEAD` already
     carries `Co-authored-by:` trailers and `(#N)` PR refs. Parse those first; only fall
     back to `gh api` for PRs whose author can't be derived from the log.
   - De-duplicate the unique PR/issue numbers BEFORE looping — never call `gh api` per
     commit, only once per distinct PR/issue.
   - Build a deduplicated list of all contributor `@handle`s for the release

4. **Update the changelog**
   - Add a new section at the top of `CHANGELOG.md` with the new version and today's date
   - **Only include changes that affect the end-user experience** - things users will see, feel, or interact with
   - Write clear, user-facing descriptions (not raw commit messages)
   - **Credit contributors inline** (see Contributor Credits below)
   - The `web/app/docs/changelog` page parses `CHANGELOG.md` at build time — no separate docs file to update
   - If there are no user-facing changes, ask the user if they still want to release

5. **Bump the version in Xcode project**
   - Run `./scripts/bump-version.sh X.Y.Z` — updates all `MARKETING_VERSION` occurrences (typically 6) and bumps `CURRENT_PROJECT_VERSION`
   - Verify: `grep -c "MARKETING_VERSION = X.Y.Z" GhosttyTabs.xcodeproj/project.pbxproj` should return ≥ 4

6. **Commit and push the release branch**
   - Stage: `CHANGELOG.md`, `GhosttyTabs.xcodeproj/project.pbxproj`
   - Commit message: `Bump version to X.Y.Z`
   - Push: `git push -u origin release/vX.Y.Z`

7. **Create a pull request**
   - Create PR: `gh pr create --title "Release vX.Y.Z" --body "...changelog summary..."`
   - Include the changelog entries in the PR body

8. **Check for branch CI without waiting for a run that cannot exist**
   - Ground truth for this repository: no workflow runs for `release/*` branches or release
     PRs. `ghostty-prebuild` runs only on pushes to `main` / `feat/**`, and `release-linux`
     runs on `v*` tag pushes. An empty branch run is therefore expected, not something to
     retry.
   - **Do NOT use `gh pr checks --watch` or `gh run watch`**. Both can hold the leader on an
     external event with no hard deadline.
   - Resolve the run id exactly once:
     ```bash
     RUN_ID=$(gh run list --repo x-mesh/term-mesh --branch release/vX.Y.Z \
       --limit 1 --json databaseId --jq '.[0].databaseId')
     ```
   - If `RUN_ID` is empty, report `No branch CI configured (expected)` and proceed directly
     to step 9. Do not sleep, retry, or wait for a run to appear.
   - If a run does exist (for example, after a future workflow change), poll it through
     `gh run view "$RUN_ID" --json status,conclusion` every 30 seconds, at most 40 times
     (~20 minutes). Proceed only on conclusion `success`. On failure, cancellation, or the
     attempt cap, stop the release and report the current state plus the next action;
     timeout is not success.

9. **Merge the PR into main**
   - Target branch is `main` (see CLAUDE.md — main is the released-version branch).
   - Merge: `gh pr merge <N> --repo x-mesh/term-mesh --squash --delete-branch`
   - Capture the squash-merge commit SHA via REST (not the GraphQL `gh pr view --json`):
     `gh api repos/x-mesh/term-mesh/pulls/<N> --jq '.merge_commit_sha'` — the tag must
     point at this SHA.

10. **Create and push the tag at the squash-merge commit**
    - `git fetch origin main` (do NOT fast-forward local main — it may carry local-only commits that diverge from the squash-merge result; the tag only needs the remote SHA).
    - `git tag vX.Y.Z <squash-merge-sha>` — tag the exact commit that got merged to main, not whatever local HEAD happens to be.
    - `git push origin vX.Y.Z`
    - The tag push triggers `release-linux.yml`; its Linux assets upload asynchronously.
      Discover only this release's run by filtering on both workflow and merge commit SHA,
      trying every 5 seconds for at most 60 seconds:
      ```bash
      RUN_URL=""
      for attempt in {1..12}; do
        RUN_URL=$(gh run list --repo x-mesh/term-mesh --workflow release-linux.yml \
          --commit <squash-merge-sha> --event push --limit 1 --json url --jq '.[0].url')
        [ -n "$RUN_URL" ] && break
        sleep 5
      done
      ```
      Include `RUN_URL` in the final report when found, but do not wait for completion. If
      it is still empty, report `release-linux run not yet observed` with the workflow page
      URL and continue; this asynchronous discovery timeout does not invalidate the release.

11. **Checkout the tag before building dSYM** *(critical — skipping this uploads the previous version's debug symbols)*
    - `git checkout vX.Y.Z` (detached HEAD on the exact released code)
    - Verify pbxproj matches: `grep -c "MARKETING_VERSION = X.Y.Z" GhosttyTabs.xcodeproj/project.pbxproj` should return ≥ 4. If not, the tag is wrong — stop and diagnose before building.

12. **Upload dSYM debug symbols to Sentry**
    - Build Release and upload: `./scripts/upload-dsym.sh --build` (runs from the tag's working tree, so the dSYM UUID matches the released binary)
    - The script enforces its own correctness and **exits non-zero** rather than uploading a mismatch — it resolves the dSYM from `xcodebuild -showBuildSettings` (never a filesystem search), then refuses if the built app's version differs from the project's, or if the dSYM UUID does not match the app binary. A successful run prints `UUID verified: <uuid>`.
    - **Do not paper over a failure here.** The failure modes it catches all look like success from the outside: Sentry accepts wrong symbols happily, and the damage only surfaces months later as a stack trace that resolves to the wrong lines. If it refuses, fix the cause (usually step 11 was skipped, or a second DerivedData directory exists for this project) and re-run.
    - Required for crash symbolication on issues like `EXC_BAD_ACCESS` in Sentry.
    - If the *upload itself* fails (sentry-cli auth, network), the release is still valid — re-run `./scripts/upload-dsym.sh` without `--build` once fixed.

13. **Build the distributable DMG and publish the GitHub Release**
    - While still on the tag's detached HEAD (from step 11), run `make dmg` — produces `term-mesh-macos-X.Y.Z.dmg` with the ad-hoc signed bundle and bundled Rust binaries.
    - Publish to GitHub: `./scripts/publish-github-release.sh X.Y.Z`
      - Creates/updates the `vX.Y.Z` release on `x-mesh/term-mesh`, uploads the DMG as an asset, and pulls release notes from `CHANGELOG.md`.
      - Safe to re-run; `--clobber` replaces an existing DMG.

14. **Update the Homebrew cask**
    - Run `./scripts/update-homebrew-cask.sh X.Y.Z ./term-mesh-macos-X.Y.Z.dmg`
      - Computes sha256, rewrites `Casks/term-mesh.rb` in `x-mesh/homebrew-tap`, commits as `term-mesh X.Y.Z`, and pushes to `main`.
      - Set `DRY_RUN=1` to stage the change locally without pushing.
    - **The smoke test at the end adapts to whether term-mesh is running.** The cask
      quits the app (`uninstall quit:` plus a preflight `pkill`) — correct for a user
      upgrading, wrong for a release check, and it used to take the maintainer's own
      session down mid-work. So: nothing running → real `brew install` as before;
      something running → mount the DMG and verify the bundle's version plus the tap's
      sha256 instead. `SMOKE_TEST=full` forces the install anyway (quit the app first),
      `SMOKE_TEST=0` skips it.
    - Verify: `brew update && brew info --cask x-mesh/tap/term-mesh` should report the new version.

15. **Return to the working branch, and re-sync `develop`**
    - `git checkout main && git fetch origin main && git merge --ff-only origin/main` so subsequent commands don't run on detached HEAD.
    - **If the release went through step 2a**, `develop` is now behind `main` by the
      version-bump commit. Left behind, the next release's PR carries a stale `CHANGELOG.md`
      and pbxproj version. Fast-forward and push it:
      ```bash
      git checkout develop && git merge --ff-only origin/main && git push origin develop
      ```
      `--ff-only` is deliberate: if it refuses, `develop` gained commits during the release —
      report that to the user rather than forcing a merge.
    - If local `main` diverged from `origin/main` during the release, flag it to the user — don't silently `reset --hard`.

16. **Notify**
    - On success: `say "term-mesh release complete"`
    - On failure: `say "term-mesh release failed"`

## Changelog Guidelines

**Include only end-user visible changes:**
- New features users can see or interact with
- Bug fixes users would notice (crashes, UI glitches, incorrect behavior)
- Performance improvements users would feel
- UI/UX changes
- Breaking changes or removed features

**Exclude internal/developer changes:**
- Setup scripts, build scripts, reload scripts
- CI/workflow changes
- Documentation updates (README, CONTRIBUTING, CLAUDE.md)
- Test additions or fixes
- Internal refactoring with no user-visible effect
- Dependency updates (unless they fix a user-facing bug)

**Writing style:**
- Use present tense ("Add feature" not "Added feature")
- Group by category: Added, Changed, Fixed, Removed
- Be concise but descriptive
- Focus on what the user experiences, not how it was implemented
- Link to issues/PRs if relevant

## Contributor Credits

Credit the people who made each release happen. This builds community and encourages contributions.

**Per-entry attribution** — append contributor credit after each changelog bullet:
- For code contributions (PR author): `— thanks @user!`
- For bug reports (issue reporter, if different from PR author): `— thanks @reporter for the report!`
- Core team (`lawrencecchen`, `austinywang`) contributions get no per-entry callout — core work is the baseline

**Summary section** — add a "Thanks to N contributors!" section at the bottom of each release:
```markdown
### Thanks to N contributors!

- [@user1](https://github.com/user1)
- [@user2](https://github.com/user2)
```
- List all contributors alphabetically by GitHub handle (including core team)
- Link each handle to their GitHub profile
- Include everyone: PR authors, issue reporters, anyone whose work is in the release

**GitHub Release body** — when the release is published, the GitHub Release should also include the "Thanks to N contributors!" section with linked handles.

## Example Changelog Entry

```markdown
## [0.13.0] - 2025-01-30

### Added
- New keyboard shortcut for quick tab switching ([#42](https://github.com/x-mesh/term-mesh/pull/42)) — thanks @contributor!

### Fixed
- Memory leak when closing split panes ([#38](https://github.com/x-mesh/term-mesh/pull/38)) — thanks @fixer!
- Notification badges not clearing properly ([#35](https://github.com/x-mesh/term-mesh/pull/35)) — thanks @reporter for the report!

### Changed
- Improved terminal rendering performance ([#40](https://github.com/x-mesh/term-mesh/pull/40))

### Thanks to 4 contributors!

- [@contributor](https://github.com/contributor)
- [@fixer](https://github.com/fixer)
- [@lawrencechen](https://github.com/lawrencechen)
- [@reporter](https://github.com/reporter)
```
