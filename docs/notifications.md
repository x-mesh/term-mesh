# Notifications

term-mesh provides a notification panel for AI agents like Claude Code, Codex, and OpenCode. Notifications appear in a dedicated panel and trigger macOS system notifications.

## Quick Start

```bash
# Send a notification (if term-mesh is available)
command -v term-mesh &>/dev/null && term-mesh notify --title "Done" --body "Task complete"

# With fallback to macOS notifications
command -v term-mesh &>/dev/null && term-mesh notify --title "Done" --body "Task complete" || osascript -e 'display notification "Task complete" with title "Done"'
```

## Detection

Check if `term-mesh` CLI is available before using it:

```bash
# Shell
if command -v term-mesh &>/dev/null; then
    term-mesh notify --title "Hello"
fi

# One-liner with fallback
command -v term-mesh &>/dev/null && term-mesh notify --title "Hello" || osascript -e 'display notification "" with title "Hello"'
```

```python
# Python
import shutil
import subprocess

def notify(title: str, body: str = ""):
    if shutil.which("term-mesh"):
        subprocess.run(["term-mesh", "notify", "--title", title, "--body", body])
    else:
        # Fallback to macOS
        subprocess.run(["osascript", "-e", f'display notification "{body}" with title "{title}"'])
```

## CLI Usage

```bash
# Simple notification
term-mesh notify --title "Build Complete"

# With subtitle and body
term-mesh notify --title "Claude Code" --subtitle "Permission" --body "Approval needed"

# Notify specific tab/panel
term-mesh notify --title "Done" --tab 0 --panel 1
```

## Integration Examples

### Claude Code Hooks

Add to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Notification": [
      {
        "matcher": "idle_prompt",
        "hooks": [
          {
            "type": "command",
            "command": "command -v term-mesh &>/dev/null && term-mesh notify --title 'Claude Code' --body 'Waiting for input' || osascript -e 'display notification \"Waiting for input\" with title \"Claude Code\"'"
          }
        ]
      },
      {
        "matcher": "permission_prompt",
        "hooks": [
          {
            "type": "command",
            "command": "command -v term-mesh &>/dev/null && term-mesh notify --title 'Claude Code' --subtitle 'Permission' --body 'Approval needed' || osascript -e 'display notification \"Approval needed\" with title \"Claude Code\"'"
          }
        ]
      }
    ]
  }
}
```

### OpenAI Codex

Add to `~/.codex/config.toml`:

```toml
notify = ["bash", "-c", "command -v term-mesh &>/dev/null && term-mesh notify --title Codex --body \"$(echo $1 | jq -r '.\"last-assistant-message\" // \"Turn complete\"' 2>/dev/null | head -c 100)\" || osascript -e 'display notification \"Turn complete\" with title \"Codex\"'", "--"]
```

Or create a simple script `~/.local/bin/codex-notify.sh`:

```bash
#!/bin/bash
MSG=$(echo "$1" | jq -r '."last-assistant-message" // "Turn complete"' 2>/dev/null | head -c 100)
command -v term-mesh &>/dev/null && term-mesh notify --title "Codex" --body "$MSG" || osascript -e "display notification \"$MSG\" with title \"Codex\""
```

Then use:
```toml
notify = ["bash", "~/.local/bin/codex-notify.sh"]
```

### OpenCode Plugin

Create `.opencode/plugins/term-mesh-notify.js`:

```javascript
export const CmuxNotificationPlugin = async ({ $, }) => {
  const notify = async (title, body) => {
    try {
      await $`command -v term-mesh && term-mesh notify --title ${title} --body ${body}`;
    } catch {
      await $`osascript -e ${"display notification \"" + body + "\" with title \"" + title + "\""}`;
    }
  };

  return {
    event: async ({ event }) => {
      if (event.type === "session.idle") {
        await notify("OpenCode", "Session idle");
      }
    },
  };
};
```

## Environment Variables

term-mesh sets these in child shells:

| Variable | Description |
|----------|-------------|
| `TERMMESH_SOCKET_PATH` | Path to control socket |
| `TERMMESH_TAB_ID` | UUID of the current tab |
| `TERMMESH_PANEL_ID` | UUID of the current panel |

## CLI Commands

```
term-mesh notify --title <text> [--subtitle <text>] [--body <text>] [--tab <id|index>] [--panel <id|index>]
term-mesh list-notifications
term-mesh clear-notifications
term-mesh ping
```

## Best Practices

1. **Always check availability first** - Use `command -v term-mesh` before calling
2. **Provide fallbacks** - Use `|| osascript` for macOS fallback
3. **Keep notifications concise** - Title should be brief, use body for details
