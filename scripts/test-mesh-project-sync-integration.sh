#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: test-mesh-project-sync-integration.sh [options]

Options:
  --profile daemon-only|full  Gate profile (default: daemon-only).
  --with-peerproto            Run `swift test` for swift/PeerProto locally.
  --peerproto-delegated       Mark PeerProto verification as delegated/UNSUPPORTED here.
  --with-app                  Build and tagged-reload the macOS app locally.
  --app-delegated             Mark app verification as delegated/UNSUPPORTED here.
  --ssh-target TARGET         Run scripts/peer-ssh-demo.sh against TARGET.
  --skip-workspace-tests      Explicitly mark Cargo workspace tests UNSUPPORTED.
  -h, --help                  Show this help.

`full` requires an explicit PeerProto and app mode. Omitted SSH target is reported as
UNSUPPORTED, never PASS.
EOF
}

PROFILE=daemon-only
PEERPROTO_MODE=unsupported
APP_MODE=unsupported
SSH_TARGET=
WORKSPACE_TESTS=local

while (($# > 0)); do
    case "$1" in
        --profile)
            [[ $# -ge 2 ]] || { printf 'missing value for --profile\n' >&2; exit 2; }
            PROFILE=$2
            shift 2
            ;;
        --with-peerproto)
            PEERPROTO_MODE=local
            shift
            ;;
        --peerproto-delegated)
            PEERPROTO_MODE=delegated
            shift
            ;;
        --with-app)
            APP_MODE=local
            shift
            ;;
        --app-delegated)
            APP_MODE=delegated
            shift
            ;;
        --ssh-target)
            [[ $# -ge 2 ]] || { printf 'missing value for --ssh-target\n' >&2; exit 2; }
            SSH_TARGET=$2
            shift 2
            ;;
        --skip-workspace-tests)
            WORKSPACE_TESTS=unsupported
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'unknown argument: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

case "$PROFILE" in
    daemon-only|full) ;;
    *) printf 'invalid profile: %s\n' "$PROFILE" >&2; exit 2 ;;
esac

if [[ $PROFILE == full && $PEERPROTO_MODE == unsupported ]]; then
    printf 'full profile requires --with-peerproto or --peerproto-delegated\n' >&2
    exit 2
fi
if [[ $PROFILE == full && $APP_MODE == unsupported ]]; then
    printf 'full profile requires --with-app or --app-delegated\n' >&2
    exit 2
fi

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
ARTIFACT_DIR=${MESH_SYNC_INTEGRATION_ARTIFACT_DIR:-"${TMPDIR:-/tmp}/mesh-project-sync-integration"}
mkdir -p "$ARTIFACT_DIR"

PASS_COUNT=0
UNSUPPORTED_COUNT=0

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    printf 'PASS: %s\n' "$1"
}

unsupported() {
    UNSUPPORTED_COUNT=$((UNSUPPORTED_COUNT + 1))
    printf 'UNSUPPORTED: %s\n' "$1"
}

run_gate() {
    local name=$1
    shift
    printf '\n==> %s\n' "$name"
    "$@"
    pass "$name"
}

json_field() {
    local field=$1
    python3 -c 'import json,sys
data=json.load(sys.stdin)
value=data
for key in sys.argv[1].split("."):
    value=value[key]
print(value)' "$field"
}

wait_for_socket() {
    local socket_path=$1
    local pid=$2
    for _ in $(seq 1 100); do
        [[ -S $socket_path ]] && return 0
        kill -0 "$pid" 2>/dev/null || return 1
        sleep 0.1
    done
    return 1
}

project_sync_cli_smoke() (
    set -euo pipefail
    local scratch daemon_socket daemon_pid project_root add_json project_id scan_json operation_id
    local status_json state
    scratch=$(mktemp -d "${TMPDIR:-/tmp}/mesh-sync-cli.XXXXXX")
    daemon_socket="$scratch/daemon.sock"
    project_root="$scratch/project"
    mkdir -p "$scratch/home" "$project_root"
    printf 'mesh project sync integration\n' >"$project_root/README.md"

    # Invoked indirectly by the EXIT trap.
    # shellcheck disable=SC2329
    cleanup_smoke() {
        if [[ -n ${daemon_pid:-} ]]; then
            kill "$daemon_pid" 2>/dev/null || true
            wait "$daemon_pid" 2>/dev/null || true
        fi
        rm -rf "$scratch"
    }
    trap cleanup_smoke EXIT

    HOME="$scratch/home" \
        TERMMESH_DAEMON_UNIX_PATH="$daemon_socket" \
        TERM_MESH_HTTP_DISABLED=1 \
        "$REPO_ROOT/daemon/target/debug/term-meshd" \
        >"$ARTIFACT_DIR/daemon-smoke.log" 2>&1 &
    daemon_pid=$!
    wait_for_socket "$daemon_socket" "$daemon_pid" || {
        tail -100 "$ARTIFACT_DIR/daemon-smoke.log" >&2 || true
        return 1
    }

    add_json=$(TERMMESH_SOCKET="$daemon_socket" \
        "$REPO_ROOT/daemon/target/debug/tm-agent" project add "$project_root")
    project_id=$(printf '%s' "$add_json" | json_field project_id)
    [[ -n $project_id ]]

    TERMMESH_SOCKET="$daemon_socket" \
        "$REPO_ROOT/daemon/target/debug/tm-agent" project list >/dev/null
    TERMMESH_SOCKET="$daemon_socket" \
        "$REPO_ROOT/daemon/target/debug/tm-agent" project status "$project_id" >/dev/null
    TERMMESH_SOCKET="$daemon_socket" \
        "$REPO_ROOT/daemon/target/debug/tm-agent" project pause "$project_id" >/dev/null
    TERMMESH_SOCKET="$daemon_socket" \
        "$REPO_ROOT/daemon/target/debug/tm-agent" project resume "$project_id" >/dev/null

    scan_json=$(TERMMESH_SOCKET="$daemon_socket" \
        "$REPO_ROOT/daemon/target/debug/tm-agent" project scan "$project_id" \
        --request-id 0123456789abcdef0123456789abcdef)
    operation_id=$(printf '%s' "$scan_json" | json_field operation_id)

    state=
    for _ in $(seq 1 100); do
        status_json=$(TERMMESH_SOCKET="$daemon_socket" \
            "$REPO_ROOT/daemon/target/debug/tm-agent" sync status "$project_id" "$operation_id")
        state=$(printf '%s' "$status_json" | json_field state)
        case "$state" in
            succeeded) break ;;
            failed|cancelled|interrupted)
                printf '%s\n' "$status_json" >&2
                return 1
                ;;
        esac
        sleep 0.1
    done
    [[ $state == succeeded ]]

    TERMMESH_SOCKET="$daemon_socket" \
        "$REPO_ROOT/daemon/target/debug/tm-agent" pairing list "$project_id" >/dev/null
    TERMMESH_SOCKET="$daemon_socket" \
        "$REPO_ROOT/daemon/target/debug/tm-agent" conflict list "$project_id" >/dev/null
    TERMMESH_SOCKET="$daemon_socket" \
        "$REPO_ROOT/daemon/target/debug/tm-agent" gc status "$project_id" >/dev/null
)

cargo_workspace_tests() (
    cd "$REPO_ROOT/daemon"
    cargo test --workspace -- --test-threads=1
)

cargo_debug_build() (
    cd "$REPO_ROOT/daemon"
    cargo build -p term-meshd -p term-mesh-cli
)

cargo_release_daemon_build() (
    cd "$REPO_ROOT/daemon"
    cargo build --release -p term-meshd
)

cd "$REPO_ROOT"
printf 'mesh project sync integration profile: %s\n' "$PROFILE"
printf 'artifacts: %s\n' "$ARTIFACT_DIR"

if [[ $WORKSPACE_TESTS == local ]]; then
    run_gate 'Cargo workspace tests (serial)' cargo_workspace_tests
else
    unsupported 'Cargo workspace tests explicitly skipped by --skip-workspace-tests'
fi

run_gate 'Debug daemon and tm-agent build' cargo_debug_build

run_gate 'CLI/daemon project sync smoke' project_sync_cli_smoke

run_gate 'Security and fault suite' \
    "$REPO_ROOT/scripts/run-security-fault-suite.sh" \
    --report "$ARTIFACT_DIR/security-fault-suite.json"

run_gate 'Mesh project sync benchmark smoke' \
    "$REPO_ROOT/scripts/bench-mesh-project-sync.sh" --smoke \
    --output "$ARTIFACT_DIR/benchmark-smoke.json" --timeout 180

run_gate 'Release daemon build for peer federation smoke' cargo_release_daemon_build

run_gate 'Daemon multi-workspace federation smoke' \
    python3 "$REPO_ROOT/tests_v2/test_peer_workspace_lifecycle.py"

if [[ -n $SSH_TARGET ]]; then
    run_gate 'SSH peer federation smoke' \
        "$REPO_ROOT/scripts/peer-ssh-demo.sh" "$SSH_TARGET"
else
    unsupported 'SSH peer federation smoke requires explicit --ssh-target TARGET'
fi

case "$PEERPROTO_MODE" in
    local)
        run_gate 'PeerProto Swift tests' swift test --package-path "$REPO_ROOT/swift/PeerProto"
        ;;
    delegated)
        unsupported 'PeerProto Swift tests delegated; this runner has no result artifact'
        ;;
    unsupported)
        unsupported 'PeerProto Swift tests excluded by daemon-only profile; use --with-peerproto'
        ;;
esac

case "$APP_MODE" in
    local)
        run_gate 'macOS app Debug build' \
            xcodebuild -project "$REPO_ROOT/GhosttyTabs.xcodeproj" -scheme term-mesh \
            -configuration Debug -destination platform=macOS build
        run_gate 'macOS app tagged reload' \
            "$REPO_ROOT/scripts/reload.sh" --tag mesh-project-sync-integration
        ;;
    delegated)
        unsupported 'macOS app build/reload delegated; this runner has no result artifact'
        ;;
    unsupported)
        unsupported 'macOS app build/reload excluded by daemon-only profile; use --with-app'
        ;;
esac

printf '\nRESULT: PASS_WITH_UNSUPPORTED pass=%d unsupported=%d profile=%s\n' \
    "$PASS_COUNT" "$UNSUPPORTED_COUNT" "$PROFILE"
