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
| `pre-commit` | Rejects a commit whose staged `daemon/**/*.rs` content fails `rustfmt --check` (edition 2021). Checks the index, not the working tree. Skipped when no such file is staged or `rustfmt` is missing; bypass with `--no-verify`. |
