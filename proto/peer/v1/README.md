# peer/v1

Schema for term-mesh peer federation protocol, v1.

See `docs/peer-federation-protocol.md` for the authoritative design. This directory holds the `.proto` file that both Swift and Rust generate bindings from.

## Files

- `peer.proto` — the canonical schema. Edit this; do not edit generated code by hand.

## Consumers

- **Rust** (daemon, CLI): `daemon/peer-proto` crate. Generated at build time via `prost-build` + `protox` (pure-Rust, no `protoc` dependency). Nothing to commit.
- **Swift** (macOS app): generated files go under `Sources/Generated/Peer_V1/` and are committed. Regenerate with `scripts/gen-proto.sh` after schema changes. (Swift side wired up in Phase 2.2.)

## Regenerating

Rust is automatic — `cargo build -p peer-proto` regenerates from `peer.proto`.

Swift requires `protoc` + `protoc-gen-swift` installed and regeneration via:

```bash
./scripts/gen-proto.sh
```

The script is idempotent. Commit the resulting `.pb.swift` files.

## Evolution rules

1. Never reuse a field number. Removing a field: mark `reserved N`.
2. New fields must be optional. Missing-on-wire decodes to defaults.
3. New messages a peer may lack support for MUST be gated behind a capability string declared in `Hello.capabilities`.
4. Incompatible changes bump the major in `Hello.protocol_version`.

When you add or remove a capability, update `docs/peer-federation-protocol.md` §Versioning so the client sidebar's "incompatible" error message stays accurate.
