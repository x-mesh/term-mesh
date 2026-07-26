# Writer report — agent-pipe-render spike docs

## Source of truth
`docs/spike/agent-pipe-render.md` (new)

## Projections synchronized
| Document | Insertion / change |
|----------|-------------------|
| `CHANGELOG.md` | New `## [Unreleased]` block at top — experimental Added/Changed entries + spike link |
| `CLAUDE.md` (=`AGENTS.md` symlink) | After CLI Profiles: cursor/agy note, new `## Native Agent Panes (experimental)` section, VERIFY commands |
| CLI Profiles bullet | `claude / kiro / codex / gemini` → includes `cursor / agy` in Settings path list |

## Intentionally not updated
- `README.md` — feature is off-by-default spike; avoid presenting as shipped product marketing
- `docs-site/` — not present in this worktree

## Self-check
- Settings UI label matches: **Agent Panes** → Terminal / Native (`SettingsView.swift`)
- tm-agent CLI names unchanged (`delegate`, `send`, `broadcast`)
- cursor binary documented as `cursor-agent`, not editor `cursor`
- UserDefaults keys match `AgentPipeTransport.swift`
- Experimental caveat present in all user-facing entries

## Stale-name grep
All four doc paths cross-reference `agentPipeTransport`, `Agent Panes`, `tm-agent-bridge`, `cursor-agent` consistently (rg verify passed).
