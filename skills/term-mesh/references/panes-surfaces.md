# Panes and Surfaces

Split layout, surface creation, focus, move, and reorder.

## Inspect

```bash
term-mesh list-panes
term-mesh list-pane-surfaces --pane pane:1
```

## Create Splits/Surfaces

```bash
term-mesh new-split right --panel pane:1
term-mesh new-surface --type terminal --pane pane:1
term-mesh new-surface --type browser --pane pane:1 --url https://example.com
```

## Focus and Close

```bash
term-mesh focus-pane --pane pane:2
term-mesh focus-panel --panel surface:7
term-mesh close-surface --surface surface:7
```

## Move/Reorder Surfaces

```bash
term-mesh move-surface --surface surface:7 --pane pane:2 --focus true
term-mesh move-surface --surface surface:7 --workspace workspace:2 --window window:1 --after surface:4
term-mesh reorder-surface --surface surface:7 --before surface:3
```

Surface identity is stable across move/reorder operations.
