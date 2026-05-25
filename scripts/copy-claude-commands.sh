#!/bin/bash
# Copy Claude slash commands and skills to app bundle with managed-file markers.
#
# Invoked from the Xcode "Run Script" build phase (see GhosttyTabs.xcodeproj/project.pbxproj).
# This is the SINGLE source of truth for which commands/skills ship in the .app bundle;
# do not re-inline this logic into the build phase.
#
# Requires these build-phase env vars: SRCROOT, TARGET_BUILD_DIR, UNLOCALIZED_RESOURCES_FOLDER_PATH.
#
# This script prepends a "<!-- term-mesh-managed: ... -->" marker to each file.
# ClaudeCommandInstaller.swift checks this marker at runtime:
# - Files WITH the marker in ~/.claude/{commands,skills}/ are overwritten on app update.
# - Files WITHOUT the marker are treated as user-customized and preserved.
#
# NOTE: The bundled files will differ from the source files by 1 line (the marker).
# Source of truth for the file contents: .claude/commands/ and .claude/skills/ in the git repo.
#
# IMPORTANT: When adding a new command that should be distributed AND installed for users,
# update all three in lockstep:
#   1. the COMMANDS array below (bundles it into the .app)
#   2. ClaudeCommandInstaller.swift managedCommandNames (installs/overwrites ~/.claude/commands)
#   3. .codex/prompts/<name>.md + imeSlashCommandAliases() (Codex IME alias), if Codex needs it too
set -euo pipefail

SRC_CMDS="${SRCROOT}/.claude/commands"
DEST_CMDS="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/claude-commands"

SRC_SKILLS="${SRCROOT}/.claude/skills"
DEST_SKILLS="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/claude-skills"

# 설치할 커맨드 파일 목록 — 새 커맨드 추가 시 여기에 파일명 추가
# 이 목록은 Sources/ClaudeCommandInstaller.swift 의 managedCommandNames 와 동기화 유지.
COMMANDS=(tm.md team.md team-up.md tm-op.md tm-bench.md watch.md)

# 설치할 스킬 목록 (디렉토리명) — 새 스킬 추가 시 여기에 추가
# 각 스킬은 .claude/skills/<name>/SKILL.md 형태여야 함
SKILLS=(term-mesh-cli)

mkdir -p "$DEST_CMDS"

for f in "${COMMANDS[@]}"; do
    if [ -f "$SRC_CMDS/$f" ]; then
        {
            echo "<!-- term-mesh-managed: do not remove this line -->"
            cat "$SRC_CMDS/$f"
        } > "$DEST_CMDS/$f"
        echo "Copied command $f to bundle"
    else
        echo "warning: $SRC_CMDS/$f not found, skipping"
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
