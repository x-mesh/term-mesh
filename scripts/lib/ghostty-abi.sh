#!/usr/bin/env bash
# Shared build guard for the GhosttyKit implementation and C API.
#
# Swift compiles the ghostty API *declarations* from the root ghostty.h
# (imported via term-mesh-Bridging-Header.h) but links the *code* from
# libghostty.a inside GhosttyKit.xcframework. The two arrive through separate
# paths and nothing type-checks one against the other, so a mismatch builds
# cleanly and then segfaults at runtime.
#
# 2026-08-04 is the worked example: the ghostty pin added a `uint32_t
# display_id` to ghostty_platform_macos_s, shifting every later field of
# ghostty_surface_config_s. The submodule worktree sat one commit behind, so
# the xcframework symlink still resolved to the older build. Swift wrote
# env_vars at the new offset, libghostty.a read it at the old one, and
# ghostty_surface_new dereferenced NULL as the env array base 2.5s after
# launch.
#
# The xcframework ships the header it was built from, so comparing that
# against the root copy tests the invariant directly — no SHA bookkeeping,
# and it holds no matter how the checkout drifted.

# The ABI check alone is not sufficient when a ghostty change only alters the
# implementation. The v0.186.2 build demonstrated that failure mode: the
# headers still matched, but the root symlink pointed at a framework built from
# an older ghostty commit and omitted the bounded subprocess teardown fix. The
# full guard below therefore also requires the parent pin, submodule checkout,
# framework stamp, and cache symlink SHA to agree.

ghostty_kit_linked_sha() {
    local xcframework="$1" resolved
    [ -L "$xcframework" ] || return 1
    resolved="$(cd "$(dirname "$xcframework")" && realpath "$(basename "$xcframework")" 2>/dev/null)" \
        || return 1
    basename "$(dirname "$resolved")"
}

# Usage: ghostty_abi_is_consistent <project_dir>
# Returns 0 when the root header matches every header shipped in the
# xcframework, non-zero on any mismatch or when either side is missing.
ghostty_abi_is_consistent() {
    local project_dir="$1"
    local root_header="$project_dir/ghostty.h"
    local xcframework="$project_dir/GhosttyKit.xcframework"

    [ -f "$root_header" ] || return 1
    [ -e "$xcframework" ] || return 1

    local header found=0
    while IFS= read -r header; do
        found=1
        cmp -s "$root_header" "$header" || return 1
    done < <(find -L "$xcframework" -name ghostty.h)

    [ "$found" -eq 1 ]
}

# Usage: ghostty_abi_report <project_dir>
# Prints why the check failed, for callers that are about to abort.
ghostty_abi_report() {
    local project_dir="$1"
    local root_header="$project_dir/ghostty.h"
    local xcframework="$project_dir/GhosttyKit.xcframework"

    if [ ! -f "$root_header" ]; then
        echo "  missing root header: $root_header" >&2
        return
    fi
    if [ ! -e "$xcframework" ]; then
        echo "  missing xcframework: $xcframework" >&2
        echo "  Run ./scripts/setup.sh to build or link it." >&2
        return
    fi

    local linked=""
    if [ -L "$xcframework" ]; then
        linked="$(basename "$(dirname "$(readlink "$xcframework")")")"
        echo "  xcframework resolves to: $linked" >&2
    fi

    local header found=0
    while IFS= read -r header; do
        found=1
        if ! cmp -s "$root_header" "$header"; then
            echo "  root ghostty.h differs from ${header#"$project_dir"/}" >&2
        fi
    done < <(find -L "$xcframework" -name ghostty.h)

    if [ "$found" -eq 0 ]; then
        echo "  no ghostty.h found inside the xcframework" >&2
    fi
}

# Usage: ghostty_kit_is_consistent <project_dir>
# Returns 0 only when both the implementation identity and C ABI are current.
ghostty_kit_is_consistent() {
    local project_dir="$1"
    local xcframework="$project_dir/GhosttyKit.xcframework"
    local parent_sha worktree_sha framework_sha linked_sha archive

    parent_sha="$(git -C "$project_dir" rev-parse HEAD:ghostty 2>/dev/null)" || return 1
    worktree_sha="$(git -C "$project_dir/ghostty" rev-parse HEAD 2>/dev/null)" || return 1

    [ -L "$xcframework" ] || return 1
    [ -f "$xcframework/.ghostty_sha" ] || return 1
    framework_sha="$(tr -d '[:space:]' < "$xcframework/.ghostty_sha")"
    linked_sha="$(ghostty_kit_linked_sha "$xcframework")" || return 1

    [ -n "$parent_sha" ] || return 1
    [ "$parent_sha" = "$worktree_sha" ] || return 1
    [ "$parent_sha" = "$framework_sha" ] || return 1
    [ "$parent_sha" = "$linked_sha" ] || return 1

    archive="$(find -L "$xcframework" -path '*/macos-*/*' -type f \
        \( -name ghostty-internal.a -o -name libghostty.a -o -name libghostty-internal.a \) \
        -print -quit 2>/dev/null)"
    [ -n "$archive" ] || return 1

    ghostty_abi_is_consistent "$project_dir"
}

# Usage: ghostty_kit_report <project_dir>
# Prints every implementation/ABI mismatch so one setup run can repair all of
# them rather than exposing failures one at a time.
ghostty_kit_report() {
    local project_dir="$1"
    local xcframework="$project_dir/GhosttyKit.xcframework"
    local parent_sha worktree_sha framework_sha linked_sha archive

    parent_sha="$(git -C "$project_dir" rev-parse HEAD:ghostty 2>/dev/null || true)"
    worktree_sha="$(git -C "$project_dir/ghostty" rev-parse HEAD 2>/dev/null || true)"
    framework_sha="$([ -f "$xcframework/.ghostty_sha" ] && tr -d '[:space:]' < "$xcframework/.ghostty_sha" || true)"
    linked_sha="$(ghostty_kit_linked_sha "$xcframework" 2>/dev/null || true)"

    echo "  parent ghostty pin : ${parent_sha:-missing}" >&2
    echo "  submodule HEAD     : ${worktree_sha:-missing}" >&2
    echo "  framework stamp    : ${framework_sha:-missing}" >&2
    echo "  symlink cache SHA  : ${linked_sha:-missing}" >&2

    if [ ! -L "$xcframework" ]; then
        echo "  GhosttyKit.xcframework is missing or is not the managed cache symlink" >&2
    fi
    if [ -n "$parent_sha" ] && { [ "$parent_sha" != "$worktree_sha" ] || \
        [ "$parent_sha" != "$framework_sha" ] || [ "$parent_sha" != "$linked_sha" ]; }; then
        echo "  implementation SHA mismatch: run ./scripts/setup.sh" >&2
    fi

    archive="$(find -L "$xcframework" -path '*/macos-*/*' -type f \
        \( -name ghostty-internal.a -o -name libghostty.a -o -name libghostty-internal.a \) \
        -print -quit 2>/dev/null || true)"
    if [ -z "$archive" ]; then
        echo "  no macOS Ghostty static archive found inside the xcframework" >&2
    fi

    if ! ghostty_abi_is_consistent "$project_dir"; then
        ghostty_abi_report "$project_dir"
    fi
}
