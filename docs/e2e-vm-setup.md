# E2E Test VM Setup (UTM)

term-mesh의 E2E 테스트는 UTM macOS VM에서 실행한다. 호스트의 앱 인스턴스를 실수로 kill하는 것을 방지하기 위해, 테스트 스크립트는 VM 유저(`term-mesh`)에서만 실행되도록 가드되어 있다.

## 1. UTM macOS VM 생성

1. [UTM](https://mac.getutm.app/) 설치
2. UTM 실행 → **Create a New Virtual Machine** → **Virtualize** → **macOS**
3. IPSW 파일 선택 (호스트와 동일한 macOS 버전 권장)
4. 리소스 할당:
   - CPU: 4코어 이상 (Xcode 빌드용)
   - RAM: 8GB 이상
   - 디스크: 80GB 이상 (Xcode ~35GB + DerivedData + 여유)

## 2. VM 초기 설정

VM 부팅 후 macOS 설치 마법사를 완료한다.

### 2-1. 사용자 계정

**반드시 `term-mesh`라는 이름으로 계정을 생성한다.** 테스트 스크립트(`run-tests-v1.sh`, `run-tests-v2.sh`)가 `id -un`으로 유저명을 체크한다.

### 2-2. Xcode 설치

```bash
# App Store에서 Xcode 설치 후
sudo xcodebuild -license accept
xcode-select --install
```

### 2-3. SSH 활성화

시스템 설정 → General → Sharing → **Remote Login** 켜기

### 2-4. 접근성 권한 (UI 테스트용)

시스템 설정 → Privacy & Security → Accessibility → Terminal.app 추가

## 3. 호스트 SSH 설정

### 3-1. VM IP 확인

VM 내에서:
```bash
ipconfig getifaddr en0
```

UTM 기본 네트워크는 Shared Network (NAT). 고정 IP가 필요하면 UTM 네트워크 설정에서 Bridged로 변경한다.

### 3-2. SSH config 추가

호스트의 `~/.ssh/config`에 추가:
```
Host term-mesh-vm
    HostName <VM IP 주소>
    User term-mesh
    Port 22
```

### 3-3. SSH 키 등록

```bash
ssh-copy-id term-mesh-vm
ssh term-mesh-vm 'whoami'   # → term-mesh
```

## 4. 프로젝트 셋업

```bash
ssh term-mesh-vm

# 프로젝트 클론
cd /Users/jinwoo/term-mesh
git clone <repo-url> GhosttyTabs
cd GhosttyTabs

# 서브모듈 초기화 + GhosttyKit 빌드
./scripts/setup.sh
```

## 5. 첫 빌드 확인

```bash
ssh term-mesh-vm 'cd /Users/jinwoo/term-mesh/GhosttyTabs && xcodebuild \
  -project GhosttyTabs.xcodeproj \
  -scheme term-mesh \
  -configuration Debug \
  -destination "platform=macOS" \
  build'
```

빌드 성공 시 `** BUILD SUCCEEDED **` 출력.

## 6. Python 테스트 의존성

Python 3는 Xcode Command Line Tools에 포함되어 있다. 추가 패키지가 필요한 경우:

```bash
ssh term-mesh-vm 'pip3 install --user <패키지>'
```

## 7. 테스트 실행

### Python 통합 테스트 (v1)

```bash
ssh term-mesh-vm 'cd /Users/jinwoo/term-mesh/GhosttyTabs && ./scripts/run-tests-v1.sh'
```

### Python 통합 테스트 (v2)

```bash
ssh term-mesh-vm 'cd /Users/jinwoo/term-mesh/GhosttyTabs && ./scripts/run-tests-v2.sh'
```

### Xcode UI 테스트 (특정 클래스)

```bash
ssh term-mesh-vm 'cd /Users/jinwoo/term-mesh/GhosttyTabs && xcodebuild \
  -project GhosttyTabs.xcodeproj \
  -scheme term-mesh \
  -configuration Debug \
  -destination "platform=macOS" \
  -only-testing:termMeshUITests/UpdatePillUITests \
  test'
```

### Xcode 유닛 테스트

```bash
ssh term-mesh-vm 'cd /Users/jinwoo/term-mesh/GhosttyTabs && ./scripts/test-unit.sh'
```

### 개별 Python 테스트

```bash
ssh term-mesh-vm 'cd /Users/jinwoo/term-mesh/GhosttyTabs && python3 tests/test_ctrl_socket.py'
```

## 8. 테스트 스크립트 동작 방식

`run-tests-v1.sh` / `run-tests-v2.sh`는 다음 순서로 실행된다:

1. **유저 체크** — `term-mesh` 유저가 아니면 즉시 종료
2. **빌드** — Debug 빌드 (DerivedData 경로 분리: `term-mesh-tests-v1` / `v2`)
3. **기존 인스턴스 정리** — `pkill` + 소켓 파일 삭제
4. **앱 실행** — `TERMMESH_UI_TEST_MODE=1` 환경변수로 실행
5. **소켓 대기** — `/tmp/term-mesh*.sock` 생성까지 폴링 (최대 120회)
6. **워크스페이스 부트스트랩** — Python 클라이언트로 초기 상태 세팅
7. **테스트 루프** — `test_*.py` 파일을 순차 실행 (실패 시 최대 3회 재시도)

## 9. 트러블슈팅

### 빌드 실패: stale module cache

```bash
ssh term-mesh-vm 'rm -rf ~/Library/Developer/Xcode/DerivedData/term-mesh-tests-*/Build/Intermediates.noindex/SwiftExplicitPrecompiledModules'
```

### 소켓 연결 실패

```bash
# 소켓 파일 존재 확인
ssh term-mesh-vm 'ls -la /tmp/term-mesh*.sock'

# 앱 프로세스 확인
ssh term-mesh-vm 'pgrep -la "term-mesh"'
```

### SSH 접속 불가

- VM에서 Remote Login이 켜져 있는지 확인
- UTM 네트워크 모드 확인 (Shared → Bridged 변경 시도)
- 방화벽 설정 확인: 시스템 설정 → Network → Firewall
