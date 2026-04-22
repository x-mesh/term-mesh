# Release

Prepare a new release for term-mesh. This command updates the changelog, bumps the version, creates a tag, and pushes.

## Steps

1. **Determine the new version number**
   - Get the current version from `GhosttyTabs.xcodeproj/project.pbxproj` (look for `MARKETING_VERSION`)
   - Bump the minor version unless the user specifies otherwise (e.g., 0.12.0 → 0.13.0)

2. **Create a release branch**
   - Create branch: `git checkout -b release/vX.Y.Z`

3. **Gather changes and contributors since the last release**
   - Find the most recent git tag: `git describe --tags --abbrev=0`
   - Get commits since that tag: `git log --oneline <last-tag>..HEAD --no-merges`
   - **Filter for end-user visible changes only** - ignore developer tooling, CI, docs, tests
   - Categorize changes into: Added, Changed, Fixed, Removed
   - **Collect contributors:** For each PR referenced in the commits, get the author:
     ```bash
     gh pr view <N> --repo JINWOO-J/term-mesh --json author --jq '.author.login'
     ```
   - Also check for linked issue reporters (the person who filed the bug):
     ```bash
     gh issue view <N> --repo JINWOO-J/term-mesh --json author --jq '.author.login'
     ```
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
   - Watch the CI workflow: `gh pr checks --watch`
   - If CI fails, fix the issues and push again
   - Wait for all checks to pass before proceeding

9. **Merge the PR into main**
   - Target branch is `main` (see CLAUDE.md — main is the released-version branch).
   - Merge: `gh pr merge <N> --repo JINWOO-J/term-mesh --squash --delete-branch`
   - Capture the squash-merge commit SHA: `gh pr view <N> --repo JINWOO-J/term-mesh --json mergeCommit --jq '.mergeCommit.oid'` — the tag must point at this SHA.

10. **Create and push the tag at the squash-merge commit**
    - `git fetch origin main` (do NOT fast-forward local main — it may carry local-only commits that diverge from the squash-merge result; the tag only needs the remote SHA).
    - `git tag vX.Y.Z <squash-merge-sha>` — tag the exact commit that got merged to main, not whatever local HEAD happens to be.
    - `git push origin vX.Y.Z`

11. **Checkout the tag before building dSYM** *(critical — skipping this uploads the previous version's debug symbols)*
    - `git checkout vX.Y.Z` (detached HEAD on the exact released code)
    - Verify pbxproj matches: `grep -c "MARKETING_VERSION = X.Y.Z" GhosttyTabs.xcodeproj/project.pbxproj` should return ≥ 4. If not, the tag is wrong — stop and diagnose before building.

12. **Upload dSYM debug symbols to Sentry**
    - Build Release and upload: `./scripts/upload-dsym.sh --build` (runs from the tag's working tree, so the dSYM UUID matches the released binary)
    - **Version check:** the script prints `dSYM version: X.Y.Z (N)` — confirm it matches the tag. If it shows an older version, abort and investigate (usually means step 11 was skipped or the tag points at a pre-bump commit).
    - Required for crash symbolication on issues like `EXC_BAD_ACCESS` in Sentry.
    - If upload fails (non-zero exit), the release is still valid — just re-run `./scripts/upload-dsym.sh` (no rebuild) once sentry-cli auth is fixed.

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
- New keyboard shortcut for quick tab switching ([#42](https://github.com/JINWOO-J/term-mesh/pull/42)) — thanks @contributor!

### Fixed
- Memory leak when closing split panes ([#38](https://github.com/JINWOO-J/term-mesh/pull/38)) — thanks @fixer!
- Notification badges not clearing properly ([#35](https://github.com/JINWOO-J/term-mesh/pull/35)) — thanks @reporter for the report!

### Changed
- Improved terminal rendering performance ([#40](https://github.com/JINWOO-J/term-mesh/pull/40))

### Thanks to 4 contributors!

- [@contributor](https://github.com/contributor)
- [@fixer](https://github.com/fixer)
- [@lawrencechen](https://github.com/lawrencechen)
- [@reporter](https://github.com/reporter)
```
