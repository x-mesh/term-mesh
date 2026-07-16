# Mesh Project Sync Protocol v1

## 상태

- ADR status: Accepted
- Wire version: `1`
- Blocking decisions: **0**
- 구현 기준: `daemon/sync-protocol`
- executable vector: `daemon/sync-protocol/tests/fixtures/v1.json`

## WHY

한 사용자의 여러 Mac이 50 GiB·100만 file 규모 project를 중앙 service 없이 동기화해야 한다. 전송 재개, 30일 offline, crash recovery를 지원하면서 acknowledged change 유실과 silent overwrite를 허용하지 않는다.

기존 peer federation은 SSH 위 Protobuf terminal protocol이다. project sync용 QUIC, durable manifest, CAS, oplog는 존재하지 않는다. 따라서 기존 protocol을 암묵적으로 확장하지 않고 독립 version·capability·canonical record contract를 먼저 고정한다.

## 결정

- O1: daemon↔daemon transport는 `quinn + rustls` QUIC다. `control`, `terminal`, `sync-operation`, bounded `blob` stream을 분리한다.
- O2: project recovery key가 device grant/revoke와 monotonic roster epoch를 승인한다. device private key는 macOS Keychain에 저장하고 recovery key export/import는 user-presence를 요구한다.
- O3: CAS identity는 BLAKE3와 fixed 4 MiB chunk를 사용한다. content-defined chunking은 correctness·benchmark 이후에만 검토한다.
- O4: regular file, directory, symlink, executable bit, package directory를 지원한다. ACL/xattr은 제외한다. hardlink와 sparse file은 regular file로 degrade하고 그 사실을 기록한다.
- O5: discovery는 Bonjour LAN과 explicit endpoint/SSH bootstrap이다. 중앙 relay와 account service는 없다.
- O6: tombstone은 최소 90일 보존한다. 모든 승인 device ACK 또는 stale device revoke 전에는 GC하지 않는다.
- O7: Git object store와 filesystem CAS는 처음에는 분리한다. integrity와 namespace 격리를 검증한 뒤에만 dedupe bridge를 검토한다.

이 결정은 모두 확정됐다. unresolved blocking decision은 없다.

## Canonical record

모든 integer는 unsigned big-endian이다. 모든 field는 아래 순서로 정확히 한 번 나타난다. 다른 field 순서, trailing byte, non-zero reserved byte는 non-canonical이다.

```text
offset  size  field
0       4     magic = "TMPS"
4       2     protocol_version = 1
6       1     record_kind
7       1     reserved = 0
8       32    project_id
40      32    device_id
72      8     roster_epoch
80      8     sequence
88      4     payload_length
92      N     payload (maximum 8 MiB)
92+N    64    signature
```

`record_kind`는 device grant/revoke, manifest, oplog, tombstone, conflict, Git ref를 구분한다. payload 내부 schema는 kind별 후속 ADR에서 정하되 이 envelope의 project, signer, epoch, sequence domain을 우회할 수 없다.

Canonical hash는 다음과 같다.

```text
BLAKE3 derive_key(
  context = "term-mesh project-sync canonical record v1",
  material = canonical_record_bytes
)
```

signature는 `CanonicalRecord::signing_preimage()`가 반환하는 canonical bytes에 적용한다. 이 API는 마지막 64-byte signature field를 zeroing한다. `domain_hash()`는 signature를 포함한 content identity이므로 signing input으로 사용하면 안 된다. executable vector가 canonical bytes, domain hash, signing preimage를 각각 고정한다. signature algorithm과 key encoding은 trust implementation ADR에서 고정한다. 현재 vector의 signature는 encoding 안정성 fixture이며 cryptographic validity fixture가 아니다.

## Version과 downgrade

- QUIC handshake는 peer가 지원 version 목록과 선택 version을 함께 제시한다.
- v1 implementation은 mutual maximum인 `1`만 수락한다.
- common version이 없거나 peer가 mutual maximum보다 낮은 version을 선택하면 mutation 전에 connection을 거부한다.
- version offer는 최대 16개다. 초과 입력은 allocation이나 durable write 전에 거부한다.
- capability가 맞지 않으면 해당 stream을 열지 않으며 compatibility fallback으로 sync mutation을 보내지 않는다.

기존 peer는 project-sync capability가 없으므로 **SSH-only compatibility mode**로 남는다. terminal federation은 계속 동작하지만 project manifest, oplog, CAS, Git ref mutation은 전송하지 않는다. SSH bootstrap은 QUIC endpoint를 전달할 수 있을 뿐 sync trust를 대신하지 않는다.

## Invariant

- Trust: forged signature, stale epoch, revoked device, replay payload mismatch는 staging 전 거부한다.
- Data: decoder는 pure validation API다. caller는 canonical decode가 성공하기 전 manifest frontier, oplog, CAS, conflict, Git ref를 바꾸지 않아야 한다. durable mutation integration test는 persistence layer 구현 task에서 추가한다.
- Bounds: record payload는 최대 8 MiB다. blob payload는 이 envelope에 넣지 않고 bounded blob stream과 4 MiB chunk contract를 사용한다.
- ACK: durable oplog commit 뒤에만 보낸다. wall clock과 `mtime`은 causal authority가 아니다.
- Conflict: unresolved base/local/remote content와 tombstone은 retention root다. last-writer-wins로 자동 소거하지 않는다.
- Path: filesystem apply는 project root 밖 traversal, symlink escape, Unicode/case collision을 typed failure로 처리한다.
- Git: remote ref는 `refs/mesh/<peer-id>/*`만 갱신할 수 있다. `HEAD`, branch, index, worktree, config, hook, alternates, replace/graft namespace는 바꾸지 않는다.
- Focus: sync, pairing, operation, conflict, GC command는 non-focus command다. macOS app activation, window raise, pane selection을 바꾸지 않는다.
- Secrets: private key, recovery key, DEK는 wire record, log, fixture에 넣지 않는다.

## Failure contract

Decoder는 input 길이를 먼저 검사한다. 최소 record보다 짧은 input은 `Truncated`, 최대 record보다 큰 input은 `RecordTooLarge`, 선언 payload가 8 MiB를 넘으면 `PayloadTooLarge`다. bad magic, unsupported version, unknown kind, non-zero reserved byte, trailing byte는 서로 구분되는 error다.

Error를 받았을 때 caller는 input을 quarantine할 수 있지만 active manifest, causal frontier, ACK, live CAS, Git ref를 바꾸면 안 된다. `tests/vectors.rs`는 persistence가 없는 현재 범위에서 malformed, non-canonical, truncated, oversized decode rejection만 검증한다. 실제 durable non-mutation은 persistence caller integration test에서 검증한다.

## Verification

```bash
cd daemon && cargo test -p sync-protocol
```

이 command는 fixture의 canonical bytes, signature-zeroed signing preimage, domain-separated BLAKE3 hash, strict decode, downgrade rejection, Git `check-ref-format` 핵심 규칙과 namespace confinement를 반복 검증한다.
