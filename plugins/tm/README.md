# tm Codex Plugin

This plugin makes term-mesh team workflows available from a normal Codex TUI, without relying on the term-mesh IME box.

## Commands

Plugin commands are namespace-prefixed by Codex:

| Command | Purpose |
| --- | --- |
| `/tm:tm` | Fan out one instruction to idle term-mesh agents and synthesize results |
| `/tm:all` | Alias-style fan-out command with the same workflow as `/tm:tm` |
| `/tm:team` | Team lifecycle, attach/detach, task board, messaging, and status |
| `/tm:up` | Create or adopt a team with the current Codex pane as leader |
| `/tm:op` | Structured strategies such as review, refine, debate, distribute, research |

The bare `/tm` and `/team` aliases remain an IME convenience inside the term-mesh app. Plain Codex plugin commands use `/tm:<command>` because Codex reserves the top-level slash command namespace.

## Install

The repository includes a workspace marketplace at `.agents/plugins/marketplace.json`, so Codex sessions opened in this repo can discover the plugin after restart.

For all workspaces, symlink this directory into `~/plugins/tm` and add a matching entry in `~/.agents/plugins/marketplace.json`:

```json
{
  "name": "local",
  "interface": {
    "displayName": "Local Plugins"
  },
  "plugins": [
    {
      "name": "tm",
      "source": {
        "source": "local",
        "path": "./plugins/tm"
      },
      "policy": {
        "installation": "AVAILABLE",
        "authentication": "ON_INSTALL"
      },
      "category": "Coding"
    }
  ]
}
```

Restart Codex after changing plugin marketplaces.
