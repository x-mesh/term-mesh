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

3. Show the version, pinned develop SHA, changelog, and prepare effects: merge `develop→main`, create/push the release branch, and open the release PR. Ask one explicit confirmation. On approval:

   ```bash
   python3 scripts/release.py prepare <version> --notes-file <temp-file> --yes --json
   ```

4. Report gates and the release PR receipt. Show publish effects: squash merge, exact merge-SHA tag, Release build, dSYM, DMG, GitHub/Linux assets, Homebrew cask, and develop resync. Ask one explicit confirmation. On approval:

   ```bash
   python3 scripts/release.py publish <version> --yes --json
   ```

5. On failure, report the JSON error and last completed receipt. Do not improvise raw Git recovery. Fix the stated blocker, then rerun:

   ```bash
   python3 scripts/release.py resume <version> --yes --json
   ```

6. Completion requires `state: complete`, matching `main`/`develop`/tag SHAs, and all required assets in the `verify` receipt.

## Status

```bash
python3 scripts/release.py status <version> --json
```

Never edit receipts manually. Use `plan <version> --reset` only before remote mutation when the pinned candidate must intentionally be replaced, and explain why first.
