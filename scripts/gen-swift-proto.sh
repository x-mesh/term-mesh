#!/usr/bin/env bash
# gen-swift-proto.sh — regenerate Swift bindings for peer.proto.
#
# Requires: protobuf (`brew install protobuf`), swift-protobuf
# (`brew install swift-protobuf`).
#
# The generated file is committed under swift/PeerProto/Sources/PeerProto/.
# Run this after editing proto/peer/v1/peer.proto and commit the diff
# alongside the .proto change so Rust and Swift stay in lockstep.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if ! command -v protoc >/dev/null 2>&1; then
    echo "ERROR: protoc not found. brew install protobuf" >&2
    exit 1
fi
if ! command -v protoc-gen-swift >/dev/null 2>&1; then
    echo "ERROR: protoc-gen-swift not found. brew install swift-protobuf" >&2
    exit 1
fi

OUT="swift/PeerProto/Sources/PeerProto"
mkdir -p "$OUT"

echo "==> generating Swift bindings from proto/peer/v1/peer.proto"
protoc \
    --proto_path=proto \
    --swift_out="$OUT" \
    --swift_opt=Visibility=Public \
    --swift_opt=FileNaming=PathToUnderscores \
    proto/peer/v1/peer.proto

echo "==> wrote:"
ls -1 "$OUT"/*.pb.swift
