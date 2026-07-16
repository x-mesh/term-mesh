# Mesh Project Sync Verification Matrix

## Verdict

**Overall binary verdict: PASS — formal t18 DoD 충족.**

이 binary verdict는 formal t18 integration DoD를 기준으로 한다. Rust workspace, PeerProto Swift test, Debug app build/reload, SSH federation, multi-workspace/project-sync smoke, R1–R16 evidence mapping이 모두 통과했다. Table의 `PARTIAL`은 requirement의 exhaustive production evidence가 아직 얕다는 뜻이며 formal t18 DoD failure가 아니다. Full 10 GiB run, real blob-saturation latency, real macOS user-presence drill은 아래에 nonblocking deferred evidence로 남긴다.

## Environment

- Date: 2026-07-16 (Asia/Seoul)
- Host: macOS 26.5.2 (25F84), arm64
- Rust: `rustc 1.96.1 (31fca3adb 2026-06-26) (Homebrew)`
- Xcode: 26.6 (17F113)
- Workspace run: `cd daemon && cargo test --workspace -- --test-threads=1` — **946 passed, 0 failed, 26 ignored**, exit `0`
- PeerProto run: `cd swift/PeerProto && swift test` — **25 passed, 0 failed, 0 ignored**, 4.66초
- Integration run: `./scripts/test-mesh-project-sync-integration.sh --profile daemon-only --skip-workspace-tests` — **PASS_WITH_UNSUPPORTED**, 6 pass, 4 explicit `UNSUPPORTED`
- Source requirement: `.xm/build/projects/mesh-project-sync/context/REQUIREMENTS.md`
- Test source: `daemon/term-meshd/tests/`, `daemon/sync-protocol/tests/`, `termMeshTests/`

행별 판정 의미: `PASS`는 requirement의 핵심 clause가 이번 run에서 통과한 test 또는 measured artifact에 연결됐다는 뜻이다. `PARTIAL`은 deterministic core는 통과했지만 production-scale/manual evidence가 deferred됐다는 뜻이다. Overall binary verdict는 별도 formal t18 DoD checklist로 계산한다.

## Formal t18 DoD

- PASS — Rust workspace: 946 passed, 0 failed.
- PASS — PeerProto Swift: 25 passed, 0 failed, 0 ignored, 4.66초.
- PASS — Debug `xcodebuild`.
- PASS — tagged Debug reload.
- PASS — localhost SSH tunnel/auth/attach/stream smoke.
- PASS — peer workspace lifecycle scenario 1, 2, 3, 4, 5, 6a, 6b.
- PASS — isolated project-sync CLI/daemon smoke와 daemon multi-workspace 6 scenarios.
- PASS — security fault suite 11/11과 benchmark smoke threshold.
- PASS — R1–R16 evidence mapping present and unique.

PeerProto hang fix는 `UnixSocketTransportTests`의 child process 종료를 bounded wait로 제한하고 timeout 뒤 `SIGKILL`하는 경로로 검증됐다. 이전 85초 무출력 hang은 재현되지 않았다.

## R1–R16

| ID | Verdict | Passing evidence | 남은 gap |
|---|---|---|---|
| R1 Stable project identity | PARTIAL | `cargo test -p term-meshd --test project_registry`; 핵심 test `project_id_survives_root_move_and_registry_reopen`, `failed_sync_state_transaction_preserves_committed_values`, `corrupt_registry_is_quarantined_without_replacement`, `list_returns_all_projects_in_stable_root_order` | Identity·root·active manifest·roster epoch persistence는 test됐지만 project policy persistence field/evidence가 없음. |
| R2 Device trust와 recovery | PASS | `cargo test -p term-meshd --test trust_rotation`; `recovery_records_reject_forgery_replay_stale_epoch_and_revoke`, `dek_wrap_binds_device_epoch_and_rotation_journal_resumes_every_phase`, `rotation_activation_rolls_back_on_missing_or_mismatched_dek_commitment`. `cargo test -p term-meshd --test quic_router`; mutual pin, revoke revalidation, wrong identity/ALPN rejection. `sync_rpc`에 포함된 Keychain fail-closed·presence binding test도 통과. | 실제 UI/CLI mutation wiring은 R11에서 별도 PARTIAL 처리. |
| R3 daemon↔daemon QUIC transport | PARTIAL | `cargo test -p term-meshd --test quic_router`; `loopback_quic_requires_mutual_pin_and_revalidates_revocation`, `independent_wrong_server_wrong_client_and_alpn_pins_fail_closed`. `cargo test -p term-meshd --test sync_rpc`; `stream_router`의 lane starvation, byte/lane permit, boundary test 통과. B run의 `./scripts/peer-ssh-demo.sh localhost`도 SSH tunnel/auth/attach/4초 stream을 PASS. | SSH smoke는 current local peer끼리의 localhost run이다. project-sync capability가 없는 구버전 peer와 장수 QUIC connection 재사용을 별도로 계측한 evidence는 없음. |
| R4 Authoritative project scan | PARTIAL | `cargo test -p term-meshd --test manifest_scan`; `initial_restart_and_overflow_scans_have_identical_roots`, `invalid_paths_are_rejected_by_canonical_manifest_builder`, `case_and_unicode_normalization_collisions_are_typed_errors`, `one_million_entry_stream_stays_within_configured_buffers`, descriptor/race/cancel boundary test. | watcher hint에서 directory Merkle dirty-subtree scan으로 이어지는 production integration artifact가 없음. Authoritative full scan correctness와 bounds만 PASS. |
| R5 Versioned immutable manifest | PASS | `cargo test -p sync-protocol --test vectors`; canonical/bounded wire tests. `cargo test -p term-meshd --test reconcile_resume`; `million_entry_source_streams_to_persisted_index_and_no_change_has_zero_paths`, `canonical_manifest_shards_reject_rehashed_split_and_merge_layouts`, `verified_manifest_snapshot_blocks_raw_writer_and_tamper_never_commits_head`. | 없음. |
| R6 Encrypted CAS와 resumable transfer | PASS | `cargo test -p term-meshd --test cas_integrity`; encrypted chunk boundary, domain separation, resume checkpoint, corruption/bitflip, storage bound, symlink confinement, crash-temp tests. 핵심 `reopened_resume_requires_exact_checkpoint_and_preserves_verified_chunks`, `resumable_ranges_reverify_chunks_and_reject_valid_old_bitmap`. | Network missing-hash negotiation end-to-end는 R3/R14 측정 gap과 별개다. CAS core는 통과. |
| R7 Signed append-only oplog | PASS | `cargo test -p term-meshd --test oplog_gc`; `duplicate_is_idempotent_and_payload_mismatch_is_durably_quarantined`, `gaps_and_out_of_order_records_only_advance_contiguous_frontier`, `durable_ack_survives_post_commit_crash_and_is_never_issued_pre_commit`, `forged_stale_revoked_and_cross_project_records_fail_before_mutation`. | 없음. |
| R8 Crash-consistent apply | PASS | `cargo test -p term-meshd --test apply_crash`; apply boundary, subprocess crash, rollback second-crash, disk-full/permission, precondition race, symlink swap, durable visibility tests. 핵심 `every_apply_boundary_reopens_to_committed_or_rolled_back`, `real_subprocess_exit_at_every_apply_durability_class_converges`. | 없음. |
| R9 Typed conflict handling | PASS | `cargo test -p term-meshd --test conflict_matrix`; unresolved text 3-side preservation, binary 2-side preservation, add/add, delete/modify, executable, case/NFC, budget, revision semantics test. | Conflict store의 local RPC wiring은 R11에서 별도 PARTIAL 처리. Core model은 통과. ACL/xattr은 O4에 따라 out of scope. |
| R10 Git replication plane | PASS | `cargo test -p term-meshd --test git_replication`; valid object graph, corrupt/missing tip rejection, namespace confinement, ref CAS/crash recovery, protected metadata byte identity, linked worktree, symlink/path swap, orphan budget tests. | 실제 remote network transfer 성능은 R14 gap. Git correctness core는 통과. |
| R11 Local daemon API | PARTIAL | `cargo test -p term-meshd --test sync_rpc` 결과 33 passed, 2 ignored; operation idempotency, cancel/retry, interruption recovery, background responsiveness, typed bounded envelope, focus observable test 통과. `cargo test -p term-mesh-cli project_sync_cli_tests` 결과 2 passed. CLI parser/help는 `project`, `sync`, `pairing`, `conflict`, `gc` command group에서 확인. | `project remove` 없음. Pairing approve/revoke/recovery는 `USER_PRESENCE_REQUIRED`로 fail-closed만 수행. Conflict get/resolve는 `CONFLICT_NOT_FOUND`; GC는 `gc_coordinator_not_initialized`; GUI capability set은 manifest-scan-only이며 registry hydration/device/conflict/GC/recovery가 unavailable. |
| R12 Offline retention과 GC | PASS | `cargo test -p term-meshd --test oplog_gc`; `tombstones_require_age_and_all_active_device_acks_and_reachable_roots_survive`, `ninety_days_without_one_approved_device_ack_never_collects_tombstone`, GC lease/journal/root recheck tests. `cargo test -p term-meshd --test reconcile_resume`; `thirty_day_orchestrator_incremental_crash_resume_and_full_fallback_converge`. | Public GC execution RPC는 R11 gap. Core retention/recovery는 통과. |
| R13 Data integrity | PASS | R6–R10 suites의 crash, replay, conflict-preservation, ACK-after-commit, incomplete-CAS rejection tests와 security fault report를 함께 evidence로 사용. Workspace 946/0, security fault 11/11이며 artifact `failed`는 0. | 실행된 deterministic/fault corpus 범위에서 PASS. Real multi-machine power/network fault는 R14–R16 gap으로 남긴다. |
| R14 Scale | PARTIAL | `benchmark-smoke.json`: virtual 50 GiB, 1,000,000 files, sparse allocated 0 B, no-change path-list 0 B, 90% resume retransmit 10%, receiver-verified 256 MiB throughput **7,814.706 MiB/s**, threshold 500 MiB/s PASS. `reconcile_resume::million_entry_source_streams_to_persisted_index_and_no_change_has_zero_paths`도 통과. | Nonblocking deferred: 최소 10 GiB incompressible full run과 실제 1 GiB network interruption artifact. Smoke와 deterministic resume core는 formal DoD를 충족한다. |
| R15 Resource safety | PARTIAL | `manifest_scan::one_million_entry_stream_stays_within_configured_buffers`, `reconcile_resume::million_entry_source_streams_to_persisted_index_and_no_change_has_zero_paths`; `sync_rpc`의 router/boundary/queue-cap tests; smoke artifact의 RSS 5,996,544 B, FD 5, peak streams 4, peak connections 1, terminal p95 0.001 ms, socket p95 0.001 ms. 모든 smoke threshold check가 true. | Nonblocking deferred: 실제 saturated blob transfer 중 terminal/socket p95, full resource run, production FD/connection leak soak. |
| R16 Security verification | PARTIAL | Security report **11/11 passed, 0 failed**, duration 54,000 ms, integrity `da56d1c29d3147768079c60a1f598c5d8e6a33fc7a4cc62f197b80a8389170a2`. forged/stale/revoked/replay/downgrade/cross-project/path/symlink/collision/decompression/disk/SQLite/CAS/packet-loss/sleep-wake를 포함한다. `trust_rotation::dek_wrap_binds_device_epoch_and_rotation_journal_resumes_every_phase`도 통과. | Nonblocking deferred: real macOS user-presence prompt/cancel과 approve→revoke→rotate real Keychain UI drill. Automated privileged-gate와 rotation core는 formal DoD를 충족한다. |

## Evidence artifacts

- Requirements: `.xm/build/projects/mesh-project-sync/context/REQUIREMENTS.md`
- Protocol vectors: `daemon/sync-protocol/tests/fixtures/v1.json`
- Security corpus: `daemon/term-meshd/tests/fixtures/security_faults.json`
- Security runner: `scripts/run-security-fault-suite.sh`
- Security report: `/var/folders/j3/vtb5p8r974xgdb6t5zcnss480000gn/T/mesh-project-sync-integration/security-fault-suite.json`
- Scale benchmark source/report producer: `daemon/term-meshd/benches/mesh_sync_scale.rs`
- Smoke benchmark JSON: `/var/folders/j3/vtb5p8r974xgdb6t5zcnss480000gn/T/mesh-project-sync-integration/benchmark-smoke.json`
- Daemon smoke log: `/var/folders/j3/vtb5p8r974xgdb6t5zcnss480000gn/T/mesh-project-sync-integration/daemon-smoke.log`
- GUI tests: `termMeshTests/ProjectSyncViewModelTests.swift`
- Debug build log: `/tmp/term-mesh-xcodebuild-mesh-project-sync.log`
- Tagged Debug runtime log: `/tmp/term-mesh-debug-mesh-project-sync.log`
- SSH federation smoke log: `/tmp/tm-peer-ssh-demo-41272.log`

## Ignored와 manual tests

Workspace run의 26 ignored는 integration test binary마다 포함된 아래 2개 Keychain test가 반복 집계된 결과다. 독립 `sync_rpc` run에서는 2 ignored였다.

- `sync::keychain::tests::macos_background_keychain_smoke_is_non_prompting`: codesigned test host와 Keychain data-protection entitlement 필요.
- `sync::keychain::tests::macos_user_presence_prompt_cancel_manual`: 실제 Touch ID/password prompt와 cancel을 확인하는 manual test.

Ignored test는 PASS 수에 포함하지 않았고 R16을 PARTIAL로 유지하는 근거다.

Daemon-only integration runner의 4개 `UNSUPPORTED`는 failure로 숨기지 않았다.

- workspace test는 앞 단계에서 별도로 실행했기 때문에 runner에서 중복 실행을 skip했다.
- SSH target이 지정되지 않아 runner 내부 SSH check는 실행하지 않았다. B의 별도 localhost SSH smoke는 PASS했다.
- daemon-only profile은 PeerProto와 app build/runtime를 실행하지 않는다. B가 별도로 app build/reload와 hang fix 이후 PeerProto 25/25를 PASS했다.

Brownfield B verification:

- PASS: `xcodebuild -project GhosttyTabs.xcodeproj -scheme term-mesh -configuration Debug -destination 'platform=macOS' build`.
- PASS: `./scripts/reload.sh --tag mesh-project-sync`.
- PASS: `python3 tests_v2/test_peer_workspace_lifecycle.py`; scenario 1, 2, 3, 4, 5, 6a, 6b 전부 통과.
- PASS: `./scripts/peer-ssh-demo.sh localhost`; SSH tunnel/auth/attach/4초 stream 완료.
- PASS: `cd swift/PeerProto && swift test`; `UnixSocketTransportTests`의 bounded terminate + timeout `SIGKILL` fix 뒤 25 passed, 0 failed, 0 ignored, 4.66초. 이전 85초 무출력 hang은 해소됐다.

## Reproduce

```bash
cd daemon
cargo test -p sync-protocol --test vectors
cargo test -p term-meshd --test project_registry
cargo test -p term-meshd --test manifest_scan
cargo test -p term-meshd --test cas_integrity
cargo test -p term-meshd --test oplog_gc
cargo test -p term-meshd --test reconcile_resume
cargo test -p term-meshd --test trust_rotation
cargo test -p term-meshd --test quic_router
cargo test -p term-meshd --test apply_crash
cargo test -p term-meshd --test conflict_matrix
cargo test -p term-meshd --test git_replication
cargo test -p term-meshd --test sync_rpc
```

Measured artifact commands:

```bash
./scripts/run-security-fault-suite.sh --report /tmp/term-mesh-security-fault-report.json
cd daemon/term-meshd
cargo bench -p term-meshd --bench mesh_sync_scale -- --full
```

`--full` benchmark, real saturated-blob latency, real user-presence/manual drill은 nonblocking deferred evidence다. Formal t18 DoD의 overall PASS를 막지 않지만 production release evidence를 확장할 때 이 matrix에 추가한다.
