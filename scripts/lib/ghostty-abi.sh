#!/usr/bin/env bash
# Shared ABI guard for the ghostty C API.
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
