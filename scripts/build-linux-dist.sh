#!/usr/bin/env bash
# build-linux-dist.sh — cross-compile term-meshd + tm-agent for Linux musl targets.
#
# Uses Docker + rust:alpine so the host needs no Rust/rustup installation.
# Produces statically linked ELF binaries in daemon/target/linux-dist/.
#
# Usage:
#   ./scripts/build-linux-dist.sh                      # both architectures
#   ./scripts/build-linux-dist.sh --arch x86_64        # x86_64 only
#   ./scripts/build-linux-dist.sh --arch aarch64       # aarch64 only
#   ./scripts/build-linux-dist.sh --no-strip           # keep debug symbols
#   ./scripts/build-linux-dist.sh --dry-run            # print commands only
#   ./scripts/build-linux-dist.sh --image rust:1.80-alpine  # custom image
#
# Options:
#   --arch x86_64|aarch64|all   architectures to build (default: all)
#   --no-strip                  do not strip debug symbols from output binaries
#   --dry-run                   print Docker commands without running them
#   --image IMAGE               Docker image (default: rust:alpine)
#   -h, --help                  show this message
#
# Output layout:
#   daemon/target/linux-dist/
#     x86_64-unknown-linux-musl/term-meshd
#     x86_64-unknown-linux-musl/tm-agent
#     aarch64-unknown-linux-musl/term-meshd
#     aarch64-unknown-linux-musl/tm-agent
set -euo pipefail

# ─── defaults ────────────────────────────────────────────────────────────────

ARCH="all"
NO_STRIP=false
DRY_RUN=false
DOCKER_IMAGE="rust:alpine"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── arg parsing ─────────────────────────────────────────────────────────────

usage() {
    sed -n '3,36p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --arch)     ARCH="$2";         shift 2 ;;
        --no-strip) NO_STRIP=true;     shift ;;
        --dry-run)  DRY_RUN=true;      shift ;;
        --image)    DOCKER_IMAGE="$2"; shift 2 ;;
        -h|--help)  usage 0 ;;
        -*) echo "error: unknown option $1" >&2; usage 1 ;;
        *)  echo "error: unexpected argument: $1" >&2; usage 1 ;;
    esac
done

case "$ARCH" in
    x86_64|aarch64|all) ;;
    *) echo "error: --arch must be x86_64, aarch64, or all" >&2; exit 1 ;;
esac

# ─── prerequisite checks ──────────────────────────────────────────────────────

check_prereqs() {
    if ! command -v docker &>/dev/null; then
        echo "error: docker not found." >&2
        echo "  Install Docker Desktop: https://www.docker.com/products/docker-desktop/" >&2
        exit 1
    fi

    if ! docker info &>/dev/null 2>&1; then
        echo "error: Docker daemon is not running." >&2
        echo "  Start Docker Desktop and try again." >&2
        exit 1
    fi

    # --platform requires buildx / Docker 19.03+
    if ! docker buildx version &>/dev/null 2>&1; then
        echo "error: docker buildx not available." >&2
        echo "  Upgrade to Docker Desktop 4.x or install the buildx plugin:" >&2
        echo "  https://docs.docker.com/buildx/working-with-buildx/" >&2
        exit 1
    fi
}

# ─── project root ─────────────────────────────────────────────────────────────

PROJECT_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null \
    || { echo "error: not inside a git repository" >&2; exit 1; })"

DIST="$PROJECT_ROOT/daemon/target/linux-dist"

# ─── helpers ──────────────────────────────────────────────────────────────────

run() {
    if $DRY_RUN; then
        echo "[dry-run]" "$@"
    else
        "$@"
    fi
}

# ─── build function ───────────────────────────────────────────────────────────

build_target() {
    local arch="$1"
    local platform rust_target

    case "$arch" in
        x86_64)
            platform="linux/amd64"
            rust_target="x86_64-unknown-linux-musl"
            ;;
        aarch64)
            platform="linux/arm64"
            rust_target="aarch64-unknown-linux-musl"
            ;;
    esac

    local out_dir="$DIST/$rust_target"
    local build_dir="$PROJECT_ROOT/daemon/target/linux-build/$rust_target"

    if ! $DRY_RUN; then
        mkdir -p "$out_dir" "$build_dir"
    fi

    echo "==> building $rust_target (platform=$platform, image=$DOCKER_IMAGE)"

    # Packages required inside the Alpine container:
    #   musl-dev          — C toolchain for the host target
    #   cmake + make      — needed by vendored-libgit2 build
    #   git               — git2 source fetch in vendored mode
    #   pkgconfig         — pkg-config for openssl-sys
    #   openssl-dev openssl-libs-static — headers; vendored-openssl builds its own but needs perl
    #   perl              — OpenSSL ./Configure script
    #   protobuf-dev      — protoc for peer-proto build.rs
    local apk_pkgs="musl-dev cmake git pkgconfig openssl-dev openssl-libs-static perl make protobuf-dev"

    # term-mesh-cli is the Cargo package that produces the tm-agent binary.
    local cargo_cmd="cargo build --release -p term-meshd -p term-mesh-cli \
        --target-dir /work/daemon/target/linux-build/$rust_target"

    local docker_script="set -euo pipefail
apk add --no-cache $apk_pkgs 2>/dev/null
$cargo_cmd"

    run docker run --rm \
        --platform "$platform" \
        -v "$PROJECT_ROOT:/work" \
        -w /work/daemon \
        "$DOCKER_IMAGE" \
        sh -c "$docker_script"

    if $DRY_RUN; then
        echo "[dry-run] would copy binaries to $out_dir"
        return
    fi

    # Docker writes files owned by root inside the mount; fix ownership.
    local uid gid
    uid="$(id -u)"
    gid="$(id -g)"
    run docker run --rm \
        --platform "$platform" \
        -v "$PROJECT_ROOT:/work" \
        "$DOCKER_IMAGE" \
        sh -c "chown -R $uid:$gid /work/daemon/target/linux-build/$rust_target/release" \
        2>/dev/null || true

    cp "$build_dir/release/term-meshd" "$out_dir/term-meshd"
    cp "$build_dir/release/tm-agent"   "$out_dir/tm-agent"

    if $NO_STRIP; then
        echo "    (debug symbols preserved)"
    else
        # strip is a best-effort — may not be available on the host for cross targets
        strip "$out_dir/term-meshd" 2>/dev/null || true
        strip "$out_dir/tm-agent"   2>/dev/null || true
    fi

    file  "$out_dir/term-meshd" "$out_dir/tm-agent"
    shasum -a 256 "$out_dir/term-meshd" "$out_dir/tm-agent"
}

# ─── main ────────────────────────────────────────────────────────────────────

if ! $DRY_RUN; then
    check_prereqs
fi

echo ""
echo "term-mesh Linux distribution builder"
echo "  project root : $PROJECT_ROOT"
echo "  output dir   : $DIST"
echo "  image        : $DOCKER_IMAGE"
echo "  arch         : $ARCH"
echo "  no-strip     : $NO_STRIP"
echo "  dry-run      : $DRY_RUN"
echo ""

case "$ARCH" in
    all)
        build_target x86_64
        build_target aarch64
        ;;
    x86_64|aarch64)
        build_target "$ARCH"
        ;;
esac

if ! $DRY_RUN; then
    echo ""
    echo "==> build complete"
    echo ""

    # Summary table
    printf "%-42s  %6s  %s\n" "binary" "size" "sha256"
    printf "%-42s  %6s  %s\n" "------" "----" "------"
    for rust_target in x86_64-unknown-linux-musl aarch64-unknown-linux-musl; do
        for bin in term-meshd tm-agent; do
            f="$DIST/$rust_target/$bin"
            [[ -f "$f" ]] || continue
            sz="$(ls -lh "$f" | awk '{print $5}')"
            sha="$(shasum -a 256 "$f" | awk '{print substr($1,1,16) "..."}')"
            printf "%-42s  %6s  %s\n" "$rust_target/$bin" "$sz" "$sha"
        done
    done

    echo ""
    echo "Next:"
    echo "  ./scripts/bootstrap-remote.sh \\"
    echo "    --daemon $DIST/x86_64-unknown-linux-musl/term-meshd \\"
    echo "    --forward-socket <user@host>"
    echo ""
fi
