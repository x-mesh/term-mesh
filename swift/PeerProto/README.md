# PeerProto

Swift Package with the generated Protobuf bindings + length-prefix framing
helpers for the term-mesh peer federation protocol. Mirrors the Rust
`daemon/peer-proto` crate.

## Layout

- `Sources/PeerProto/peer_v1_peer.pb.swift` — generated from `proto/peer/v1/peer.proto`. Do not edit by hand.
- `Sources/PeerProto/Framing.swift` — `encodeFrame` / `decodeFrame` helpers so
  callers don't reimplement the little-endian u32 length prefix.
- `Tests/PeerProtoTests/FramingTests.swift` — round-trip tests covering
  Hello, PtyData, WorkspaceUpdate.meta, partial-frame handling,
  oversized-frame rejection, and forward-compat with unknown fields.

## Regenerating the .pb.swift

Requires `protobuf` and `swift-protobuf` installed locally (one-time):

```bash
brew install protobuf swift-protobuf
```

From the repo root:

```bash
./scripts/gen-swift-proto.sh
```

The script is idempotent; commit any resulting `.pb.swift` diff along with
the `.proto` change. CI should treat an uncommitted diff from the generator
as a build failure (future work).

## Running tests

```bash
cd swift/PeerProto && swift test
```

Runs on the macOS host directly — no simulator involvement, no Xcode
project needed yet.

## Future integration into term-mesh.app

The eventual plan (Phase C-2+) is to add this package to
`GhosttyTabs.xcodeproj` as a local Swift Package reference via Xcode's
"File > Add Package Dependencies > Add Local…". Once attached, the Swift
side of term-mesh.app can import `PeerProto` and use the same types the
Rust daemon speaks.

Until that integration lands, `PeerProto` stands alone: the tests above
are the authoritative verification that the Swift side of the protocol
matches the Rust side bit-for-bit.
