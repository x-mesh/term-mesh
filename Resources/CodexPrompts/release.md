---
description: "term-mesh resumable release — plan, prepare, publish, or resume"
---

# /release — resumable term-mesh release

User provided: $ARGUMENTS

Use `scripts/release.py`; it owns ordering and durable receipts. Do not recreate the release sequence with ad-hoc Git/GitHub commands.

- Empty input or SemVer: run `python3 scripts/release.py plan [version] --json`. Draft a user-facing changelog section from commits since `latest_tag`, write it to a temporary file, show the plan, and obtain explicit approval.
- `status <version>`: run `python3 scripts/release.py status <version> --json`.
- `resume <version>`: read status, obtain approval for the next remote phase, then run `python3 scripts/release.py resume <version> --yes --json`.

Before prepare, run the daemon test suite on the pinned develop SHA, before the relay E2E, on the mac-sub checkout, as one chain so a failed check stops it: `cd /Users/jinwoo/work/term-mesh && git fetch origin && git checkout --detach <pinned-sha> && test "$(git rev-parse HEAD)" = "<pinned-sha>" && git diff --quiet --ignore-submodules HEAD && test -z "$(git status --porcelain -- daemon Proto)" && ./scripts/sync-submodules.sh && cd daemon && cargo test --workspace --no-fail-fast --locked -- --test-threads=4` (4 threads is required: at the runner's default parallelism, PTY tests with wall-clock deadlines fail even though they pass alone). Report the SHA and the passed/failed counts. A compile error or lockfile mismatch is a defect. Any failing test stops the release until the user decides: rerun only the failed tests three times each with `cargo test -p <crate> --bin <name>|--test <name> --locked -- <test names>` taken from cargo's rerun hint. A test is intermittent only if it passes all three reruns and its full-run panic was a timeout; everything else, including any single failure alone, an assertion panic, or an unclear case, is a defect to fix in a separate PR before planning again. The user may release with intermittent tests. State the result in the release summary.

Prepare mutates remote branches and opens a PR. Before it, show the pinned develop SHA, version, changelog, and effects. Then run:

```bash
python3 scripts/release.py prepare <version> --notes-file <temp-file> --yes --json
```

Publish squash-merges, tags, publishes artifacts and Homebrew, and resyncs develop. Ask again after prepare receipts, then run:

```bash
python3 scripts/release.py publish <version> --yes --json
```

On failure, relay the JSON error and last receipt. Do not improvise raw Git recovery; fix the blocker and use `resume`. Completion requires `state: complete` and the `verify` receipt.
