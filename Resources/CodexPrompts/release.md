---
description: "term-mesh resumable release — plan, prepare, publish, or resume"
---

# /release — resumable term-mesh release

User provided: $ARGUMENTS

Use `scripts/release.py`; it owns ordering and durable receipts. Do not recreate the release sequence with ad-hoc Git/GitHub commands.

- Empty input or SemVer: run `python3 scripts/release.py plan [version] --json`. Draft a user-facing changelog section from commits since `latest_tag`, write it to a temporary file, show the plan, and obtain explicit approval.
- `status <version>`: run `python3 scripts/release.py status <version> --json`.
- `resume <version>`: read status, obtain approval for the next remote phase, then run `python3 scripts/release.py resume <version> --yes --json`.

Prepare mutates remote branches and opens a PR. Before it, show the pinned develop SHA, version, changelog, and effects. Then run:

```bash
python3 scripts/release.py prepare <version> --notes-file <temp-file> --yes --json
```

Publish squash-merges, tags, publishes artifacts and Homebrew, and resyncs develop. Ask again after prepare receipts, then run:

```bash
python3 scripts/release.py publish <version> --yes --json
```

On failure, relay the JSON error and last receipt. Do not improvise raw Git recovery; fix the blocker and use `resume`. Completion requires `state: complete` and the `verify` receipt.
