# Peer Federation Protocol Spec

Last updated: April 23, 2026
Status: Draft (Phase 1) — companion to `peer-federation.md`

This document specifies the wire protocol for term-mesh peer attach. Phase 0 (`peer-federation.md`) defines what is being built and why; this document defines the on-wire bytes.

## Scope

1. Message framing and encoding choice.
2. Full message set for MVP (Phase 2) with fields and types.
3. Connection handshake state machine.
4. Version negotiation rules.
5. GridSnapshot structure.
6. Error code taxonomy.
7. Flow control and backpressure strategy.

Out of scope for this document: transport layer details (SSH tunnel vs TLS) and pairing UX. Those are tracked in the Phase 0 charter and Phase 3 spec.

## Framing

1. **Choice: length-prefixed Protobuf.** Each frame is a little-endian `uint32` byte length followed by a Protobuf-encoded `Envelope` message. No varint framing; fixed 4-byte prefix for trivial parser state.
2. Maximum frame size: 16 MiB. Frames larger than this MUST be rejected with `ERR_FRAME_TOO_LARGE` and the transport closed.
3. Schema files live in `proto/peer/v1/*.proto` and are compiled to Swift via `swift-protobuf` and to Rust via `prost` so the daemon can speak the same protocol.
4. Rationale:
   - Typed schema survives cross-language evolution (Swift client, Rust daemon).
   - Compact on the wire — matters because `PtyData` dominates traffic.
   - `protoc --decode_raw` gives readable debug dumps without a schema handshake.
   - MessagePack was considered but lacks compile-time safety; JSON was considered but its cost for high-frequency `PtyData` is unjustified.

## Envelope

All messages are wrapped in a single top-level `Envelope`:

```proto
message Envelope {
  uint64 seq = 1;              // monotonic per sender, starts at 1
  uint64 correlation_id = 2;   // 0 unless this is a reply; otherwise echoes the request's seq
  oneof payload {
    Hello hello = 10;
    AuthChallenge auth_challenge = 11;
    Auth auth = 12;
    AuthResult auth_result = 13;
    ListSurfaces list_surfaces = 20;
    SurfaceList surface_list = 21;
    AttachSurface attach_surface = 22;
    AttachResult attach_result = 23;
    DetachSurface detach_surface = 24;
    PtyData pty_data = 30;
    Input input = 31;
    Resize resize = 32;
    GridSnapshot grid_snapshot = 33;
    DataAck data_ack = 34;
    WorkspaceUpdate workspace_update = 40;
    Ping ping = 50;
    Pong pong = 51;
    Goodbye goodbye = 60;
    Error error = 99;
  }
}
```

Field number gaps (10s, 20s, 30s) leave room for category growth without reshuffling.

## Handshake State Machine

States on each side: `Init → HelloSent → HelloReceived → AuthPending → Ready → Closing → Closed`.

Sequence on successful attach:

1. **TCP/SSH-tunnel connect.** Transport is established by the time the protocol speaks.
2. Client → Host: `Hello { protocol_version, client_id, client_name, capabilities }`
3. Host → Client: `Hello { protocol_version, host_id, host_name, capabilities }`
4. Host → Client: `AuthChallenge { nonce, supported_methods }`
5. Client → Host: `Auth { method, token_id, signature }`
6. Host → Client: `AuthResult { accepted, reason, session_id }`
7. Either side may now send `ListSurfaces`, `AttachSurface`, etc.

Aborts:

1. If `protocol_version` is incompatible (see §Versioning), the side detecting it sends `Error { code: ERR_VERSION_INCOMPATIBLE, message }` and sends `Goodbye`.
2. Failed auth sends `AuthResult { accepted: false, reason }` followed by `Goodbye`.
3. Any unexpected message before `Ready` sends `Error { code: ERR_UNEXPECTED_MESSAGE }` and closes.

A connection may send one `Ping` every 15 s by default; if no `Pong` arrives within 30 s, the side times out and closes.

## Versioning

1. `protocol_version` is a semver string, e.g. `"1.0.0"`.
2. Major numbers MUST match exactly for the connection to proceed.
3. Minor differences are allowed: the side with the lower minor advertises its supported capabilities; the higher side MUST NOT use capabilities the lower side did not advertise.
4. Patch differences are ignored.
5. Capability flags are string tags in `Hello.capabilities` (e.g. `"grid-snapshot-v1"`, `"browser-surface"`).
6. Version mismatch surfaces in the client sidebar as a human-readable error: "Host runs 2.x; this client speaks 1.x. Upgrade one side."

## Message Reference

### Hello

```proto
message Hello {
  string protocol_version = 1;       // semver
  bytes  peer_id          = 2;       // stable 128-bit UUID of this install
  string display_name     = 3;       // "MacBook Pro" or user-set alias
  repeated string capabilities = 4;  // feature flags
  string app_version      = 5;       // term-mesh marketing version, for diagnostics
}
```

### AuthChallenge / Auth / AuthResult

```proto
message AuthChallenge {
  bytes  nonce              = 1;       // 32 random bytes
  repeated string supported_methods = 2;  // ["token-ed25519", ...]
}

message Auth {
  string method   = 1;      // must be one of supported_methods
  bytes  token_id = 2;      // identifier for the key used (0 if pre-shared token)
  bytes  signature = 3;     // method-specific (ed25519(nonce) for token-ed25519)
}

message AuthResult {
  bool    accepted   = 1;
  string  reason     = 2;   // human-readable on failure
  bytes   session_id = 3;   // echoed in all subsequent messages for correlation (informational)
}
```

For MVP over SSH tunnel, `method = "ssh-passthrough"` is accepted with an empty signature — the SSH transport has already authenticated the user. Native TLS path in Phase 3 uses `token-ed25519`.

### ListSurfaces / SurfaceList

```proto
message ListSurfaces {}

message SurfaceList {
  repeated SurfaceInfo surfaces = 1;
}

message SurfaceInfo {
  bytes surface_id   = 1;
  string workspace_name = 2;
  string title        = 3;
  uint32 cols         = 4;
  uint32 rows         = 5;
  string surface_type = 6;   // "terminal" | "browser"
  bool   attachable   = 7;   // host policy may forbid attach per-surface
}
```

### AttachSurface / AttachResult / DetachSurface

```proto
enum AttachMode {
  ATTACH_MODE_UNSPECIFIED = 0;
  READ_ONLY = 1;
  CO_WRITE  = 2;
  TAKE_OVER = 3;
}

message AttachSurface {
  bytes surface_id = 1;
  AttachMode mode  = 2;
  uint32 client_cols = 3;
  uint32 client_rows = 4;
}

message AttachResult {
  bool   accepted       = 1;
  string reason         = 2;
  bytes  surface_id     = 3;
  uint64 initial_seq    = 4;   // the PtyData seq that follows
  AttachMode granted_mode = 5; // may differ from requested if host downgraded
}

message DetachSurface {
  bytes surface_id = 1;
}
```

### PtyData / Input / Resize

```proto
message PtyData {
  bytes  surface_id = 1;
  uint64 byte_seq   = 2;   // cumulative byte offset since attach
  bytes  payload    = 3;
}

message Input {
  bytes  surface_id = 1;
  oneof  kind {
    bytes keys = 10;          // raw key bytes in terminal encoding
    MouseEvent mouse = 11;
    Paste paste = 12;
  }
}

message MouseEvent {
  uint32 col = 1;
  uint32 row = 2;
  uint32 button = 3;  // 0=move, 1=left, 2=middle, 3=right, 4=wheel-up, 5=wheel-down
  uint32 modifiers = 4; // bitfield: 1=shift, 2=ctrl, 4=alt, 8=cmd
  bool   pressed = 5;
}

message Paste {
  bytes text = 1;
}

message Resize {
  bytes  surface_id = 1;
  uint32 cols = 2;
  uint32 rows = 3;
  uint32 pixel_width  = 4;
  uint32 pixel_height = 5;
}
```

### GridSnapshot

The snapshot is deliberately minimal for Phase 1: the **current visible screen** and cursor. Scrollback is NOT included — clients within the ring-buffer reconnect window get bytes replayed, clients outside accept scrollback loss.

```proto
message GridSnapshot {
  bytes  surface_id  = 1;
  uint64 byte_seq    = 2;         // the PtyData seq this snapshot is consistent with
  uint32 cols        = 3;
  uint32 rows        = 4;
  bool   alt_screen  = 5;
  CursorState cursor = 6;
  repeated GridRow rows_data = 7;
}

message CursorState {
  uint32 col = 1;
  uint32 row = 2;
  bool   visible = 3;
  uint32 style = 4;   // libghostty cursor style enum
}

message GridRow {
  repeated Cell cells = 1;
}

message Cell {
  string text       = 1;    // usually 1 grapheme; wide chars occupy one Cell + a continuation
  uint32 fg_rgba    = 2;
  uint32 bg_rgba    = 3;
  uint32 attrs      = 4;    // bitfield: bold, italic, underline, strike, inverse, dim
  bool   is_continuation = 5;
}
```

Cell-level encoding intentionally mirrors libghostty's public grid API at a high level. Implementation will pin to whichever libghostty version the pinned submodule exposes; if libghostty's cell model changes, bump the protocol minor version and add capability `"grid-snapshot-v2"`.

### WorkspaceUpdate

Host pushes structural changes so the client's sidebar mirror stays correct.

```proto
message WorkspaceUpdate {
  oneof kind {
    SurfaceAdded    added   = 1;
    SurfaceRemoved  removed = 2;
    SurfaceRetitled retitled = 3;
    WorkspaceMeta   meta    = 4;
    SplitChanged   split    = 5;
  }
}

message SurfaceAdded    { SurfaceInfo surface = 1; bytes pane_id = 2; }
message SurfaceRemoved  { bytes surface_id = 1; }
message SurfaceRetitled { bytes surface_id = 1; string title = 2; }
message WorkspaceMeta   { string branch = 1; string cwd = 2; repeated uint32 ports = 3; string latest_notification = 4; }
message SplitChanged    { bytes pane_id = 1; bytes snapshot = 2; }  // opaque tree snapshot; decoder in sidebar
```

### Ping / Pong / Goodbye

```proto
message Ping    { uint64 nonce = 1; }
message Pong    { uint64 nonce = 1; }
message Goodbye { string reason = 1; }
```

### Error

```proto
message Error {
  uint32 code = 1;
  string message = 2;
  bytes  correlation_id_bytes = 3;   // raw 16 bytes if needed
}
```

## Error Codes

| Code | Symbol                        | Meaning                                                  |
|------|-------------------------------|----------------------------------------------------------|
| 100  | `ERR_UNKNOWN`                 | Fallback                                                 |
| 101  | `ERR_FRAME_TOO_LARGE`         | Frame exceeded 16 MiB                                    |
| 102  | `ERR_MALFORMED_MESSAGE`       | Protobuf decode failure                                  |
| 103  | `ERR_UNEXPECTED_MESSAGE`      | Message arrived in wrong state                           |
| 104  | `ERR_VERSION_INCOMPATIBLE`    | Major version mismatch                                   |
| 200  | `ERR_AUTH_REQUIRED`           | Host refuses unauthenticated frames                      |
| 201  | `ERR_AUTH_METHOD_UNSUPPORTED` | Client requested an unsupported method                   |
| 202  | `ERR_AUTH_INVALID`            | Signature / token failed validation                      |
| 203  | `ERR_AUTH_REVOKED`            | Token was revoked                                        |
| 300  | `ERR_SURFACE_NOT_FOUND`       | `surface_id` does not exist on host                      |
| 301  | `ERR_SURFACE_NOT_ATTACHABLE`  | Host policy forbids attaching this surface               |
| 302  | `ERR_SURFACE_ALREADY_DETACHED`| Detach on a surface not currently attached               |
| 400  | `ERR_WRITE_NOT_ALLOWED`       | `Input` sent on a read-only attach                       |
| 401  | `ERR_ATTACH_LIMIT`            | Host reached maximum concurrent attachments              |
| 500  | `ERR_HOST_SHUTTING_DOWN`      | Host terminated; reconnect will fail until host is back  |
| 501  | `ERR_INTERNAL`                | Host-side bug; log and close                             |

Clients MUST treat unknown error codes as fatal-for-this-surface, not fatal-for-the-connection, unless the code is ≥ 500.

## Flow Control

1. Phase 1 relies on TCP/SSH transport backpressure for correctness. Senders MUST NOT buffer unbounded PtyData if the transport stalls.
2. `DataAck` is advisory: clients MAY send it every N PtyData frames for RTT measurement and to let hosts trim the reconnect ring buffer early.
3. If a host detects `unacked_bytes > 8 MiB` on a single surface, it MAY drop the oldest queued PtyData and emit an `Error { code: ERR_INTERNAL, message: "slow consumer" }` after which the client MUST re-request a `GridSnapshot` to re-sync.
4. Higher-order credit-based flow control is Phase N+ work; not needed for LAN.

## Reconnection Protocol

1. Client reconnects with the same `peer_id` and a new `Hello`.
2. On a new `AttachSurface`, the client includes the previously seen `byte_seq` in a field `resume_from_seq` (added in `AttachSurface`, omitted above for brevity; will be `uint64 resume_from_seq = 5` in the actual `.proto`).
3. If `resume_from_seq` is within the host ring buffer, host replays `PtyData` starting from that seq. If outside, host responds with `GridSnapshot` and begins streaming fresh `PtyData` from its current seq.
4. The client's `byte_seq` is cumulative per attach instance; a fresh attach restarts counting from 0 and relies on `initial_seq` from `AttachResult`.

## Schema Evolution Rules

1. Never reuse a field number. Removing a field: mark it `reserved N`.
2. New fields are optional. Missing fields on the wire must decode to sensible defaults.
3. Add a new capability flag when introducing a message a peer may lack support for; gate the message behind that flag.
4. Version bumps:
   - Add field / message: minor bump, new capability flag.
   - Remove or incompatibly change a field: major bump.

## Deliverables for Phase 1 → Phase 2

1. `proto/peer/v1/peer.proto` — full schema matching this document.
2. Build rules generating Swift and Rust bindings.
3. A ~200-line README in `proto/peer/v1/` summarizing this spec for future contributors.
4. Tracking: a short section in Phase 2 PoC issue listing any messages deferred past MVP.

## Open Questions

1. Should `GridSnapshot` carry the full screen as cells, or a compact ANSI re-render that the client libghostty can `feed()`? Re-render is smaller and reuses existing parsing; cells are more robust against version drift. Decide when prototyping.
2. Should `Input` keystrokes carry modifier bitfields separately, or trust the client to already encode them into raw bytes? Current spec trusts client encoding; revisit if we see IME issues.
3. Does `WorkspaceUpdate.SplitChanged` ship an opaque payload (host-side tree serialized, client blindly renders) or a structured diff? Opaque is simpler but couples versions tightly. Default to structured for long-term stability; leave as `bytes` placeholder until the split-tree schema is frozen.
4. How much of `tm-agent` routing piggybacks on this protocol vs. staying on its own socket? Probably stays separate in MVP.
