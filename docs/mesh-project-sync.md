# Mesh Project Sync 사용 가이드

현재 구현은 local project 등록과 manifest scan을 제공한다. 실제 peer 간 file 복제, pairing mutation, conflict mutation, GC 실행은 아직 연결되지 않았다. 지원되지 않는 동작은 성공을 가장하지 않고 JSON 상태 또는 stable error code로 닫힌다.

## CLI

모든 명령은 `term-meshd` socket을 사용하며 app focus, window, workspace, pane 선택을 바꾸지 않는다. 아래 `<project-id>`, `<operation-id>`, `<request-id>`, `<device-id>`, `<conflict-id>`는 설명용 placeholder다. 실제 ID나 recovery material을 문서, issue, log에 붙이지 않는다.

Clap global flag인 `--team <TEAM>`은 모든 subcommand 위치에서 parser가 받는다. 일반 team·agent 명령에서는 대상 team 선택에 사용되지만, 이 문서의 `project`, `sync`, `pairing`, `conflict`, `gc` 명령은 daemon-global project registry로 일찍 route되므로 `--team`을 사용하지 않는다. 이 flag로 daemon instance나 project를 선택할 수 없다. Project는 `<project-id>`로, daemon instance는 `TERMMESH_DAEMON_SOCKET` 또는 `TERMMESH_DAEMON_UNIX_PATH` 같은 daemon socket 환경으로 선택한다.

### Project

```bash
tm-agent project add /absolute/path/to/project
tm-agent project list
tm-agent project status <project-id>
tm-agent project pause <project-id>
tm-agent project resume <project-id>
tm-agent project scan <project-id>
tm-agent project scan <project-id> --request-id <request-id>
```

- `add`는 directory를 canonical path로 durable registry에 등록한다.
- `list`는 등록된 project를 path 순서로 반환한다.
- `status`, `pause`, `resume`은 project record와 `paused` 상태를 반환한다.
- `scan`은 durable `manifest_scan` operation을 시작한다. `--request-id`를 생략하면 CLI가 local request ID를 만든다.
- pause 상태는 현재 daemon process memory에만 있다. daemon restart 뒤에는 유지되지 않는다.

Project 응답 형태:

```json
{
  "project_id": "<redacted>",
  "root_path": "/absolute/path/to/project",
  "active_manifest": null,
  "roster_epoch": 0,
  "paused": false
}
```

`project list`는 같은 record를 `projects` array에 넣는다.

### Sync operation

```bash
tm-agent sync start <project-id>
tm-agent sync start <project-id> --peer <peer-id> --request-id <request-id>
tm-agent sync status <project-id> <operation-id>
tm-agent sync cancel <project-id> <operation-id>
```

현재 `sync start`는 manifest scan operation을 시작한다. `--peer`는 parser와 RPC envelope에는 포함되지만 peer transfer를 시작하지 않는다. peer 간 CAS, oplog, Git ref, filesystem mutation은 이 CLI 경로에 아직 연결되지 않았다.

Operation 응답은 JSON이며 주요 field는 다음과 같다.

```json
{
  "operation_id": "<redacted>",
  "request_id": "<redacted>",
  "project_id": "<redacted>",
  "kind": "manifest_scan",
  "root": "/absolute/path/to/project",
  "state": "running",
  "created_at_ms": 0,
  "updated_at_ms": 0,
  "focus_events_emitted": 0
}
```

`state`는 `pending`, `running`, `cancel_requested`, `succeeded`, `failed`, `cancelled`, `interrupted` 중 하나다. 성공한 scan에는 bounded result가 붙는다. 같은 request ID는 같은 project·kind·root에 대해 idempotent하다.

### Pairing과 recovery

```bash
tm-agent pairing list <project-id>
tm-agent pairing approve <project-id> <request-id>
tm-agent pairing revoke <project-id> <device-id>
tm-agent pairing recovery-export <project-id>
tm-agent pairing recovery-import <project-id>
```

현재 `pairing list` 결과는 다음 capability state다.

```json
{
  "project_id": "<redacted>",
  "devices": [],
  "state": "not_configured",
  "user_presence_required": true
}
```

`approve`, `revoke`, `recovery-export`, `recovery-import`는 authenticated local user-presence flow가 연결되기 전까지 `USER_PRESENCE_REQUIRED`로 종료한다. CLI argument로 recovery key, private key, DEK, password, biometric data를 전달하지 않는다.

### Conflict

```bash
tm-agent conflict list <project-id>
tm-agent conflict get <project-id> <conflict-id>
tm-agent conflict resolve <project-id> <conflict-id> <choice>
```

현재 durable conflict store는 control-plane RPC에 연결되지 않았다. `list`는 빈 `conflicts` array를 반환하고 `get`과 `resolve`는 `CONFLICT_NOT_FOUND`로 종료한다. `<choice>`는 현재 free-form parser argument이며 실제 resolution mutation으로 사용되지 않는다.

### GC

```bash
tm-agent gc status <project-id>
```

현재 결과는 실행 가능한 GC가 아니라 capability state다.

```json
{
  "project_id": "<redacted>",
  "state": "idle",
  "eligible": false,
  "retention_days": 90,
  "reason": "gc_coordinator_not_initialized"
}
```

## JSON과 오류 처리

성공하면 CLI는 daemon의 `result` object만 pretty JSON으로 stdout에 출력하고 exit code `0`을 반환한다. Daemon이 반환한 semantic failure는 stderr에 `Error: CODE: message` 형태로 출력되고 non-zero로 종료한다.

Stable `CODE` 계약은 아래 daemon semantic error에만 적용된다. Socket connect, serialize, write, read, parse, empty response, response-too-large 같은 transport/protocol failure는 code 없이 `Error: ...`만 출력될 수 있다. 자동화는 exit code를 먼저 확인하고, 성공 시 stdout JSON shape를 검증하며, 실패 시 optional semantic `CODE`와 code 없는 transport error를 모두 처리해야 한다. Message 전체를 stable API로 비교하지 않는다.

현재 project-sync command에서 사용하는 stable code:

- `INVALID_PARAMS`, `INVALID_PROJECT_ID`, `INVALID_PROJECT_ROOT`: argument 또는 project root가 유효하지 않다.
- `PROJECT_NOT_FOUND`, `PROJECT_PAUSED`, `PROJECT_ROOT_CHANGED`: project lookup 또는 root identity 조건이 맞지 않는다.
- `PROJECT_STATE_ERROR`, `PROJECT_STORAGE_ERROR`, `PROJECT_STORAGE_QUARANTINED`: local state 또는 registry integrity 문제가 있다.
- `OPERATION_ERROR`: operation lookup, transition, persistence 또는 runner가 실패했다.
- `USER_PRESENCE_REQUIRED`: pairing/recovery mutation에 authenticated local approval이 필요하다.
- `CONFLICT_NOT_FOUND`: durable conflict record가 없다.

오류 출력에는 secret이 없어야 한다. telemetry와 UI는 identifier가 필요할 때도 짧은 prefix만 표시한다.

## GUI capability 상태

Settings의 Project Sync panel은 현재 `liveManifestScanOnly` snapshot으로 시작한다. 실제 capability set은 비어 있으므로 다음 항목은 `Unavailable from the current daemon`으로 표시되거나 action이 disabled다.

- project discovery와 자동 registry hydration
- device list와 revoke
- conflict resolution
- protected GC root
- recovery export

초기 snapshot에는 project ID가 없어서 `Scan Manifest`도 disabled다. GUI client에 현재 연결된 operation은 manifest scan의 start, status, cancel, retry뿐이다. CLI에서 project를 등록해도 GUI snapshot을 자동 갱신하는 discovery RPC는 아직 연결되지 않았다. Recovery는 항상 Touch ID 또는 macOS password 같은 user presence가 필요하다고 표시한다.

## Compatibility와 data degradation

기존 peer federation은 SSH 위 terminal protocol이며 project-sync capability가 없다. 이런 peer는 **SSH-only compatibility mode**로 유지된다.

- terminal federation은 계속 동작한다.
- project manifest, oplog, CAS, Git ref mutation은 SSH fallback으로 보내지 않는다.
- SSH bootstrap은 QUIC endpoint를 전달할 수 있지만 sync trust나 device approval을 대신하지 않는다.
- common protocol version이나 capability가 없으면 sync mutation 전에 연결을 거부한다.

지원하는 filesystem 의미는 regular file, directory, symlink, executable bit, package directory다. ACL과 xattr은 현재 범위 밖이다. hardlink와 sparse file은 regular file로 degrade하며 sync metadata에 degradation을 기록하는 계약이다. silent overwrite나 last-writer-wins conflict 소거는 허용하지 않는다.

## 현재 범위 밖

- 중앙 account service와 relay
- SSH를 통한 project data fallback
- CLI `--peer`를 사용한 실제 network replication
- pairing/recovery secret mutation
- durable conflict query와 resolution mutation
- GC coordinator 실행
- ACL, xattr, hardlink identity, sparse extent 보존
- filesystem CAS와 Git object store 사이 dedupe

Protocol과 security invariant는 [mesh-project-sync-protocol.md](design/mesh-project-sync-protocol.md)를 따른다.
