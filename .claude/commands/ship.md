# Ship

Fast-track commit and delivery. Two modes: direct push to main, or PR creation.

**Usage:**
- `/ship` or `/ship push` — commit + merge to main + push
- `/ship pr` — commit + create PR to main
- `/ship amend` — amend last commit + force push current branch

## Arguments

$ARGUMENTS — optional: `push` (default), `pr`, or `amend`

## Steps

### 1. Pre-flight checks

```bash
git status
git diff --stat HEAD
git log --oneline -5
```

- If working tree is clean, say "Nothing to ship" and stop.
- Detect current branch name.

### 2. Build verification

Run both builds in parallel (background):
- Swift: `xcodebuild -project GhosttyTabs.xcodeproj -scheme term-mesh -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -5`
- Rust: `cd daemon && cargo build --release 2>&1 | tail -5`

Only run builds for file types that changed:
- If only `.swift` files changed, skip Rust build
- If only `.rs` files changed, skip Swift build
- If neither, skip both

**If build fails, stop and report errors. Do not commit broken code.**

### 3. Commit

- Analyze all staged + unstaged changes
- Auto-generate commit message following project conventions:
  - `feat(scope):` for new features
  - `fix(scope):` for bug fixes
  - `refactor(scope):` for refactoring
  - `chore(scope):` for maintenance
- Stage relevant files (never `git add -A`, be explicit)
- Commit with generated message + `Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>`
- Show the commit to the user for confirmation before proceeding

### 4a. Mode: `push` (default)

- If on a feature branch: `git checkout main && git pull origin main && git merge <branch> && git push origin main`
- If already on main: `git push origin main`
- Report: commit hash, files changed, push status

### 4b. Mode: `pr`

- If on main, create a new branch: `git checkout -b <auto-name-from-commit>`
- Push branch: `git push -u origin <branch>`
- Create PR:
  ```bash
  gh pr create --title "<from commit message>" --body "$(cat <<'EOF'
  ## Summary
  <bullet points from changes>

  ## Build verification
  - [x] Swift build passed
  - [x] Rust build passed

  🤖 Generated with [Claude Code](https://claude.com/claude-code)
  EOF
  )"
  ```
- Report: PR URL

### 4c. Mode: `amend`

- `git add <changed files> && git commit --amend --no-edit`
- If branch has upstream: `git push --force-with-lease`
- Report: amended commit hash

## Safety rules

- NEVER force push to main
- NEVER commit `.env`, credentials, or secrets
- NEVER skip pre-commit hooks
- If submodule pointers changed, verify submodule commits are pushed to remote first (per CLAUDE.md)
- Always show the user what will be committed before committing
