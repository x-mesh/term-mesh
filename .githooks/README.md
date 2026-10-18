# .githooks

Project-local git hooks. Activate once per clone:

```bash
git config core.hooksPath .githooks
```

To deactivate:

```bash
git config --unset core.hooksPath
```

## Hooks

| Hook | Purpose |
|------|---------|
| `commit-msg` | Strips fenced code-block marker lines (` ``` ` or ` ```lang `) from commit messages. Inline backticks are preserved. |
| `pre-commit` | Rejects a commit that stages `daemon/**/*.rs` while `cargo fmt --all --check` fails. Skipped when no such file is staged or `cargo` is missing; bypass with `--no-verify`. |
