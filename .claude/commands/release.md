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
   - **If on `develop`: do NOT release from here.** `develop` is this repo's integration branch — it mirrors `main` between releases (see the merge-PR history: #106, #108, #112). Releasing from it squashes every accumulated commit into the single `Bump version` commit, so main loses the individual history AND the same changes end up under two different SHAs — after which `develop` and `main` have permanently diverged and every later release fights conflicts. Instead:
     1. Open a `develop → main` PR and merge it **with a merge commit, not squash** (`gh pr merge <N> --merge`). The commits are preserved.
     2. `git checkout main && git merge --ff-only origin/main`
     3. Re-run `/release` from `main`. The release PR then carries only the version bump, which is safe to squash.
   - **If NOT on `main` or `develop`** (e.g. a feature branch like `fix/memory-leak`): the current branch's work is **folded into the release PR** and squash-merged to main together with the version bump. Before cutting the branch, run these guards:
     - **Clean tree:** `git status --porcelain` must be empty. Uncommitted changes are NOT included — commit or stash first.
     - **Not behind main:** `git rev-list --count HEAD..origin/main` must be `0`. If non-zero, rebase or merge `origin/main` into the branch and resolve conflicts before continuing — otherwise the release PR will conflict.
     - **Confirm the fold-in set with the user:** `git log --oneline origin/main..HEAD` — every one of these commits gets **squashed into the single `Bump version to X.Y.Z` commit** on main (history is flattened by the squash-merge in step 9). If the user wants the feature commits preserved as a distinct change, stop and merge the feature branch to main on its own PR first, then re-run `/release` from main.
   - Cut the release branch from the current HEAD: `git checkout -b release/vX.Y.Z`
   - The PR → squash-merge → tag-on-main steps below then carry the folded work into `main`.

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

8. **Monitor CI**
   - **Do NOT use `gh pr checks --watch`** — it polls the GraphQL pool continuously and a
     long CI run can drain thousands of GraphQL calls in a single release.
   - Instead, poll with a bounded loop on the underlying workflow run (uses the REST/core
     pool, and `gh run watch` streams without per-tick GraphQL):
     ```bash
     # Resolve the run id once, then stream it (REST-backed):
     RUN_ID=$(gh run list --repo x-mesh/term-mesh --branch release/vX.Y.Z \
       --limit 1 --json databaseId --jq '.[0].databaseId')
     gh run watch "$RUN_ID" --repo x-mesh/term-mesh --exit-status
     ```
   - If `gh run watch` is unavailable, fall back to a capped manual poll: `gh run view
     "$RUN_ID" --json status,conclusion` every ~30s, max ~40 iterations (~20 min), then
     stop and report rather than polling forever.
   - If CI fails, fix the issues and push again
   - Wait for all checks to pass before proceeding

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
    - Verify: `brew update && brew info --cask x-mesh/tap/term-mesh` should report the new version.

15. **Return to the working branch**
    - `git checkout main` (or `develop`) so subsequent commands don't run on detached HEAD.
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
