#!/usr/bin/env bash
# Regenerate tests_v2/peer_pb2/peer_pb2.py from proto/peer/v1/peer.proto.
#
# Why a pinned protoc download instead of `brew install protobuf`'s protoc:
# protoc's generated Python gencode embeds a minimum-runtime-version check
# (`_runtime_version.ValidateProtobufRuntimeVersion`) against the protoc
# release's OWN Y.Z version. Homebrew's protoc tracks the latest upstream
# release (35.1 as of writing) while the `protobuf` PyPI package installed
# system-wide here is older (6.33.6, i.e. Y.Z=33.6) -- generating with a
# newer protoc than the installed runtime supports fails at import time
# with a VersionError. Fix: use the protoc release whose Y.Z matches the
# installed Python package's Y.Z exactly. The package's leading digit
# (the "6" in "6.33.6") is a Python-package-only major lineage marker and
# is NOT part of the protoc release tag (which is just "v33.6").
#
# Usage: ./tests_v2/peer_pb2/generate.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT_DIR="$REPO_ROOT/tests_v2/peer_pb2"
PROTO_DIR="$REPO_ROOT/proto/peer/v1"

PY_PROTOBUF_VERSION="$(python3 -c 'import google.protobuf; print(google.protobuf.__version__)')"
# Drop the leading Python-package-only major component: "6.33.6" -> "33.6".
PROTOC_TAG_VERSION="$(echo "$PY_PROTOBUF_VERSION" | cut -d. -f2-)"
PROTOC_TAG="v${PROTOC_TAG_VERSION}"

echo "Installed protobuf (Python): ${PY_PROTOBUF_VERSION}"
echo "Matching protoc release tag: ${PROTOC_TAG}"

ARCH="$(uname -m)"
case "$ARCH" in
  arm64) PROTOC_ASSET_ARCH="osx-aarch_64" ;;
  x86_64) PROTOC_ASSET_ARCH="osx-x86_64" ;;
  *)
    echo "unsupported arch: $ARCH (add a case for it, or download a matching" >&2
    echo "protoc yourself and run: protoc --proto_path=$PROTO_DIR --python_out=$OUT_DIR $PROTO_DIR/peer.proto)" >&2
    exit 1
    ;;
esac

CACHE_DIR="${TMPDIR:-/tmp}/term-mesh-protoc-${PROTOC_TAG_VERSION}"
PROTOC_BIN="$CACHE_DIR/bin/protoc"

if [ ! -x "$PROTOC_BIN" ]; then
  echo "Downloading protoc ${PROTOC_TAG} (${PROTOC_ASSET_ARCH})..."
  mkdir -p "$CACHE_DIR"
  ASSET="protoc-${PROTOC_TAG_VERSION}-${PROTOC_ASSET_ARCH}.zip"
  curl -sL --fail -o "$CACHE_DIR/protoc.zip" \
    "https://github.com/protocolbuffers/protobuf/releases/download/${PROTOC_TAG}/${ASSET}"
  (cd "$CACHE_DIR" && unzip -oq protoc.zip)
fi

GOT_VERSION="$("$PROTOC_BIN" --version | awk '{print $2}')"
if [ "$GOT_VERSION" != "$PROTOC_TAG_VERSION" ]; then
  echo "protoc version mismatch: got $GOT_VERSION, expected $PROTOC_TAG_VERSION" >&2
  exit 1
fi

rm -f "$OUT_DIR/peer_pb2.py"
"$PROTOC_BIN" --proto_path="$PROTO_DIR" --python_out="$OUT_DIR" "$PROTO_DIR/peer.proto"
echo "Wrote $OUT_DIR/peer_pb2.py"
