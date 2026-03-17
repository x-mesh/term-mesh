# Windows and Workspaces

Window/workspace lifecycle and ordering operations.

## Inspect

```bash
term-mesh list-windows
term-mesh current-window
term-mesh list-workspaces
term-mesh current-workspace
```

## Create/Focus/Close

```bash
term-mesh new-window
term-mesh focus-window --window window:2
term-mesh close-window --window window:2

term-mesh new-workspace
term-mesh select-workspace --workspace workspace:4
term-mesh close-workspace --workspace workspace:4
```

## Reorder and Move

```bash
term-mesh reorder-workspace --workspace workspace:4 --before workspace:2
term-mesh move-workspace-to-window --workspace workspace:4 --window window:1
```
