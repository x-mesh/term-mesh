# Mesh Project Sync — Wiring & Implementation Plan

> Status: **DRAFT — ready for review** (2026-07-17). Turns the currently-dormant
> sync engine into a working, verifiable cross-machine sync in small phases.
> Companion to the `mesh-project-sync-protocol.md` ADR (the *what*); this doc is
> the *how to wire it up and prove it*. §2 interface inventory is filled from a
> five-layer source survey (transport, orchestration, data-plane, transfer/CAS,
> design-intent); every claim carries a `file:line`. Confirm §6 decisions
> (esp. D3 trust provisioning — it gates all e2e) before Phase S0 coding.

## 1. Where we actually are (honest state)

The sync subsystem landed via PR #97 (develop `5a5ad8d3`). It is **component-rich
but not wired end-to-end**:

**Built + unit-tested (components):**
- `reconcile.rs` (diff/plan), `apply.rs` (filesystem apply), `cas.rs`
  (BLAKE3 4 MiB content store), `oplog.rs`, `manifest.rs`, `scanner.rs`,
  `merge.rs`, `conflict.rs`
- `transport.rs` `SyncEndpoint` + `transport_auth.rs` + `stream_router.rs`
  (QUIC transport primitive), `crypto.rs`, `trust.rs`, `rotation.rs`,
  `keychain.rs`
- `git.rs`, `path_sandbox.rs`, `sqlite_openat_vfs.rs`, `secure_sqlite.rs`
- Component tests: `apply_crash.rs`, `quic_router.rs`, `reconcile_resume.rs`,
  `sync_rpc.rs`, `trust_rotation.rs`

**NOT wired (the gap = "구현 덜함"):**
- `OperationKind` has **only `ManifestScan`**; the only `OperationRunner` is
  `ManifestScanRunner` (local scan). **No network-sync operation/runner** that
  connects to a peer and moves data.
- `SyncEndpoint` has **zero production callers** — nothing binds a listener,
  accepts, or dials a peer at daemon runtime.
- Several sync RPCs in `socket.rs` are stubs (pairing → `USER_PRESENCE_REQUIRED`,
  conflict → `CONFLICT_NOT_FOUND`, gc → `gc_coordinator_not_initialized`).
- No discovery wired (Bonjour / explicit endpoint).

**NOT tested (the gap = "테스트 덜함"):**
- **No end-to-end test**: "a change on machine A appears on machine B." Only
  component/fixture tests exist. `logical_transfer_fixture` is explicitly a
  fixture, not a measured transfer.

> Net: the algorithms mostly exist; the **top-level assembly + a real two-daemon
> e2e** are missing. This plan is about assembly + proof, not rewriting the
> data-plane math.

## 2. Interface inventory (filled from layer survey)

### 2.1 Transport (`SyncEndpoint`, streams, auth) — surveyed

QUIC via `quinn` + rustls, TLS 1.3, mutual cert-pinning. (`transport.rs`)
- **Bind**: `SyncEndpoint::server(bind: SocketAddr, trust: Arc<TrustStore>, identity: &DeviceTlsIdentity)`
  (listener) / `::client(...)` (dialer). `local_addr()` for the bound port.
- **Dial**: `async fn connect(&self, remote: SocketAddr, hello: SyncHello) -> Result<AuthenticatedConnection>`.
- **Accept**: `async fn accept(&self, hello: SyncHello) -> Result<AuthenticatedConnection>`.
  Both do the full handshake inline: semaphore permit (max 32 conns) → QUIC connect/accept
  (server name hardcoded `"term-mesh.local"`) → ALPN check (`sync_protocol::SYNC_ALPN`) →
  `SyncHello` exchange over the first bidi stream → binding validate →
  `trust.revalidate_transport_peer` → replay-nonce consume.
- **`AuthenticatedConnection { pub connection: quinn::Connection, pub peer: TransportPeerSnapshot }`** —
  ⚠️ **NO named stream helpers**. A runner calls raw quinn `connection.open_uni()/open_bi()/
  accept_uni()/accept_bi()`. Limits: 16 bidi + 16 uni streams.
- **Auth** (`transport_auth.rs` + `trust.rs`): caller supplies `Arc<TrustStore>` (device roster /
  cert-hash allowlist) + `&DeviceTlsIdentity` (own cert+key, from `keychain.rs`; `generate()` makes
  a self-signed `term-mesh.local`). Peer identity derives from its pinned TLS cert via
  `trust.authorize_transport_certificate` (requires exactly one `approved` device with that cert
  hash). `ProjectKey` (`crypto.rs`, XChaCha20) is for **payload/at-rest** encryption, NOT the TLS
  wire — a runner encrypts blob/oplog bodies with it before sending.

**⚠️ The transport-layer gap (this is the crux of Phase S0/S2 wiring):**
`StreamLane { Control=0, Terminal=1, SyncOperation=2, Blob=3 }` + `StreamRouter`/
`StreamRouterSender::send(lane, payload)` exist (`stream_router.rs`) as a **purely in-memory
deficit-round-robin queue** with per-lane byte/depth caps. **Nothing binds it to QUIC**: there is
no pump draining `StreamRouter::next()` onto `connection.open_uni()/open_bi()` per lane, and no
receive-side demux reading incoming QUIC streams back into lanes. `transfer.rs`'s `TransferSession`
enqueues frames to a `StreamRouterSender` + writes a `WireTrace` — a **logical fixture not attached
to any live connection**. Building this **lane↔QUIC-stream pump + demux** is the core new transport
code the runner needs. Existing tests (`tests/quic_router.rs`) prove the handshake but drive no
lane-multiplexed payload over a live connection.

### 2.2 Orchestration (`OperationManager`, runners, RPCs) — surveyed

**Runner contract** (`operation.rs`):
- `OperationRunner::run(&self, spec: &OperationSpec, cancelled: Arc<AtomicBool>) -> Result<OperationResult, String>`
  is **synchronous** — invoked inside `spawn_blocking` (operation.rs:462). Cancellation is
  cooperative: poll `cancelled.load(Acquire)`, return `Err("cancelled")`.
- ⚠️ **Async/sync bridge needed**: network sync is QUIC (async). The runner is sync, so the
  `NetworkSyncRunner` must own/enter a runtime handle and `block_on` the async transfer inside
  `run()` (or we add an async-runner path to the manager). **Decision D1** (§6).
- `OperationKind` (operation.rs:35) has ONLY `ManifestScan`, and the SQLite schema hardcodes
  `CHECK(kind IN ('manifest_scan'))` (operation.rs:25). Adding `Sync` requires: enum variant +
  schema migration + `as_str`/`parse` arms + a `normalize_runner_error` arm (operation.rs:725,
  which today collapses unknown errors to `operation_failed`).
- `OperationSpec { project_id, kind, root: PathBuf, held_root: HeldProjectRoot }` and
  `OperationResult { manifest_root: String, entries: u64 }` carry **no peer/network field**, and
  `finish()` persists only those two result columns. A sync op needs a peer target in the spec
  and a richer result (bytes moved, files changed) → new columns/reshape.

**Manager wiring** (`operation.rs`):
- `Inner` holds a **single `Arc<dyn OperationRunner>`** (operation.rs:207); `spawn_operation`
  calls it unconditionally regardless of `spec.kind`. Two options to add a runner:
  (a) make it a map keyed by `OperationKind`, or (b) branch on `spec.kind` inside one combined
  runner (`ManifestScanRunner` already branches internally). **Decision D2** (§6).
- Injection seam exists: `open_with_runner_and_limits(path, registry, runner, max_workers,
  max_queued)` (operation.rs:261) — but `socket.rs:276` calls the hardcoded
  `open()` → `Arc::new(ManifestScanRunner)` (operation.rs:255). Wiring a network runner means
  routing through the seam.
- Lifecycle: `start` (idempotent by 16-byte `request_id`, admits against `max_queued`, resolves
  root off-thread, INSERTs `pending`) → `spawn_operation` (semaphore `DEFAULT_MAX_WORKERS=2` →
  `pending→running` CAS → `spawn_blocking(runner.run)`) → `finish` (Succeeded/Failed/Cancelled/
  Interrupted). Crash-interrupted ops marked on `open()`. SQLite is `SecureSqlite` (WAL,
  `synchronous=FULL`); storage failure sets `unhealthy` → blocks new starts.

**Registry** (`registry.rs`): `ProjectRegistry` (projects only; no peer/roster tables beyond a
`roster_epoch` counter + `active_manifest` per project). `resolve_root(project_id) ->
HeldProjectRoot` gives a validated `O_DIRECTORY|O_NOFOLLOW` dir fd with `revalidate()` (TOCTOU
guard). `update_sync_state(project_id, active_manifest, roster_epoch)` is transactional and
rejects epoch regression — the sync runner commits the new manifest/epoch through this.

**Sync RPCs** (`socket.rs` dispatch):
- REAL (drive `OperationManager`/`ProjectRegistry`): `operation.start/status/cancel/retry`,
  `project.add/list/status/pause/resume/scan`, `sync.status/cancel`.
- **`sync.start` (socket.rs:1631) is the extension seam**: it already parses `peer_id` and
  **discards it** (`SyncStartParams._peer_id`, `#[serde(rename="peer_id")]`), then behaves
  identically to `project.scan` (local ManifestScan). No peer connection anywhere. Wiring the
  network runner = thread `peer_id` into the spec + dispatch to `NetworkSyncRunner`.
- STUBS (fixed errors, project-id still validated): `pairing.*` → `USER_PRESENCE_REQUIRED`
  (socket.rs:1681) / `not_configured`; `conflict.*` → `CONFLICT_NOT_FOUND` (socket.rs:1701);
  `gc.status` → `gc_coordinator_not_initialized` (socket.rs:1713). No `gc.run` exists.
- No `TODO`/`unimplemented!` markers in operation.rs/registry.rs/sync-RPC section — the "gap" is
  the missing runner + the stub error strings, not scattered todos.

### 2.3 Data plane (scan → reconcile → apply, oplog) — surveyed

**⚠️ Load-bearing correction: `reconcile.rs` does NOT emit a file-level plan.** It yields
head/frontier *verdicts* (`HeadDecision`, `FrontierRelation`) and moves oplog records + manifest
pages. **The runner assembles the `ApplyPlan` itself** by decoding manifest pages and diffing them
against local visible state, then hands it to `apply`. So "compose reconcile→apply" is really
"drive the orchestrator for head/oplog state, THEN build the per-file diff in the runner."

- **Scan** (`scanner.rs`): `ManifestScanner::scan(root: &Path, reason) -> (Manifest, ScanMetrics)`
  (openat/fd-scoped). `Manifest { root: [u8;32], entry_count }` is a rolling BLAKE3 hash, not a
  list; per-`ManifestEntry` streamed via `ScanObserver::entry`. Feed entries into `ManifestIndex`
  for a queryable/paged manifest.
- **Reconcile** (`reconcile.rs`): top-level driver is `ReconcileOrchestrator<'a>::new(heads:
  &ReconcileStore, trust: &TrustStore)`. Key methods:
  - `offer_authenticated(peer, root, frontier, full) -> HeadDecision` — intake a peer's head offer.
  - `no_change(peer, root, frontier, trace) -> bool` — fast "heads equal" short-circuit.
  - `sync_incremental_report(source: &OplogStore, destination: &OplogStore, committed_at_ms) ->
    IncrementalSyncReport` — the oplog-pull driver (frontier → `missing_tail` → `export_range` →
    `ingest_batch`, ≤1024 recs / ≤8 MiB/batch; `FullResyncRequired` if behind retained floor).
  - `install_full_baseline(...)` / `reconcile_baseline_install(...)` — full-resync + crash-resume.
  - `commit_persisted(id, peer, index: &ManifestIndex, handle) -> ()` — promote candidate to head.
  - Manifest transfer unit: `ManifestIndex::shard_roots() -> Vec<[u8;32]>` (set-reconciliation) and
    `page(shard_index) -> Vec<Vec<u8>>` (encoded `ManifestEntry` blobs; decode with crate-internal
    `decode_index_entry`). Shard = 1024 entries, ≤1 MiB/page.
- **Apply** (`apply.rs`): `ApplyStore::apply(root, cas: &CasStore, domain, plan: &ApplyPlan) ->
  VisibleState`. `ApplyPlan { operation_id, project, target_manifest_root, frontier, entries }`;
  `ApplyPlanEntry { relative_path, action: File{object_id, content_hash, length, executable} |
  Directory | Symlink | Delete, precondition: Absent | Present(fingerprint) }`. Content is pulled +
  hash-verified from CAS (`cas.copy_verified_plaintext(domain, object_id, writer)`). Writes go
  through `PathSandbox` (symlink-safe, openat) with a crash-safe temp→backup→install→commit
  protocol + rollback; `visible_state(project)` is the sole authority for local fs generation.
  `ApplyPlan` is a plain pub struct re-exported at `mod.rs:30`, **constructed by the runner**.
- **Oplog** (`oplog.rs`): `OplogStore` — `ingest`/`ingest_batch` (signed canonical records, dedup,
  quarantine), `frontier() -> BTreeMap<[u8;32],u64>` (contiguous per-device seq — what reconcile
  compares), `retained_floor()`, `missing_tail(remote_frontier)`, `export_range(...)`. Two frontier
  notions: authenticated remote head (`ReconcileStore`, `Vec<u8>`) vs oplog contiguous-seq
  (`OplogStore`, `BTreeMap`). ACK only after durable oplog commit.
- **Conflict** (`conflict.rs`/`merge.rs`): `merge_file(ThreeWayFile) -> MergeOutcome::{Resolved |
  Conflict(ConflictRecord)}`; `ConflictSet::insert/resolve`; `ResolvedConflict.content` feeds back
  into an `ApplyPlan` entry. Optimistic-concurrency via `ResolutionPrecondition`.
- No TODO/stub markers in any of these files — they are complete libraries awaiting composition.

### 2.4 Transfer + CAS — surveyed

`CHUNK_SIZE = 4 MiB` (`cas.rs`). `ObjectId([u8;32])` = BLAKE3 over domain header + plaintext;
`ObjectDomain { project_id, object_type: FILE|MANIFEST|CONFLICT, version }`.

- **CAS PUT** (`cas.rs`): `CasStore::begin_stage(domain, expected_id, plaintext_len) -> StagingObject`
  → per chunk `encrypt_chunk_for_key(key, key_id, domain, object_id, len, index, plaintext) ->
  EncryptedChunk` → `StagingObject::write_encrypted_chunk(index, envelope)` (decrypts+verifies vs
  AAD, marks bitmap) → `finish() -> LiveObject` (rehashes all chunks, enforces `ObjectId`, atomically
  links into `live/`). `ObjectId::for_plaintext(domain, bytes)` / streaming `ObjectIdHasher`.
- **CAS GET** (`cas.rs`): `get_live(domain, object_id) -> Option<LiveObject>`;
  `LiveObject::read_encrypted_chunk(index) -> (len, EncryptedChunk)`;
  `copy_verified_plaintext(domain, object_id, writer)` (the apply-side read).
- **CAS resume**: `resume_stage(stage_id, expected: ResumeCheckpoint)` (caller persists the
  checkpoint outside staging).
- ⚠️ **No batch have/missing API** — the only existence primitive is per-object `get_live -> None`.
  Missing-hash negotiation must be driven by the runner looping `get_live` per hash. The wire type
  `MissingObject { hashes, resume_ranges }` exists but **nothing produces/consumes it** yet.
- **Transfer** (`transfer.rs`): `TransferSession::enqueue(frame: &WireFrame, retransmit) ` is
  **SEND-ONLY** (maps `BlobChunk`→`StreamLane::Blob`, `sender.send(lane, bytes).await`, trace).
  **There is no receive/ingest side** — the RX path is only the generic
  `StreamRouter::next() -> RoutedFrame`, with nothing wiring a received `BlobChunk` into
  `StagingObject::write_encrypted_chunk`. `TransferCheckpoint` (MAC'd, `seal`/`decode`) is the
  wire/persisted resume record. `logical_transfer_fixture()` fabricates a report and moves **nothing**.
- **Wire** (`sync-protocol/wire.rs`): `WireFrame { binding: WireBinding{project_id, roster_epoch,
  operation_id}, body: WireBody }`. Chunk-relevant `WireBody`: **`BlobChunk { object_id, chunk_index,
  plaintext_length, envelope }`** (carrier; `envelope` = `EncryptedChunk` bytes → `write_encrypted_chunk`;
  cap 4 MiB+64), **`MissingObject { hashes, resume_ranges }`** (negotiation), `StreamPreface { lane,
  declared_length }` (opens the blob lane); plus `ManifestNodeRequest/Batch`, `OplogRangeRequest/Batch`,
  `BatchAck`.

**⚠️ Confirmed gap (grep, non-test):** zero production constructions of `BlobChunk`, zero callers of
`begin_stage`/`write_encrypted_chunk`/`read_encrypted_chunk`. The encode/store/encrypt/checkpoint
primitives all exist; **no runner** (a) enumerates missing chunks, (b) reads sender CAS →
`BlobChunk` frames, (c) `enqueue`s them, (d) ingests received `BlobChunk`s into a receiver
`StagingObject`. That sender↔receiver loop + the receive-side of `TransferSession` are Phase S2's
concrete deliverables. No TODO markers anywhere — pure composition gap.

### 2.5 Intended flow + verification requirements (from ADR/matrix) — surveyed

**Intended e2e flow** (protocol O1–O7): discovery (O5) → QUIC connect + version negotiate (reject
downgrade/missing-cap before any mutation) → mutual-pin auth + roster-epoch/device check (reject
forged-sig/stale/revoked/replay *before staging*) → manifest exchange (canonical records) →
reconcile (frontier diff; no-change = zero paths; incremental w/ crash-resume + full-scan fallback)
→ missing-hash negotiation + encrypted 4 MiB chunk transfer over bounded blob stream (resumable) →
crash-consistent apply (path-sandboxed) → signed append-only oplog (**durable ACK only after
durable oplog commit** — not mtime/wall-clock) → conflict preservation (no last-writer-wins) →
tombstone ≥90d / GC after all-ACK-or-revoke → Git plane confined to `refs/mesh/<peer>/*`.

**Minimal discovery = explicit endpoint** (skip Bonjour). Provide peer's QUIC `addr:port` + pinned
identity directly; mutual-pin auth already tested. The CLI already has a `--peer <id>` flag that is
**parser/envelope-only and starts no transfer** — that is the natural production seam
(`sync.start`'s discarded `peer_id`, §2.2).

**Verification matrix (R1–R16) — coverage vs e2e gaps:**
- Covered by existing unit/integration tests (no new e2e needed for the correctness core): R2
  (trust/recovery), R5 (immutable manifest), R6-local (CAS resume/bitflip), R7 (oplog ACK-after-
  commit), R8 (crash-consistent apply), R9-model (conflict), R10-local (Git plane), R12 (offline/
  30-day resume).
- **Need new cross-machine e2e** (what this plan must add): **R3** (real 2-machine QUIC session +
  reuse — today only localhost handshake), **R6-network** (missing-hash negotiation over the wire),
  **R11** (unlock pairing/conflict/GC control planes past fail-closed stubs; also `project remove`
  missing), **R13/R16** (real power + packet-loss + sleep-wake fault injection — prior "fault" tests
  were removed as fake), **R14/R15** (real ≥10 GiB throughput + resource soak; today's 7,814 MiB/s
  is a *virtual in-memory* smoke, not measured network/disk).

**Doc-implied phasing / deferrals** (align our phases to these): content-defined chunking deferred
(O3, v1 = fixed 4 MiB), Git↔CAS dedupe bridge deferred (O7), ACL/xattr/hardlink/sparse out of scope
(O4, degrade+record), per-`record_kind` payload schemas + signature algorithm punted to follow-up
ADRs (v1 signature is an *encoding fixture, not crypto-valid*), Bonjour discovery is a later add-on.
Benchmark: virtual "smoke" profile for the dev loop; physical ≥500 MiB/s gate is release-only.

**Explicitly NOT-yet-wired** (the stub inventory to unlock, in priority order for a working sync):
real network replication via `--peer` (primary stub) → pairing mutation (`USER_PRESENCE_REQUIRED`)
→ conflict query/resolve (`CONFLICT_NOT_FOUND`) → GC execution (`gc_coordinator_not_initialized`)
→ `project remove` → DEK-rotation operator CLI → GUI discovery/hydration RPC. Pause is memory-only.

## 3. Target minimal end-to-end flow (v0 "hello sync")

The smallest thing that proves real cross-machine sync, reusing existing parts:

```
Machine A (source)                         Machine B (dest)
  scanner → manifest_A
                          ── connect (SyncEndpoint dial, explicit endpoint) ──▶
                          ◀── manifest_B (scan of B's root) ──
  reconcile(manifest_A, manifest_B) → plan (files to send)
  for each changed file: cas.put → transfer chunks ──────────▶ cas.store
                          ── oplog/records ──▶
                                                    reconcile→ apply(plan, cas) → B filesystem
  verify: B's tree hash == A's tree hash
```

Deliberate v0 scope cuts (defer to later phases): Bonjour discovery, device
pairing/user-presence, conflict resolution UX, 30-day offline, tombstone GC,
Git/CAS dedupe, content-defined chunking, 50 GiB scale. v0 = one project, one
direction, explicit endpoint, small tree, happy path + integrity check.

## 4. Phased plan (each phase independently verifiable)

> Ordering principle: every phase ends with a **runnable check** (unit or e2e),
> and each builds on the previous. No phase lands dormant code. The heart of the
> work is **connecting halves that already exist**, in this dependency order:
> transport pump → manifest/reconcile → chunk transfer/apply.

### Phase S0 — The transport pump + a connected NetworkSyncRunner (prove the pipe)
The single biggest missing piece. Reusable across both peers.
- **Lane↔QUIC bridge** (new, `transport.rs`/new `sync_connection.rs`): a
  `SyncConnection` wrapper over `AuthenticatedConnection` that (a) drains
  `StreamRouter::next()` and writes each `RoutedFrame` onto a per-`StreamLane`
  quinn stream (`open_uni`/`open_bi`), and (b) accepts incoming quinn streams and
  demuxes them back into lanes. This is the code that does NOT exist yet (§2.1).
- **OperationKind::Sync** (`operation.rs`): enum variant + SQLite
  `CHECK(kind IN (...))` migration + `as_str`/`parse`/`normalize_runner_error`
  arms + a peer field on `OperationSpec` (+ richer `OperationResult`/columns).
- **NetworkSyncRunner** skeleton, registered via `open_with_runner_and_limits`
  (route `socket.rs` through the seam; dispatch by `spec.kind` — Decision D2).
  Bridges sync→async with an owned/handle `block_on` (Decision D1), polling the
  `cancelled` flag between async steps.
- **Explicit-endpoint connect**: `sync.start` threads its currently-discarded
  `peer_id` into the spec; runner resolves it to `addr:port` + pinned identity
  and `SyncEndpoint::client.connect` / daemon listener `accept`. No discovery.
- **v0 trust/identity provisioning** (Decision D3 — RESOLVED): a
  `sync/trust_bootstrap.rs` helper that provisions each daemon's
  `DeviceTlsIdentity` and applies recovery-key-signed `DeviceGrant` records via
  `apply_control_record` (the real trust mechanism; mirrors `tests/quic_router.rs`
  `fn grant`). Only dev-grade concession: the recovery key is supplied directly,
  not through the interactive user-presence flow. See §6 D3 for the exact recipe.
- **Check:** `tests/sync_e2e.rs` spins two `SyncEndpoint`s (loopback), completes
  auth, and round-trips a control-lane message through the pump both directions.
  Assert delivery + lane integrity. No project data yet.

### Phase S1 — Manifest exchange + reconcile + build the ApplyPlan (prove the diff)
- Scan each side (`ManifestScanner::scan` → `ManifestIndex`).
- Over the `SyncOperation` lane, exchange `shard_roots()` then pull differing
  `page(shard)` blobs; decode entries. Drive `ReconcileOrchestrator`
  (`offer_authenticated` / `no_change`) for head/frontier verdict and
  `sync_incremental_report` for the oplog tail.
- **Runner builds `ApplyPlan`** (Decision D5, likely a new `plan.rs`): diff
  decoded remote entries vs local `ApplyStore::visible_state` → `File{object_id,
  content_hash,…}` / `Delete` entries with `Absent`/`Present` preconditions.
- **Check:** e2e where A has 1 file B lacks → the assembled `ApplyPlan` lists
  exactly that entry; `no_change` short-circuits when trees match. Still no bytes.

### Phase S2 — CAS chunk transfer + apply (prove the bytes) — the milestone
- Put changed files into A's CAS (chunked, BLAKE3 4 MiB) → **missing-hash
  negotiation** → transfer chunks over the `Blob` lane (real `TransferSession`
  driven onto the pump, replacing `logical_transfer_fixture`) → store into B's
  CAS → `ApplyStore::apply(root, cas, domain, plan)` writes B's filesystem
  (content pulled + hash-verified from CAS) → commit oplog + `update_sync_state`.
- **Check (실측 milestone):** create a file on A, sync, assert a byte-identical
  file (content + exec bit + manifest root) appears on B, in one test process
  with two daemons. This is the first end-to-end proof the engine actually syncs.

### Phase S3 — Real two-daemon e2e on hardware
- Run S2 across **Macmini ↔ sub Mac** (optionally jw-server Linux) with isolated
  daemons (same discipline as the runner e2e: separate socket/HOME, cleanup
  after). Drivable from a `tm-agent sync` subcommand (extend the existing
  parser-only `--peer` seam) or a scripted harness. Assert cross-machine file
  sync + integrity. Satisfies verification-matrix **R3** + **R6-network**.

### Phase S4+ — Harden toward the ADR (separately scoped, one phase per matrix row)
Bidirectional + concurrent edits, conflict control plane (unlock
`CONFLICT_NOT_FOUND`, R11/R9), pairing/user-presence (unlock
`USER_PRESENCE_REQUIRED`, R11/R2), GC execution (unlock
`gc_coordinator_not_initialized`, R11/R12), `project remove`, real fault-injection
e2e (power/packet-loss/sleep-wake — R13/R16), scale + throughput gate (R14/R15),
Bonjour discovery, DEK-rotation CLI, GUI hydration. Each = its own phase + the
matrix row's e2e (all currently listed deferred).

## 5. Testing strategy

- **Unit** (exists, extend as needed): per-component in `src/sync/*` `#[cfg(test)]`.
- **Integration** (new): `daemon/term-meshd/tests/sync_e2e.rs` — two daemons in
  one test process (or two spawned), driving S0→S2 with assertions at each phase.
  This is the missing layer between component tests and hardware e2e.
- **Hardware e2e** (new, Phase S3): scripted Macmini↔sub Mac, isolated daemons,
  integrity assertion, cleanup. Same discipline as the runner e2e.
- Every phase's check is a gate: no advancing on red.

## 6. Decisions to confirm before coding

- **D1 — sync↔async bridge.** `OperationRunner::run` is synchronous (§2.2).
  Recommendation: the `NetworkSyncRunner` holds a `tokio::runtime::Handle` and
  `block_on`s the async QUIC/transfer flow inside `run()`, polling `cancelled`
  between awaits. (Alternative — add an async-runner path to `OperationManager` —
  is more invasive; defer.)
- **D2 — runner dispatch.** Add a second `OperationRunner` behind
  `open_with_runner_and_limits` and dispatch by `spec.kind` (map keyed by
  `OperationKind`, or a thin composite runner). Prefer the map — explicit and
  each runner stays single-purpose.
- **D3 — v0 trust/identity provisioning (blocker) — RESOLVED.** The concern was
  that pairing mutation is stubbed (`USER_PRESENCE_REQUIRED`), so no product path
  seeds two devices into each other's `TrustStore`. **Investigation resolved it:**
  a device is approved by applying a **recovery-key-signed `DeviceGrant`
  `CanonicalRecord` via `TrustStore::apply_control_record`** (`trust.rs:314,339`)
  — real ed25519 crypto, verified against the `recovery_signing_public` the store
  was opened with. **`USER_PRESENCE_REQUIRED` guards only the interactive
  recovery-key export/import (O2), not grant application.** So **no TrustStore
  backdoor is needed** — v0 uses the *real* trust mechanism with only one
  dev-grade concession: the recovery key is supplied directly instead of through
  the interactive user-presence/Keychain flow.

  **Confirmed v0 recipe** (mirrors `tests/quic_router.rs:96–129`, helper
  `fn grant` at `:54`):
  1. Create/load the project recovery signing keypair (ed25519). Public half →
     `TrustStore::open(path, project_id, recovery.verifying_key())` on each daemon.
  2. Each daemon `DeviceTlsIdentity::generate()` (persist via `keychain.rs`).
  3. Build a `DeviceGrant` (`ControlFields` + `DeviceGrantPayload {..,
     tls_certificate_hash: identity.certificate_hash()}`), **sign with the
     recovery private key**, at a **monotonically advancing roster epoch** per
     device (A@1, B@2, …).
  4. Apply **every** grant to **every** participating daemon's `TrustStore`
     (`apply_control_record`) so each daemon trusts itself + the peer.

  **Decision:** ship this as a `sync/trust_bootstrap.rs` dev/test helper (+ a
  hidden `tm-agent sync bootstrap-trust` for the hardware e2e). Non-production
  only because the recovery key is dev-managed. Production (S4) wires
  `pairing.approve` to drive the *same* `apply_control_record` behind a real
  local user-presence + Keychain flow. **This unblocks S0–S3.**
- **D4 — where the lane↔QUIC pump lives.** New reusable `SyncConnection`
  (wrapping `AuthenticatedConnection` + `StreamRouter`), not runner-private, so
  both accept and connect sides share it and future features reuse it.
- **D5 — ApplyPlan construction.** `reconcile` does NOT emit a file plan (§2.3);
  the runner diffs decoded manifest pages vs `ApplyStore::visible_state`. Put this
  in a new `sync/plan.rs` (unit-testable without the network) rather than inline
  in the runner.
- **D6 — explicit-endpoint bootstrap shape.** Direct QUIC `addr:port` + pinned
  identity is simplest; reusing the existing SSH peer tunnel to *carry* the QUIC
  endpoint is the doc's O5 "SSH bootstrap" and avoids a new inbound port, but adds
  coupling. Recommendation: direct `addr:port` for S0–S3; SSH-carried endpoint as
  an S4 convenience.
- **D7 — scope of v0.** Confirm one-directional (A→B), single project, happy path
  + integrity check is the S0–S3 target, with bidirectional/conflict/fault/scale
  all in S4+. (This plan assumes yes.)

## 7. One-line summary

The math is built and unit-tested; **three composition gaps** remain, in order:
(1) a **lane↔QUIC pump** binding `StreamRouter` to `AuthenticatedConnection`,
(2) a **network-sync `OperationRunner`** that drives scan→manifest-exchange→
reconcile→**build ApplyPlan**→chunk-transfer→apply and commits the oplog, and
(3) a **cross-machine e2e** that proves a file on A appears byte-identical on B.
The one-time blocker (D3, v0 trust provisioning) is **resolved**: apply
recovery-key-signed `DeviceGrant` records via `apply_control_record` — real
crypto, only the recovery key is dev-supplied. Everything else (conflict, GC,
fault-injection, scale, Bonjour) is S4+.

---
_§2 + §6 are filled from a five-layer interface survey (all `file:line`-cited);
§3–5 are stable regardless. Survey confirmed the modules are complete libraries
with **no partial network wiring already present** and **no in-code TODO/stub
markers** — the gap is pure composition, not half-finished code._
