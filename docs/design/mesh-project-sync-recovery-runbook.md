# Mesh project sync recovery runbook

이 문서는 project sync 장애를 멈추고, 증거를 보존하고, 복구한 뒤 다시 여는 절차다. 데이터보다 가용성을 우선하지 않는다. 검증할 수 없는 상태에서는 sync를 재개하지 않는다.

## 현재 구현 경계

현재 `tm-agent`가 제공하는 project sync 명령은 `project`, `pairing`, `sync`, `conflict`, `gc`다. 이 중 다음 제한은 운영 절차의 일부다.

- `pairing approve`, `pairing revoke`, `pairing recovery-export`, `pairing recovery-import`는 local socket에서도 `USER_PRESENCE_REQUIRED`로 거부된다. 인증된 local user-presence flow가 아직 연결되지 않았으므로 CLI, SSH, raw RPC로 우회하면 안 된다.
- `pairing list`는 현재 `state: not_configured`, 빈 device 목록, `user_presence_required: true`를 반환한다.
- `conflict list`는 현재 빈 목록을 반환하고 `conflict get/resolve`는 `CONFLICT_NOT_FOUND`로 거부된다. durable conflict control plane이 연결되기 전에는 수동 file 덮어쓰기로 대신하지 않는다.
- DEK rotation engine에는 `prepared → published → activated → ack_wait → retired → completed` journal이 있지만 operator CLI는 없다. revoke와 rotation 완료를 주장하려면 향후 인증된 local flow와 공개 status API가 둘 다 필요하다.
- `sync start`의 현재 operation kind는 `manifest_scan`이다. 이것만으로 peer transfer, conflict resolution, DEK rotation이 수행됐다고 해석하지 않는다.

이 경계 때문에 approve/revoke/recovery가 필요한 사고는 **차단 상태로 유지**하는 것이 현재의 정상 동작이다.

## 안전 원칙

1. 먼저 project를 pause한다. pause는 새 scan/sync admission을 막지만 이미 실행 중인 operation을 자동 취소하지 않는다.
2. 원본, SQLite, CAS, Git을 수정하기 전에 별도 volume에 read-only 증거와 backup을 만든다.
3. user-presence prompt 취소, 잠긴 Keychain, identity 불일치, stale epoch는 모두 거부로 처리한다. 재시도 횟수로 우회하지 않는다.
4. conflict의 base/local/remote와 content root를 모두 보존한다. 선택 전에는 어느 쪽도 삭제하지 않는다.
5. corruption과 missing object를 구분한다. corruption을 "없는 파일"로 바꿔서 진행하지 않는다.
6. data degradation 또는 loss가 생기면 영향 범위와 근거를 사람이 명시적으로 승인하기 전까지 새 baseline을 만들지 않는다.

## 준비와 식별

아래 값은 예시가 아닌 sanitized placeholder다. 실제 ID와 경로는 `project list` 결과와 incident 기록에서 채운다. recovery key, DEK, token, private key는 shell variable이나 transcript에 넣지 않는다.

```bash
PROJECT_ID='<project-id-from-project-list>'
PROJECT_ROOT='<absolute-project-root>'
OPERATION_ID='<operation-id-from-sync-start>'
REQUEST_ID='<new-unique-request-id>'
BACKUP_ROOT='<absolute-backup-directory-on-separate-volume>'
```

현재 daemon이 보는 project와 pause 상태를 기록한다.

```bash
tm-agent project list
tm-agent project status "$PROJECT_ID"
tm-agent pairing list "$PROJECT_ID"
tm-agent gc status "$PROJECT_ID"
```

`project status`가 요청한 root와 다른 identity를 가리키거나 `project list`에 ID가 없으면 중단한다. 같은 path를 다시 `project add`해 새 identity를 만들지 않는다.

## 즉시 격리와 backup

새 작업을 막는다.

```bash
tm-agent project pause "$PROJECT_ID"
tm-agent project status "$PROJECT_ID"
```

활성 operation이 있으면 상태를 기록하고 취소를 요청한다. 결과가 `cancel_requested`면 terminal state가 아니다. `cancelled`, `failed`, `succeeded`, `interrupted` 중 하나가 될 때까지 status를 다시 확인한다.

```bash
tm-agent sync status "$PROJECT_ID" "$OPERATION_ID"
tm-agent sync cancel "$PROJECT_ID" "$OPERATION_ID"
tm-agent sync status "$PROJECT_ID" "$OPERATION_ID"
```

backup은 daemon과 app을 정상 종료한 뒤 만든다. 이 runbook은 설치 방식별 stop 명령을 추측하지 않는다. 종료 후에도 관련 process가 DB나 project root를 열고 있으면 복사를 시작하지 않는다.

```bash
mkdir -p "$BACKUP_ROOT"
cp -a "$PROJECT_ROOT" "$BACKUP_ROOT/project-root"
```

SQLite, CAS, sync metadata의 실제 경로는 진단 결과에서 확인한 뒤 각각 별도 이름으로 복사한다. 아래 placeholder를 추측한 default path로 바꾸지 않는다.

```bash
SQLITE_DB='<verified-sqlite-path>'
CAS_ROOT='<verified-cas-root>'
SYNC_STATE_ROOT='<verified-sync-state-root>'

cp -a "$SQLITE_DB" "$BACKUP_ROOT/state.sqlite"
cp -a "$CAS_ROOT" "$BACKUP_ROOT/cas"
cp -a "$SYNC_STATE_ROOT" "$BACKUP_ROOT/sync-state"
```

backup manifest에는 path 대신 run-local label, size, hash, timestamp를 남긴다. 원본 backup은 수정하지 않는다.

## Approve → revoke → DEK rotation

### Approve

pending request를 조회하는 공개 CLI는 아직 없다. 이미 신뢰할 수 있는 local UI가 표시한 sanitized request ID가 있어도 CLI approve는 실행 수단이 아니라 fail-closed 확인 수단이다.

```bash
PAIR_REQUEST_ID='<request-id-from-authenticated-local-ui>'
tm-agent pairing approve "$PROJECT_ID" "$PAIR_REQUEST_ID"
```

현재 기대 결과는 `USER_PRESENCE_REQUIRED`다. 성공으로 바꾸기 위해 daemon socket을 직접 호출하거나 DB row를 추가하지 않는다. 향후 local flow가 연결되면 user-presence 성공, project ID, device identity, roster epoch가 모두 일치할 때만 approve한다.

### Revoke

분실 또는 침해 device를 revoke하기 전에 project를 pause하고 device ID를 두 독립 자료로 대조한다. display name이나 hostname만으로 고르지 않는다.

```bash
DEVICE_ID='<device-id-confirmed-by-two-sources>'
tm-agent pairing revoke "$PROJECT_ID" "$DEVICE_ID"
```

현재 기대 결과도 `USER_PRESENCE_REQUIRED`다. SSH session, CI, remote desktop의 keystroke injection은 local user presence가 아니다. 이 gate를 통과하지 못하면 device는 **revoked가 아니다**.

### DEK rotation

revoke가 인증된 local flow에서 확정된 뒤에만 DEK rotation을 시작한다. 현재는 시작/status CLI가 없으므로 operator가 실행할 명령도 없다. 내부 journal을 직접 UPDATE하거나 Keychain item을 교체하지 않는다.

향후 공개 control plane에서 확인해야 할 observable state는 다음과 같다.

- `prepared`: 새 key가 durable하게 저장됐지만 아직 게시되지 않음.
- `published`: signed rotation control record가 게시됨.
- `activated`: 새 write key가 활성화됨. old-key object read는 아직 필요할 수 있음.
- `ack_wait`: 현재 approved device 전원의 동일 generation ACK를 기다림.
- `retired`: old-key object, inflight transfer, reachable root가 모두 0으로 검증됨.
- `completed`: old key가 삭제됨.

중단 후에는 같은 signed plan과 같은 rotation ID로 journal을 resume해야 한다. 새 rotation을 겹쳐 시작하거나 `ack_wait`를 건너뛰지 않는다. `completed`와 old-key deletion을 공개 status에서 확인하기 전까지 incident를 닫지 않는다.

## Interrupted operation 복구

daemon 재시작 시 `pending`, `running`, `cancel_requested` operation은 `interrupted`로 바뀐다. 기존 operation ID를 성공으로 재사용하지 않는다.

```bash
tm-agent sync status "$PROJECT_ID" "$OPERATION_ID"
```

`interrupted`면 먼저 root identity와 backup을 다시 확인한다. 그 다음 새 request ID로 새 operation을 시작한다.

```bash
tm-agent project status "$PROJECT_ID"
tm-agent project resume "$PROJECT_ID"
tm-agent sync start "$PROJECT_ID" --request-id "$REQUEST_ID"
```

반환된 새 operation ID를 기록하고 terminal state까지 관찰한다.

```bash
NEW_OPERATION_ID='<operation-id-from-sync-start>'
tm-agent sync status "$PROJECT_ID" "$NEW_OPERATION_ID"
```

상태 의미는 다음과 같다.

- `pending`, `running`, `cancel_requested`: 진행 중. 복구 완료가 아님.
- `succeeded`: manifest scan 결과만 성공. receiver data나 DEK rotation 성공의 증거가 아님.
- `failed`: `error_code`를 보존하고 pause로 돌아감.
- `cancelled`: mutation 재개 전 backup과 root identity를 다시 확인함.
- `interrupted`: 새 request ID로 다시 시작하되 반복되면 storage/process 원인을 먼저 해결함.

## Conflict 보존과 수동 resolution

먼저 목록과 원문을 보존한다.

```bash
tm-agent conflict list "$PROJECT_ID"
CONFLICT_ID='<conflict-id-from-conflict-list>'
tm-agent conflict get "$PROJECT_ID" "$CONFLICT_ID"
```

현재 구현에서는 목록이 비어 있고 `get`이 거부된다. 이 상태에서 conflict가 없다고 결론내리지 않는다. apply/reconcile이 block됐는데 durable record를 조회할 수 없으면 project를 pause한 채 escalation한다.

control plane이 durable record를 반환하는 버전에서는 다음을 backup한다.

- conflict ID와 precondition/revision
- base, local, remote content root
- path와 canonical collision 정보
- executable bit, symlink, delete/modify 같은 conflict kind
- 조회 시각과 project/roster epoch

사람이 세 버전을 비교한 뒤 local UI/API가 반환한 **정확한 choice token**만 사용한다. token 이름을 추측하지 않는다.

```bash
CHOICE='<exact-choice-token-returned-by-supported-control-plane>'
tm-agent conflict resolve "$PROJECT_ID" "$CONFLICT_ID" "$CHOICE"
```

stale precondition, missing content root, foreign project/epoch, hash mismatch가 나오면 새 목록을 읽고 처음부터 검토한다. 해결을 강제하기 위해 working tree나 conflict DB를 직접 수정하지 않는다.

## Storage별 복구

### SQLite

항상 종료된 daemon의 backup copy를 검사한다. live DB에 repair SQL을 실행하지 않는다.

```bash
sqlite3 -readonly "$BACKUP_ROOT/state.sqlite" 'PRAGMA quick_check;'
sqlite3 -readonly "$BACKUP_ROOT/state.sqlite" 'PRAGMA integrity_check;'
```

둘 다 정확히 `ok`여야 한다. corrupt DB에서 row를 골라 새 DB로 옮기면 signature, epoch, operation journal의 원자성이 깨질 수 있다. 검증된 whole-file backup으로 rollback하거나, 지원되는 migration/rebuild 도구가 생길 때까지 차단한다.

### CAS

CAS bit flip, missing object, decrypt/hash mismatch는 해당 object만의 문제가 아닐 수 있다. 원본 CAS를 보존하고 object ID, expected/actual digest, 참조 root를 incident에 기록한다. 현재 공개 CAS verify/repair CLI는 없다.

검증된 backup 또는 approved peer에서 같은 content root를 다시 얻을 수 있을 때만 복원한다. 어느 쪽도 없으면 아래 data-loss 승인 절차로 이동한다. 손상 object를 빈 파일로 바꾸거나 index에서 참조만 삭제하지 않는다.

### Git

Git repository라면 backup copy에서 object graph를 먼저 검사한다.

```bash
git -C "$BACKUP_ROOT/project-root" fsck --full
```

검증된 bundle이 있으면 restore 전에 bundle 자체를 검사한다.

```bash
GIT_BUNDLE='<verified-git-bundle-path>'
git bundle verify "$GIT_BUNDLE"
```

missing/corrupt object가 있으면 원본을 덮어쓰지 않는다. 별도 recovery clone에서 trusted remote 또는 verified bundle로 graph를 재구성하고 `git fsck --full` 통과 후 비교한다. force push, history rewrite, reflog expiry는 이 runbook 범위 밖이며 별도 승인 없이는 금지다.

## Data degradation/loss 승인

완전 복원이 불가능하면 자동으로 빈 baseline을 만들지 않는다. 담당자와 data owner가 다음 내용을 사람이 읽을 수 있는 incident record에 승인해야 한다.

- 영향 project와 시간 범위
- missing/corrupt path 및 content root
- SQLite/CAS/Git 검사 결과와 backup hash
- 복구를 시도한 trusted source와 실패 근거
- 보존되는 local/remote/conflict 사본
- 예상되는 기능 저하 또는 영구 loss
- rollback 가능 시점과 중단 조건

승인 전 상태는 `PAUSED / DATA_LOSS_ACK_REQUIRED`로 취급한다. 현재 이 acknowledgement를 저장하는 CLI가 없으므로 ticket 상태를 product state로 가장하지 않는다. 승인 뒤에도 새 baseline 생성은 별도 구현·검증 절차가 있어야 한다.

## SSH-only 운영 제한

SSH에서 허용되는 것은 상태 조회, pause/resume, scan 시작/상태/취소처럼 user-presence를 요구하지 않는 명령뿐이다. remote host의 daemon socket을 쓰는 경우에도 명령은 그 host의 project ID를 대상으로 해야 한다.

SSH-only로 할 수 없는 작업은 다음과 같다.

- device approve/revoke
- recovery export/import
- Keychain recovery secret 접근
- DEK rotation 승인 또는 user-presence 대체
- local UI가 보여 주는 identity/conflict 선택 확인

SSH에서 `USER_PRESENCE_REQUIRED`가 나오면 정상적인 차단이다. socket permission 변경, DB 편집, environment flag로 우회하지 않는다. 현장 사용자가 인증된 local flow를 실행할 수 있을 때까지 project를 pause한다.

## Rollback과 재개 gate

rollback은 원본을 지우고 backup을 덮는 방식으로 시작하지 않는다. 현재 손상본을 두 번째 보존 위치로 이동하고, 검증된 backup을 새 recovery 위치에 복원해 검사한다. SQLite, CAS, Git, project root는 같은 checkpoint 세트여야 한다.

재개 전 아래 조건을 모두 충족한다.

- project ID와 root identity가 backup 전 기록과 일치함.
- SQLite `quick_check`와 `integrity_check`가 `ok`임.
- CAS에서 필요한 모든 reachable content root가 검증됨.
- Git project면 `git fsck --full`이 통과함.
- unresolved conflict의 base/local/remote가 보존됨.
- approve/revoke가 필요했다면 인증된 local flow 결과가 확인됨.
- revoke 뒤 rotation이 필요했다면 공개 status에서 `completed`가 확인됨.
- degradation/loss가 있다면 명시적 승인이 기록됨.

마지막으로 project를 resume하고 새 request ID로 scan을 실행한다.

```bash
tm-agent project resume "$PROJECT_ID"
tm-agent project scan "$PROJECT_ID" --request-id "$REQUEST_ID"
```

반환된 operation을 `sync status`로 확인한다. `succeeded` 뒤에도 conflict, pairing, GC 상태를 다시 기록한다.

```bash
FINAL_OPERATION_ID='<operation-id-from-project-scan>'
tm-agent sync status "$PROJECT_ID" "$FINAL_OPERATION_ID"
tm-agent conflict list "$PROJECT_ID"
tm-agent pairing list "$PROJECT_ID"
tm-agent gc status "$PROJECT_ID"
```

## 관련 설계

- [Mesh project sync protocol](mesh-project-sync-protocol.md)
- [Mesh project sync benchmark](mesh-project-sync-benchmark.md)
