# Mesh Project Sync Benchmark Contract v1

## 상태

- Contract status: Draft
- Schema version: `1`
- 대상: project manifest/CAS planning과 peer 간 blob 전송
- 성능 gate: full profile의 receiver-verified steady-state throughput가 **500 MiB/s 이상**
- 현재 측정값: 없음. 이 문서의 JSON은 schema 예시이며 benchmark 결과가 아니다.

## WHY

Project sync는 50 GiB·100만 file project를 다뤄야 한다. 작은 fixture만 재면 file 수에 따른 metadata 비용을 놓치고, 압축하기 쉬운 zero stream만 보내면 실제 전송 성능을 과장한다. 반대로 매번 50 GiB·100만 file을 disk에 만들면 fixture 준비 시간이 benchmark보다 길어지고 host 상태에 따라 결과가 크게 흔들린다.

따라서 두 workload를 분리한다.

- **Virtual scale workload**: 50 GiB logical data와 1,000,000 file descriptor로 manifest/CAS planning의 scale을 잰다. 실제 file 100만 개를 만들지 않는다.
- **Physical throughput workload**: 압축 불가능한 10 GiB logical payload를 실제 sender→receiver data path로 보내고 receiver가 byte 수와 hash를 검증한다.

둘 중 하나의 결과로 다른 하나를 대신 설명하면 안 된다. Virtual fixture는 disk와 network throughput 증거가 아니고, 10 GiB stream은 100만 file metadata scale 증거가 아니다.

## Profile

### Smoke

개발 중 correctness와 benchmark harness 회귀를 빠르게 확인하는 profile이다. 성능 합격 판정에는 사용하지 않는다.

- virtual fixture: 10,000 files, 512 MiB logical bytes
- physical payload: 256 MiB logical incompressible bytes
- iteration: warm-up 1회, measured 1회
- receiver verification: 필수
- artifact 생성과 schema validation: 필수
- 500 MiB/s gate: 적용하지 않음

Smoke의 크기는 harness 실행 시간을 제한하기 위한 contract 값이다. 제품 scale이나 성능을 대표하지 않는다.

### Full

release 후보와 성능 변경을 판정하는 profile이다.

- virtual fixture: 정확히 1,000,000 files, 총 logical size 정확히 50 GiB
- physical payload: 정확히 10 GiB logical incompressible bytes
- iteration: warm-up 1회, measured 3회 이상
- 결과 집계: measured iteration의 median을 대표값으로 사용
- receiver verification: 모든 iteration에서 필수
- 500 MiB/s gate: physical workload 대표값에 적용

Full run에서 verification 실패, iteration 누락, environment metadata 누락이 하나라도 있으면 throughput 숫자와 무관하게 `INVALID`다.

## 50 GiB·100만 virtual fixture

Virtual fixture는 deterministic descriptor stream이다. 각 descriptor는 실제 file 대신 아래 값을 만든다.

```text
index
relative_path
logical_size_bytes
mode
content_seed
expected_chunk_count
```

생성 규칙은 다음과 같다.

1. 동일한 `fixture_seed`, schema version, file count를 입력하면 descriptor 순서와 값이 byte-for-byte 같아야 한다.
2. path는 project-relative canonical UTF-8 path다. 중복, `..`, absolute path, symlink escape를 만들지 않는다.
3. file 수는 정확히 1,000,000개다. directory descriptor는 file 수에 포함하지 않고 별도 집계한다.
4. 모든 file의 `logical_size_bytes` 합은 정확히 `50 * 1024^3` bytes다.
5. size distribution은 fixture schema에 versioned algorithm과 seed로 기록한다. 구현 변경은 schema version을 올려 이전 결과와 섞이지 않게 한다.
6. `content_seed`로 4 MiB fixed chunk identity를 deterministic하게 계산한다. 실제 50 GiB buffer를 allocate하거나 disk에 materialize하지 않는다.
7. fixture 생성 시간과 benchmark 대상 처리 시간을 분리해 기록한다. gate 대상은 benchmark 대상 처리 시간이다.

이 workload는 descriptor ingest, path validation, manifest construction, chunk planning, dedupe lookup 계획, memory high-water mark를 잰다. 실제 filesystem traversal, file open/read, CAS write, network 전송은 재지 않는다.

Full run 전 fixture 자체를 검증한다.

```text
file_count == 1_000_000
logical_bytes == 53_687_091_200
duplicate_path_count == 0
invalid_path_count == 0
descriptor_digest == digest_from_same_seed_regeneration
```

`descriptor_digest` algorithm과 encoding은 artifact에 기록한다. 구현이 확정되기 전에는 서로 다른 algorithm의 digest를 비교하지 않는다.

## 10 GiB logical incompressible throughput

Physical workload는 production과 같은 chunk framing, integrity check, flow control, encryption, sender/receiver I/O 경로를 사용해야 한다. benchmark 전용 bypass가 production cost를 생략하면 결과는 `INVALID`다.

Payload는 versioned deterministic PRNG가 만든 byte stream이다. seed와 generator version을 artifact에 남긴다. all-zero, 반복 block, sparse file처럼 압축 가능한 입력은 금지한다. 전송 계층의 compression이 활성화되어 있다면 sender의 logical bytes와 wire bytes를 모두 기록한다.

Receiver는 ACK 전에 다음을 검증한다.

- 수신 logical byte 수가 정확히 `10 * 1024^3`인지
- chunk sequence와 각 chunk length가 contract와 맞는지
- receiver에서 계산한 whole-payload BLAKE3가 같은 seed로 독립 생성한 expected digest와 같은지
- corruption, retry exhaustion, dropped chunk가 0인지
- durable mode를 표방한 run이면 required durability boundary가 완료됐는지

Sender가 보낸 byte 수만으로 성공을 판정하지 않는다. `receiver_verified=true`와 일치하는 receiver digest가 없는 iteration은 `INVALID`다.

### 측정 구간

두 시간을 모두 기록한다.

- `end_to_end_seconds`: session 준비 시작부터 receiver verification 완료까지
- `steady_state_seconds`: 첫 payload byte가 sender data path에 들어간 시점부터 마지막 payload byte가 receiver data path를 통과한 시점까지

Gate throughput은 다음 식만 사용한다.

```text
steady_state_mib_per_second =
  receiver_verified_logical_bytes / 1_048_576 / steady_state_seconds
```

Handshake, pairing, fixture generation, digest 사전 계산 시간을 숨기지 않도록 `end_to_end_seconds`도 반드시 보고한다. 다만 500 MiB/s binary gate는 measured iteration의 `steady_state_mib_per_second` median에만 적용한다.

```text
PASS    valid full profile && median >= 500.0 MiB/s
FAIL    valid full profile && median < 500.0 MiB/s
INVALID verification/schema/environment/profile contract 위반
```

반올림 전 값을 gate에 사용한다. display 반올림으로 `FAIL`을 `PASS`로 바꾸면 안 된다.

## 실행 runbook

Runner entry point는 `scripts/bench-mesh-project-sync.sh`다. Smoke가 기본값이지만 재현 가능한 기록에는 profile을 항상 명시한다.

```bash
RUN_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
OUT="artifacts/mesh-project-sync/$RUN_ID"
mkdir -p "$OUT"
./scripts/bench-mesh-project-sync.sh --smoke --output "$OUT/report.json"
```

Full은 큰 workload이므로 explicit opt-in이다. 기본 timeout은 runner가 정하지만, override했다면 artifact에 남겨야 한다.

```bash
RUN_ID="$(uuidgen | tr '[:upper:]' '[:lower:]')"
OUT="artifacts/mesh-project-sync/$RUN_ID"
mkdir -p "$OUT"
./scripts/bench-mesh-project-sync.sh --full --output "$OUT/report.json"
```

`MESH_PROJECT_SYNC_BENCH_BIN`으로 executable을 override할 수 있다. Override path와 binary digest를 environment metadata에 기록해야 한다. Runner가 수집하는 terminal/socket latency threshold는 보조 회귀 gate다. 이 값이 10 GiB receiver-verified throughput의 500 MiB/s gate를 대체하지 않는다.

1. 두 peer를 동일 commit의 Release build로 준비한다. Debug build 결과는 진단용이며 gate 결과로 쓰지 않는다.
2. CPU governor, 전원 연결, thermal 상태, foreground 부하를 확인한다.
3. sender와 receiver의 host, storage, network topology를 고정하고 metadata를 수집한다.
4. profile과 fixture seed를 명시한다. seed를 생략한 run은 `INVALID`다.
5. virtual fixture를 생성·self-validate한 뒤 warm-up과 measured iteration을 수행한다.
6. physical payload expected digest를 receiver 쪽에서 독립 계산하거나, receiver가 같은 versioned generator로 재생성해 검증한다.
7. physical warm-up 뒤 measured iteration을 수행한다. iteration 사이에 connection과 cache reset 정책을 동일하게 적용한다.
8. raw iteration JSON, aggregate JSON, process log를 보존한다.
9. schema validator와 receiver verification을 통과한 뒤에만 median과 gate를 계산한다.
10. baseline과 비교할 때 동일 profile, fixture/generator version, topology, durability mode만 비교한다.

Cold-cache와 warm-cache 결과가 필요하면 별도 run으로 만든다. 한 run 안에서 섞어 median을 내지 않는다. Cache reset 방법과 성공 여부를 artifact에 기록한다.

Loopback은 software overhead를 격리하는 데 쓸 수 있지만 network performance 주장에는 쓸 수 없다. 500 MiB/s gate run은 topology를 명시해야 하며 baseline과 동일한 topology에서 수행한다.

## Metric contract

필수 metric은 다음과 같다.

- virtual: descriptor count, logical bytes, planned chunk count, unique chunk count, dedupe ratio, fixture generation seconds, processing seconds, peak RSS bytes
- physical: receiver-verified logical bytes, wire bytes, steady-state seconds, end-to-end seconds, MiB/s, chunk retries, corrupt chunks, sender/receiver CPU time, sender/receiver peak RSS
- system: sender/receiver disk read/write bytes, network TX/RX bytes, thermal state 전후, available memory 전후
- validity: profile, iteration kind, receiver verification, expected/actual digest, error count, gate result

지원되지 않는 OS counter는 `null`과 이유를 함께 기록한다. `0`으로 대체하면 안 된다.

## Artifact schema

Run마다 immutable directory 하나를 만든다.

```text
artifacts/mesh-project-sync/<run-id>/
  report.json
  environment.json
  virtual-iterations.jsonl
  physical-iterations.jsonl
  aggregate.json
  runner.log
```

`--output`이 지정하는 `report.json`은 run의 entry artifact다. Environment와 raw iteration을 inline으로 포함할 수 있지만, 크기 때문에 별도 파일로 저장하면 상대 path와 digest를 `report.json`에 기록한다. 어느 방식이든 아래 필수 field와 raw iteration 보존 규칙은 같다.

각 JSON record에는 최소한 아래 field가 있어야 한다. 추가 field는 허용하지만 기존 field 의미를 바꾸려면 schema version을 올린다.

```json
{
  "schema_version": 1,
  "run_id": "<UUID>",
  "profile": "full",
  "commit": "<40-hex git commit>",
  "build_configuration": "Release",
  "workload": "physical_incompressible",
  "iteration": 1,
  "iteration_kind": "measured",
  "fixture": {
    "schema_version": 1,
    "seed": "<recorded seed>",
    "generator": "<name and version>",
    "file_count": null,
    "logical_bytes": 10737418240,
    "chunk_bytes": 4194304
  },
  "timing": {
    "steady_state_seconds": null,
    "end_to_end_seconds": null
  },
  "receiver": {
    "verified": null,
    "verified_logical_bytes": null,
    "expected_blake3": "<hex digest>",
    "actual_blake3": "<hex digest>"
  },
  "metrics": {
    "steady_state_mib_per_second": null,
    "wire_bytes": null,
    "chunk_retries": null,
    "corrupt_chunks": null,
    "sender_peak_rss_bytes": null,
    "receiver_peak_rss_bytes": null
  },
  "validity": {
    "valid": null,
    "invalid_reasons": []
  }
}
```

위 record는 **형식 예시**다. `null`은 미측정 placeholder이며 실제 measured artifact에서 필수 metric이 `null`이면 해당 run은 `INVALID`다.

`aggregate.json`은 raw iteration을 대체하지 않는다. 대표값, 산식, gate만 담는다.

```json
{
  "schema_version": 1,
  "run_id": "<same UUID>",
  "profile": "full",
  "valid_measured_iterations": null,
  "physical_median_mib_per_second": null,
  "gate_threshold_mib_per_second": 500.0,
  "gate_result": "INVALID",
  "raw_artifact_digest": "<digest over canonical raw artifacts>"
}
```

## Environment metadata

`environment.json`에 다음을 기록한다.

- UTC 시작 시각, run ID, repository commit, dirty worktree 여부
- build configuration, compiler/Xcode/Rust version, dependency lock digest
- protocol version, benchmark runner version, fixture/generator schema version
- macOS version/build, machine model, CPU model/core 수, RAM
- sender/receiver process arguments에서 secret을 제거한 값
- storage model, filesystem, free space, durability/fsync mode
- network interface, link speed, MTU, loopback/LAN 여부, sender↔receiver topology
- encryption, compression, QUIC 설정, stream/concurrency/chunk 크기
- cache policy와 reset 방법
- 전원 상태, thermal state 전후, 주요 foreground load

IP, username, project path, recovery key, private key, token은 artifact에 넣지 않는다. Host는 익명 run-local ID로 표시한다.

## 해석과 bottleneck 분류

숫자 하나만 보고 원인을 단정하지 않는다. 최소한 아래 신호를 함께 본다.

- virtual processing time이 file count와 함께 증가하고 CPU 한 core가 포화되면 manifest/path/hash planning 후보
- peak RSS가 descriptor count에 비례해 계속 증가하면 전체 manifest materialization 후보
- receiver disk write가 throughput와 맞물리고 CPU/network가 남으면 storage 또는 durability boundary 후보
- sender나 receiver CPU가 포화되고 wire가 남으면 hashing, encryption, framing 후보
- wire throughput가 link ceiling에 가깝고 CPU/disk가 남으면 network 후보
- retry, loss, RTT와 함께 throughput가 흔들리면 QUIC flow/congestion control 후보
- logical throughput는 높은데 end-to-end가 낮으면 handshake, setup, final verification 후보

이는 진단 가설이다. profiler, OS counter, isolated rerun으로 확인하기 전에는 원인으로 확정하지 않는다.

성능 변경의 보고에는 baseline과 candidate의 raw artifact, absolute 값, 차이율, environment 차이를 함께 둔다. 서로 다른 machine이나 topology의 차이율은 참고값이며 regression 판정에 쓰지 않는다.

## 재현성

- seed, generator version, commit, build configuration을 고정한다.
- measured iteration은 같은 순서와 reset policy로 실행한다.
- wall clock은 monotonic clock으로 잰다.
- byte 단위는 IEC를 사용한다: `1 MiB = 1,048,576 bytes`, `1 GiB = 1,073,741,824 bytes`.
- raw artifact는 수정하지 않고 digest를 남긴다.
- 실패 iteration도 삭제하지 않는다. 실패 이유와 함께 보존한다.
- 비교 run은 가능하면 같은 host pair에서 연속 실행하고 baseline/candidate 순서를 교차해 thermal/order bias를 확인한다.

## 한계

- Virtual fixture는 실제 filesystem의 directory enumeration, metadata cache, inode pressure, Unicode normalization 비용을 재현하지 않는다.
- Deterministic incompressible stream은 실제 repository의 file-size 분포, dedupe율, sparse file, package directory를 대표하지 않는다.
- 10 GiB steady-state gate는 initial pairing, offline reconciliation, conflict resolution, GC latency의 합격 기준이 아니다.
- Median 3회는 큰 regression을 찾는 최소 기준이지 통계적 성능 연구가 아니다. 분산이 크면 iteration을 늘리고 원인을 조사한다.
- Machine, thermal, storage, network가 바뀐 결과는 직접 비교할 수 없다.
- 이 문서는 benchmark contract다. 실제 측정값은 artifact로만 주장하며 문서의 placeholder를 결과로 인용하지 않는다.
