# Command Reference (term-mesh Browser)

This maps common `agent-browser` usage to `term-mesh browser` usage.

## Direct Equivalents

- `agent-browser open <url>` -> `term-mesh browser open <url>`
- `agent-browser goto|navigate <url>` -> `term-mesh browser <surface> goto|navigate <url>`
- `agent-browser snapshot -i` -> `term-mesh browser <surface> snapshot --interactive`
- `agent-browser click <ref>` -> `term-mesh browser <surface> click <ref>`
- `agent-browser fill <ref> <text>` -> `term-mesh browser <surface> fill <ref> <text>`
- `agent-browser type <ref> <text>` -> `term-mesh browser <surface> type <ref> <text>`
- `agent-browser select <ref> <value>` -> `term-mesh browser <surface> select <ref> <value>`
- `agent-browser get text <ref>` -> `term-mesh browser <surface> get text <ref>`
- `agent-browser get url` -> `term-mesh browser <surface> get url`
- `agent-browser get title` -> `term-mesh browser <surface> get title`

## Core Command Groups

### Navigation

```bash
term-mesh browser open <url>                        # opens in caller's workspace (uses CMUX_WORKSPACE_ID)
term-mesh browser open <url> --workspace <id|ref>   # opens in a specific workspace
term-mesh browser <surface> goto <url>
term-mesh browser <surface> back|forward|reload
term-mesh browser <surface> get url|title
```

> **Workspace context:** `browser open` targets the workspace of the terminal where the command is run (via `CMUX_WORKSPACE_ID`), even if a different workspace is currently focused. Use `--workspace` to override.

### Snapshot and Inspection

```bash
term-mesh browser <surface> snapshot --interactive
term-mesh browser <surface> snapshot --interactive --compact --max-depth 3
term-mesh browser <surface> get text|html|value|attr|count|box|styles ...
term-mesh browser <surface> eval '<js>'
```

### Interaction

```bash
term-mesh browser <surface> click|dblclick|hover|focus <selector-or-ref>
term-mesh browser <surface> fill <selector-or-ref> [text]   # empty text clears
term-mesh browser <surface> type <selector-or-ref> <text>
term-mesh browser <surface> press|keydown|keyup <key>
term-mesh browser <surface> select <selector-or-ref> <value>
term-mesh browser <surface> check|uncheck <selector-or-ref>
term-mesh browser <surface> scroll [--selector <css>] [--dx <n>] [--dy <n>]
```

### Wait

```bash
term-mesh browser <surface> wait --selector "#ready" --timeout-ms 10000
term-mesh browser <surface> wait --text "Done" --timeout-ms 10000
term-mesh browser <surface> wait --url-contains "/dashboard" --timeout-ms 10000
term-mesh browser <surface> wait --load-state complete --timeout-ms 15000
term-mesh browser <surface> wait --function "document.readyState === 'complete'" --timeout-ms 10000
```

### Session/State

```bash
term-mesh browser <surface> cookies get|set|clear ...
term-mesh browser <surface> storage local|session get|set|clear ...
term-mesh browser <surface> tab list|new|switch|close ...
term-mesh browser <surface> state save|load <path>
```

### Diagnostics

```bash
term-mesh browser <surface> console list|clear
term-mesh browser <surface> errors list|clear
term-mesh browser <surface> highlight <selector>
term-mesh browser <surface> screenshot
term-mesh browser <surface> download wait --timeout-ms 10000
```

## Agent Reliability Tips

- Use `--snapshot-after` on mutating actions to return a fresh post-action snapshot.
- Re-snapshot after navigation, modal open/close, or major DOM changes.
- Prefer short handles in outputs by default (`surface:N`, `pane:N`, `workspace:N`, `window:N`).
- Use `--id-format both` only when a UUID must be logged/exported.

## Known WKWebView Gaps (`not_supported`)

- `browser.viewport.set`
- `browser.geolocation.set`
- `browser.offline.set`
- `browser.trace.start|stop`
- `browser.network.route|unroute|requests`
- `browser.screencast.start|stop`
- `browser.input_mouse|input_keyboard|input_touch`

See also:
- [snapshot-refs.md](snapshot-refs.md)
- [authentication.md](authentication.md)
- [session-management.md](session-management.md)
