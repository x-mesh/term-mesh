#!/bin/bash
# Copy Claude slash commands + skills AND Codex prompts to the app bundle with managed-file markers.
#
# Invoked from the Xcode "Run Script" build phase (see GhosttyTabs.xcodeproj/project.pbxproj).
# This is the SINGLE source of truth for which commands/skills/codex-prompts ship in the .app
# bundle; do not re-inline this logic into the build phase.
#
# Requires these build-phase env vars: SRCROOT, TARGET_BUILD_DIR, UNLOCALIZED_RESOURCES_FOLDER_PATH.
#
# This script inserts a "<!-- term-mesh-managed: ... -->" marker on line 2 of each
# command file (line 1 stays as the source file's heading so Claude Code's slash
# command picker shows the human-readable description). For SKILL.md files the
# marker goes right after the YAML frontmatter (line 2 of the body).
# ClaudeCommandInstaller.swift checks this marker at runtime:
# - Files WITH the marker in ~/.claude/{commands,skills}/ are overwritten on app update.
# - Files WITHOUT the marker are treated as user-customized and preserved.
#
# NOTE: The bundled files will differ from the source files by 1 line (the marker).
# Source of truth for the file contents: .claude/commands/, .claude/skills/, and
# Resources/CodexPrompts/ in the git repo. Codex distribution prompts intentionally
# do not live under project-local .codex/prompts/.
#
# IMPORTANT: When adding a new command that should be distributed AND installed for users,
# update all FOUR in lockstep:
#   1. the COMMANDS array below (bundles the Claude command into the .app)
#   2. ClaudeCommandInstaller.swift managedCommandNames (installs/overwrites ~/.claude/commands)
#   3. Resources/CodexPrompts/<name>.md + imeSlashCommandAliases()
#   4. the CODEX_PROMPTS array below + ClaudeCommandInstaller.swift managedCodexPromptNames
#      (bundles + installs the Codex prompt into ~/.codex/prompts for native Codex `/<name>`)
set -euo pipefail

SRC_CMDS="${SRCROOT}/.claude/commands"
DEST_CMDS="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/claude-commands"

SRC_SKILLS="${SRCROOT}/.claude/skills"
DEST_SKILLS="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/claude-skills"

SRC_CODEX="${SRCROOT}/Resources/CodexPrompts"
DEST_CODEX="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/codex-prompts"

# Codex skills: Codex lists ~/.codex/skills/<name>/SKILL.md under `$name`; it does
# not expose ~/.codex/prompts as slash commands, so a command that must be
# reachable from Codex's own composer ships as a skill too.
SRC_CODEX_SKILLS="${SRCROOT}/Resources/CodexSkills"
DEST_CODEX_SKILLS="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/codex-skills"

# 설치할 커맨드 파일 목록 — 새 커맨드 추가 시 여기에 파일명 추가
# 이 목록은 Sources/ClaudeCommandInstaller.swift 의 managedCommandNames 와 동기화 유지.
COMMANDS=(tm.md team.md team-up.md tm-op.md tm-bench.md watch.md release.md rc.md)

# 설치할 스킬 목록 (디렉토리명) — 새 스킬 추가 시 여기에 추가
# 각 스킬은 .claude/skills/<name>/SKILL.md 형태여야 함
SKILLS=(term-mesh-cli)

# 설치할 Codex prompt 파일 목록 — Claude COMMANDS 와 짝을 이룬다.
# 이 목록은 Sources/ClaudeCommandInstaller.swift 의 managedCodexPromptNames 와 동기화 유지.
CODEX_PROMPTS=(team.md team-up.md tm.md tm-op.md tm-bench.md watch.md release.md rc.md)

# 설치할 Codex skill 목록 (디렉토리명) — Resources/CodexSkills/<name>/SKILL.md.
# 이 목록은 Sources/ClaudeCommandInstaller.swift 의 managedCodexSkillNames 와 동기화 유지.
CODEX_SKILLS=(rc)

mkdir -p "$DEST_CMDS"

for f in "${COMMANDS[@]}"; do
    if [ -f "$SRC_CMDS/$f" ]; then
        # Emit the source file's first line FIRST so Claude Code reads the
        # human-readable heading (e.g. "# /watch — Stateless Drift Oversight")
        # as the slash-command description. Drop the managed marker on line 2
        # so ClaudeCommandInstaller can still detect this file as term-mesh-owned.
        {
            head -n 1 "$SRC_CMDS/$f"
            echo "<!-- term-mesh-managed: do not remove this line -->"
            tail -n +2 "$SRC_CMDS/$f"
        } > "$DEST_CMDS/$f"
        echo "Copied command $f to bundle"
    else
        echo "warning: $SRC_CMDS/$f not found, skipping"
    fi
done

mkdir -p "$DEST_CODEX"

for f in "${CODEX_PROMPTS[@]}"; do
    if [ -f "$SRC_CODEX/$f" ]; then
        # Codex prompts open with YAML frontmatter. Keep it valid and insert the
        # ownership marker immediately after its closing delimiter.
        awk '
            BEGIN { in_fm = 0; printed_marker = 0 }
            NR == 1 && /^---[[:space:]]*$/ { in_fm = 1; print; next }
            in_fm && /^---[[:space:]]*$/ {
                print
                print "<!-- term-mesh-managed: do not remove this line -->"
                in_fm = 0
                printed_marker = 1
                next
            }
            { print }
        ' "$SRC_CODEX/$f" > "$DEST_CODEX/$f"
        echo "Copied codex prompt $f to bundle"
    else
        echo "warning: $SRC_CODEX/$f not found, skipping"
    fi
done

mkdir -p "$DEST_SKILLS"

for skill in "${SKILLS[@]}"; do
    src_file="$SRC_SKILLS/$skill/SKILL.md"
    if [ -f "$src_file" ]; then
        mkdir -p "$DEST_SKILLS/$skill"
        # Skills have YAML frontmatter, so the marker goes AFTER the closing '---'.
        # Insert marker as an HTML comment on the line right after the frontmatter block.
        awk '
            BEGIN { in_fm = 0; fm_done = 0; printed_marker = 0 }
            NR == 1 && /^---[[:space:]]*$/ { in_fm = 1; print; next }
            in_fm && /^---[[:space:]]*$/ {
                print
                print "<!-- term-mesh-managed: do not remove this line -->"
                in_fm = 0
                fm_done = 1
                printed_marker = 1
                next
            }
            { print }
            END {
                if (!printed_marker) {
                    # No frontmatter; nothing we can do — leader installer will treat as unmanaged
                }
            }
        ' "$src_file" > "$DEST_SKILLS/$skill/SKILL.md"
        echo "Copied skill $skill to bundle"
    else
        echo "warning: $src_file not found, skipping"
    fi
done

mkdir -p "$DEST_CODEX_SKILLS"

for skill in "${CODEX_SKILLS[@]}"; do
    src_file="$SRC_CODEX_SKILLS/$skill/SKILL.md"
    if [ -f "$src_file" ]; then
        mkdir -p "$DEST_CODEX_SKILLS/$skill"
        # Same marker placement as Claude skills: right after the frontmatter.
        awk '
            BEGIN { in_fm = 0; printed_marker = 0 }
            NR == 1 && /^---[[:space:]]*$/ { in_fm = 1; print; next }
            in_fm && /^---[[:space:]]*$/ {
                print
                print "<!-- term-mesh-managed: do not remove this line -->"
                in_fm = 0
                printed_marker = 1
                next
            }
            { print }
        ' "$src_file" > "$DEST_CODEX_SKILLS/$skill/SKILL.md"
        echo "Copied codex skill $skill to bundle"
    else
        echo "warning: $src_file not found, skipping"
    fi
done
