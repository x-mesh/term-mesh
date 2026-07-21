# Changelog

All notable changes to term-mesh are documented here.

## [0.163.0] - 2026-07-21

### Fixed
- **로컬 pane에 붙여넣은 파일을 열 수 없던 문제** — 원격 pane을 하나라도 열어두면, 로컬 pane에 이미지나 파일을 붙여넣어도 원격에만 있는 경로가 대신 들어갔다. 로컬에서 도는 CLI 에이전트에게는 없는 파일이라 붙여넣기가 통째로 무용지물이었다. 이제 어느 pane에 붙여넣는지를 보고 판단하므로, 원격 연결을 열어둔 채로도 로컬 붙여넣기가 그대로 동작한다.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.162.0] - 2026-07-21

### Added
- **터미널에 "맨 아래로" 버튼이 생겼다** — 스크롤을 위로 올려 지난 출력을 보고 있으면 pane 오른쪽 아래에 작은 버튼이 나타난다. 누르면 최신 출력으로 바로 돌아간다. 네 줄 이상 올라갔을 때만 나타나므로 평소에는 화면을 가리지 않고, 한글 입력줄을 열면 그 위로 비켜선다.
- **원격 pane이 끊겨도 보던 내용을 잃지 않는다** — 연결이 잠깐 끊겼다 돌아오면 그동안의 출력을 이어서 받아온다. 호스트가 최근 출력을 보관해 두었다가 재연결 시점부터 빠진 만큼만 다시 보내므로, 화면을 처음부터 다시 그리거나 중간이 빈 채로 남지 않는다.

### Fixed
- **새 터미널이 열리지 않던 문제** — 원격 pane을 쓰다 보면 시스템의 터미널 자원이 조금씩 새어 나가, 결국 term-mesh뿐 아니라 다른 터미널 앱에서도 새 창이 열리지 않는 상태가 됐다. pane을 띄울 때 이전 pane의 자원이 딸려가던 것과, 데몬이 종료될 때 pane들이 회수되지 않고 남던 것을 함께 고쳤다.
- **원격 pane의 입력이 굼뜨던 문제** — 타이핑이 한 박자씩 밀려 도착하던 것을 고쳤다. relay 연결이 작은 조각을 모았다가 보내는 대신 즉시 내보낸다.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.161.0] - 2026-07-20

### Added
- **CLI 에이전트가 훅 하나로 알림을 띄울 수 있다** — Claude·Codex 등 어떤 CLI 에이전트든 훅에서 알림을 올릴 수 있게 됐다. 알림에는 어느 pane에서 왔는지가 담기고, pane 이름도 그 안에서 도는 에이전트 이름을 따라간다. workspace 카드 역시 알림을 띄운 pane의 이름으로 표시되어, 알림만 보고도 어디서 온 것인지 바로 알 수 있다.
- **원격 호스트 알림 설정이 한 번에 끝난다** — 호스트마다 스크립트를 올리고 훅을 엮던 과정을 명령 하나로 대신한다. 호스트 편집기의 Test는 이제 "이 호스트의 에이전트가 실제로 나에게 알림을 보낼 수 있는가"까지 함께 답한다.
- **원격 호스트가 얼마나 바쁜지 타이틀바에서 보인다** — 호스트가 자기 부하를 보고하고, 1·5·15분 로드 애버리지 세 개와 디스크 사용량이 함께 표시된다.
- **Remote Work가 무슨 일을 하고 있는지 말한다** — 터널 연결·해제와 그 사유, 원격 pane 부착·종료, 워크스페이스 미러의 상실과 재연결, 붙여넣은 파일의 전송 크기와 소요 시간, 체크포인트가 실제로 실행한 명령까지 Live Activity에 남는다. 이전에는 실패해도 화면에 아무 흔적이 없어 무엇이 잘못됐는지 알 수 없었다.
- **원격 경로가 다른 저장소 안에 있으면 알려준다** — 프로젝트로 묶으려는 원격 폴더가 이미 다른 Git 저장소에 속해 있을 때 그 사실을 밝힌다.

### Fixed
- **끊긴 SSH 터널이 계속 쌓이던 문제** — 남은 터널을 정리하는 절차가 프로세스 목록을 읽다 멈춰 한 번도 끝까지 돌지 못했다. 그 바람에 종료된 앱이 남긴 SSH 연결이 원격 호스트에 계속 붙어 있었다. 이제 실행할 때마다 정리되고, 무엇을 정리했는지 Live Activity에 남는다.
- **워크스페이스 미러가 "reconnecting…"에서 영영 멈추던 문제** — 호스트가 죽은 게 아니라 응답만 멈춘 경우(노트북 절전, 네트워크 블랙홀) 재연결이 첫 시도에서 물려 재시도도 포기도 하지 않았다. 이제 제한 시간을 두고 다시 시도하며, 시도 상황이 로그에 남는다.
- **커맨드 팔레트가 터미널에 가려지던 문제** — 터미널 위에서 팔레트를 열면 pane 사이 틈에 걸친 부분만 보이고 나머지가 덮이던 것을 고쳤다.
- **브랜치 이름으로 워크스페이스를 찾을 때 순위가 낮던 문제** — 폴더 이름으로 찾을 때와 달리 브랜치 이름 전체로 검색하면 한참 아래에 나오던 것을 같은 기준으로 맞췄다.
- **원격 호스트 수치가 뒤섞여 보이던 문제** — 여러 호스트의 부하 값이 서로 구분되지 않던 것을 고쳤다.
- **호스트가 먼저 보낸 알림이 응답을 깨뜨리던 문제** — 요청에 대한 답을 기다리는 중 호스트가 자발적으로 보낸 메시지가 끼어들면 그 응답이 어긋나던 것을 고쳤다.
- **알림의 출처가 잘못 표시되던 문제** — pane이 자신이 어느 터미널에 붙어 있는지 모르거나, 실행 창의 정체성이 pane에 그대로 넘어가 알림이 엉뚱한 곳에서 온 것처럼 보이던 것을 바로잡았다.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.160.0] - 2026-07-19

### Added
- **Remote Work 패널을 명시적 바인딩 기반으로 개편** — 어떤 로컬 폴더와 어떤 원격 폴더를 짝지을지 직접 골라 등록하고, 등록한 프로젝트 쌍을 대상으로 Prepare/Checkpoint가 동작한다. 패널 상단에 로그 레벨(Info/Debug)과 dry-run 체크박스가 생겨, 실제로 실행하지 않고도 어떤 동작이 일어날지 먼저 확인할 수 있다. 활동 로그는 선택·복사가 가능해졌다.
- **붙여넣기가 원격 pane에 실제 파일을 전달** — 클립보드의 이미지나 파일을 원격 pane에 붙여넣으면 이전에는 로컬 경로 문자열만 전달되어 원격에서 파일을 찾을 수 없었다. 이제 파일 자체가 함께 전송되어 원격에서 바로 열어볼 수 있다.

### Fixed
- **출력이 몰릴 때 원격 pane이 끊기거나 화면이 잘리던 문제** — 무거운 출력이 이어지는 동안 relay pane 연결이 죽거나 내용이 잘려 보이던 현상을 고쳤다.
- **SGR 마우스 버튼·Shift+Tab·kitty 키가 원격에 전달 안 되던 문제** — 특정 마우스 버튼 조합과 일부 특수 키 입력이 원격 호스트로 전달되지 않던 것을 고쳤다.
- **비정상 입력으로 인한 크래시 방지** — 조작된 CSI/kitty 키 시퀀스가 데몬을 크래시시킬 수 있던 취약점을 막았다.
- **pane을 닫을 때 데몬 전체가 멈추던 경우 방지** — 좀처럼 종료되지 않는 프로세스를 강제 종료하는 도중 데몬이 함께 멈춰버릴 수 있던 경합 조건을 없앴다.
- **데몬이 SIGTERM으로 정상 종료되지 않던 문제** — 백그라운드 파일 감시 스레드 때문에 종료 신호를 받고도 프로세스가 남아있던 것을 고쳤다.
- **Shift+PageUp/Down/Home/End 스크롤백 단축키 복구** — 회귀로 동작하지 않던 스크롤백 이동 단축키를 되살렸다.
- **Mac을 호스트로 쓸 때 원격 workspace 삭제·이름변경이 안 되던 문제** — 뷰어 쪽에서는 정상 동작하던 workspace 삭제·이름변경이, Mac이 호스트인 경우에는 조용히 무시되던 것을 고쳤다.
- **호스트 연결이 완전히 끊겼을 때도 미러가 좀비로 남지 않도록** — 탭 제목만 바뀌고 닫히지는 않아 입력도 안 먹던 미러 workspace를 마저 정리했다.
- **SSH 호스트 프로필 중복 저장 방지** — 같은 접속 대상을 가리키는 프로필이 여러 개로 중복 저장되던 것을 정리했다.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.159.0] - 2026-07-17

### Added
- **원격 workspace를 우클릭 한 번으로 현재 workspace의 pane으로** — 사이드바 Peer Hosts의 원격 workspace 항목에 "Open as Pane in Current Workspace" 메뉴가 생겼다. pane이 하나뿐인 workspace는 선택 창 없이 즉시 열리고, 여러 개면 그 workspace의 pane만 추려서 보여준다.
- **원격 surface 선택 창에 workspace 이름 표시** — "Open Surface as Pane…"에서 shell을 고를 때 각 항목에 소속 workspace 이름이 함께 표시되어 원하는 pane을 찾기 쉬워졌다.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.158.0] - 2026-07-17

### Fixed
- **원격에서 삭제된 workspace의 미러가 좀비로 남던 문제 수정** — 호스트에서 workspace를 삭제하면 뷰어에 열려 있던 라이브 미러 workspace가 입력도 안 되고 닫히지도 않는 멈춘 상태로 남던 것을 고쳤다. 이제 삭제 통지를 받으면 미러 workspace가 자동으로 닫히고 알림으로 안내한다.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.157.0] - 2026-07-17

### Added
- **호스트 편집기에서 원격 term-meshd 버전 확인 + 원클릭 업데이트** — Peer Host 편집기의 Test 버튼이 원격 term-meshd 버전을 확인해 최신·업데이트 가능·레거시 상태를 표시하고, 구버전이면 Update 버튼으로 기존 설치 경로를 재사용해 바로 업데이트한다. 업데이트가 진행되는 동안 같은 호스트로의 중복 설치는 차단되고, 실패한 설치는 곧바로 재시도할 수 있다. 이 릴리즈부터 term-meshd 버전이 앱 버전과 동기화되어(`daemon.status`에 노출) 버전 비교가 의미를 갖는다 — 그 이전에 설치된 데몬은 "legacy"로 표시된다.
- **피어 replay 버퍼 크기 설정 가능** — 뷰어가 pane에 붙을 때 재생되는 최근 출력 버퍼가 64 KiB에서 기본 1 MiB로 커졌고, `TERMMESH_PEER_REPLAY_BYTES` 환경 변수 또는 `tm-agent daemon replay-capacity --set 2mb`로 실행 중에도 조정할 수 있다(4 KiB–64 MiB).

### Fixed
- **사이드바에서 편집한 호스트 소켓 경로가 무시되던 문제 수정** — 저장된 호스트의 소켓 경로를 수정해도 연결이 수정 전에 캐시된 경로로 조용히 터널링하던 것을 고쳤다. 비워두면(자동 탐지) 기존처럼 탐지된 경로를 재사용한다.
- **term-meshd가 중지 요청(SIGTERM) 후 종료되지 않던 문제 수정** — 파일 감시 스레드가 프로세스 종료를 막아 서비스 중지·재시작이 영원히 걸리던 것을 고쳤다. 앱 쪽에도 SIGKILL 폴백이 추가되어 구버전 데몬도 확실히 정리된다.
- **라이브 미러 pane에서 대량 출력 시 잘린 화면이 복구되지 않던 문제 수정** — 출력 드롭 감지와 자동 화면 복구가 일반 relay pane에만 적용되고 workspace 라이브 미러 pane에는 빠져 있던 것을 고쳤다.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.156.0] - 2026-07-16

### Fixed
- **피어 릴레이 pane이 출력이 몰릴 때 끊기거나 화면이 깨지던 문제 수정** — 하트비트가 backpressure(응답 지연)를 연결 끊김으로 오판해 pane을 닫아버리던 문제와, 호스트가 밀린 출력을 조용히 버려 화면이 잘려 보이던 문제를 고쳤다. 끊김이 감지되면 자동으로 화면을 다시 그린다.
- **피어 릴레이에서 SGR 마우스 클릭/드래그, Shift+Tab, kitty 키가 무시되던 문제 수정** — 뷰어가 보낸 마우스 이벤트와 일부 키 입력이 인식되지 못하고 버려지던 것을 고쳐, 원격 vim·htop 등에서 마우스 선택·드래그와 역방향 탭 이동이 정상 동작한다.
- **조작된 원격 터미널 시퀀스로 인한 크래시 방지** — 매우 긴 숫자 필드를 가진 CSI/kitty 시퀀스를 원격 호스트가 보내면 정수 오버플로로 앱이 크래시하던 문제를 막았다.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.155.0] - 2026-07-15

### Added
- **원격 호스트에서 여러 워크스페이스 관리** — Linux 피어 호스트 하나에 이름 붙은 워크스페이스를 여러 개 만들고 전환할 수 있다. 사이드바 호스트 옆 + 버튼으로 새 워크스페이스를 만들고, 우클릭으로 이름 변경·삭제가 가능하다(마지막 하나는 삭제할 수 없다). 호스트 이름 옆에 워크스페이스 개수가 표시된다(예: `jw-server (3)`).
- **Peer Host를 리치 프로파일로 저장** — 이름, SSH 대상, 포트, 식별 키, 색상, 아이콘을 사이드바에서 직접 추가·편집·삭제한다. 연결 테스트와 원격 설치를 도와주는 진단(doctor) 기능이 추가됐다.
- **호스트 workspace 라이브 미러** — 사이드바 원격 workspace 우클릭 → "Open as Live Workspace in Main Window"로 호스트의 split 레이아웃을 메인 윈도우 workspace에 실시간 동기화한다. 호스트에서 pane을 나누거나 닫으면 로컬이 즉시 따라오고, 로컬에서 Cmd+D/Cmd+W/divider를 조작하면 호스트로 전달돼 호스트가 레이아웃의 주인으로 유지된다(양방향 수렴). 재접속 시 자동 재동기화.
- **원격 peer surface를 메인 윈도우 pane으로** — 별도 relay 창 없이, 연결 다이얼로그의 "Open as a pane in the current workspace" 체크박스(또는 사이드바 Peer Hosts 우클릭)로 원격 surface가 현재 workspace의 일반 Bonsplit pane으로 열린다. 한 workspace에 로컬 pane과 여러 서버의 원격 pane을 자유롭게 혼합할 수 있고, split/zoom/탭 이동이 로컬 pane과 동일하게 동작한다. 같은 호스트의 pane들은 SSH 터널 하나를 공유하며 마지막 pane을 닫으면 터널도 정리된다.
- **입력 대상 호스트 시각 신호** — 포커스된 pane이 원격이면 타이틀바에 호스트별 색 그라데이션이 켜지고(로컬 포커스로 돌아오면 원상복구), 모든 원격 pane은 상단 컬러 스트립과 탭 제목의 `이름 ⌁ 호스트` 칩으로 상시 식별된다. 원격 끊김 시 pane 자리에 배너가 뜨고 Reconnect 한 번으로 재접속된다.
- **피어 연결 시 원격 소켓 경로 자동 탐지** — 소켓 필드를 비워두면 ssh로 원격 호스트의 기본 위치(`peer.env`의 `TERMMESH_PEER_SOCKET` → `$XDG_RUNTIME_DIR/tm-peer.sock` → `/run/user/<uid>/tm-peer.sock` → `/tmp/term-mesh-peer-<uid>/peer.sock`)를 순서대로 확인해 첫 번째 살아있는 소켓을 자동으로 사용한다. Linux 설치기 기본 구성이면 SSH target만 입력하면 된다.
- **사이드바 레이아웃 상태 유지** — 사이드바 너비와 섹션·호스트 접힘 상태가 앱을 재시작해도 유지된다.

### Changed
- **Peer 관련 진입점이 사이드바 중심으로 재편** — "Remote Hosts"가 "Peer Hosts"로 이름이 바뀌고, 흩어져 있던 연결 다이얼로그 대신 사이드바에서 호스트를 관리·연결한다. 피어 워크스페이스는 사이드바와 pane 상단 스트립이 같은 호스트 색상 그라데이션으로 표시돼 어느 워크스페이스가 원격인지 한눈에 구분된다.
- **"Open as Snapshot Workspace" 제거** — 한 번만 복제되던 스냅샷 모드가 라이브 미러와 혼동을 줘서 제거됐다. 실시간으로 동기화되는 Live Mirror만 남는다.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

### Added
- **호스트 workspace 라이브 미러** — 사이드바 원격 workspace 우클릭 → "Open as Live Workspace in Main Window"로 호스트의 split 레이아웃을 메인 윈도우 workspace에 실시간 동기화한다. 호스트에서 pane을 나누거나 닫으면 로컬이 즉시 따라오고, 로컬에서 Cmd+D/Cmd+W/divider를 조작하면 호스트로 전달돼 호스트가 레이아웃의 주인으로 유지된다(양방향 수렴). 재접속 시 자동 재동기화. 한 번만 복제하는 기존 방식은 "Open as Snapshot Workspace"로 남아 있다.
- **원격 peer surface를 메인 윈도우 pane으로** — 별도 relay 창 없이, 연결 다이얼로그의 "Open as a pane in the current workspace" 체크박스(또는 사이드바 Remote Hosts 우클릭)로 원격 surface가 현재 workspace의 일반 Bonsplit pane으로 열린다. 한 workspace에 로컬 pane과 여러 서버의 원격 pane을 자유롭게 혼합할 수 있고, split/zoom/탭 이동이 로컬 pane과 동일하게 동작한다. 같은 호스트의 pane들은 SSH 터널 하나를 공유하며 마지막 pane을 닫으면 터널도 정리된다.
- **입력 대상 호스트 시각 신호** — 포커스된 pane이 원격이면 타이틀바에 호스트별 색 그라데이션이 켜지고(로컬 포커스로 돌아오면 원상복구), 모든 원격 pane은 상단 컬러 스트립과 탭 제목의 `이름 ⌁ 호스트` 칩으로 상시 식별된다. 원격 끊김 시 pane 자리에 배너가 뜨고 Reconnect 한 번으로 재접속된다.
- **피어 연결 시 원격 소켓 경로 자동 탐지** — SSH 연결 다이얼로그에서 소켓 필드를 비워두면 ssh로 원격 호스트의 기본 위치(`peer.env`의 `TERMMESH_PEER_SOCKET` → `$XDG_RUNTIME_DIR/tm-peer.sock` → `/run/user/<uid>/tm-peer.sock` → `/tmp/term-mesh-peer-<uid>/peer.sock`)를 순서대로 확인해 첫 번째 살아있는 소켓을 자동으로 사용한다. Linux 설치기 기본 구성이면 SSH target만 입력하면 된다.
- **메뉴바 "Connect to Recent Peer" 서브메뉴** — 최근 접속한 피어 호스트(8개)를 메뉴바에서 원클릭으로 재접속. 다이얼로그를 거치지 않는다.

## [0.154.0] - 2026-07-14

### Added
- **Linux 서버를 GUI 없이 tmux 대체 호스트로 쓸 수 있게 됨** — `term-meshd` 데몬만 설치하면 셸이 SSH 접속과 무관하게 계속 살아있고, split/close/tab/divider 같은 pane 조작이 macOS 앱에서 그대로 동작한다. 설치는 한 줄 스크립트로 systemd 사용자 서비스로 등록되며 로그아웃·재부팅에도 유지된다.
- **원격 피어 호스트의 대시보드를 SSH 터널로 그대로 볼 수 있음** — 피어 연결 시 같은 SSH 프로세스가 원격 호스트의 대시보드(포트 9876)도 함께 로컬 `http://127.0.0.1:19876`으로 전달한다. 추가 네트워크 노출 없이 여러 호스트를 동시에 연결해도 각각 다른 로컬 포트로 열린다.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.153.0] - 2026-07-13

### Fixed
- **피어 뷰어에서 원격 전체화면 앱(Claude Code, vim, htop)이 마우스 휠로 스크롤되지 않던 문제 수정** — 뷰어가 보낸 휠 이벤트(SGR 마우스 리포트)를 호스트 입력 경로가 조용히 버리고 있었다. 이제 호스트 pane의 실제 마우스 모드에 맞춰 다시 전달하며, 스크롤 속도도 로컬과 1:1로 맞는다.
- **headless pane(fleet/에이전트 워커)에 피어로 붙었을 때 마우스 휠이 동작하지 않던 문제 수정** — 접속 전에 켜진 마우스 리포팅 모드를 데몬이 추적했다가 접속 시점에 재생한다. 일반 셸 pane에는 아무것도 재생하지 않아 기존 동작이 그대로 유지된다.

> 두 수정 모두 **접속 대상 호스트**가 이 버전 이상일 때 적용된다. 와이어 포맷은 바뀌지 않아 구버전 피어와도 그대로 연결된다.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.152.0] - 2026-07-10

### Changed
- **원격 피어 워크스페이스를 열 때 pane마다 따로 연결하지 않고 하나의 연결을 공유하며 pane들을 동시에 붙인다** — 워크스페이스가 더 빨리 열리고, 연결 수와 하트비트가 pane 수에 비례해 늘어나지 않는다.
- **원격 피어의 터미널 출력을 짧은 창(6ms)으로 묶어 전송한다** — 출력이 쏟아질 때 전송 횟수가 줄어든다. 첫 출력은 즉시 보내므로 타이핑 반응성은 그대로다.
- **릴레이 헬퍼가 유휴 상태에서 초당 10번 깨어나던 동작을 없앴다** — 이제 실제로 보낼 데이터가 있을 때만 깨어난다.
- **가려진 피어 릴레이 창의 GPU 메모리를 회수한다** — 창이 다른 창에 덮이면 렌더러 자원을 반납했다가 다시 보일 때 복구한다.

### Fixed
- **피어 연결이 끊겼을 때 "재연결 중" 안내가 30초 뒤에야 뜨던 문제 수정** — 첫 하트비트 누락(약 10초)에 바로 표시하고, 조용히 회복되면 안내를 정리한다.
- **다른 뷰어가 이미 보고 있는 pane에 붙을 때 색상과 스타일이 사라지던 문제 수정** — 화면을 일반 텍스트로 다시 그리지 않고 원본 출력을 그대로 재생한다. 다만 아무도 보고 있지 않은 pane에 처음 붙는 경우는 여전히 텍스트 스냅샷이며, 후속 릴리즈에서 개선할 예정이다.

> 출력 코얼레싱과 색상 보존은 **접속 대상 호스트**가 이 버전 이상일 때 적용된다. 와이어 포맷은 바뀌지 않아 구버전 피어와도 그대로 연결된다.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.151.0] - 2026-06-30

### Added
- **피어 릴레이 연결이 끊겨도 창이 바로 닫히지 않고 Close 버튼이 있는 안내 오버레이를 표시** — 원격 호스트 연결이 끊기면 창이 자동으로 사라지는 대신 끊김 상태를 보여주고 직접 닫을 수 있게 했다.
- **같은 피어 호스트로의 중복 연결 방지** — 이미 연결된 호스트로 다시 연결을 시도하면 차단한다.

### Changed
- **피어 전송에 연결/읽기 타임아웃 추가** — 응답이 없거나 도달할 수 없는 호스트에서 무기한 멈추지 않고 빠르게 실패한다.
- **피어 메뉴에서 긴 호스트명과 작업 경로를 잘라 표시** — 메뉴가 과도하게 늘어나지 않도록 했다.

### Fixed
- **clean 종료(goodbye) 후 피어 릴레이가 약 30초간 멈춰 있던 문제 수정** — 양방향 펌프가 즉시 정리된다.
- **응답 없는 피어와 연결을 끊을 때 메인 스레드가 멈출 수 있던 문제 수정**.
- **릴레이 종료 콜백이 세션당 2~3회 중복 실행되던 문제 수정** — 이제 정확히 한 번만 호출된다.
- **시그널로 중단된(EINTR) 릴레이 입출력에서 가짜 끊김이 발생하던 문제 수정** — 죽은 writer로 프레임이 조용히 유실되던 문제도 함께 고쳤다.
- **데몬이 빠른 연속 리사이즈를 합쳐 처리(논블로킹 SIGWINCH)** — 리사이즈가 몰릴 때의 불안정을 줄였다.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.150.0] - 2026-06-15

### Fixed
- **장시간 사용 시 메모리(GPU)가 수십 GB까지 쌓이던 문제** — 다른 워크스페이스로 가려져 보이지 않는 터미널이 Metal 렌더러의 GPU 리소스(스왑 체인·IOSurface, 표면당 약 40MB)를 계속 붙들고 있어, 워크스페이스·탭을 많이 열고 오래 쓰면 메모리가 수십 GB까지 누적되던 문제를 수정했다. 이제 일정 시간 보이지 않은 터미널은 GPU 리소스를 자동으로 반납하고(터미널 내용·세션은 그대로 유지), 다시 보일 때 복원한다.

### Changed
- **pane 전체화면(zoom) 처리 일원화** — 탭바 zoom을 delegate 경로로 통일하고 내부 panel ID 매핑을 바로잡아, zoom 토글 시 대상 pane이 잘못 처리되던 경계 케이스를 줄였다.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.149.0] - 2026-06-11

### Fixed
- **pane 전체화면(zoom) 시 터미널이 좌상단에 이전 크기로 고착되던 문제** — zoom 토글이 내부 ID 불일치로 zoom 대상 pane의 터미널까지 숨겼다가 되살리는 과정에서 race에 지면, 화면이 좌상단에 구 크기로 박히고 입력도 이전 폭으로 줄바꿈되던 문제를 수정했다. zoom 직후 geometry 재동기화 안전망도 추가했다.
- **탭 우클릭 메뉴의 "Zoom Pane"이 동작하지 않던 문제** — 메뉴 선택이 무시되던 것을 수정했고, 탭의 zoom 해제 버튼도 동일 경로로 통일해 해제 후 다른 pane이 검게 남을 수 있던 가능성을 차단했다.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.148.0] - 2026-06-10

### Changed
- **내장 터미널 엔진(ghostty)을 최신 upstream 리비전으로 업데이트** — fork를 상위 ghostty(fork/main)의 최신 상태로 올려, 그동안 누적된 상위 터미널 엔진의 개선과 버그 수정을 반영했다.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.147.0] - 2026-06-09

### Added
- **에이전트 watch의 유령(phantom) watcher 자동 진단·복구 — `tm-agent watch doctor`** — watch에 watcher가 등록은 됐지만 실제 pane이 만들어지지 않은 "유령" 상태를 감지해 자동으로 다시 만든다. 이전에는 이 상태에서 watch를 켜면 매 점검이 `workspace_missing`으로 실패하기만 했다. 살아있는 watcher는 건드리지 않고, 팀 종류에 맞게 안전하게 복구한다.

### Fixed
- **peer 창에서 긴 텍스트를 붙여넣으면 깨지거나 이후 입력이 멈추던 문제** — 붙여넣기 시작 프레임에서 멀티바이트(한글·이모지) 글자의 끝 바이트가 내부 전송 경계에 걸치면 중복 전송돼 글자가 깨지고, 붙여넣기 종료 시퀀스가 불완전하게 끝나면 타이머 재전송이 무한 반복돼 이후 키 입력이 삼켜지던(먹통) 문제를 함께 수정했다.
- **New Agent Team에서 직접 만든 custom 팀 프리셋의 편집이 저장되지 않던 문제** — custom 프리셋에 에이전트를 추가하거나 모델을 바꿔도 저장되지 않고, 앱을 다시 켜면 프리셋 자체가 사라지던 문제. 이제 custom 프리셋 편집이 즉시 저장되고, 이름만 붙여둔 빈 프리셋도 다음 실행까지 보존된다.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.146.0] - 2026-06-04

### Fixed
- **peer 창에서 긴 텍스트를 붙여넣을 때 간헐적으로 입력이 먹통이 되던 문제** — 붙여넣기 끝을 알리는 제어 시퀀스가 내부 전송 경계에 정확히 걸치면 붙여넣기가 닫히지 않아 이후 키 입력이 삼켜지던 문제. 쪼개진 제어 시퀀스를 다음 프레임에서 이어붙여 항상 정상적으로 닫히게 했다.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.145.0] - 2026-06-03

### Fixed
- **peer 창에서 한글 등 멀티바이트 텍스트를 붙여넣으면 깨지던 문제** — 다른 호스트의 pane에 한글·이모지 등을 복붙할 때 "결과"가 "ê²°ê³¼"처럼 깨지던 문제. 붙여넣기가 내부 전송 프레임 경계에서 쪼개질 때 불완전한 UTF-8 바이트를 다음 프레임으로 이어붙이도록 해 글자가 온전히 전달된다.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.144.0] - 2026-06-03

### Fixed
- **원격 peer 화면(pane)이 비어 보이던 문제** — 다른 호스트의 작업 공간을 peer로 접속해 볼 때, 처음 연결한 직후나 창 크기를 바꿀 때 pane이 검게 비어 보이던 문제(v0.139.0 회귀). 리사이즈 시 화면을 지운 뒤 호스트의 현재 화면을 다시 보내도록 해, 일반 쉘이든 vim·htop 같은 전체화면 앱이든 내용이 바로 복원된다.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.143.0] - 2026-06-02

### Fixed
- **에이전트 watch가 점검 결과 제출에 실패하지 않음** — GUI watch의 watcher(claude/codex)가 drift 점검 결과(verdict)를 제출할 때 heredoc 본문이 누락되거나 "no active task"로 거부돼 여러 번 재시도하던 문제. `tm-agent reply`가 이제 stdin(heredoc/pipe) 본문도 읽고, 일회성 watcher는 닫을 task가 없어도 정상 종료하며, 일시적인 메시지 전송 실패에도 작업 완료를 건너뛰지 않는다.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.142.0] - 2026-06-02

### Fixed
- **여러 term-mesh가 동시에 떠 있을 때 `tm-agent` 명령이 엉뚱한 인스턴스에 붙던 문제** — production 앱과 `--tag`/STAGING 빌드를 함께 실행하면, 일반 pane에서 실행한 `tm-agent attach`/`read`/`collect`가 자기 앱의 daemon이 아니라 다른 인스턴스의 daemon에 연결돼 `not_in_workspace`로 실패하던 문제. 각 pane이 자신이 속한 앱의 control socket을 우선 사용하도록 해 각 명령이 올바른 daemon으로 라우팅된다.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.141.0] - 2026-06-02

### Added
- **`/watch test` — watch 파이프라인 즉시 검증** — `/watch on` 후 첫 자율 점검(최대 interval, 기본 300s)을 기다리지 않고 한 번의 drift 점검을 즉시 강제 실행해 watcher가 실제로 동작하는지(spawn → verdict → 기록) 확인한다.
- **GUI watcher pane 실행 모델** — GUI 팀에서 자율 watch가 숨은 headless one-shot 대신 떠 있는 watcher pane(claude/codex)을 recycle하고 review를 보내 verdict를 받는다. watcher의 추론 과정이 pane에 그대로 보여 신뢰·교정이 쉬워졌다. 순수 headless 팀은 종전 one-shot을 유지한다.

### Fixed
- **codex 등 사용자 설치 CLI가 watcher로 정상 실행** — GUI 앱이 띄운 daemon이 launchd 최소 PATH를 상속해 `~/.local/bin/codex` 같은 사용자 설치 CLI를 못 찾아 watcher spawn이 매번 실패하던 문제. daemon이 표준 사용자 bin 경로(`~/.local/bin`, `~/.cargo/bin`, Homebrew 등)를 복구하도록 수정.
- **`watch status`가 실패한 점검을 드러냄** — watcher가 매 tick 실패하는데도 status가 정상으로 보이던 문제. 성공 시각(`last_ok`)과 시도 시각을 분리하고 `health`/`error`를 노출해, 계속 실패하는 watch가 즉시 드러난다.
- **codex watcher verdict 회수** — codex headless watcher가 spawn은 되지만 출력을 못 읽어 매번 timeout하던 문제. codex 프로토콜 어댑터를 추가해 verdict를 정상 회수한다.
- **워크스페이스-로컬 팀(`ws-…`)의 에이전트 명령** — `attach`로 만든 `ws-…` 팀에서 `read`/`collect`/`inbox`/`send`가 기본 팀(`live-team`)으로 잘못 해석되던 문제. team 해석에 `--team` 옵션과 workspace fallback을 추가해 해결.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.140.0] - 2026-06-02

유지보수 릴리즈 — 사용자 영향 변경 없음. leader-as-watch-target watch fallback의 daemon e2e 회귀 테스트를 추가했다(내부 변경).

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.139.0] - 2026-06-02

### Added
- **`/watch`가 worker 없는 팀에서 leader를 감시** — `attach`로 만든 1인 팀처럼 감시할 worker가 없을 때, `/watch`가 leader pane 자체를 감시 대상으로 삼는다. `--target leader`로 명시하거나, `--target all`인데 worker가 0이면 자동으로 leader로 전환된다(worker가 한 명이라도 있으면 종전대로 worker만 감시). leader 대상일 때는 진행 중인 미완 출력을 drift로 오판하지 않고, drift 보고에 `[self-watch]` 표식을 단다.

### Fixed
- **원격 viewer에서 TUI 리사이즈 시 화면 깨짐 수정** — 원격 peer로 접속해 보는 화면에서 창 크기를 바꿀 때 vim·htop 같은 절대 커서 TUI의 출력이 깨지거나 중복되던 문제. 리사이즈 시 stale한 그리드를 지우고 다시 그리도록 해 해결했다.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.138.0] - 2026-06-01

### Added
- **`/watch` 마법사에서 watcher CLI 선택** — `/watch`를 처음 설정할 때 watcher를 실행할 CLI(claude/codex/gemini/kiro, 기본 claude)를 고를 수 있다. 선택한 CLI가 watcher pane과 자율 헤드리스 점검 양쪽에 모두 적용된다.
- **Codex pane에서 네이티브 슬래시 커맨드** — 앱이 `/team`, `/tm`, `/tm-op`, `/watch` 등 팀 커맨드의 Codex 프롬프트를 `~/.codex/prompts/`에 자동 설치한다. 이제 Codex 리더·에이전트 pane에서도 네이티브 `/<command>` 형태로 팀 커맨드를 쓸 수 있다.

### Fixed
- **`/watch` 첫 설정이 더 견고해짐** — `/watch`를 처음 켤 때 워크스페이스에 단일 단계로 watcher를 붙이도록 바꿔, 간헐적으로 발생하던 watch 설정 실패를 없앴다.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.137.0] - 2026-06-01

### Added
- **에이전트 팀: 사이드바 행에서 에이전트 리사이클** — 사이드바의 에이전트 행 우클릭 메뉴에 "Recycle Agent" / "Recycle Agent (Force)"가 추가됐다. 기존엔 에이전트 터미널 화면 우클릭에만 있어 찾기 어려웠다.

### Fixed
- **Homebrew 자동 업데이트가 한 번에 최신 버전으로** — 여러 버전이 밀려 있을 때(예: 0.135 → 0.137) 중간 버전(0.136)을 거쳐 여러 번 업데이트해야 하던 문제. 이제 업데이트 전에 tap을 갱신해 단일 업데이트로 곧장 최신 버전까지 올라간다. 메뉴바 펄(pill)에 표시되는 "최신 버전"도 stale한 중간 버전 대신 실제 최신 버전을 반영한다.
- **`tm-agent watch status`가 활성 watch를 표시** — watch를 켜도 `tm-agent watch status`가 항상 "No watches configured"로 표시되던 문제. CLI가 JSON-RPC 응답 envelope를 잘못 파싱한 것으로, daemon과 실제 watch 동작은 정상이었다. 이제 활성 watch 상태를 올바로 보여준다.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.136.0] - 2026-06-01

### Added
- **원격 peer 접속 시 호스트의 모든 창에 접속** — connect-to-peer로 원격 호스트에 연결하면 이제 활성 창 하나가 아니라 **호스트의 모든 term-mesh 창의 모든 workspace**가 보인다. workspace 선택 창과 사이드바는 창이 여러 개일 때 **창별 섹션**으로 그룹핑되고(같은 제목의 탭도 어느 창인지 구분됨), 창이 하나면 기존 평면 목록을 그대로 유지한다. (이 기능은 vim ESC 수정과 마찬가지로 **원격 호스트** 측 빌드가 업데이트되어야 적용된다.)
- **에이전트 팀: 작업 풀 자동 소진 (auto-claim-next)** — 작업을 마친 유휴 에이전트가 리더의 추가 지시 없이 미할당 작업 풀에서 다음 작업을 스스로 가져온다. `tm-agent task create`(미할당)로 작업을 쌓고 `tm-agent claim`을 한 번만 보내면, 에이전트들이 풀을 알아서 비운다. 지정한 에이전트에게 직접 위임한 작업(`delegate`/`fan-out`)에는 영향을 주지 않는다.
- **에이전트 팀: 작업 의존성 지정 (`tm-agent task create --depends-on a,b`)** — 작업 간 선후 관계를 지정하면, 선행 작업이 모두 완료될 때까지 해당 작업은 claim되지 않는다(우선순위가 더 높아도 게이트가 우선).
- **에이전트 팀: 결정적 pane 지정 전송 (`tm-agent send/delegate --panel`)** — 같은 이름의 에이전트 pane이 여러 개일 때 특정 pane을 명시해 전송할 수 있고, fan-out도 각 대상을 서로 다른 pane에 결정적으로 분배한다.

### Fixed
- **에이전트 팀: 수동 `tm-agent claim` 복구** — `tm-agent claim`(및 work-pool 패턴 `broadcast 'tm-agent claim'`)이 내부 라우팅 누락으로 `unknown_method`를 반환하며 동작하지 않던 문제. 이제 정상적으로 작업 풀에서 작업을 가져온다.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.135.0] - 2026-05-31

### Fixed
- **원격 peer 연결에서 vim 등 TUI 입력이 먹통 되던 문제 수정** — connect-to-peer로 접속한 원격 호스트에서 vim을 편집할 때, 화살표 이동은 되지만 ESC를 누른 뒤 `:wq!` 같은 문자열을 입력하면 키가 누락되거나 입력이 중간에 멈추던 버그. 호스트 측 키 재인코딩 파서(`sendPeerInputBytes` / `trailingIncompleteEscape`)가 "ESC + 일반 문자"(예: ESC 다음 `:`)를 프레임 경계에서 잘린 미완성 escape 시퀀스로 오판해, 입력을 32바이트가 쌓일 때까지 버퍼에 가둬두고 한꺼번에 쏟아내던 것이 원인이었다. 이제 ESC 다음에 escape 시퀀스를 시작할 수 없는 바이트가 오면 즉시 전달하고, 뒤따르는 입력이 없는 단독 ESC는 짧은 타임아웃 후 flush한다. (이 수정은 vim이 실행되는 **원격 호스트** 측 빌드가 업데이트되어야 적용된다.)

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.134.0] - 2026-05-30

### Added
- **Watch oversight GUI** — autonomous drift watch is now fully controllable from the app, not just the CLI. A new **Configure Watch** sheet (Enabled toggle, target All/Specific, stance Critic/Advisor/Pair, spec presets or path/inline, interval presets, CLI/model pickers, cost preview, live status panel) is reachable from the sidebar team row context menu, an agent row "Watch This Agent", and the command palette (Configure Watch / Stop Watch / Run Watch Check Now). The sidebar team row also shows a live watch chip (target · worker count · stance · next-tick countdown).
- **Watch all-workers fan-out** — `--target all` now actually watches every worker on a team (one bounded check per worker each tick) instead of being a no-op. Same-name workers are de-duplicated with a warning surfaced in the watch status and sidebar chip.
- **Run Watch Check Now** — trigger an immediate watch sweep without waiting for the next interval, from the sidebar menu or command palette.
- **Watch spec presets** — pick a ready-made oversight spec (`executor`, `reviewer`, `security`, `general`) via `preset:<name>` instead of writing one each time; custom path/inline specs still supported.
- **Recycle All Agents** — recycle every worker on a team in one action from the sidebar team row context menu or command palette, with a confirmation step; agents with active work are skipped.
- **Team creation pair options** — the "Pair with" companion watcher can now use the same CLI as the leader (e.g. a Claude leader paired with a Claude watcher), with selectable stance and an Auto-watch toggle that starts watching as soon as the team is created.
- **Browser Cmd-[ / Cmd-] navigation** — back/forward in browser panes via keyboard.

### Changed
- **Agent teams now use Opus 4.8 (1M context)** — the `opus` model option resolves to Opus 4.8, replacing the previous Opus 4.7 / `opus-1m` (4.7 1M) entries, which are normalized automatically so existing team and profile settings keep working.

### Fixed
- **Remote hosts no longer pile up duplicates in the sidebar** — connecting to the same SSH peer host from a new window kept adding a fresh entry every time, because each SSH tunnel used a unique socket path. Hosts are now de-duplicated by a stable SSH identity, and reconnecting refreshes the workspace list against the new tunnel so opening a workspace after reconnect no longer fails.
- **Auto-recycle task counter** — GUI-team agents now reset their completed-task count consistently on recycle (matching headless agents), so count-based auto-recycle cadence stays accurate.
- **Browser webview focus** — focus handling hardened to avoid losing keyboard focus during navigation.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.133.0] - 2026-05-28

### Added
- **Headless agent auto-recycle (Phase 1–3)** — long-running headless team agents (claude, codex, kiro, gemini) can now be restarted on a configurable cadence so their context windows stay fresh without manual intervention. Configure via `tm-agent recycle <agent>` for an immediate guarded restart, `--auto-recycle N` / `--auto-recycle-per-agent name:N,name:N` on `tm-agent create` / `add` for cadences, Settings → Auto-recycle for the team-wide default, and the right-click context menu or Team menu-bar entry for ad-hoc recycles. SQLite persistence keeps each agent's `completed_task_count` and cadence across daemon restarts. ([#57](https://github.com/x-mesh/term-mesh/pull/57))
- **tm-agent wait push + auto-watch** — `tm-agent wait` now subscribes to a real-time event stream from the daemon (`events.subscribe`) with a 200ms inner loop and deadline-decay quiet-stream cadence, so leaders wake on task completion in milliseconds instead of waiting for the next poll tick. Polling fallback retained for older daemons. The `auto-watch` hook fires after any agent add (helper gates internally), and `result_path` propagates end-to-end so leaders can open `FULL_REPORT` without socket truncation. ([#59](https://github.com/x-mesh/term-mesh/pull/59))
- **AutoReplyDetector v2** — header detection now uses a sliding window (capacity 60) with a partial-commit fallback gated on STATUS-field presence and a 5s hard cap, so paste-race scenarios that previously dropped the reply now commit reliably. New `AutoReplyDetectorTests` covers the FIX C regression scenarios. ([#59](https://github.com/x-mesh/term-mesh/pull/59))

### Fixed
- **Tagged debug bundles can no longer steal the production term-mesh socket** — `./scripts/reload.sh --tag <tag>` builds now derive the socket path from their bundle identifier (`/tmp/term-mesh-<bundleid>.sock`) instead of falling back to the shared `/tmp/term-mesh.sock`. Tagged bundles also ignore `TERMMESH_SOCKET_PATH` env overrides so a stray env var in one window can't redirect a tagged build at the prod socket and kill the running production app. ([#55](https://github.com/x-mesh/term-mesh/pull/55))
- **term-meshd connection lifecycle stability** — three daemon-side fixes squashed: (1) completed tokio connection tasks are now drained from the join set on every accept iteration so long-running term-meshd RSS no longer climbs unbounded, (2) `events.subscribe` subscribers that close their end of the stream are noticed immediately via EOF instead of waiting for the next event, (3) headless agent child processes that exited naturally (CLI quit, `tm-agent destroy`) are now reaped at every RPC entrypoint so no more `<defunct>` zombies. ([#56](https://github.com/x-mesh/term-mesh/pull/56))
- **AutoReplyEmit false-drop on vim/htop output** — anchor field scans to the latest STATUS block so repeating headers in editors and TUIs no longer match the wrong frame and drop a completed reply. ([#59](https://github.com/x-mesh/term-mesh/pull/59))
- **tm-agent paste-delivery / delegate-fallback wedge** — failed paste delivery and the legacy 2-RPC delegate fallback path now auto-block the task instead of leaving it `IN_PROGRESS` indefinitely. ([#59](https://github.com/x-mesh/term-mesh/pull/59))
- **BrewSelfUpdater stale running-binary detection** — periodic update poll now re-checks the running binary version so a tap-side update no longer requires a full app restart to notice. ([#59](https://github.com/x-mesh/term-mesh/pull/59))
- **Slash command descriptions in Claude Code now show the human-readable heading** (e.g. `/watch — Stateless Drift Oversight`) instead of the internal `<!-- term-mesh-managed: ... -->` marker comment. The managed marker is now inserted on line 2 of bundled command files so the picker reads line 1 as the description.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.132.0] - 2026-05-27

### Fixed
- `tm-agent` now reports `{"code":"no_app","message":"no active term-mesh app..."}` instead of a raw JSON parse error when the control socket returns nothing (app not running, socket reset, or early disconnect).
- Critical memory leak when destroying the last team workspace in a window — `TabManager.closeWorkspace` previously skipped all panel cleanup if the workspace was the only tab. TerminalPanel + TerminalSurface + Ghostty render state remained alive forever; reported up to 40–80GB after long sessions with repeated team create/destroy. Cleanup now runs unconditionally and the last tab is replaced by a fresh blank workspace.
- `AutoReplyPoller.forget(panelId:)` is now called on all panel close paths (`closeWorkspace` and `didCloseTab` non-detach) to release per-panel state (lastScrollbackText buffers, detector instances).
- AutoReplyPoller hang on main thread — increased poll interval from 0.4s to 1.0s to stay under the 5000ms ANR threshold when running multiple agent teams (Sentry TERM-MESH-2R, -2Q, -2P, -2N, -2M, -2K, -2J, -2H, -2G, -2F, -1D).
- AutoReplyPoller main-thread block (Phase 2) — moved `ghostty_surface_read_text` off the main thread. `tick()` now acquires `SurfaceReadLease` tokens on MainActor then fans out all terminal scrollback reads to a background `userInitiated` queue; only detector state updates and event emission run back on main. Eliminates the O(N×M) synchronous read loop that caused the Sentry hangs when multiple agent teams were active simultaneously.
- **tapHubs 메모리 누수** — peer-federation 세션이 SSH 단절·relay crash 등 비정상 종료로 끝날 때 `PtyTapHub.surfaceRef` 강참조가 남아 TerminalSurface(10–30MB)가 해제되지 않던 문제. 패널이 닫힐 때 `PeerHostCoordinator.invalidateTapHub` 를 호출해 hub를 즉시 shutdown하고 강참조를 nil로 해제. `TabManager.closeWorkspace`, `Workspace+BonsplitDelegate.didCloseTab`, `didClosePane` 세 경로 모두 처리(`didClosePane` 경로는 이번 패치로 추가).
- **AutoReplyPoller `lastScrollbackText` 무제한 증가** — 장시간 에이전트 팀 운용 시 scrollback 전체가 per-panel 버퍼에 계속 쌓이며 세션 1시간 이후 수백 MB까지 성장하던 문제. scrollback 저장 시 최근 2MB 꼬리만 보존하도록 캡 적용(`lastScrollbackCapBytes = 2 MB`). delta 감지는 `previous` 전체를 역방향 탐색(A 경로)해 vim/htop의 반복 STATUS 헤더 때문에 256자 anchor가 delta 안에서 재매칭되던 오탐(false drop)을 제거. 롤백 완전 회전 시에는 256자 anchor 폴백(B 경로) 사용.
- **단일 패널 Bonsplit 닫기(didClosePane) 경로의 cleanup 누락** — Bonsplit에서 패널을 닫을 때 `splitTabBar(_:didClosePane:)` 경로가 `AutoReplyPoller`, `PeerHostCoordinator.invalidateTapHub`, `TerminalController.v2CleanupSurface` 호출을 누락해 per-panel 상태와 PtyTapHub 강참조가 그대로 남아있던 문제. `didCloseTab` 비-분리 경로 및 `TabManager.closeWorkspace`의 동일 cleanup 스택을 `didClosePane`에도 적용.
- **peer-relay 미인식 CSI/OSC/SS3 시퀀스 전달 버그 재발** — 이전에 DROP으로 수정했던 경로(mouse reports, OSC color queries 등 unrecognized CSI)가 pair WIP 커밋에서 `sendPeerKeyEvent(text: ESC…)` 경로로 복귀해 원격 TUI 화면 깨짐이 재발. DROP 동작 복원. bracketed-paste 본문은 `peerPendingPasteBody` 경로로 처리되므로 영향 없음.

## [0.130.0] - 2026-05-25

### Added
- **`/watch`, `/tm-bench` slash command가 Claude·Codex 리더 모두에서 동작** — 이전에는 Claude 리더에만 등록되던 `/watch`(drift 감시 토글·점검)와 `/tm-bench`(에이전트 팀 통신 벤치마크)가 Codex IME 별칭 맵에도 등록되어 동일하게 호출 가능. 커맨드 번들 로직을 `scripts/copy-claude-commands.sh` 한 곳으로 통합해 빌드 시 중복 등록과 누락 모두 해소.

### Fixed
- **connect-to-peer 원격 pane에서 paste가 깨지던 문제 일괄 해소** — bracketed-paste 마커가 ESC와 본문이 분리되어 전송되며 (1) 첫 paste 시 `[200~text[201~`가 literal로 노출되고, (2) vim insert mode + 멀티라인 paste 시 본문이 invisible 바이트로 들어가 빈 줄만 추가되며, (3) 본문 첫 몇 글자(`⏺` 등 multibyte)가 소실되던 문제. peer-relay가 ESC+CSI 시퀀스를 단일 text payload로 묶어 전달하고, `\e[200~…\e[201~` 마커를 stripped 본문으로 ghostty 표준 paste API에 전달하도록 변경. claude·codex CLI·vim 모두 정상 paste. **연결 대상(원격) 피어도 이 버전 이상이어야 호스트 측 수정이 적용**된다.
- **제어 소켓 `/tmp/term-mesh.sock`이 외부 unlink로 사라져도 자동 복구** — 외부 정리 도구나 부분적 cleanup race로 socket 파일이 unlink되면 listener FD는 살아 있는데 client `connect()`는 path lookup으로 ENOENT를 받아 `term-mesh` CLI·Claude Code stop hook·외부 자동화가 모두 `Socket not found at /tmp/term-mesh.sock`으로 실패하던 orphan listener 문제. 앱이 2초 주기로 socket path 존재 여부를 점검해 사라지면 자동으로 listener를 재bind한다. 앱 재시작 없이도 짧은 지연 후 stop hook이 다시 동작.
- **Peer-federation 장시간 운영 시 fd 누수와 동시 연결 한계 회피** — peer-federation 연결을 반복 사용할 때 누적되던 file descriptor 누수를 막고, 프로세스 NOFILE 한계를 끌어올려 다수의 동시 원격 워크스페이스 연결에서 fd 고갈로 인한 산발적 실패를 예방.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.129.0] - 2026-05-22

### Added
- **Watcher — 에이전트 drift 감시(페어 프로그래밍)** — 매번 새 컨텍스트로 동작하는 watcher가 spec과 대상 에이전트의 최근 작업을 대조해 **execution drift**(작업을 잘못 수행 — 오류 무시·스코프 이탈·잘못된 파일 수정)와 **direction drift**(애초에 잘못된 작업 수행)를 잡아 리더에게 보고한다. 장시간 에이전트 세션이 조용히 이탈하는 문제를 사람이 일일이 지켜보지 않아도 잡아낸다.
  - 신규 `watcher` 에이전트 role + `/watch review|on|off|status` 명령. `/watch review`는 즉시 단발 점검, `/watch on`은 데몬이 주기적으로 자율 점검(켜고/끄는 토글로 비용 통제).
  - `tm-agent create --spec <텍스트|@경로>`로 watcher에 점검 기준(spec)을 주입(watcher에만 적용). `tm-agent watch on/off/status`로 자율 감시를 토글·상태 확인.
  - drift 발견 이력은 `.xm/watch/board.jsonl`에 누적되고 `/watch status`로 이번 세션 drift 횟수를 확인. 감시 결과는 리더에게만 보고하며 코드를 자동 수정하지 않는다(항상 사람 승인).

### Changed
- **Peer-relay 워크스페이스 분할의 최소 패널 크기 보장** — peer-relay 워크스페이스 창에서 디바이더를 드래그해 패널을 지나치게 작게 줄이거나 접어버릴 수 없도록 최소 패널 크기(100pt, 컨테이너 절반 상한)를 적용. 패널이 사실상 사라져 내용을 못 보던 문제 해소.

### Fixed
- **connect-to-peer(원격 워크스페이스) 창에서 shift+enter가 줄바꿈 대신 입력을 바로 제출하던 문제** — 원격에 연결한 창에서 Claude·Codex 등 멀티라인 입력창에 shift+enter로 줄바꿈을 넣으려 해도 입력이 즉시 제출되던 문제를 수정. peer-relay가 shift+enter를 LF로 전달하면 호스트가 이를 일반 Return으로 재생하던 것이 원인이었고, 이제 Shift+Return으로 재생해 호스트가 줄바꿈으로 처리한다. 호스트 측 동작이므로 **연결 대상(원격) 피어도 이 버전 이상이어야 적용**된다.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.128.0] - 2026-05-20

### Changed
- 내부 유지보수 릴리즈 — 저장소 슬러그 정정 등 내부 정비. 사용자 화면에 보이는 변경 없음.

## [0.127.0] - 2026-05-20

### Fixed
- **pane을 닫을 때 발생하던 use-after-free 크래시** — pane이 닫힐 때 `pty_data_callback`을 동기적으로 정리하지 않아, 이미 해제된 pane을 가리키는 콜백이 호출되며 일어나던 use-after-free 크래시를 수정. 분할 패널을 자주 닫는 환경에서 간헐적으로 앱이 죽던 문제 해소.
- **장시간 실행 시 메모리가 계속 늘어나던 누수** — 데몬의 per-session 캐시와 usage-dedup 캐시가 상한 없이 무한히 커지던 문제를 수정. 오래 켜둘수록 메모리 사용량이 계속 증가하던 누수 해소.
- **터미널 텍스트 처리 메모리 누수** — ghostty `free_text` ABI 불일치로 텍스트 버퍼가 해제되지 않던 메모리 누수를 수정.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.126.0] - 2026-05-18

### Changed
- **`/tm` 기본 동작이 v1 동일 instruction fan-out으로 복귀** — Step 1.5 자동 분해(T1-T8 template matching)는 이제 `--decompose` opt-in 플래그가 있을 때만 실행. 이전엔 자동 분해가 기본이었는데 단순 fan-out에서도 leader가 매번 template 매칭·dispatch plan 생성을 거쳐 응답이 느리던 문제 해소. `--no-decompose`는 새 기본값과 동일한 no-op 별칭으로 유지.
- **`/tm` slash command 컨텍스트 크기 ~37% 감소** — T1-T8 템플릿 라이브러리, fallback policy, worked examples를 `tm-decompose-templates.md`로 분리. 기본 `/tm` 호출에서는 로드하지 않고 `--decompose` 명시 시에만 leader가 참조. 매 호출마다 leader가 따라가야 할 본문이 733줄에서 461줄로 줄어 응답 지연 감소.

### Fixed
- **`tm-agent collect --headers`가 한 줄짜리 5필드 STATUS 헤더를 잘못 파싱해 FILES/VERIFY/NEXT/FULL_REPORT 정보 손실되던 문제** — codex agent 등이 `STATUS: DONE FILES: none VERIFY: ... NEXT: ... FULL_REPORT: ...`를 한 줄로 출력하면 line-based parser가 첫 KEY만 잡고 나머지 4필드를 `n/a`로 떨어뜨리던 silent data loss. `split_inline_headers` normalize 단계 추가로 ` KEY:` 경계마다 줄바꿈을 삽입해 multi-line/single-line 모두 일관되게 파싱. body 본문의 `Run:` 같은 자유 콜론은 영향 없음.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.125.0] - 2026-05-18

### Fixed
- **첫 agent spawn 시 init prompt가 중간에 잘려서 들어가던 paste truncation 문제** — Claude TUI의 stdin reader loop이 banner 출력 시작 후 1.5초 이상 늦게 활성화되어 그 사이 paste한 byte가 silent drop되던 race. ghostty `pty_data_callback`을 TUI readiness proxy로 활용해 첫 paste 전에 `age ≥ 1500ms AND bytes ≥ 500` 조건을 자동으로 기다린다. 빠른 TUI는 ~1s, 느리면 자동으로 더 대기. 매번 같은 byte 위치에서 잘리던 deterministic 패턴 해소.
- **paste→Enter race** — 긴 paste(2KB+ agent init prompt)에서 paste 중간에 Enter가 들어가 부분만 submit되던 race. `asyncTeamSend`가 ack을 paste dispatch 직후가 아니라 `finalizePaste` callback 시점에 보내도록 변경. `ghostty_surface_text`도 256-char chunk + 2ms yield로 호출해 IO thread가 매 chunk 후 drain 보장.
- **`tm-agent wait --mode report`이 부분 fan-out에서 영원히 timeout되던 문제** — fallback path `team.result.status`가 팀 전체 agent를 count해서 6명 팀에 3명만 delegate하면 영원히 `all_done=false`. `agentFilter`/`activeOnly` 옵션 추가로 wait이 active task 있는 agent만 카운트.

### Added
- **Agent auto-reply detector** — agent CLI(Claude/Codex)가 응답에 STATUS 5-line header 텍스트만 출력하고 `tm-agent reply` shell command를 안 부르면 task가 영원히 `assigned`로 stuck되던 문제 해소. headless agent는 daemon PTY reader에서, GUI agent는 ghostty scrollback polling으로 5라인 헤더(`STATUS: ... FILES: ... VERIFY: ... NEXT: ... FULL_REPORT: ...`)를 자동 감지해 `team.report` + `team.task.update`를 leader 대신 호출. 500ms idle debounce + 5s hard cap + per-task content_hash dedup. `TERMMESH_AUTO_REPLY=off`로 끌 수 있음.

### Changed
- **Agent init prompt 강조 메시지 강화** — `[REQUIRED FINAL STEP — you MUST run this shell command]` 블록을 prompt 최상단으로 이동 + literal command block + "printing the header in your response is NOT enough" 경고. agent가 reply shell command 호출 누락하는 빈도를 prompt-side에서도 줄임 (detector는 safety net).

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.124.0] - 2026-05-18

### Fixed
- **Smart Preset Balanced가 사용자 추가 에이전트를 덮어쓰던 문제** — Balanced 프리셋 적용 시 원래 프리셋 구성으로 행이 재생성되어 사용자가 직접 추가한 에이전트가 사라지던 문제. 이제 현재 에이전트 목록은 보존하고 각 role에 권장 모델만 적용한다.
- **Pane-mode 팀 Resume 가용성 확장** — leader 또는 에이전트 중 하나라도 Claude session id가 캡처된 archive는 Resume 후보로 노출. 이전에는 leader session id가 없으면 Resume 버튼이 비활성화되어 복구 가능한 archive조차 휴지통밖에 누를 수 없었다.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.123.0] - 2026-05-18

### Added
- **Agent 사이드바 새 visual cue — `★` (active) / `◯` (assigned) / `⏳` (assigned + stale) / `✓` (completed) / `✗` (blocked/failed) / `🔍` (review_ready)** — `tm-agent task list` / `tm-agent inbox` 출력이 raw JSON dump에서 한 줄 표 포맷으로 전환. 파이프/자동화는 `--json` 옵트인으로 기존 동작 유지.
- **`tm-agent task current` 신규 서브커맨드** — 호출자의 현재 active task를 한 줄로 즉시 확인.
- **Agent 좀비 task 자동 정리** — agent가 `tm-agent reply`를 빼먹고 idle로 돌아가도 daemon이 3~6분 안에 해당 task를 자동으로 `blocked`로 전이해 다음 라운드 inbox 오염을 차단. 부팅 시에도 1회 sweep으로 직전 run의 좀비 정리.

### Fixed
- **Agent reply 누락으로 인한 좀비 task 누적** — Sonnet 4.6 agent가 작업을 마치고도 reply를 안 보내고 idle로 복귀하면 task가 `assigned`로 영구 잔존하던 문제. daemon이 `Assigned→Blocked` 자동 전이 + `task_assign` 중복 in_progress 가드 + `compute_agent_anomalies`에 `assigned_stale` branch 추가로 lifecycle을 강제. 사이드바 active_task_id도 task가 terminal 상태가 되면 즉시 클리어.
- **`tm-agent reply`가 stale task에 잘못 매칭되던 문제** — 동일 assignee에 다수 `in_progress` 후보가 있을 때 가장 오래된 stale task를 닫던 버그. 이제 `is_stale=false` 우선 + `created_at desc` 정렬로 정확한 active task를 선택. 후보가 다수면 stderr 경고 + `--task-id` opt-in.
- **`tm-agent reply` 실패 silent fail** — active task 없을 때 stderr warning만 띄우고 exit 0이던 동작을 `code: "no_active_task"` JSON error + exit 2로 강화.

### Internal
- 8개 role runbook (`.agent-runbooks/{explorer,executor,reviewer,backend,frontend,architect,api,syseng}.md`)에 reply-first invariant reminder 추가
- `.agent-runbooks/_common.md` 신설 — 모든 role에 적용되는 task lifecycle 규약(P0)
- `scripts/cleanup-stale-tasks.sh` — 부팅 sweep 누락 시 backstop으로 사용 가능한 운영 스크립트 (기본 `--dry-run`)

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.122.0] - 2026-05-18

### Fixed
- **사이드바 update pill이 항상 *가장 최신* 버전 표시** — 이전엔 사용자 로컬 brew tap 클론이 stale이면 한 단계 옛 버전만 보여서 latest까지 도달하려면 update를 여러 번 해야 했다. 이제 boot 시점과 매 시간 tap refresh 직후에 outdated check를 자동 chain해 pill이 항상 truly-latest 버전을 가리킨다.
- **Resumable Teams 좀비 archive 제거** — destroyed로 표시되지만 휴지통만 누를 수 있고 Resume 버튼은 비활성화된 좀비 entry가 쌓이던 문제. `archive_pane` RPC가 매번 새 UUID를 발급해 중복 archive가 양산되던 것을 idempotent(replace-in-place)로 정정. pane 팀 종료 시 실제 Claude session id를 FSEventStream으로 캡처해 archive에 함께 저장하므로 다음 launch에서 Resume 버튼이 정상적으로 활성화된다. 부팅 시 session id가 빠진 기존 좀비 archive는 자동 GC.
- **Gemini runbook 경로 복원** — 0.121.0 이후 daemon이 Gemini runbook을 잘못된 경로에서 찾던 문제. 기존 `$HOME/.agents/skills` 경로로 복원.
- **머지 중복 broadcaster 제거** — origin/main merge 후 broadcaster가 중복 등록되어 동일 이벤트를 두 번 처리하던 문제 수정.

## [0.121.0] - 2026-05-18

### Added
- **Gemini CLI 에이전트 지원** — New Agent Team에서 Gemini CLI 기반 에이전트를 추가할 수 있음. 팀 생성 시 Gemini 에이전트가 올바른 경로(`~/.agents/skills/`)로 runbook을 읽어 실행.
- **에이전트 사이드바 실시간 토큰 사용량** — Claude(JSONL FSEvents) / Codex(rollout JSONL) 에이전트의 input·output 토큰을 사이드바에서 현재 세션 기준으로 실시간 표시. leader 토큰 사용량도 팀 확장 행에 표시.
- **pane별 세션 바인딩** — 프로세스 시작 시간(`proc_start_unix`) 기준으로 pane과 agent 세션을 1:1 매핑해 동시 spawn 시에도 토큰 귀속이 정확.
- **Team Creation Smart Preset 추가/삭제 UI** — 팀 생성 그리드에서 프리셋을 직접 추가·삭제 가능.
- **진행 중 태스크 스피너** — 사이드바의 `in_progress` 태스크에 스피너 인디케이터 표시.

### Fixed
- **Opus 1M 리더/에이전트가 뜨지 않는 버그** — `claude-opus-4-7[1m]`의 `[1m]`이 zsh에서 glob 패턴으로 해석되어 커맨드 실행이 실패하던 문제 수정. `--model` 인자를 single-quote로 보호.
- **Return키가 IME 조합 해제 시 삼켜지는 버그** — IME 조합을 커밋 없이 취소(Return)할 때 `composing=true` 플래그가 잘못 설정되어 `\r`이 Ghostty에 전달되지 않던 문제 수정.
- **`delegate`/`send` 후 Return키 재시도 누락** — Path C(텍스트 전달 실패)에서 Return키 재시도가 항상 수행되도록 수정.
- **시스템 sleep/wake 후 에이전트 pane 검은 화면** — wake 이벤트를 병합·지연 처리하고 모든 에이전트 surface를 강제 재드로우.
- **팀 생성 실패 시 리더 모델 선택이 초기화되는 버그** — `createTeam`이 성공한 경우에만 AppStorage에 저장하도록 수정.
- **Team Preset 그리드 중복/빈 항목** — Smart Preset 그리드에서 중복 항목과 방치된 빈 행 제거.
- **사이드바 토큰 카운터가 누적값 표시** — 현재 세션의 토큰만 표시하도록 수정.
- **Codex 토큰 input/output 분리 오류** — rollout JSONL 파싱을 수정해 input·output 토큰을 올바르게 분리.
- **에이전트 결과 파일 동시 쓰기 시 손상** — 원자적 쓰기(임시 파일 → rename)와 고정 경로(`<task_id>.md`)로 전환.
- **동시 pane spawn 시 세션 바인딩 오류** — 같은 초에 생성된 pane들을 PID tiebreaker로 구분.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.120.0] - 2026-05-17

### Added
- **Claude leader/agent에 opus 1M context 모델 선택지** — New Agent Team 다이얼로그의 leader / bulk / per-agent 모델 picker에 `opus (1M context)`가 추가됨. 선택 시 내부적으로 `--model claude-opus-4-7[1m]`가 전달되어 1M 토큰 컨텍스트 변형으로 실행. 마지막 선택값은 AppStorage에 영구 저장되어 다음 다이얼로그부터 기본 선택.
- **`/tm` 슬래시 커맨드 자동 설치** — 앱이 첫 실행되면 `~/.claude/commands/tm.md`를 번들에서 자동으로 install. 이전 버전은 `team`·`team-up`·`tm-op`·`tm-bench`만 install 됐다.

### Changed
- **기존 사용자의 슬래시 커맨드 일회성 마이그레이션** — `team.md` / `tm.md` / `team-up.md` / `tm-op.md` / `tm-bench.md` 5개는 term-mesh가 소유권을 갖는 managed 이름으로 지정. 이미 같은 이름의 마커 없는 파일(직접 복사·심볼릭 링크·구버전 잔여물 등)이 있어도 자동으로 `<name>.bak-yyyyMMdd-HHmmss`로 백업한 뒤 번들 버전을 install. 첫 launch 시 일회성으로만 수행되며, 그 외 사용자 커스텀 파일은 그대로 건드리지 않는다.
- **모델 picker 빈 선택 방지** — leader / bulk / per-agent 모델 picker가 AppStorage에 저장된 모델이 현재 CLI의 목록에 없을 때(예: codex로 바꾼 뒤 claude로 돌아옴) selectbox가 잠깐 비어 보이던 문제를 self-healing 바인딩으로 차단. 잘못된 값은 fallback으로 즉시 정상화된다.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.119.0] - 2026-05-17

### Added
- **CLI Profiles** — 여러 개의 named CLI 프로파일(path + extraArgs + env + modelOverride)을 저장하고 메뉴바 / Settings에서 즉시 전환. 같은 CLI(claude / codex / kiro / gemini)라도 모델·인수·환경변수가 다른 여러 구성을 만들어 두고 한 번의 클릭으로 갈아탈 수 있다.
- **Settings → CLI Paths: Recent/Detected dropdown** — 경로 입력 필드에 자동 감지된 경로와 최근 사용 경로를 드롭다운으로 표시.
- **CLI Profile 자동 마이그레이션** — 기존 `cliPath.<cli>` 값이 시작 시 자동으로 "Default" 프로파일로 변환. 구버전 빌드 호환을 위해 dual-write 유지.
- **메뉴바 › CLI Profile 서브메뉴** — CLI별 프로파일 목록을 라디오 항목으로 표시하며 즉시 전환 가능. "Apply to Active Pane (Restart)"로 현재 pane을 새 프로파일로 hard restart.
- **Pane mode 팀 archive & resume** — 사용자가 split으로 직접 띄운 agent 팀(pane mode)의 leader / agent 구성, 작업 디렉토리, claude session id를 워크스페이스 종료(Cmd+Q) / destroy 시 자동으로 archive. 다음 실행 때 New Agent Team 다이얼로그의 Resume picker에서 leader session id와 마지막 메시지를 보고 한 번에 복원되며, agent들은 이전 대화 컨텍스트를 그대로 이어간다 (leader는 항상 새 세션으로 시작해 stale id 회피).
- **Resume picker — archive 삭제** — 더 이상 필요 없는 pane 팀 archive를 picker에서 바로 삭제.
- **`/team` 슬래시 커맨드 — lifecycle 전용으로 분리** — 팀 *구성 편집* 책임만 가지며 `add` / `remove` / `swap` / `ensure` / `status` / `destroy` / `edit` 서브커맨드를 제공. 인자 없이 호출하면 인터랙티브 편집기. GUI 팀에서도 동작 (`tm-agent add`/`remove` RPC 신설). `/tm`(dispatch)과 양방향으로 안내된다.
- **`/tm --ensure <roles>` 옵션** — fan-out 직전에 누락된 role을 자동으로 보강한 뒤 instruction을 전파. 팀 구성 변경은 명시적 opt-in일 때만 일어난다.
- **`/tm` 인터랙티브 메뉴** — 인자 없이 호출 시 instruction 입력 + 옵션 선택 UI를 표시.
- **`/tm` 이질적 fan-out 합성** — reviewer / planner / executor 등 서로 다른 역할의 결과를 3-tier read rules로 자동 종합하고 `[결론] / [충돌] / [다음]` 3줄로 수렴. instruction을 자동 분해해 역할별로 분배하며, `--no-decompose`로 분해를 비활성화할 수 있다.

### Changed
- **`/team` ↔ `/tm` 책임 분리** — 이전엔 `/team`이 lifecycle + dispatch를 둘 다 처리해 의도가 섞였다. 이제 `/team` = 구성 편집, `/tm` = 실행으로 단일 책임을 가진다. 기존 호출 패턴은 호환되며 인터랙티브 메뉴와 안내 메시지가 신구 사용자를 모두 이끈다.
- **Pane mode 팀 leader 재개 정책** — resume 시 leader는 항상 새 세션으로 시작 (이전엔 stale session id로 인해 첫 메시지가 무시되는 경우가 있었다). agent들은 자신의 worktree에 기록된 실제 claude session id로 정확히 재개.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.118.0] - 2026-05-15

### Changed
- **컨트롤 소켓 상태 버튼 위치 조정** — 0.117.0에서 추가된 소켓 상태/복구 버튼을 타이틀바 정보 행(세션 시간·버전 옆)으로 옮김. 이전 위치에서 윈도우 제목 및 버전 텍스트와 겹치던 문제를 해소.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.117.0] - 2026-05-15

### Added
- **컨트롤 소켓 상태 표시 + 자가 복구** — 타이틀바에 컨트롤 소켓 health를 보여주는 버튼이 추가됨(녹색=정상 / 주황=half-dead / 회색=중단). 앱은 떠 있는데 소켓이 "Connection refused"로 응답하지 않던 half-dead 상태를 감지하면, 버튼 클릭만으로 앱 재시작 없이 리스너를 그 자리에서 복구한다. accept 루프가 비정상 종료(연속 50회 실패)하면 누수된 fd를 닫고 리스너를 자동으로 재시작.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.116.0] - 2026-05-15

### Fixed
- **IME 입력 박스 높이 확대** — 입력 박스가 너무 낮아 `@`(에이전트 멘션) / `/`(슬래시 커맨드) 자동완성 팝업이 잘리던 문제. 기본 높이를 2배로 늘려 팝업이 온전히 보이며, 이전에 직접 키워 둔 사용자 설정은 그대로 유지.
- **에이전트에 보낸 Return이 씹히던 문제** — 리더가 `tm-agent send`/`delegate`로 에이전트 pane에 빠르게 연속 전송할 때 paste와 Return이 겹쳐 매 두 번째 입력이 통째로 누락되던 버그. pane별로 전송을 직렬화하고 Return 재시도 간격을 조정해 해소.
- **에이전트/패널을 닫아도 자식 CLI 프로세스가 고아로 남던 문제** — claude / codex / gemini 등 에이전트 CLI 프로세스가 패널 종료 후에도 백그라운드에 살아 있던 문제를 수정.
- **에이전트 종료 시 관련 없는 프로세스가 함께 종료되던 문제** — 에이전트를 종료할 때 프로세스 그룹 처리가 부정확해 같은 부모를 공유하는 다른 프로세스까지 영향을 받을 수 있던 문제를 수정.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.115.0] - 2026-05-14

### Added
- **`/tm` 슬래시 커맨드 — 팀 일괄 dispatch** — 한 줄 instruction을 활성 팀의 모든 idle agent에게 동시에 위임하고 결과를 `[결론] / [충돌] / [다음]` 3줄로 수렴. `/tm-op`(10+ 전략)의 경량 진입점으로, 라운드·전략 선택 없이 "지금 전원 동원" 한 가지만 한다. `/team`과 양방향으로 연결되어 New 사용자가 `/tm`만 알아도 `/team`의 low-level 명령을 자연스럽게 발견.
- **Gemini CLI agent 지원** — 팀 구성 시 claude / codex / kiro에 더해 gemini agent를 띄울 수 있음.
- **New Agent Team 다이얼로그 — Smart Preset 추가/삭제** — preset 목록 끝의 점선 "+" 카드로 새 preset을 그 자리에서 즉석 생성(이름 입력 후 자동 저장), 카드에 hover하면 "×"로 삭제. built-in preset은 🔒로 보호되어 삭제 대신 Reset만 가능. preset이 하나도 없을 땐 "+" 카드가 전체 폭으로 확장.
- **Pane mode agent 사이드바 토큰 표시** — 이전엔 headless agent만 토큰 카운터가 보였으나, 이제 사용자가 직접 split에 띄운 Claude / Codex agent도 input·output 토큰이 사이드바에 표시됨. 같은 작업 디렉토리를 공유하는 여러 agent도 프로세스 시작 시각으로 각자의 세션을 구분해 정확히 귀속. Codex는 rollout 로그를 직접 파싱해 input / output / cached를 정확히 분리.
- **작업 중 agent 스피너** — task가 `in_progress`인 agent row에 정적 dot 대신 애니메이션 스피너가 표시되어 지금 일하는 agent를 한눈에 구분.

### Fixed
- **Enter 씹힘 — 두 개의 별개 경로 모두 수정** — (1) IME 조립 중 Enter를 누르면 Ghostty의 composing 가드가 `\r`을 삼키던 문제, (2) 리더가 `tm-agent send`/`delegate`로 pane에 메시지를 주입할 때 paste watchdog 타임아웃 후 Return 재시도가 통째로 skip되던 문제. 두 경로 다 막혀 텍스트는 들어가는데 실행이 안 되던 증상을 해소.
- **슬립에서 깨어난 후 검은 pane** — wake 이벤트를 합쳐 agent surface를 다시 그리도록 수정.
- **New Agent Team — leader 모델 선택이 저장되지 않던 문제** — leader 모델 / 모드가 팀 생성 성공 직후에만 저장되도록 변경. 이전 세션의 다른 CLI 모델이 남아 모델 셀렉트 박스가 빈 상태로 보이던 문제도 함께 해소. 미완성·중복 Smart Preset은 실행 시 자동 정리.
- **사이드바 토큰 카운터가 누적 합계를 표시하던 문제** — 같은 작업 디렉토리의 과거 세션 전체가 합산돼 수치가 부풀던 문제를 현재 세션만 표시하도록 수정. Codex 토큰은 전체 합(total)을 output 칸에 잘못 넣던 것을 input / output / cached로 정확히 분리.

### Changed
- **사이드바 토큰 라벨 간결화** — `13 in · 1.1k out` → `13↑ 1.1k↓`로 축약, 상세는 hover tooltip으로 이동.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.114.0] - 2026-05-13

### Added
- **Smart Preset v3 — built-in 위에 사용자 편집 inline 적용** — Smart preset 카드를 그 자리에서 직접 편집할 수 있게 됨. 변경한 카드에는 `(Modified)` 배지가 뜨고, 클릭하면 built-in 기본값으로 즉시 복원. 새 Preview Panel로 카드를 클릭하면 agent / model / instructions를 미리 볼 수 있고, 마지막에 사용한 preset의 override가 다음 New Agent Team 다이얼로그에서 자동 복원됨.
- **Headless agent 모드 + 세션 재개 (Phase 2)** — daemon이 GUI pane 없이 agent CLI를 subprocess로 관리. 워크스페이스 닫고 다시 열어도 진행 중이던 세션이 그대로 재개되며, 사이드바에 agent별 input/output 토큰 카운터가 1초 간격으로 갱신.
- **사이드바 agent 가시화 (Phase 2.5)** — agent별 상태 dot (running / idle / parked / error), 인라인 펼침으로 토큰 사용량과 status label, per-agent 우클릭 메뉴, footer에 재개 가능한 세션 카운터.
- **`tm-agent restart <agent>` 명령** — agent CLI가 응답 없을 때 재시작. Soft mode (⌥-click)는 Ctrl-C + launch command 재타이핑, Hard mode (기본 click)는 패널을 닫고 같은 자리에 새 split으로 재spawn하여 stuck 상태 회복.
- **Agent pane 헤더에 ↻ 재시작 버튼** — agent 터미널 pane 우상단에 항상 표시. agent pane에만 노출되어 browser / debug pane은 영향 없음.
- **`tm-agent doctor` 명령 (초기 골격)** — 환경 변수, daemon socket, 살아있는 process를 한 번에 진단 (WIP).
- **xm/op override 파일 안내 토스트** — `~/.xm/op/agent-role-presets-override.json`이 외부 도구(xm:op) 전용임을 첫 실행 시 1회 안내.

### Changed
- **Smart Preset — v2 Force-Copy 흐름 폐기, v3 inline 편집 채택** — v2의 "Customize → 새 custom 복제" 흐름이 발견성 결여로 사용자 의도와 불일치. v3에서는 built-in 카드를 그 자리에서 편집하고 디스크에 override만 저장, 다음 사용 시 `(Modified)` 표시.
- **Agent pane ↻ 버튼 default 동작** — 단순 click이 hard restart (close + respawn)로 변경됨. soft mode (text retype만)는 ⌥-click. 사용자가 ↻를 누르는 거의 모든 상황 = stuck 회복이므로 default를 더 강력한 동작으로.

### Fixed
- **`tm-agent send` Return이 silent drop되던 race condition (Enter swallow)** — agent 패널에 텍스트는 들어가는데 Enter가 적용 안 되던 문제. surface attach 재구성 중 `ghostty_surface_key`가 false 반환하면 Rust CLI retry가 활성화되도록 RPC 응답에 `delivery_failed` 전파. KeyDeliveryToken + attachGeneration으로 stale callback 무효화, 10ms~3s exponential backoff retry. broadcast 후 응답 누락이 거의 사라짐.
- **Hard restart 시 pane 위치 보존** — agent pane을 닫고 새로 spawn할 때 원래 자리가 아닌 다른 곳에 떨어지던 결함. `paneLayoutSnapshot`의 walk를 pre-order에서 post-order로 변경하여 root가 아닌 immediate parent split을 정확히 매치하도록 fix. nested split layout에서도 정확한 슬롯에 재spawn.
- **Headless agent 사이드바 토큰 표시 안 되던 결함** — Swift이 headless member에 placeholder UUID를 panelId로 sync해서 daemon이 pane mode agent로 잘못 분류하던 결함. `AgentMember.panelId`를 `Optional<UUID>`로 변경 + JSON 직렬화 시 nil이면 omit하여 daemon이 진짜 headless로 인식하도록 fix. stream-json 토큰 캐치 + 1초 coalesced broadcast 정상 동작.
- **Smart Preset various** — schema:1 → schema:2 자동 migration, custom store eager seed (첫 실행 시 빈 파일 생성), 마지막 선택한 preset의 override 자동 복원, `(Modified)` 배지 클릭 영역 확장, leader_mode resolution 순위 (pinned preset → AppStorage fallback).
- **Restart 시 풀 spawn invocation 복원** — agent를 처음 spawn할 때 사용한 model flag, system prompt, MCP config, worktree cd 등을 보존했다가 restart 시 그대로 재실행. 기존엔 `claude` / `codex` 같은 binary 이름만 retype해서 system prompt가 누락되던 문제 회복.

### Removed
- **v2 Force-Copy "Customize" 버튼** — Smart Preset v3 inline edit 채택으로 UI에서 제거 (코드는 보존, 추후 "Save as new" 액션으로 부활 가능).

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.113.0] - 2026-05-13

### Fixed
- **Team leader pane no longer launches as a blank shell when the CLI binary lives outside `~/.local/bin`** — `claude`, `codex`, and `gemini` are now also auto-detected at `/opt/homebrew/bin`, `/usr/local/bin`, `~/.npm-global/bin`, `~/.volta/bin`, and `/opt/homebrew/opt/node/bin`. Previously a Homebrew/npm/Volta install would silently fall back to a bare shell with the title still showing "👑 Leader (Claude)".
- **Missing CLI binary is now surfaced as a visible error in the leader pane** instead of silently dropping into a blank shell. The pane prints a red `term-mesh: '<cli>' binary not found …` message pointing to Settings → Agent Teams → CLI Paths.
- **Korean IME no longer doubles the leading jamo of the next syllable** in raw-mode TUI panes such as `codex` and `kiro-cli`. When the IME committed the previous syllable and started a new marked syllable in the same `keyDown` (e.g. typing "정진우"), the physical key was replayed on top of the new preedit, producing "정ㅈ진ㅇ우 나ㅡ는 뭔ㄱ가". Term-mesh now skips the physical-key replay whenever a CJK IME starts a fresh composition right after committing prior text.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.112.0] - 2026-05-12

### Fixed
- **CJK IME no longer doubles punctuation when used as a commit trigger** — Korean, Chinese, and Japanese input methods often commit composed text when the user presses a punctuation key (`.`, `/`, `?`, `!`, `-`, `=`, `[`, `]`, `'`, `;`, `,`, and their Shift variants). The physical key was then replayed on top of the composed text, inserting the punctuation character twice (e.g. "완료.." instead of "완료."). Term-mesh now detects when the text-input layer already included the trigger character as part of the IME commit and skips the redundant replay.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.111.0] - 2026-05-12

### Fixed
- **Korean IME no longer doubles the separator space** — some Korean input methods (e.g. Korean 2-bulsik) deliver the trigger Space that commits a syllable as part of the accumulated `insertText` buffer (either as a trailing space on the last chunk or as a separate `" "` chunk). The physical Space key was then replayed on top of it, inserting two spaces instead of one. Term-mesh now detects when the text-input layer has already included the Space and skips the replay.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.110.0] - 2026-05-12

### Fixed
- **Spacebar no longer inserts two spaces** — the v0.109.0 key-handling change caused space (and other plain text keys) to be processed twice: once by the explicit `keyDown` call added in that release, and again by AppKit's normal responder-chain dispatch. The dispatch logic is simplified back to returning `performKeyEquivalent`'s result directly so AppKit handles the single `keyDown` dispatch as before.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.109.0] - 2026-05-11

### Fixed
- **Plain ASCII characters no longer double when typing in TUI applications such as claude code** — the `termMesh_performKeyEquivalent` window swizzle forwarded non-Command key events to the Ghostty surface but returned the surface's raw result. When that came back `false` (which it does for ordinary letters that aren't a keyboard binding), AppKit re-dispatched the same `NSEvent` through `keyDown`, firing `ghostty_surface_key` twice and producing duplicated characters. The swizzle now snapshots the first responder, calls `keyDown` itself exactly once on a `false` return, and tells AppKit the event was consumed — except when `performKeyEquivalent` moved focus (e.g. into the IME bar), in which case the original `false` return is preserved so the new responder still receives the key. The Cmd-modifier, font-zoom, and IME `markedText` paths are unchanged.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.108.0] - 2026-05-11

### Fixed
- **Terminal typing no longer duplicates plain characters after the v0.107.0 IME fix** — the IME text accumulator is used by normal AppKit text input too, not only by active CJK composition. v0.107.0 correctly split committed IME text into a keycode-free UTF-8 event, but then replayed the physical key for every accumulated-text path. Plain ASCII input could therefore arrive as both `insertText("a")` and a replayed physical `a`, showing up as doubled characters in Claude Code, shells, and other terminal apps. Term-mesh now replays the physical key only when it is still needed: actual IME composition commits and control/special keys whose accumulated text was not sent as printable text. Plain left-arrow remains suppressed for macOS IME finalization.
- **Opening a sheet no longer sends portal geometry sync into a CPU/log loop** — terminal and browser portal windows defer geometry synchronization while an `NSSheet` is attached, but the retry was being scheduled back onto the main queue immediately. If the sheet stayed open, DEBUG builds could emit `portal.sync.deferSheet reason=attachedSheetActive` hundreds of times per second, trigger the debug log circuit breaker, and drive the app above 100% CPU. The retry is now delayed while the sheet remains attached, preserving the hang avoidance without spinning.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.107.0] - 2026-05-11

### Fixed
- **Korean/Japanese/Chinese IME input is now reliable in kitty-protocol terminals** — typing CJK characters in zsh inside term-mesh used to occasionally lose the composed text or emit the bare physical key (e.g., `d` instead of `ㄴ`) because the kitty keyboard protocol encoded the physical key code instead of the composed UTF-8 text. Two layers were fixed:
  - The bundled Ghostty now sends the committed composed text directly as UTF-8 when the key has no physical mapping (cherry-pick of upstream `fdfc9fea2`).
  - The terminal view now emits the IME-committed text as a separate keycode-free event before replaying the physical key, so a Korean syllable followed by a physical arrow no longer mixes its character with the arrow's keycode. Plain left-arrow that macOS sends to finalize composition is dropped; other navigation keys still replay so cursor movement after committing works.
- **Return/Tab no longer swallowed when the notifications popover is empty** — an internal popover would consume every plain keyDown event with no modifier while it was shown, including Return and Tab. The empty-popover guard now explicitly lets keyCode 36 (Return) and 48 (Tab) through, so pressing Enter to send a line or Tab to autocomplete works even if the popover is open and empty.
- **`team.delegate` no longer races Return ahead of the pasted instruction** — three independent races in the IME paste pipeline are addressed; together they eliminate the "Enter intermittently dropped" symptom observed when chaining `tm-agent delegate` commands. `processPaste()` no longer leaves the paste queue blocked when the surface is momentarily nil during peer workspace transitions, the Rust CLI now waits for an actual paste-completion ack from Swift before sending Return (instead of a hard-coded 150 ms sleep, now 20 ms safety margin), and the ack timeout is aligned with the paste watchdog so a stale paste can't be left behind a suppressed Return.

### Added
- **`tm-agent` agent routing now distributes work across same-named workers** — previously, teams with two agents of the same name (e.g. two `executor`) routed every `tm-agent delegate executor` call to the first matching pane, leaving the second one permanently idle. `selectAgent()` now round-robins across duplicate-named workers, `tm-agent broadcast` reaches every pane (not just the first match per name), and `tm-agent claim` automatically pushes the claimed task to the worker so autonomous claim-and-work patterns can run without leader intervention. A new `scripts/test-parallel.sh` exercises all four behaviours as a regression check.
- **Atomic appends to research/swarm board.jsonl** — multi-agent research, solve, consensus, and swarm modes used a plain `echo >> board_path` to record observations, so concurrent writers could interleave JSON lines and break downstream parsing. Writes now go through a `python3 fcntl.flock` exclusive-lock append, so the board file stays line-valid under parallel agents.
- **Debug log signals for diagnosing Enter/IME issues** — DEBUG builds now emit `key.PRESS_ignored`/`RELEASE_ignored` when Ghostty reports a synthetic keypress wasn't handled, and `ime.return_with_markedText`, `ime.resignFirstResponder`, `ime.becomeFirstResponder`, and `ime.ghosttyKey path=accumulated.text` to trace IME state and composed-text delivery. Useful for narrowing down "Enter intermittently doesn't fire" reports — see `CLAUDE.md` "Debug event log" for the grep patterns.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.106.0] - 2026-05-11

### Added
- **Peer Workspace inner sidebar** — opening a Peer Workspace window now shows a host-workspaces sidebar inside the window itself, so you can switch between a peer host's workspaces without going back to the main window. The main window also gains a "Remote Hosts" section in its sidebar listing all peers you have configured.
- **Keychain-backed Peer ID with Settings UI** — your peer identity is now stored in the macOS Keychain and surfaced in a dedicated Settings panel; previously the ID lived only in plaintext on disk and there was no in-app way to inspect or rotate it.
- **`tm-agent watch` CLI for live agent events** — a new CLI subcommand streams JSONL events (task status changes, agent replies, stale heartbeats) from the daemon as they happen, replacing the previous "poll `tm-agent status` every few seconds" workflow that leader sessions had to use. Backed by a new `events.subscribe` RPC and a 30s stale-heartbeat scanner that broadcasts a `heartbeat_stale` event when an agent stops checking in.
- **`xm-build` reply bridge for tm-agent tasks** — when an agent's reply includes a `XMB_TASK:` line in its Standard Header, the daemon now writes the status straight into the matching `xm-build` `tasks.json`, so dogfooding tm-agent with xm-build no longer requires the leader to hand-edit task files.

### Fixed
- **Enter key intermittently swallowed during workspace transitions and after `tm-agent delegate`** — three independent races in the paste/Return pipeline are addressed:
  - `processPaste()` no longer leaves `pasteInFlight = true` when the surface is momentarily nil (e.g., during peer workspace split or close), which used to block every subsequent paste/Enter for up to 8 seconds until the watchdog fired. The flag is now cleared on the surface-nil path so the next trigger drains the queue immediately.
  - `team.delegate` now waits for an actual paste-completion ack before responding to the Rust CLI, instead of letting the CLI rely on a hard-coded 150 ms sleep. The CLI also drops its post-ack delay from 150 ms to 20 ms now that ordering is guaranteed at the Swift layer.
  - The new ack timeout is aligned with the paste watchdog (12 s ≥ 8 s watchdog + retry budget + margin) so a timeout firing first can no longer leave a stale paste queued behind a Return that the CLI already suppressed — the bug-the-fix-introduced regression that the original ack patch shipped with.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.105.0] - 2026-05-10

### Added
- **Cost-aware bulk action buttons in team creation** — three new buttons (💎 최대 성능 / ⚖️ 균형 / 💰 최소 비용) above the Agents list set every agent's tier in one click. "최대 성능" pushes everyone to `opus`, "최소 비용" drops everyone to `haiku`, and "균형" re-applies the currently selected Smart Preset's per-role tier distribution (or falls back to `sonnet` when no Smart Preset is active). Useful for dialing the session's compute budget without editing each agent row by hand.
- **Compact agent runbook digest** — `tm-agent runbook digest` returns a token-efficient role brief instead of the full runbook source, and the default agent init prompt now uses the digest. Set `TERMMESH_RUNBOOK_MODE=full` to opt back into the full source for debugging role behaviour.

### Changed
- **Codex agents now default to GPT-5.5 with tier-based reasoning effort** — the previous `gpt-5.4` and `gpt-5.1-codex-mini` identifiers are no longer accepted by current ChatGPT accounts. All three short tiers (`opus` / `sonnet` / `haiku`) now map to `gpt-5.5` and dispatch the reasoning level separately as `high` / `medium` / `low` via `-c model_reasoning_effort=…`, so tier ordering is meaningful even though the underlying model is the same.
- **Gemini agents use Gemini 3 series previews** — `gemini-3.1-pro-preview` (opus), `gemini-3-flash-preview` (sonnet), `gemini-3.1-flash-lite-preview` (haiku) replace the previously hard-coded `gemini-3.1-pro` / `gemini-3-flash` identifiers that 404'd against current accounts. The Gemini 2.5 family stays selectable as a fallback in the model picker.
- **Kiro agents use the dotted model identifier format** — `claude-opus-4.7` / `claude-sonnet-4.6` / `claude-haiku-4.5` replace the previous `claude-opus-4-6-20250618` style strings that `kiro-cli` no longer accepts.
- **Smart Presets prefer Claude over Kiro for `architect` and `infra` roles** — when both CLIs are available, Claude is the safer default; Kiro stays available as a manual choice in the picker. Affected presets: `architect`, `quality`, `aws`, `idea`, `security-audit`, `api-factory`.
- **Smart Presets' `reviewer` role is now codex/opus (high reasoning)** — code review is where the extra reasoning budget pays off the most. Affected presets: `standard`, `architect`, `fullstack`, `refactor`, `quality`, `security-audit`, `migration`.
- **Codex and Gemini model pickers show CLI-native labels** — picking the `opus` tier under codex now displays as `gpt-5.5 (high)`, under gemini as `gemini-3.1-pro-preview`. Internal storage still uses the tier name so Smart Presets and saved roles round-trip without breakage.
- **Compact task capsule protocol for `tm-agent delegate`** — delegated tasks now ship a `TM-PROTOCOL-v1` capsule instead of re-stating the full lifecycle instructions per task, freeing context budget for the actual work.

### Fixed
- **Codex reasoning effort flag is no longer injected for non-tier model identifiers** — selecting `gpt-5.3-codex` (or any other passthrough name) used to add an unwanted `-c model_reasoning_effort=medium` argument on the headless daemon spawn path. The flag is now only added for tier names that actually map to a reasoning level, matching the Swift app's existing behaviour.
- **Reviewer agent's codex model picker no longer renders empty** — Smart Presets now write `primaryModel="opus"` for the codex reviewer, the picker recognises that selection, and the row shows `gpt-5.5 (high)` instead of an empty box.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.104.1] - 2026-05-10

### Fixed
- **Stale running binary now surfaces a "Restart and Update" pill within seconds of launch** — when `brew upgrade --cask term-mesh` runs externally (manual brew CLI, multi-machine sync, the cask smoke-test that publishes a release) the disk bundle is replaced but macOS keeps the old binary mapped into any still-running term-mesh process. The 30-minute `brew outdated` poll then reports "up-to-date" (disk version equals tap latest) and the running app silently keeps executing stale code with no pill. On startup the app now compares `Bundle.main`'s cached `CFBundleShortVersionString` (frozen when the process launched) against the on-disk `Info.plist` (re-read fresh) and immediately publishes `.readyToInstall(running → disk)` when they differ — so a relaunch into the new binary is one click away regardless of how the bundle was replaced.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.104.0] - 2026-05-10

### Added
- **Agent Runbooks — per-role behavior reference for term-mesh teams** — `.agent-runbooks/<role>.md` files are now the source of truth for what each role does (architect, executor, reviewer, security, …). The `tm-agent runbook` CLI manages them: `init` writes the 23 default templates into the current project, `install --tool claude|codex|opencode|all` projects them as tool-specific skill files (e.g. `.claude/skills/term-mesh-<role>/SKILL.md`), and `status` reports whether each projection is in sync. A new "Agent Runbooks" panel in Settings exposes the same flow with one-click Init / Install / Force Repair, and team agents created via the GUI or CLI automatically receive the relevant runbook content as part of their init prompt — an `executor` agent now knows it's an executor without you reminding it every session.
- **Workflow presets in team creation** — Settings → Team Presets now offers "workflow" presets alongside the existing "smart" presets. Workflow presets bundle a role list, task templates, and review checkpoints that the dashboard auto-creates when you start a team — useful for canned multi-agent flows (build/review/ship loops). The dropdown is wider so the new presets fit without truncation.

### Fixed
- **Dark mode no longer flips back to light after a slow brew upgrade** — v0.103.3 added a `GhosttyApp` color-scheme sync at startup, but its retry budget (5 × 100 ms) ran out on sluggish brew-upgrade relaunches, leaving the terminal rendering with the light theme even though the saved appearance was Dark. The retry now schedules one final long-delay attempt (3 s) before giving up, so the slow-startup case the original fix targeted actually closes.
- **Sidebar tint follows the saved appearance from the first frame** — when SwiftUI's environment color scheme had not yet propagated (the same brew-upgrade window where the terminal was light), the sidebar would render with the configured white tint while everything else was already dark. The sidebar now reads the user's explicit appearance preference directly and only falls through to SwiftUI's environment when the user has chosen "System".
- **`tm-agent team create` agents finally receive their runbook content** — the socket parameter that carried the "include runbook in init prompt" intent was wired to its own inverse on the Swift side, so CLI-created teams were silently spawning with bare instructions and no role context. The wiring now matches the parameter name, so `tm-agent team create` actually injects the runbook into the agent's first prompt.
- **Editing a managed `.agent-runbooks/<role>.md` file no longer gets clobbered on `tm-agent runbook install`** — the installer was treating the marker line at the top of each file as "still default, regenerate", so any edits below it were silently overwritten by the built-in defaults the next time you ran install. The installer now reads the on-disk content (the same way `tm-agent runbook status` does), so edits propagate into the projected skill files instead of looping "outdated → install → still outdated" without `--force`.

### Security
- **`tm-agent` binary lookup no longer searches the project's working directory in Release builds** — the runbook installer used to prefer `<projectRoot>/daemon/target/release/tm-agent` over the signed app bundle. A repository with a planted binary at that path would have been executed under the term-mesh app's privileges the moment the user clicked Init / Install / Force Repair in runbook Settings. Release builds now resolve only from the bundled `Contents/Resources/bin/tm-agent` and Homebrew/system paths; the project-relative candidates are kept only in DEBUG builds for development convenience. The `/usr/bin/env tm-agent` PATH-search fallback was also removed — when no known binary is found, the UI surfaces an explicit error instead of silently following `$PATH`.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.103.3] - 2026-05-10

### Added
- **Cmd+Shift+Return zooms a single pane to fill the relay window** — peer-relay workspace windows now honour the same "Zoom Pane" shortcut as local windows. The focused pane expands to occupy the full relay window, hiding all the other panes; pressing Cmd+Shift+Return again restores the original split tree. The zoom is purely local — the host workspace and any other relay clients are untouched. Useful when a remote split has too many panes to read comfortably and you want to focus on one without resizing the window or asking the host to rearrange.

### Fixed
- **Shift+Return inserts a real newline in remote multi-line input fields (codex, Claude Code, jupyter, …)** — when the local Ghostty has the Kitty keyboard protocol enabled it encodes Shift+Return as `CSI 13 ; 2 u`. The remote shell / TUI rarely shares that mode and was printing `[13;2u` verbatim into whatever multi-line input field was open. The peer-relay filter now translates Shift+Return to a literal LF (`\n`) before forwarding, which every text-input field treats as "insert newline".

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.103.2] - 2026-05-10

### Fixed
- **Codex (and other Kitty-keyboard TUIs) no longer receive ghost double-fire keystrokes through the peer relay** — when the local relay terminal had Kitty's keyboard protocol enabled in "report all events" mode, every key press was followed by a release event encoded as `CSI <key>;<mods>:3 <final>` (e.g. `\x1B[97;1:3u` for `a` release, `\x1B[1;1:3B` for ↓ release). The relay's filter only understood event-type-1 (press) and was forwarding the release events as a second keystroke, so menu selections in `codex` jumped two rows per keypress, Esc closed dialogs twice, and Ctrl-C arrived as `^C` plus a literal `[27;1:3u`. The relay now parses the `:event_type` field on both `CSI ... u` and Kitty special-key sequences (arrows, Page/Home/End, function keys) and drops release events while still translating presses and auto-repeats correctly.
- **Kitty keyboard protocol state reports stop polluting the host shell** — when a remote TUI queried the local relay terminal's keyboard mode with `CSI ? u`, Ghostty answered with `\x1B[?7u` (or similar) and the relay forwarded the answer back to the remote shell as typed input, so users saw stray `[?7u` literals appear in their `codex` prompt or the host's zsh after closing a TUI. The filter now classifies the `CSI ? <flags> u` response as terminal-generated and drops it, including when the response is split across two reads (`\x1B` then `[?7u`).
- **Connections panel now lists every active peer connection, not just workspace windows** — opening a peer console (debug socket) or a single-pane peer attach left the Connections panel empty even though the connection was live, so there was no UI affordance to disconnect it without closing the window manually. The panel now shows Console, Pane, and Workspace connections in one open-order list and the "Disconnect" button works for all three.

### Changed
- **Peer windows have a coloured titlebar accent** — peer relay panes, workspace windows, and the debug console now render a pink-to-blue gradient strip across the titlebar so they're visually distinct from local Ghostty windows at a glance. The accent reinstalls itself on `show()` so it survives window-merge / fullscreen transitions.
- **Connections panel grew a "Type" column and a wider Host column** — host display now prefixes SSH targets with `SSH ·` and falls back to the peer's advertised display name before the raw socket path, so it's easier to tell apart multiple peers at a glance. Window default width is 660 pt to fit the new layout.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.103.1] - 2026-05-09

### Fixed
- **Tab, Enter, Escape, and Backspace work in peer relay panes when Ghostty's keyboard protocol is active** — Ghostty encodes some unmodified control keys as `CSI <codepoint> u` (e.g. `\x1B[9u` for Tab, `\x1B[27u` for Escape) instead of the bare control byte. The relay was passing these through verbatim, so the remote shell saw `\x1b[9u` as literal text instead of a tab character; navigation in `vim`, `less`, and any TUI that reads raw stdin was broken. The relay now translates `CSI 9u` / `CSI 13u` / `CSI 27u` / `CSI 127u` to `\t` / `\r` / `\x1b` / `\x7f` before forwarding.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.103.0] - 2026-05-09

### Fixed
- **TUIs in peer relay panes no longer leak terminal-control responses to the remote shell** — `gk`, `vim`, `less`, etc. probe the terminal at startup with OSC/CSI queries (background colour, cursor position, device attributes). The local Ghostty answered those queries per spec, but the relay was forwarding the answers as user keystrokes — they arrived at the remote shell *after* the originating program had already exited and zsh treated them as commands (`zsh: command not found: 11`, `no such file or directory: rgb:0d0d/1111/17177`). The relay now runs a stateful filter on its stdin that drops OSC 4/10–19 (colour reports), OSC 52/5522 (clipboard reads), CSI cursor-position / status / device-attribute / focus replies, and translates Kitty CSI-u Ctrl-letter sequences (including Korean IME jamo) to the proper control byte before forwarding to the host.
- **OSC 52 clipboard contents no longer leak to peer hosts** — a malicious or compromised peer host could emit `OSC 52 ; c ; ?` to query the local terminal's clipboard; Ghostty would answer with the BASE64 contents, which the previous filter happily forwarded as typed input. The relay now drops every OSC 52 reply unconditionally.
- **Terminal replies split across read boundaries no longer slip through the relay filter** — when stdin returned `\x1B` and `[2;1R` in two separate reads (normal under PTY chunking), the filter used to flush the lone ESC and forward the rest as ordinary input. The state machine now holds pending escapes across reads, with a 100 ms `poll(2)` timeout so a user-typed Escape with no follow-up still reaches the host promptly.
- **Focus-tracking events stop polluting the host shell** — when a remote full-screen app turned on focus tracking, the local terminal's `\x1B[I` / `\x1B[O` events were forwarded as `[I` / `[O` literals into the remote prompt. The relay now classifies these as terminal-generated and drops them.
- **Korean Ctrl-key presses reach the remote shell as the right control byte** — when the Korean 2-set IME was active, Ctrl-C / Ctrl-A / etc. arrived at the relay as Kitty CSI-u sequences with Hangul jamo codepoints (`\x1B[12618;5u` for ㅊ on the C key) and were passed through unchanged; the remote shell saw the raw escape instead of `^C`. The relay now translates these to the QWERTY-equivalent control byte before forwarding.
- **Peer relay panes keep host-window keyboard focus** — peer focus pushes from the host used to steal the user's keyboard focus into the relay window even when they were typing in another app. The provider now updates the visual focus indicator without calling `makeFirstResponder`.
- **Pane focus follows the click in workspace relay windows** — clicking a pane in a multi-pane relay used to keep focus on whichever pane was last attached. The workspace controller now hit-tests the click against the actual pane geometry and restores focus after layout swaps.

### Changed
- **Peer host menu prefills the connect dialog with the current socket path** — if you've changed the daemon socket path away from the default, the connect / configure dialogs now start from the value already in use instead of always showing the default. Custom socket paths persist across app launches.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.102.9] - 2026-05-09

### Fixed
- **Peer relay panes no longer hang silently when the remote machine sleeps, the daemon pauses, or the network drops** — v0.102.8's reconnect overlay only fired when the SSH tunnel itself died. That left a much bigger gap: a remote laptop sleeping with its lid closed (the most common case), a paused/deadlocked daemon, or a Wi-Fi/VPN switch where the kernel hadn't yet seen a TCP RST all left the kernel believing the connection was alive — `read()` would block forever and macOS's default 2-hour TCP keepalive was the only thing that would eventually notice. Term-mesh now sends an application-level Ping every 10 s on every active peer session, expects a Pong back within 30 s, and on miss closes the transport so the existing reconnect overlay fires within seconds instead of leaving the user staring at an unresponsive terminal.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.102.8] - 2026-05-09

### Fixed
- **Peer relay over SSH no longer pollutes the remote shell with `command not found: 11` and similar nonsense after running TUIs like `gk`, `vim`, or `less`** — TUIs probe the terminal at startup with control sequences such as `CSI 6n` (cursor position) and `OSC 11 ?` (background colour). Until now the bytes flowed straight through to the local Ghostty, which answered per spec; the answer then made the round trip back over SSH and arrived at the remote PTY *after* the querying program had already exited, so it landed in zsh's prompt and zsh tried to execute it ("`zsh: command not found: 11`", "`no such file or directory: rgb:0d0d/1111/17177`"). The daemon now intercepts the queries (DA1/DA2/DA3, DSR-status, DSR-CPR, OSC 10/11) at the PTY boundary, writes a synthesised reply straight back to the PTY master so the originating program reads it on stdin without a relay round trip, and strips the query from the broadcast so the local terminal never sees it ([#20](https://github.com/x-mesh/term-mesh/pull/20)).
- **Peer relay panes no longer go silent after the remote daemon restarts, the remote machine sleeps/wakes, or the SSH session closes** — when the peer session ended while the SSH tunnel itself was still up (the common "Mac slept and woke", "remote daemon restarted", "vpn flapped" cases), the workspace window quietly displayed nothing with no indication that the connection was gone. A status overlay now appears for `down` / `reconnecting` / `failed` transitions with a Reconnect action; in the session-ended-while-tunnel-alive case the workspace also tears the SSH tunnel down and re-establishes it via the normal reconnect loop, so a sleeping laptop reattaching is handled automatically.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.102.7] - 2026-05-09

### Fixed
- **Peer host menu no longer stacks duplicate "Start Peer Server…" sheets when clicked twice** — clicking Start (or hitting the hotkey) while the start sheet was already up could either present a second sheet underneath the first or silently drop the action. The menu actions now track whether a sheet is up and bail out cleanly instead of stacking, and any "info" alert (already running / starting / stopping / no server) is also de-duplicated.
- **Stopping the peer server while it was still finishing startup no longer leaves the coordinator in a wedged state** — race between menu Stop and the in-flight `bringUp` could leave `server` as `nil` while the bonjour publisher and layout bridge stayed installed. The coordinator is now driven by an explicit `.stopped/.starting/.running/.stopping` lifecycle so every transition cleans up the same way and a stop in the middle of starting just no-ops with a sheet asking the user to wait.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.102.6] - 2026-05-09

### Fixed
- **Ctrl-C now interrupts foreground commands inside a peer relay pane** — pressing Ctrl-C in a remote peer pane (the kind opened from another machine over SSH) was sometimes leaving the foreground process running. The Ghostty key encoder, in some host states, was turning the ETX byte (`0x03`) into keyboard-protocol text that the remote PTY's line discipline never recognised as SIGINT, so `sleep`, `tail -f`, REPLs, etc. kept running until you closed the pane. The relay path now forwards `0x03` raw to the PTY, bypassing the encoder, so Ctrl-C reaches the foreground process the way the local terminal does ([#17](https://github.com/x-mesh/term-mesh/pull/17)).
- **Peer relay over SSH no longer reports "connection lost" while the connection is actually fine** — when an OpenSSH `ControlMaster` was already running for the same host, the forwarded Unix-socket request would be answered by the master and the spawned `ssh` process would exit immediately. The local socket appeared, so the upper layer thought the tunnel was up, but a few seconds later it would tear down and retry, surfacing as a flapping "reconnecting…" banner. Managed peer tunnels now pass `-S none -o ControlMaster=no -o ControlPersist=no` to opt out of multiplexing, and the tunnel is only marked healthy after the spawned `ssh` process is confirmed alive *after* the local socket appears, so a stale-socket scenario surfaces as a clean spawn failure instead of a phantom reconnect ([#17](https://github.com/x-mesh/term-mesh/pull/17)).
- **Attaching to an existing peer pane no longer shows a blank terminal until you press a key** — when a second client attached to a surface that had already produced output (a shell prompt, a long-running `tail`, a previous command's result), the new client would see nothing until fresh bytes arrived, because the daemon only broadcast newly-written PTY bytes. The daemon now keeps a 64 KB ring buffer of recent PTY output per surface and replays the snapshot on attach (deduped against live broadcast via byte-sequence numbers), so the new pane shows the current screen state immediately ([#17](https://github.com/x-mesh/term-mesh/pull/17)).

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.102.5] - 2026-05-09

### Fixed
- **Peer relay no longer fails with "relay binary not found" on any machine other than the developer's** — `term-mesh-peer-relay` (the Ghostty PTY shim spawned for every remote peer pane) was never actually copied into the shipped `.app` bundle: every `make deploy` / `make dmg` target only copied `term-meshd`, `term-mesh-run`, and `tm-agent`. Worse, `PeerRelaySession.findRelayBinary()` carried a hardcoded `/Users/jinwoo/...` dev fallback, so the developer's machine masked the bug while every brew user hit it the moment they tried to open a peer pane (locally or over SSH). Fix: bundle the relay binary alongside the other Rust binaries under `Contents/Resources/bin/`, switch the Swift lookup to that location (with a DerivedData-derived dev fallback that works for any contributor), drop the hardcoded user path, and add `verify-daemon-binaries` + `scripts/check-bundle-binaries.sh` guards to the build so the next workspace member that gets added can't be silently dropped from the bundle the same way.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.102.4] - 2026-05-08

### Changed
- Release pipeline verification build — exercises the full in-app update path end-to-end (brew outdated detection, helper-driven `brew upgrade --cask`, relaunch) on top of the v0.102.3 ghostty rollback. No code changes other than the version bump.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.102.3] - 2026-05-08

### Fixed
- **App no longer crashes on launch with `KERN_INVALID_ADDRESS` in `ghostty_config_get`** — v0.102.2 bumped the ghostty submodule to a SHA cherry-picked onto a much newer fork/main (1298 commits ahead of the prior base). The resulting GhosttyKit ABI was incompatible with our Swift bindings and any first window that became first responder crashed in `ghostty_config_get` during `ensureSurfaceReadyForInput`, blocking app launch entirely. Roll the submodule back to the SHA shipped with v0.102.1 (`c6e5476a`) where the PTY tap callback works without ABI drift; the PeerSSHTunnel ghost-socket fix and BrewSelfUpdater outdated-exit fix from v0.102.1 / v0.102.2 are preserved on top of this base.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.102.2] - 2026-05-08

### Fixed
- **In-app "Check for Updates" no longer fails with "Update Failed" when an update is actually available** — `brew outdated --cask --json=v2 <token>` exits with code 1 (with valid JSON on stdout) when the cask is outdated and 0 when up-to-date. The previous Process wrapper treated any non-zero exit as failure, so users on 0.102.0 saw "Update Failed" with the JSON payload bleeding through as the error message — exactly the condition the check was trying to detect, mistaken for a runtime error. The wrapper now accepts `{0, 1}` for the outdated check and relies on the JSON shape for the actual decision.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.102.1] - 2026-05-08

### Fixed
- **Peer relay/socket connect no longer silently fails after a previous app crash** — If the app exited abnormally while a peer SSH tunnel was up, the local listen socket file at `/tmp/tm-peer-ssh-*.sock` could end up unlinked while the ssh subprocess (now reparented to launchd) kept the unix socket bound in the kernel. New connect attempts saw `ENOENT` even though `lsof` still listed the socket — relay and direct socket connects both failed with no error surfaced. Term-mesh now (a) waits for ssh to actually exit before unlinking the socket file in `stop()`, with a 2 s SIGTERM grace and 1 s SIGKILL escalation, (b) sweeps `/tmp/tm-peer-ssh-*.sock` and orphan ssh subprocesses on launch using owner-PID gating so sibling app instances (DEV / STAGING / Release running side-by-side) never reap each other's live tunnels, and (c) embeds the owning app's PID in the listen socket filename to make that gate possible.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.102.0] - 2026-05-08

### Removed
- **Sparkle is gone** — the appcast feed has been 404 for some time and was producing `SUDownloadError (2001)` dialogs every time the user clicked `Check for Updates…`. The Sparkle SDK is no longer linked, the Sparkle public key and feed URL are out of `Info.plist`, and the three SPUUpdater shim files (`UpdateController.swift`, `UpdateDelegate.swift`, `UpdateDriver.swift`, ~720 lines combined) are gone. brew has been the actual update channel since 0.100.0; this just makes that explicit. No user action needed.

### Changed
- **`Check for Updates…` now gives you an actual answer** — the manual click was running silently in the background; you'd only see a pill if there was already an update sitting around. The titlebar pill now shows `Checking…` the moment you click, holds for at least 0.8 seconds so you can register that something happened, then transitions to either `Up to date` (which fades after 5 seconds) or `Update Available: X.Y.Z`. The 30-minute background poll is unchanged.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.101.2] - 2026-05-08

### Fixed
- **`Check for Updates…` no longer surfaces a Sparkle download error** — the manual menu click was firing both Sparkle and the brew self-updater. Sparkle's appcast feed has been unreachable for a while (the configured host returns 404), so each click produced a `SUDownloadError (2001)` dialog even though brew was happily picking up the new version in the background. The manual click now only runs the brew check; Sparkle's install path (`applyUpdateIfAvailable`) is left in place for the rare case its feed comes back online.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.101.1] - 2026-05-08

### Fixed
- **`Check for Updates…` menu now actually finds new versions** — the manual click was calling the brew updater's `checkNow()` path, which runs `brew outdated` against the locally cached tap state and skips `brew update`. If the tap was stale (the common case right after a release that the user wants to install), no new version was visible and the click silently did nothing. Manual click now goes through `refreshNow()` so the tap is refreshed before the version comparison. The 30-minute background poll is unchanged — it still uses `checkNow()` to avoid `brew update` thrashing.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.101.0] - 2026-05-08

### Fixed
- **Peer relay SSH first-connect no longer hangs** — Connecting a relay to a Mac whose host key isn't in `~/.ssh/known_hosts` previously stopped at the SSH "Are you sure you want to continue connecting (yes/no/[fingerprint])?" prompt with no way to answer from inside term-mesh. The tunnel now passes `-o StrictHostKeyChecking=accept-new` so brand-new hosts are auto-registered (TOFU) while changed keys are still rejected, and `-o BatchMode=no` keeps password fallback available when public-key auth isn't.
- **Peer relay window split (Cmd+D) actually splits now** — Three silent-fail paths were eating the keypress: `dispatchSplit` returned with no log when the subscription session was still nil, `GHOSTTY_ACTION_NEW_SPLIT` routed relay surfaces through `tabManager.newSplit(tabId: UUID())` (random UUID, no matching tab), and the relay window's keyMonitor only installed after the subscription handshake. Cmd+D during the handshake now stays inside the relay controller, the GhosttyApp action short-circuits for relay windows so the split goes through `dispatchSplit`, and a DEBUG `relay.split.skip` dlog surfaces a refusal when a split is genuinely unavailable.
- **Multi-pane broadcasts no longer strand peers at `[Pasted text #1]`** — When `tm-agent broadcast` (or any 3+ simultaneous deliveries) arrived faster than the previous Return retry could finish, four out of five surfaces could end up with the pasted text but no Enter — a `sendIMEText` reentrancy where the second paste hit `false` and the daemon's Return RPC was skipped. Replaced with a per-surface FIFO paste queue (depth 16, oldest-drop with a Sentry breadcrumb) that drains on the main actor, a `pasteGeneration` cancellation token that prevents async retry double-completion, and a finalize watchdog so a wedged surface never holds the queue forever. Return retry shortened from `[0.2, 0.5, 1.0, 5.0, 25.0]s` to `[0.2, 0.5, 1.0, 2.0, 3.0]s` so one bad delivery no longer parks the queue for 25 seconds.

### Security
- **Daemon control socket is now owner-only** — `daemon/term-meshd` previously bound the local control socket without a tight umask, so the file could end up at 0o660 (group-readable/writable). The bind now runs under `umask 0o077`, the socket is force-set to 0o600 after creation, and the accept loop adds a `LOCAL_PEERCRED` (macOS) / `SO_PEERCRED` (Linux) UID match — connections from a different UID are dropped with a warn log instead of being served. Mirrors the hardening already applied to the peer relay socket in 0.99.0.
- **Peer relay handshake gets bounded reads** — `acceptRelay()` now sets `SO_RCVTIMEO = 5s` after the non-blocking accept polls finish, so a peer that opens the socket and never sends bytes can't park a relay handshake task indefinitely. The auth-frame size is capped at 256 bytes (down from the 1 MiB read-frame ceiling) before `verifyRelaySecret`, blocking pre-auth allocation amplification.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.100.0] - 2026-05-08

### Added
- **Homebrew cask self-updater** — installs done via `brew install --cask x-mesh/tap/term-mesh` now check for new cask versions every 30 minutes, pre-fetch the next release in the background via `brew fetch`, and surface an "Update Available" pill in the right side of the titlebar. A matching "Restart and Update term-mesh" entry appears in the menu bar once the download is ready. Confirming the update opens an alert that renders the GitHub release notes inline (headings, bullets, links); accepting it quits the app, runs `brew upgrade --cask --force term-mesh` via a detached helper script, and relaunches automatically with focus restored. The standard `Check for Updates…` menu item now triggers a brew check alongside Sparkle in the same click.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.99.1] - 2026-05-07

### Fixed
- **App Hang false positives gone** — the 3-second titlebar refresh timer no longer trips Sentry's hang detector during foreground/background transitions. The timer now skips entirely when the app isn't active, coalesces with other titlebar-relevant events, and snapshots the workspace's published state in a single pass instead of repeatedly entering each `@Published` keypath under the runtime exclusivity check.
- **Modal alerts no longer block the main run loop** — peer-federation, browser, workspace, and tab dialogs that still used `NSAlert.runModal()` now present as window-attached sheets via `presentAsSheet`. The main thread keeps ticking while a dialog is up, so legitimate user interaction doesn't show up in Sentry as a fake App Hang.
- **Hang detector tolerates legitimate AppKit waits** — Sentry's `appHangTimeoutInterval` raised to 10s in DEBUG / 5s in Release so brief filesystem / Bonjour / SwiftUI rebuild stalls don't get reported as hangs.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.99.0] - 2026-05-07

### Added
- **Peer Federation** — attach another Mac's term-mesh from the status-bar menu (SSH or local Unix socket), mirror its workspace's split layout in a Ghostty relay window, and drive everything from your client: Cmd+D / Cmd+Shift+D split, Cmd+W close, Cmd+T new tab, divider drag, click-to-focus, in-relay tab strip for switching between tabs of the same pane. Supports multiple concurrent clients per host pane (count badge on the teal ring shows how many are attached). New "Show Peer Connections…" panel lists active relay windows with per-row Disconnect.
- **SSH transport with auto-reconnect** — `ssh -L`-tunneled relay survives sleep/wake, server reboots, and transient network blips with exponential backoff (1s → 30s, 12-attempt cap before a Retry-banner stop). The relay window's title and an in-window banner show live state: 🔌 Disconnected / Reconnecting (try N…) / Reconnected.
- **Bonjour LAN discovery** — hosts with the peer server enabled advertise themselves; the connect dialog has a live "Discovered on LAN" picker plus a recent-hosts dropdown so reconnecting is one keystroke.
- **Settings → Peer Federation** — toggle the local peer server, enable auto-start at app launch, override the socket path / display name, and opt in to "Force TUI redraw on attach" (sends Ctrl-L when a peer attaches so vim / htop / less repaint with full color).
- **Status-bar peer indicator** — small blue dot on the menu-bar icon when the local peer server is running.

### Security
- Local peer socket gated by `LOCAL_PEERCRED` (Darwin) / `SO_PEERCRED` (Linux) UID match on accept; bind runs under `umask 0o077` so the socket is created at 0600 with no TOCTOU window. Parent directory is forced to 0700 and ownership-checked, with sticky-bit world-writable parents (`/tmp`) explicitly accepted as a special case. SSH target / remote-socket validation rejects option-injection inputs (leading `-`, embedded `:`) before they reach `Process`. Relay handshake secret compared in constant time, auth nonces from a CSPRNG (`SecRandomCopyBytes` / `getrandom`) instead of UUIDv4 concatenation.

### Fixed
- **Connect dialogs no longer trip the App-Hang detector** — the SSH connect, workspace picker, surface picker, and error dialogs now present as window-attached sheets via `beginSheetModal(for:)` instead of `NSAlert.runModal()`. The main run loop is no longer parked in `mach_msg2_trap` while a dialog is up, eliminating the false-positive "App Hanging" Sentry events that the modal pattern produced.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.98.2] - 2026-04-22

No user-visible changes. Release-flow validation build — exercises the end-to-end `/release` pipeline introduced in v0.98.1 (DMG build → GitHub Release asset upload → Homebrew cask auto-update in `x-mesh/homebrew-tap`) and verifies `brew upgrade --cask term-mesh` picks up the new version without manual intervention.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.98.1] - 2026-04-22

### Added
- **Homebrew cask install path** — term-mesh is now available via the `x-mesh/tap` Homebrew tap. Install with `brew install --cask x-mesh/tap/term-mesh`; upgrade with `brew upgrade --cask term-mesh`. The cask strips the Gatekeeper quarantine attribute automatically on install and upgrade, so the unsigned DMG launches without a manual `xattr` step.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.98.0] - 2026-04-20

No user-visible changes. Internal release-tooling update only: `/release` now tags the squash-merge SHA on `main` and checks out that tag before building the dSYM, so Sentry debug symbols always match the released binary (previously a divergent local `main` could let an older build upload its dSYMs under the new tag's name).

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.97.0] - 2026-04-20

### Fixed
- **Restored sessions no longer collapse every pane to the same working directory** — when multiple split panes were open in different directories, quitting and relaunching term-mesh used to reopen every pane in a single shared cwd (the last-focused pane's directory). Per-pane working directories are now snapshotted at save time and each restored pane's shell launches in its original directory. Paths that no longer exist fall back to the workspace directory (or `$HOME`) so the shell still opens cleanly.
- **Secondary windows' titlebar no longer freezes in dark mode under light system appearance** — windows opened via Cmd+N or the app menu did not inject the current ghostty background theme into their SwiftUI environment, so their chrome used `GhosttyTheme.default` (hardcoded black) and ignored later light/dark transitions. Secondary windows now own a live `@State ghosttyTheme` and subscribe to `ghosttyDefaultBackgroundDidChange`, matching the primary window's behavior.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.96.0] - 2026-04-19

### Fixed
- **New windows no longer duplicate the primary window's restored session** — `TabManager.init` used to re-run session restore for every new window whose `initialWorkingDirectory` was `nil`, so opening a second term-mesh window brought up the same workspaces as the first one (the saved session, restored twice). Session restore is now an explicit opt-in: only the primary window created at launch by `TermMeshApp` passes `restoreSavedSession: true`. Secondary windows opened via the app menu, Cmd+N, or the dock start with a single fresh workspace, so they no longer shadow the primary window's tabs.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.95.0] - 2026-04-17

### Fixed
- **Ctrl+C no longer leaks `9;5u` text after a TUI app crashes or is killed** — TUI apps (Claude Code CLI, nvim, helix, etc.) enable the kitty keyboard protocol's "disambiguate escape codes" mode via `CSI > 1 u` on startup and are expected to disable it via `CSI < u` on exit. If the app crashed, was force-quit, or exited abnormally (for example after an API error during `/compact`), the flags remained on the terminal's protocol stack, causing the next Ctrl+C at the shell prompt to be encoded as `\e[99;5u` — which the shell would then echo to the screen as `9;5u9;5u9;5u…` instead of delivering SIGINT. term-mesh's zsh and bash shell integration now automatically pops any leftover kitty keyboard flags on every prompt render, so Ctrl+C recovers cleanly on the very next prompt without any user configuration or terminal restart. Running TUIs are unaffected because they re-push their flags on each prompt cycle.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.94.0] - 2026-04-17

### Fixed
- **Observer/NSAlert leak when two deferred alerts race for the same key-window transition** — the v0.93.3 fix for the notification-permission App Hanging warning (Sentry TERM-MESH-18) installed a one-shot `NSWindow.didBecomeKeyNotification` observer to wait for a key window before presenting the sheet. If two alerts queued before any window was focused (e.g. permission prompt + quit warning while the app was activated from the menu bar) and a window then became key, the first observer would attach its sheet and the second observer fell through its guard without deregistering — leaking the observer, the `NSAlert`, and its completion closure for the remainder of the session. A Settings/About window with an attached sheet could also silently swallow an alert intended for a terminal window. The observer now re-registers cleanly when the key window already has a sheet attached, so the alert still surfaces on the next key-window transition without leaking.

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.93.3] - 2026-04-17

### Fixed
- **App hang when opening a terminal whose last working directory is on a stalled filesystem** — if the previous working directory (OSC 7 / session snapshot) pointed at an unmounted network share, a spun-down external drive, or a broken SSHFS, Ghostty's internal `openat(workingDir)` during surface creation blocked the main thread for 2 s+ and tripped macOS's App Hanging watchdog (Sentry TERM-MESH-17). The working directory is now probed on a background queue with a 300 ms timeout before handing it to Ghostty; an unreachable path falls back to `$HOME` so a new terminal always opens immediately.
- **App hang when the notification-permission prompt appeared without a focused window** — `TerminalNotificationStore.promptToEnableNotifications` falls through `NSAlert.presentAsSheet` to a fallback path when no key/main window is available. That fallback used `runModal()`, which spins a nested modal event loop on the main thread and trips the App Hanging watchdog if the app is activated from the menu bar / background with no visible window (Sentry TERM-MESH-18). The fallback now defers presentation via a one-shot `NSWindow.didBecomeKeyNotification` observer — the sheet shows as soon as any window becomes key, without ever blocking main.
- **Possible app hang during SwiftUI layout involving drag-and-drop** — `FileDropOverlayView.hitTest` used to read `NSPasteboard(name: .drag).types` on every AppKit hit test, including idle-layout probes that run outside any active drag. If a prior external (Finder) drag left an `NSFilePromiseReceiver` on the drag pasteboard, macOS could wake the receiver during that probe and stall the main thread (Sentry TERM-MESH-19). The pasteboard read is now gated on an active drag-motion event; idle layout no longer touches the drag pasteboard at all. No behavior change for real drags.
- **New windows no longer stack on top of the previously-focused window** — `LastWindowPosition.restore()` used to apply the saved window position to every new window, so each new window jumped to the position of the most recently focused window and the cascade logic only offset it slightly. It now restores only the first window per app launch; subsequent new windows cascade from fresh positions. (ghostty submodule)

### Thanks to 1 contributor!

- [@JINWOO-J](https://github.com/JINWOO-J)

## [0.93.2] - 2026-04-16

### Fixed
- **`claude` wrapper `stop` / `notification` hooks no longer surface "Tab not found" errors to Claude Code's Stop hook log** — `term-mesh claude stop` / `claude notification` are best-effort telemetry auto-injected by the wrapper; stale session mappings (tab closed/renamed between launches, or `claude -p` subprocesses with stale workspace IDs) previously bubbled up as hook failures and spammed Claude Code's hook log. Workspace resolve failures and `notify_target` errors in the `stop`, `idle`, and `notification` subcommands are now caught and the hook returns `OK` instead of throwing. (`CLI/term-mesh.swift`)
- **`make dmg` no longer fails on stale `/Volumes/term-mesh` mounts or leftover `rw.*.dmg` intermediates** — repeated DMG builds in the same session could hit "resource busy" when a previous `/Volumes/term-mesh` mount hadn't been detached, and `create-dmg` occasionally leaves the read-write intermediate behind when Finder's detach is slow. `make dmg` now force-detaches any lingering `/Volumes/term-mesh` before and after `create-dmg` and removes `rw.*.term-mesh.dmg` intermediates so only the final UDZO image remains. (`Makefile`)

## [0.93.1] - 2026-04-15

### Fixed
- **App hang during periodic session save** — `TabManager.saveSessionState()` is called every 30 s and on tab/split churn; previously it ran JSON encoding and an `atomicWrite` on the main thread. The `rename()` behind `atomicWrite` triggers FSEvents/Darwin notify, and under file-watcher pressure this could block main for 2 s+ (Sentry TERM-MESH-2). Session snapshot is still captured on main (required by `@MainActor` isolation), but encoding and the disk write now run on a dedicated serial background queue.
- **Garbled terminal output when SSHing to servers without `xterm-ghostty` terminfo** — Ghostty defaults `TERM=xterm-ghostty`, which most remote hosts don't have. Shell redraw sequences were mis-interpreted, making every keystroke look like it echoed the previous autosuggestion. term-mesh now writes a baseline Ghostty config that enables `shell-integration-features = ssh-env,ssh-terminfo` out of the box; this installs the terminfo on the remote the first time you connect (falls back to `xterm-256color` if `tic` is unavailable). The baseline is loaded before the user config, so `~/.config/ghostty/config` can still override it.

### Changed
- **CLI symlinks moved from `~/bin` to `~/.local/bin`** — `make deploy` / `make deploy-prod` used to fail on machines without `~/bin` (the directory isn't created by default on macOS, and isn't on PATH in most default shell setups). Symlinks now go to `~/.local/bin`, which matches the XDG convention and is already on PATH for common setups. The Makefile creates the directory if it's missing.
- **Sentry dSYM upload is automatic on Release builds** — `make prod` / `make deploy-prod` / `make dmg` now run `sentry-cli debug-files upload --include-sources` at the end of the build. No-ops gracefully if `sentry-cli` is missing, unauthenticated, or no dSYMs are present, so unsigned-in contributors aren't blocked. Crash/hang reports from here on will be symbolicated with Swift file:line + source snippets.

## [0.93.0] - 2026-04-09

### Added
- **`tm-agent attach` / `tm-agent detach` — workspace-local agent management** — Add or remove agent panes inside the caller's current workspace without spawning a new one. First `attach` auto-creates a workspace-local team (`ws-<first8hex>` derived from the workspace UUID) and adopts the caller's pane as the team leader; subsequent attaches append agents to the same team. `detach <agent_name>` closes that agent's pane and removes it from the team; the last detach destroys the team while preserving the leader pane. Rejected if the workspace already hosts a `tm-agent create`-based team, so workspace-local and create-spawned teams never mix. `tm-agent create` behavior is unchanged.
- **`buildAgentPaneEnv` helper (single source of truth for agent pane env)** — Extracted from `createTeam` into `TeamOrchestrator.buildAgentPaneEnv(teamName:agentName:agentCli:windowId:workspaceId:)` so the workspace-local attach path and the existing create path construct the exact same agent environment. Guards against the 2026-03-19 regression where `TERMMESH_WINDOW_ID` / `TERMMESH_WORKSPACE_ID` went missing on spawned panes.
- **`addAgentPaneToWorkspace` helper (shared pane construction)** — Also extracted from `createTeam`, encapsulates the full CLI-specific invocation build (claude/codex/gemini/kiro), shell wrapping with worktree `cd`, env injection, split pane spawn, pane title, and `AgentMember` construction. Used by both `createTeam`'s agent loop and the new `attachToWorkspace`.
- **New JSON-RPC methods `team.attach` / `team.detach`** — Route through `dispatchTeamCommandAsync` and reuse `asyncTeamCreate`'s TabManager resolution precedence (`window_id` → `surface_id` → `workspace_id` → keyWindow) to prevent the 2026-03-17 multi-window routing regression. Both handlers run off-main with minimal `await MainActor.run` blocks and contain no `DispatchQueue.main.sync`.
- **Rust CLI `Commands::Attach` / `Commands::Detach`** — Auto-derive the team name from `TERMMESH_WORKSPACE_ID` via `resolve_workspace_team_name` when `TERMMESH_TEAM` is unset, validate agent names against `^[a-zA-Z0-9_-]{1,32}$` via `validate_agent_name`, and require `TERMMESH_PANEL_ID` / `TERMMESH_WORKSPACE_ID` context via `require_termmesh_context`. Errors surface with structured codes: `existing_gui_team`, `agent_name_conflict`, `team_not_found`, `agent_not_found`, `not_in_workspace`.
- **`tm-agent` Claude Code skill bundle** — `skills/tm-agent/SKILL.md` (328 lines) ships alongside `term-mesh`, `term-mesh-browser`, `term-mesh-debug-windows`, and `release`. Covers the full `tm-agent` CLI surface (create/attach/detach, messaging, task board, autonomous research/solve/consensus/swarm) with four end-to-end workflow examples, an invariants-and-gotchas section (socket focus policy, main-thread policy, adopted leader, send stagger, reply truncation), and a raw-RPC escape hatch.
- **CLAUDE.md `attach` / `detach` quick reference** — "Team agent system" section gains `tm-agent attach <type>` / `tm-agent detach <name>` examples noting the current-workspace-only semantics.

## [0.92.0] - 2026-04-09

### Added
- **`term-mesh-cli` Claude Code skill** — bundled skill teaches Claude (when running inside term-mesh) how to open browser splits, evaluate JavaScript in browser panels, navigate/click pages, and manage workspaces/panes via the `term-mesh` CLI. Build phase copies the skill into `Resources/claude-skills/` with a managed-file marker; `ClaudeCommandInstaller` installs it to `~/.claude/skills/` on launch and respects user-customized files.
- **README CLI usage section** — full command reference for window, workspace, surface, pane, browser, and team subcommands with worked examples.

### Changed
- **Slash command documentation refinements** — `.claude/commands/tm-op.md` extracted shared Result Collection block, added precedence rule for `--preset`/`--timeout`/`--rounds`, documented `tm-agent` binary fallback, added Autonomous Mode error-recovery subsection, defined stigmergy concept, and replaced literal `my-team` placeholders with `<team>`. `team-up.md` deduplicated command tables (links to `team.md` as canonical reference) and hoisted CRITICAL warning to top. `tm-bench.md` added explicit "Argument Parsing Precedence" section with worked examples for `agent N` + flag combinations.
- **Settings dashboard no longer auto-restarts daemon** — toggle/bind/port/password changes no longer auto-restart the daemon (reverts the auto-restart behavior introduced in 0.91.0; was causing UX friction).

### Fixed
- **Shell-integration path security** — escape shell-integration paths and sanitize temp file names across `DashboardController`, `SettingsView`, `TabManager`, and `TeamOrchestrator` to prevent shell injection through path interpolation.
- **TabManager refactor** — removed unnecessary `[weak self]` capture in `setTitle` closure (closure does not outlive `self`), added version-guard comment explaining the format compatibility strategy.

## [0.91.1] - 2026-04-08

### Fixed
- **Sleep/wake white-screen regression** — Removed the stale `suppressLayoutDuringDisplayReconfiguration` workaround (TERM-MESH-2). It was added to dodge a 2 s main-thread block from `NSHostingView.layout → CVDisplayLinkCreateWithCGDisplays`, but upstream Ghostty's 2025-06-16 renderer rework (`371d62a82`) moved macOS rendering to `IOSurfaceLayer`, so that blocker no longer exists. The leftover `contentView.isHidden = true/false` dance instead detached descendant `IOSurfaceLayer` contents on wake, leaving windows white until the user clicked. Removing the mechanism restores correct behavior with no measurable hang on current Ghostty.

## [0.91.0] - 2026-04-08

### Added
- **Dashboard preset switcher** — Overview / Team Ops / DevOps / Cost views with section visibility
- **Process Monitor tree view** — parent-child hierarchy with collapsible UI and Expand All/Collapse All
- **System Extended card** — Load Average bars, Swap usage, collapsible Network I/O (total + per-interface detail)
- **Per-Core CPU Heatmap** — color-coded grid showing per-core utilization
- **Anomaly detection** — high CPU sustained, repeated failure, no-heartbeat detection in daemon
- **Dashboard keyboard shortcut** — Cmd+Shift+D toggles the dashboard window
- **CLI: `new-split --type browser --url`** — one-step browser split creation
- **CLI: `close-surface --close-pane`** — collapse pane after closing all surfaces
- **CLI: `browser eval` scalar output** — string/number/bool printed directly without `--json`
- **Side-by-side card layout** — Watched Projects + Agent Status, Agent Sessions + Needs Attention, Daemon Tasks + Team Tasks

### Changed
- Settings dashboard toggle/bind/port/password now auto-restart the daemon (with debounce for port/password)
- WKWebView polling skip narrowed to dedicated dashboard window (split browser panels now poll correctly)
- Tagged builds (`./scripts/reload.sh --tag`) disable HTTP server to avoid port conflict with main app
- ProcessSnapshot now includes `ppid` for tree rendering

### Fixed
- **Initial cursor-in-middle-of-prompt bug** — terminal surfaces now force-refresh at 0.3s/0.8s/1.5s after launch to correct column count after SwiftUI layout settles (re-applies the c580530 fix that was reverted in c32830e)
- **Browser dashboard "disconnected"** — restored missing JS helpers (togglePid, toggleAllProcesses, updateProcessTree) that were accidentally deleted during section reorder
- **Mobile layout horizontal scroll** — reset `grid-column` on `#agents-card`/`#tasks-card`/`#team-tasks-card`/`#team-attention-card` in mobile media query, force inner grids to single/dual column
- **Card layout collapse to single column on Overview** — added agent/team cards to overview preset so paired cards stay side-by-side
- **Chart.js double-init error** — `cpuChart`/`timelineChart` initialized only in `window.onload` with destroy guards
- **Display type override** — `switchPreset` now uses `style.display = ''` instead of `'block'` so CSS grid/flex layouts are preserved
- **Sidebar Environment card visibility** — replaced hardcoded white background with theme-aware CSS variables

## [0.89.1] - 2026-04-07

### Changed
- Default Gemini model updated from `gemini-3.1-pro-preview` to `gemini-3.1-pro` (GA release)

## [0.88.1] - 2026-04-07

### Added
- `/tm-op research` strategy — invoke autonomous multi-agent research from the tm-op command palette

## [0.88.0] - 2026-04-07

### Added
- `tm-agent research <topic>` — autonomous multi-agent research with board.jsonl stigmergy coordination
  - Idle agent detection with graceful degradation (uses available agents, warns on shortfall)
  - Configurable depth (shallow/deep/exhaustive), round budget, timeout, web search toggle
  - Staggered dispatch with 3s intervals to reduce board write contention
  - Structured synthesis output with per-agent finding statistics

## [0.87.1] - 2026-04-07

### Fixed
- Dashboard metric cards (Teams, Agents, Open Tasks, Attention) now visible in dark theme — replaced hardcoded white background with theme-aware colors

## [0.87.0] - 2026-04-07

### Added
- Split pane layouts are now saved and restored across app restarts — no more manual re-splitting after relaunch
- Periodic session auto-save every 30 seconds for crash and force-quit resilience

### Fixed
- Memory growth in long-running agent teams — message history now capped at 500 per team with FIFO pruning

## [0.86.5] - 2026-04-07

### Fixed
- Terminal screen turning white after waking from sleep or monitor connect/disconnect — clicking was required to restore display

## [0.75.0] - 2026-03-21

### Added
- Default light theme for terminal — fresh installs now have proper light colors out of the box
- Auto-detect macOS system appearance and apply matching terminal theme in "System" mode
- Light/Dark theme pickers now show only matching themes (light themes for Light, dark themes for Dark)
- IME slash command picker discovers project-local commands from `.claude/commands/` (e.g. `/squash`)
- IME font zoom with Cmd+Plus/Minus shortcuts
- Plain arrow key pass-through when IME input is empty
- Stop/interrupt command for team agents

### Fixed
- Terminal always showing dark theme regardless of appearance setting
- IME Cmd+Z crash caused by stale undo stack after view teardown
- Option+Arrow keys in IME now send plain arrows instead of Alt-modified sequences
- Agent panels no longer counted in shell health assessment

## [0.74.0] - 2026-03-20

### Added
- Terminal settings GUI — configure font family, font size, light/dark theme, cursor style, cursor color, unfocused split opacity, and scrollback limit from Settings without editing config files
- 459 bundled ghostty themes available in theme picker
- System monospace fonts listed first in font picker with all fonts available

### Fixed
- Metal terminal surfaces no longer bleed through browser panels during pane zoom
- Infinite layout loops in portal sync and focus chains resolved
- IME command highlighting no longer triggers at line start — only after pipe/separator
- Worktree creation from an existing worktree now correctly resolves the main repo
- Agent Enter key delivery made reliable with atomic IME-style press/release pairs
- Worktree deletion now checks for uncommitted changes by default — dirty worktrees are protected unless explicitly force-removed
- Stale worktree cleanup during branch re-creation refuses to prune dirty worktrees

### Changed
- `worktree.remove` RPC now defaults to safe mode (rejects dirty worktrees); pass `force=true` to override

## [0.69.0] - 2026-03-17

### Fixed
- IME composition no longer strips trailing newline on Enter submit
- Team creation now routes to the correct window instead of always targeting the last active window
- Team name uniqueness is now enforced across all windows, not just the current one
- Agents in shared/isolated worktree mode now correctly start in the worktree directory

## [0.64.2] - 2026-03-16

### Fixed
- **tm-agent socket detection**: `detect_socket()` now checks `/tmp/term-mesh-last-socket-path` before glob fallback, avoiding ambiguity with multiple tagged debug sockets
- **tm-agent wait infinite loop**: `--interval 0` no longer causes an infinite loop (clamped to minimum 1 second)
- **tm-agent prompt consistency**: `agent_init_prompt` now instructs agents to use `tm-agent reply` (unified with `REPORT_SUFFIX` and `BROADCAST_SUFFIX`)
- **tm-agent RPC error surfacing**: `run_wait` and `run_create` now print warnings to stderr on RPC failures instead of silently ignoring them
- **tm-agent.sh reply**: Shell fallback `reply` command now correctly sends both `message.post` (type=report, to=leader) and `team.report`, matching Rust binary behavior

### Added
- `tests/test_tm_agent.py` — 34-test automated suite covering task lifecycle, messaging, reply integration, wait modes, and edge cases (`python3 tests/test_tm_agent.py --rounds 3`)
- `docs/tm-agent-architecture-review.md` — Architecture review with 6 identified issues and prioritized recommendations

### Changed
- `.claude/commands/team.md` — Added missing `task block`, `inbox`, `create` flags documentation; fixed `task review` signature

## [0.60.0] - 2026-02-21

### Added
- Tab context menu with rename, close, unread, and workspace actions ([#225](https://github.com/manaflow-ai/term-mesh/pull/225))
- Cmd+Shift+T reopens closed browser panels ([#253](https://github.com/manaflow-ai/term-mesh/pull/253))
- Vertical sidebar branch layout setting showing git branch and directory per pane
- JavaScript alert/confirm/prompt dialogs in browser panel ([#237](https://github.com/manaflow-ai/term-mesh/pull/237))
- File drag-and-drop and file input in browser panel ([#214](https://github.com/manaflow-ai/term-mesh/pull/214))
- tmux-compatible command set with matrix tests ([#221](https://github.com/manaflow-ai/term-mesh/pull/221))
- Pane resize divider control via CLI ([#223](https://github.com/manaflow-ai/term-mesh/pull/223))
- Production read-screen capture APIs ([#219](https://github.com/manaflow-ai/term-mesh/pull/219))
- Notification rings on terminal panes ([#132](https://github.com/manaflow-ai/term-mesh/pull/132))
- Claude Code integration enabled by default ([#247](https://github.com/manaflow-ai/term-mesh/pull/247))
- HTTP host allowlist for embedded browser with save and proceed flow ([#206](https://github.com/manaflow-ai/term-mesh/pull/206), [#203](https://github.com/manaflow-ai/term-mesh/pull/203))
- Setting to disable workspace auto-reorder on notification ([#215](https://github.com/manaflow-ai/term-mesh/issues/205))
- Browser panel mouse back/forward buttons and middle-click close ([#139](https://github.com/manaflow-ai/term-mesh/pull/139))
- Browser DevTools shortcut wiring and persistence ([#117](https://github.com/manaflow-ai/term-mesh/pull/117))
- CJK IME input support for Korean, Chinese, and Japanese ([#125](https://github.com/manaflow-ai/term-mesh/pull/125))
- `--help` flag on CLI subcommands ([#128](https://github.com/manaflow-ai/term-mesh/pull/128))
- `--command` flag for `new-workspace` CLI command ([#121](https://github.com/manaflow-ai/term-mesh/pull/121))
- `rename-tab` socket command ([#260](https://github.com/manaflow-ai/term-mesh/pull/260))
- Remap-aware bonsplit tooltips and browser split shortcuts ([#200](https://github.com/manaflow-ai/term-mesh/pull/200))

### Fixed
- IME preedit anchor sizing ([#266](https://github.com/manaflow-ai/term-mesh/pull/266))
- Cmd+Shift+T focus against deferred stale callbacks ([#267](https://github.com/manaflow-ai/term-mesh/pull/267))
- Unknown Bonsplit tab context actions causing crash ([#264](https://github.com/manaflow-ai/term-mesh/pull/264))
- Socket CLI commands stealing macOS app focus ([#260](https://github.com/manaflow-ai/term-mesh/pull/260))
- CLI unix socket lag from main-thread blocking ([#259](https://github.com/manaflow-ai/term-mesh/pull/259))
- Main-thread notification cascade causing hangs ([#232](https://github.com/manaflow-ai/term-mesh/pull/232))
- Favicon out-of-sync during back/forward navigation ([#233](https://github.com/manaflow-ai/term-mesh/pull/233))
- Stale sidebar git branch after closing a split
- Browser download UX and crash path ([#235](https://github.com/manaflow-ai/term-mesh/pull/235))
- Browser reopen focus across workspace switches ([#257](https://github.com/manaflow-ai/term-mesh/pull/257))
- Mark Tab as Unread no-op on focused tab ([#249](https://github.com/manaflow-ai/term-mesh/pull/249))
- Split dividers disappearing in tiny panes ([#250](https://github.com/manaflow-ai/term-mesh/pull/250))
- Flaky browser download activity accounting ([#246](https://github.com/manaflow-ai/term-mesh/pull/246))
- Drag overlay routing and terminal overlay regressions ([#218](https://github.com/manaflow-ai/term-mesh/pull/218))
- Initial bonsplit split animation flicker
- Window top inset on new window creation ([#224](https://github.com/manaflow-ai/term-mesh/pull/224))
- Cmd+Enter being routed as browser reload ([#213](https://github.com/manaflow-ai/term-mesh/pull/213))
- Child-exit close for last-terminal workspaces ([#254](https://github.com/manaflow-ai/term-mesh/pull/254))
- Sidebar resizer hitbox and cursor across portals ([#255](https://github.com/manaflow-ai/term-mesh/pull/255))
- Workspace-scoped tab action resolution
- IDN host allowlist normalization
- `setup.sh` cache rebuild and stale lock timeout ([#217](https://github.com/manaflow-ai/term-mesh/pull/217))
- Inconsistent Tab/Workspace terminology in settings and menus ([#187](https://github.com/manaflow-ai/term-mesh/pull/187))

### Changed
- CLI workspace commands now run off the main thread for better responsiveness ([#270](https://github.com/manaflow-ai/term-mesh/pull/270))
- Remove border below titlebar ([#242](https://github.com/manaflow-ai/term-mesh/pull/242))
- Slimmer browser omnibar with button hover/press states ([#271](https://github.com/manaflow-ai/term-mesh/pull/271))
- Browser under-page background refreshes on theme updates ([#272](https://github.com/manaflow-ai/term-mesh/pull/272))
- Command shortcut hints scoped to active window ([#226](https://github.com/manaflow-ai/term-mesh/pull/226))
- Nightly and release assets are now immutable (no accidental overwrite) ([#268](https://github.com/manaflow-ai/term-mesh/pull/268), [#269](https://github.com/manaflow-ai/term-mesh/pull/269))

## [0.59.0] - 2026-02-19

### Fixed
- Fix panel resize hitbox being too narrow and stale portal frame after panel resize

## [0.58.0] - 2026-02-19

### Fixed
- Fix split blackout race condition and focus handoff when creating or closing splits

## [0.57.0] - 2026-02-19

### Added
- Terminal panes now show an animated drop overlay when dragging tabs

### Fixed
- Fix blue hover not showing when dragging tabs onto terminal panes
- Fix stale drag overlay blocking clicks after tab drag ends

## [0.56.0] - 2026-02-19

_No user-facing changes._

## [0.55.0] - 2026-02-19

### Changed
- Move port scanning from shell to app-side with batching for faster startup

### Fixed
- Fix visual stretch when closing split panes
- Fix omnibar Cmd+L focus races

## [0.54.0] - 2026-02-18

### Fixed
- Fix browser omnibar Cmd+L causing 100% CPU from infinite focus loop

## [0.53.0] - 2026-02-18

### Changed
- CLI commands are now workspace-relative: commands use `TERMMESH_WORKSPACE_ID` environment variable so background agents target their own workspace instead of the user's focused workspace
- Remove all index-based CLI APIs in favor of short ID refs (`surface:1`, `pane:2`, `workspace:3`)
- CLI `send` and `send-key` support `--workspace` and `--surface` flags for explicit targeting
- CLI escape sequences (`\n`, `\r`, `\t`) in `send` payloads are now handled correctly
- `--id-format` flag is respected in text output for all list commands

### Fixed
- Fix background agents sending input to the wrong workspace
- Fix `close-surface` rejecting cross-workspace surface refs
- Fix malformed surface/pane/workspace/window handles passing through without error
- Fix `--window` flag being overridden by `TERMMESH_WORKSPACE_ID` environment variable

## [0.52.0] - 2026-02-18

### Changed
- Faster workspace switching with reduced rendering churn

### Fixed
- Fix Finder file drop not reaching portal-hosted terminals
- Fix unfocused pane dimming not showing for portal-hosted terminals
- Fix terminal hit-testing and visual glitches during workspace teardown

## [0.51.0] - 2026-02-18

### Fixed
- Fix menubar and right-click lag on M1 Macs in release builds
- Fix browser panel opening new tabs on link click

## [0.50.0] - 2026-02-18

### Fixed
- Fix crashes and fatal error when dropping files from Finder
- Fix zsh git branch display not refreshing after changing directories
- Fix menubar and right-click lag on M1 Macs

## [0.49.0] - 2026-02-18

### Fixed
- Fix crash (stack overflow) when clicking after a Finder file drag
- Fix titlebar folder icon briefly enlarging on workspace switch

## [0.48.0] - 2026-02-18

### Fixed
- Fix right-click context menu lag in notarized builds by adding missing hardened runtime entitlements
- Fix claude shim conflicting with `--resume`, `--continue`, and `--session-id` flags

## [0.47.0] - 2026-02-18

### Fixed
- Fix sidebar tab drag-and-drop reordering not working

## [0.46.0] - 2026-02-18

### Fixed
- Fix broken mouse click forwarding in terminal views

## [0.45.0] - 2026-02-18

### Changed
- Rebuild with Xcode 26.2 and macOS 26.2 SDK

## [0.44.0] - 2026-02-18

### Fixed
- Crash caused by infinite recursion when clicking in terminal (FileDropOverlayView mouse event forwarding)

## [0.38.1] - 2026-02-18

### Fixed
- Right-click and menubar lag in production builds (rebuilt with macOS 26.2 SDK)

## [0.38.0] - 2026-02-18

### Added
- Double-clicking the sidebar title-bar area now zooms/maximizes the window

### Fixed
- Browser omnibar `Cmd+L` now reliably refreshes/selects-all and supports immediate typing without stale inline text
- Omnibar inline completion no longer replaces typed prefixes with mismatched suggestion text

## [0.37.0] - 2026-02-17

### Added
- "+" button on the tab bar for quickly creating new terminal or browser tabs

## [0.36.0] - 2026-02-17

### Fixed
- App hang when omnibar safety timeout failed to fire (blocked main thread)
- Tab drag/drop not working when multiple workspaces exist
- Clicking in browser WebView not focusing the browser tab

## [0.35.0] - 2026-02-17

### Fixed
- App hang when clicking browser omnibar (NSTextView tracking loop spinning forever)
- White flash when creating new browser panels
- Tab drag/drop broken when dragging over WebView panes
- Stale drag timeout cancelling new drags of the same tab
- 88% idle CPU from infinite makeFirstResponder loop
- Terminal keys (arrows, Ctrl+N/P) swallowed after opening browser
- Cmd+N swallowed by browser omnibar navigation
- Split focus stolen by re-entrant becomeFirstResponder during reparenting

## [0.34.0] - 2026-02-16

### Fixed
- Browser not loading localhost URLs correctly

## [0.33.0] - 2026-02-16

### Fixed
- Menubar and general UI lag in production builds
- Sidebar tabs getting extra left padding when update pill is visible
- Memory leak when middle-clicking to close tabs

## [0.32.0] - 2026-02-16

### Added
- Sidebar metadata: git branch, listening ports, log entries, progress bars, and status pills

### Fixed
- localhost and 127.0.0.1 URLs not resolving correctly in the browser panel

### Changed
- `browser open` now targets the caller's workspace by default via TERMMESH_WORKSPACE_ID

## [0.31.0] - 2026-02-15

### Added
- Arrow key navigation in browser omnibar suggestions
- Browser zoom shortcuts (Cmd+/-, Cmd+0 to reset)
- "Install Update and Relaunch" menu item when an update is available

### Changed
- Open browser shortcut remapped from Cmd+Shift+B to Cmd+Shift+L
- Flash focused panel shortcut remapped from Cmd+Shift+L to Cmd+Shift+H
- Update pill now shows only in the sidebar footer

### Fixed
- Omnibar inline completion showing partial domain (e.g. "news." instead of "news.ycombinator.com")

## [0.30.0] - 2026-02-15

### Fixed
- Update pill not appearing when sidebar is visible in Release builds

## [0.29.0] - 2026-02-15

### Added
- Cmd+click on links in the browser opens them in a new tab
- Right-click context menu shows "Open Link in New Tab" instead of "Open in New Window"
- Third-party licenses bundled in app with Licenses button in About window
- Update availability pill now visible in Release builds

### Changed
- Cmd+[/] now triggers browser back/forward when a browser panel is focused (no-op on terminal)
- Reload configuration shortcut changed to Cmd+Shift+,
- Improved browser omnibar suggestions and focus behavior

## [0.28.2] - 2026-02-14

### Fixed
- Sparkle updates from `0.27.0` could fail to detect newer releases because release build numbers were behind the latest published appcast build number
- Release GitHub Action failed on repeat runs when `SUPublicEDKey` / `SUFeedURL` already existed in `Info.plist`

## [0.28.1] - 2026-02-14

### Fixed
- Release build failure caused by debug-only helper symbols referenced in non-debug code paths

## [0.28.0] - 2026-02-14

### Added
- Optional nightly update channel in Settings (`Receive Nightly Builds`)
- Automated nightly build and publish workflow for `main` when new commits are available

### Changed
- Settings and About windows now use the updated transparent titlebar styling and aligned controls
- Repository license changed to GNU AGPLv3

### Fixed
- Terminal panes freezing after repeated split churn
- Finder service directory resolution now normalizes paths consistently

## [0.27.0] - 2026-02-11

### Fixed
- Muted traffic lights and toolbar items on macOS 14 (Sonoma) caused by `clipsToBounds` default change
- Toolbar buttons (sidebar, notifications, new tab) disappearing after toggling sidebar with Cmd+B
- Update check pill not appearing in titlebar on macOS 14 (Sonoma)

## [0.26.0] - 2026-02-11

### Fixed
- Muted traffic lights and toolbar items in focused window caused by background blur in themeFrame
- Sidebar showing two different textures near the titlebar on older macOS versions

## [0.25.0] - 2026-02-11

### Fixed
- Blank terminal on macOS 26 (Tahoe) — two additional code paths were still clearing the window background, bypassing the initial fix
- Blank terminal on macOS 15 caused by background blur view covering terminal content

## [0.24.0] - 2026-02-09

### Changed
- Update bundle identifier to `com.termmesh.app` for consistency

## [0.23.0] - 2026-02-09

### Changed
- Rename app to term-mesh — new app name, socket paths, Homebrew tap, and CLI binary name (bundle ID remains `com.termmesh.app` for Sparkle update continuity)
- Sidebar now shows tab status as text instead of colored dots, with instant git HEAD change detection

### Fixed
- CLI `set-status` command not properly quoting values or routing `--tab` flag

## [0.22.0] - 2026-02-09

### Fixed
- Xcode and system environment variables (e.g. DYLD, LANGUAGE) leaking into terminal sessions

## [0.21.0] - 2026-02-09

### Fixed
- Zsh autosuggestions not working with shared history across terminal panes

## [0.17.3] - 2025-02-05

### Fixed
- Auto-update not working (Sparkle EdDSA signing was silently failing due to SUPublicEDKey missing from Info.plist)

## [0.17.1] - 2025-02-05

### Fixed
- Auto-update not working (Sparkle public key was missing from release builds)

## [0.17.0] - 2025-02-05

### Fixed
- Traffic lights (close/minimize/zoom) not showing on macOS 13-15
- Titlebar content overlapping traffic lights and toolbar buttons when sidebar is hidden

## [0.16.0] - 2025-02-04

### Added
- Sidebar blur effect with withinWindow blending for a polished look
- `--panel` flag for `new-split` command to control split pane placement

## [0.15.0] - 2025-01-30

### Fixed
- Typing lag caused by redundant render loop

## [0.14.0] - 2025-01-30

### Added
- Setup script for initializing submodules and building dependencies
- Contributing guide for new contributors

### Fixed
- Terminal focus when scrolling with mouse/trackpad

### Changed
- Reload scripts are more robust with better error handling

## [0.13.0] - 2025-01-29

### Added
- Customizable keyboard shortcuts via Settings

### Fixed
- Find panel focus and search alignment with Ghostty behavior

### Changed
- Sentry environment now distinguishes between production and dev builds

## [0.12.0] - 2025-01-29

### Fixed
- Handle display scale changes when moving between monitors

### Changed
- Fix SwiftPM cache handling for release builds

## [0.11.0] - 2025-01-29

### Added
- Notifications documentation for AI agent integrations

### Changed
- App and tooling updates

## [0.10.0] - 2025-01-29

### Added
- Sentry SDK for crash reporting
- Documentation site with Fumadocs
- Homebrew installation support (`brew install --cask term-mesh`)
- Auto-update Homebrew cask on release

### Fixed
- High CPU usage from notification system
- Release workflow SwiftPM cache issues

### Changed
- New tabs now insert after current tab and inherit working directory

## [0.9.0] - 2025-01-29

### Changed
- Normalized window controls appearance
- Added confirmation panel when closing windows with active processes

## [0.8.0] - 2025-01-29

### Fixed
- Socket key input handling
- OSC 777 notification sequence support

### Changed
- Customized About window
- Restricted titlebar accessories for cleaner appearance

## [0.7.0] - 2025-01-29

### Fixed
- Environment variable and terminfo packaging issues
- XDG defaults handling

## [0.6.0] - 2025-01-28

### Fixed
- Terminfo packaging for proper terminal compatibility

## [0.5.0] - 2025-01-28

### Added
- Sparkle updater cache handling
- Ghostty fork documentation

## [0.4.0] - 2025-01-28

### Added
- term-mesh CLI with socket control modes
- NSPopover-based notifications

### Fixed
- Notarization and codesigning for embedded CLI
- Release workflow reliability

### Changed
- Refined titlebar controls and variants
- Clear notifications on window close

## [0.3.0] - 2025-01-28

### Added
- Debug scrollback tab with smooth scroll wheel
- Mock update feed UI tests
- Dev build branding and reload scripts

### Fixed
- Notification focus handling and indicators
- Tab focus for key input
- Update UI error details and pill visibility

### Changed
- Renamed app to term-mesh
- Improved CI UI test stability

## [0.1.0] - 2025-01-28

### Added
- Sparkle auto-update flow
- Titlebar update UI indicator

## [0.0.x] - 2025-01-28

Initial releases with core terminal functionality:
- GPU-accelerated terminal rendering via Ghostty
- Tab management with native macOS UI
- Split pane support
- Keyboard shortcuts
- Socket API for automation
