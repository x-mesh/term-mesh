# peer relay 성능 개선 제안서

**기준 커밋**: `0fd6bd97c7f5710c8680c65badf590e364d1c42b` (develop)
**작성일**: 2026-07-09
**생성 맥락**: x-build `peer-perf-proposal` 프로젝트 산출물 — 조사 원본은 `.xm/build/projects/peer-perf-proposal/`에 보존되어 있다.

## At a Glance

term-mesh의 peer relay(Connect to Peer) 기능은 네 가지 축에서 사용자가 실제로 체감하는 성능 문제를 안고 있다 — **입력 레이턴시**(타이핑 에코 지연), **렌더링/화면 갱신**(화면 갱신 버벅임), **연결 수명주기**(attach·재연결이 느림), **자원 사용**(CPU·메모리 부하). 이 문서는 코드 분석(정적) → 실측 시도(라이브 peer 세션 부재로 대부분 산정/추정으로 대체) → impact×effort 매트릭스 산정 → 안전 감사(금지계약 12개 항목 대조, 롤아웃 순서 검증) 순으로 조사해, 10개의 우선순위화된 개선 제안(P1-P10)을 도출했다. 실제 구현은 이 문서의 스코프 밖이며 후속 프로젝트로 분리한다.

### 상위 3개 제안

1. **P1 — 세션 멀티플렉싱(좁은 공유) + attach 병렬화** (Impact H · Effort S · client-only): pane마다 별도로 열던 handshake를 워크스페이스당 1회로 줄이고 attach 자체도 병렬화한다. 나쁜 WAN(RTT 300ms)·8-pane 워크스페이스의 재연결이 약 8.9초에서 개별 pane 지연 수준으로 수렴할 잠재력이 있으며, 부수적으로 heartbeat wakeup의 (N+1)-선형 증가 문제도 함께 해소된다.
2. **P2 — idle 자원 즉시 절감(10Hz 폴링 축소 + GPU occlusion 배선)** (Impact H · Effort S · client-only): 완전 유휴 상태에서도 확정적으로 발생하는 초당 10회 프로세스 wakeup과, peer relay 창이 백그라운드로 가도 전혀 회수되지 않는 GPU 자원(surface당 추정 1.5-6MB) 문제를 네트워크와 무관하게 즉시 축소한다.
3. **P3 — Capability 게이팅 플러밍** (Impact H · Effort M · 양측/4개 구현체): 압축·Native TCP(P8)처럼 와이어를 바꾸는 향후 개선 전부가 기대는 안전 협상 인프라를 완성한다. 단, 이번 감사에서 draft 원안의 "수정 지점"이 실제로는 Rust host 구현체 한 곳만 가리키고 있었고 Swift host/client·Rust CLI client 3곳이 누락돼 있었다는 스코프 오류가 발견되어, 최종안은 4개 구현체 전부를 대상으로 재정의했다(아래 §제안 P3, §감사 요약 참조).

### 제안 요약표 (P1-P10)

| P# | 제목 | Impact | Effort | 호환성 | 관련 C# |
|---|---|---|---|---|---|
| P1 | 세션 멀티플렉싱(좁은 공유) + attach 병렬화 | H | S | client-only | C8, C2 |
| P2 | idle 자원 즉시 절감 — 10Hz 폴링 축소 + GPU occlusion 배선 | H | S | client-only | C10, C11 |
| P3 | Capability 게이팅 플러밍 | H | M | 양측(4개 구현체 전부) | C20 |
| P4 | Rust ReplayBuffer 패턴 이식 + attach/resize 스타일 보존 | H | M(1단계)/L(2단계) | host-only(판단) | C15, C7, C3 |
| P5 | 원격 grid 조회 API 신설 | H | M | host-only | C22 |
| P6 | 재연결/슬립 복구 SLO — 타이머 통합 + 조기 배너 | H | M | 양측(효과 조건) | C18 |
| P7 | PtyData 브로드캐스트 배칭 | H | M | host-only(대칭 시 client도 가능) | C1 |
| P8 | 전송계층 최적화 — LAN Native TCP 직결 + WAN 조건부 압축 | H | L | 와이어 변경(capability 필요) | C13, C12 |
| P9 | Swift drop 가시화 + 자동 재동기화 | M | S | host-only | C17 |
| P10 | DataAck 정식 구현 | M | M | 양측(효과 조건) | C14 |

세부 근거·수정 지점·감사 결과는 아래 각 섹션을 참조.

## 제안

**정렬 규칙**: ① impact 내림차순(H>M>L) → ② 동일 impact 내 effort 오름차순(S<M<L) → ③ 동일 (impact,effort) 구간 내에서는 매트릭스·§결정이 명시한 선행조건 관계(다른 제안의 게이트인 항목을 먼저) 및 파급력(여러 R항목을 동시에 해결하는 항목을 먼저) 순으로 배열한다.

**판단 편차 고지**: C19(배압/재동기화 전체 재설계)는 원 지시의 "C19+C20 패키지" 예시와 달리 탈락 후보로 분류했다. draft.md 189행 R11 결정("채택 — 2단계: ①카운터+dlog ②drop 감지 시 자동 재스냅샷, ③배너/배압정책 전체는 기각·후속분리")이 이미 C19를 이번 제안서 범위에서 제외하기로 확정했고, 매트릭스 C19 행 비고도 "다른 후보의 하드 선행조건은 아님"이라 명시한다. C20이 실제로 하드 선행조건인 대상은 C12·C13뿐이다(C3·C14는 매트릭스가 "C20 대상 아님"으로 명시). 따라서 C19는 P9(C17+R11 2단계)로 대체된 것으로 보고 부록C에 배치했다.

---

### P1. 세션 멀티플렉싱(좁은 공유) + attach 병렬화
- 축: ③ | Impact: H(산정 — R6·R7 동시해결하는 매트릭스 전체 최대 파급력 후보) | Effort: S | 호환성: client-only
- LAN/WAN: 둘 다 유효, WAN서 효과 더 큼(handshake N회→1회 절감폭이 RTT에 비례) | SSH-한정 여부: 아님 — Native TCP 전환 이후에도 유효
- 근거: `Sources/PeerRelaySession.swift:836-842`@0fd6bd97(hostToRelay가 surfaceID를 `_`로 버림) / `Sources/PeerRelayWorkspaceWindowController.swift:1049-1075`@0fd6bd97(TaskGroup 없는 순차 for-await) / `swift/PeerProto/Sources/PeerProto/PeerServer.swift:676`@0fd6bd97(host는 이미 다중attach 지원, architecture-verify 검증2) — C8, C2
- 내용: 워크스페이스당 이미 인증된 subscriptionSession이 있는데도 client가 pane마다 완전히 새 PeerSession+NWConnection을 열어 N번 handshake를 반복한다. host는 이미 세션 하나로 다중 attach를 무제한 수용하도록 검증됐으므로(architecture-verify 검증2), client의 hostToRelay 파이프를 surfaceID 필터로 좁혀 subscriptionSession을 재사용하면 host 변경 없이 handshake를 N회에서 1회로 줄인다. 세션을 공유해도 attachSurface RPC 자체는 여전히 개별 호출이 필요하므로 TaskGroup으로 병렬화하면 순차 누적이 max(개별 pane 지연)로 수렴한다. 두 변경은 배타적이지 않고 상호 보강 관계이며 R7 결정이 이미 이 조합을 채택했다.
- 수정 지점:
  - `Sources/PeerRelaySession.swift:836-842` — `case .ptyData(_, _, let data)` 필터를 `case .ptyData(let sid, _, let data) where sid == self.surfaceID`로 변경
  - `swift/PeerProto/Sources/PeerProto/PeerSession.swift` — 신규 NWConnection을 열지 않고 워크스페이스의 subscriptionSession을 주입받는 팩토리 오버로드 추가
  - `Sources/PeerRelayWorkspaceWindowController.swift:1049-1075` — `for surfaceID in missingSurfaceIDs {...}` 순차 루프를 `withThrowingTaskGroup`로 교체, 동시성 상한 적용
- 기대 효과: t6 지표4 기준 WAN(RTT≈300ms) N=8 attach 약 8.9초(R8 SLO 5초 초과)가 max(개별 지연)로 수렴[산정+추정]; R6의 (N+1)-선형 heartbeat wakeup 문제도 세션 공유 시 부수적으로 해소[산정]
- 금지계약: 통과 — F1-F8(ESC prefix/peerPendingInputTail/bracketed-paste/Kitty/query_filter/OSC52/key-text분리/acceptRelay) 전부 해당없음(수정 지점이 client측 hostToRelay 필터·세션 팩토리·attach TaskGroup이며, 호스트측 ESC/paste 상태기계(`GhosttyPaneSurfaceProvider.swift`)를 전혀 건드리지 않음). F9(소켓 threading)·F10(focus policy) 통과 — 신규 `DispatchQueue.main.sync`·`makeFirstResponder` 없음. F11·F12 해당없음.
- 회귀 게이트: test_peer_input_bracketed_paste_split_close.py(하드) — 근거는 아래 감사 소견 참조. test_peer_input_esc_freeze_regression.py는 코드 경로 비중첩으로 선택 사항.
- 검증수단: 수동 2-노드 — N-pane 세션 공유 활성화 후 각 pane이 자신의 surfaceID에 해당하는 PtyData만 수신하는지(다른 pane 내용 혼입 없는지) 확인. 자동화는 P5(grid 조회 API) 완료 후 가능.
- ⚠ 감사 소견: 축 라벨이 "③"만 표기돼 있으나 `hostToRelay`는 호스트→클라이언트 PtyData 라우팅(렌더링 입력)이라 축②(렌더링) 성격도 있다 — surfaceID 필터 버그는 렌더 정합성 문제(잘못된 pane에 다른 pane 화면 표시)로 직결된다. 또한 P1은 여러 pane이 하나의 subscriptionSession을 공유하는 신규 구조이므로, pane close 시 다른 pane에 귀속된 in-flight PtyData/paste 바이트가 세션과 함께 잘못 정리·오배송되지 않아야 한다 — `test_peer_input_bracketed_paste_split_close.py`(명칭이 정확히 이 시나리오)가 이 신규 위험을 가장 직접적으로 커버하며, ESC/paste 상태기계 코드 자체를 건드려서가 아니라 이 신규 결합 위험 때문에 하드 게이트가 필요하다. 심각도: 중간(회귀 게이트로 완화 가능, 채택 차단 사유는 아님).

### P2. idle 자원 즉시 절감 — 10Hz 폴링 축소 + GPU occlusion 배선
- 축: ④ | Impact: H(산정, 확정치 — C10은 상수기반 100% 확정, C11은 pitfalls-verify 검증1 high confidence) | Effort: S | 호환성: client-only
- LAN/WAN: 둘 다 동일(네트워크 무관, 순수 로컬 자원) | SSH-한정 여부: 아님
- 근거: `daemon/term-mesh-peer-relay/src/main.rs:667`@0fd6bd97(recv_timeout 100ms) / `Sources/PeerRelayWindowController.swift`(199줄 전체)@0fd6bd97 + `Sources/PeerRelayWorkspaceWindowController.swift`(1654줄 전체)@0fd6bd97(occlusion 배선 0건) — C10, C11
- 내용: 서로 다른 언어/파일의 독립적 낭비이지만 R6이 "가장 확정적인 두 항목"으로 페어링했고 둘 다 즉시 축소 가능·와이어 변경 불요라는 공통점이 있어 하나의 제안으로 묶는다. `term-mesh-peer-relay`는 완전 유휴 상태에도 `recv_timeout(100ms)`로 초당 10회 wakeup을 결정론적으로 발생시킨다. peer relay 창 2종은 `TerminalSurface`를 `GhosttySurfaceScrollView` 포탈 없이 직접 인스턴스화해 occlusion 알림 구독·`setRendererRealized` 호출이 전무하다 — 정상 로컬 pane은 비가시 5초 후 GPU를 회수하지만 relay 창은 백그라운드로 가도 전혀 회수되지 않는다. upstream 수정(`ghostty_surface_set_renderer_realized`)은 이미 트리에 있으므로 두 컨트롤러에 배선만 추가하면 된다.
- 수정 지점:
  - `daemon/term-mesh-peer-relay/src/main.rs:667` — `rx.recv_timeout(Duration::from_millis(100))` 타임아웃 확대 또는 블로킹 recv+조건변수 전환
  - `Sources/PeerRelayWindowController.swift`(전체 199줄, 창 생성/해제 지점) — `NSWindow.didChangeOcclusionStateNotification` 구독 + `setRendererRealized` 배선
  - `Sources/PeerRelayWorkspaceWindowController.swift`(전체 1654줄, pane 생성/포커스 지점) — 동일 배선
- 기대 효과: idle CPU wakeup 100% 확정 축소[산정]; pane당 GPU 잔존 1.5-6MB 회수 가능(바이트는 과거 조사 인용치, 재검증 플래그 있음)[산정(배선부재)+추정(바이트)]; 회귀테스트 신규 부담 없음(와이어 무변경)
- 금지계약: 통과 — F1-F8·F12 해당없음(idle 폴링/occlusion 배선은 입력 재조립·query_filter·key-text분리와 무관). F9 해당없음(occlusion 알림 처리는 소켓 커맨드가 아닌 NSNotificationCenter 콜백이며 AppKit/렌더 상태 직접 조작이라 정책상 MainActor 허용 범주와 일관). F10 해당없음. **F11(display link/수동 폴링 루프 금지) 통과 — 방향이 오히려 금지목록 취지에 부합**: `main.rs:667` 변경은 폴링 주기 확대 또는 blocking recv/condvar 전환으로 wakeup *빈도를 줄이는* 것이지 신규 폴링·display-link 루프 추가가 아니다.
- 검증수단: R15가 제시한 3가지 후보(수동 2-노드/XCUITest/P5 grid 조회 API) 중 재가시 시 화면이 정상 그려지는지는 수동 2-노드로 확인 가능하나, **GPU 메모리 회수 자체는 셋 다 검증 불가**(전부 화면 텍스트/속성만 확인) — 아래 감사 소견 참조.
- ⚠ 감사 소견(2건):
  1. 축 라벨이 "④"만 표기돼 있으나 GPU occlusion/`setRendererRealized` 배선은 렌더링 축② 그 자체다(비가시→가시 전환 시 렌더러 재생성 타이밍에 직접 관여) — R15 렌더축 검증수단 요구가 라벨 누락으로 빠지지 않도록 위 검증수단 필드를 추가했다.
  2. R15 검증수단 후보 3가지 중 어느 것도 GPU 메모리 회수 여부를 직접 검증하지 못하는 방법론적 공백이 있다 — 실제 검증에는 Instruments/`footprint` 런타임 계측(`[[ghostty-metal-renderer-gpu-leak]]` 메모리와 동일 레시피)이 필요하며 이는 R15의 3가지 후보 목록에 없다. 추가로 R15가 명시한 확정 root-cause 3건 중 **h3 "relay wakeup 미연결"은 명칭상 P2가 고치려는 결함(occlusion 배선 부재로 relay 창이 백그라운드에서 렌더 자원을 회수·재생하지 못함)과 동일 계열일 가능성이 높다** — 원 조사 문서에 직접 접근하지 못해 100% 동일 여부는 미확정이나, P2 착수 전 h1(focus-gated display_link)·h3·h4(0-size/late layout) 원 조사 결과를 재확인해 중복수정/누락 여부를 교차검증할 것을 착수 조건으로 권고. 심각도: 중간(검증 인프라 공백 + 잠재적 중복작업 리스크, 안전 위반은 아님).

### P3. Capability 게이팅 플러밍
- 축: ③ | Impact: H(산정, 확정 — 모든 와이어레벨 성능개선의 공통 하드 선행조건, 미구현이 전수검색으로 확정) | Effort: M | 호환성: 양측(4개 구현체 전부: Rust host/CLI client, Swift host/client)
- LAN/WAN: 둘 다 무관하게 필요(협상 메커니즘 자체) | SSH-한정 여부: 아님
- 근거: `proto/peer/v1/README.md:32`@0fd6bd97(Evolution rule 3) / `daemon/term-meshd/src/peer/connection.rs:427`@0fd6bd97(`capabilities: vec![]`) / `daemon/term-meshd/src/peer/server.rs:344,707,1055,1261`@0fd6bd97(4곳 모두 빈 배열 고정 — Rust host) / `swift/PeerProto/Sources/PeerProto/PeerServer.swift:752-758`@0fd6bd97(Hello 생성에 capabilities 대입 자체가 부재 — Swift host) / `swift/PeerProto/Sources/PeerProto/PeerSession.swift:430-448`@0fd6bd97(동일 — Swift client) / `daemon/term-mesh-cli/src/peer.rs:56`@0fd6bd97(`capabilities: vec![]` — Rust CLI client) — C20 [t8 감사로 정정된 인용]
- 내용: capability 게이팅이 proto 스키마상 필드(`Hello.capabilities`)는 준비돼 있으나 실제로 읽고 분기하는 코드가 4개 구현체(Rust host/CLI client, Swift host/client) 어디에도 없다 — 생성측은 빈 배열 고정(Rust 5곳, CLI 1곳) 또는 대입문 자체 부재(Swift host/client)로 사실상 미동작이다. P8(압축/Native TCP)을 무중단 배포하려면 신버전이 구버전 상대를 만났을 때 우아하게 폴백할 협상 메커니즘이 선행돼야 한다. 신규 wire 필드는 불요하고 로직만 신규다 — 4개 Hello 생성 지점에서 실제 지원 기능 목록을 채우고 상대측 capabilities를 읽어 기능별로 분기하는 판정 로직을 추가한다.
- 수정 지점: (t8 감사 소견 반영 재작성 — 4개 구현체 전부)
  - Rust host: `daemon/term-meshd/src/peer/connection.rs:427` + `daemon/term-meshd/src/peer/server.rs:344,707,1055,1261` — `capabilities: vec![]`를 실제 지원 기능 열거로 교체
  - Swift host: `swift/PeerProto/Sources/PeerProto/PeerServer.swift:752-758` — Hello 생성에 capabilities **대입문 신설** (현재 protocolVersion/displayName/appVersion/peerID만 설정, proto3 기본 빈 배열이 암묵 전송됨)
  - Swift client: `swift/PeerProto/Sources/PeerProto/PeerSession.swift:430-448` (`sendHello`) — 동일하게 대입문 신설
  - Rust CLI client: `daemon/term-mesh-cli/src/peer.rs:51-56` — `capabilities: vec![]` 교체
  - 공통: 상대측 capabilities 파싱 후 기능별 분기 판정 로직 신규 추가 (4개 구현체 수신측 대칭)
- 기대 효과: P8의 안전 배포를 가능케 하는 게이트[확정 — 이것 없이는 P8 배포 자체가 원천 불가]; 향후 GridSnapshot 등 추가 와이어 변경의 재사용 가능한 공통 인프라
- 금지계약: 통과 — F1-F12 전부 해당없음(Hello 생성/파싱 로직 변경이며 ESC/paste/Kitty/query_filter/OSC52/key-text/acceptRelay/threading/focus/display-link/쿼리왕복 어느 계약과도 코드 경로가 겹치지 않음).
- 롤아웃: 다른 와이어 변경 제안(P8)의 하드 선행조건이라는 순서 자체는 옳다. 단 아래 감사 소견 참조 — "완료"의 실제 커버리지가 원안보다 좁다.
- ⚠ 감사 소견(심각 — R14 하드 선행조건의 실효성 문제): `수정 지점`에 적힌 4개 지점 `swift/PeerProto/Sources/PeerProto/PeerServer.swift:344,707,1055,1261`을 코드로 직접 확인한 결과 **실제로는 Swift 파일이 아니라 Rust `daemon/term-meshd/src/peer/server.rs`의 동일 라인번호였다** — `grep -n "capabilities" swift/PeerProto/Sources/PeerProto/PeerServer.swift` 결과 0건(파일 전체 1031줄에 "capabilities" 문자열 자체가 없음), `grep -n "capabilities" daemon/term-meshd/src/peer/server.rs` 결과 344/707/1055/1261 전부 `capabilities: vec![],`로 정확히 일치(파일 총 1317줄, 라인 범위 내). 즉 `connection.rs:427` + `server.rs:344,707,1055,1261` = **5곳 전부 Rust daemon host 구현체 하나**(같은 `daemon/term-meshd/src/peer/` 모듈)이며, "4개 구현체 전부(Rust host/CLI client, Swift host/client)"라는 커버리지 주장과 달리 **Rust host 구현체 단 하나만** 다룬다. 직접 확인한 실제 상황: (a) Swift host의 진짜 Hello 생성 지점은 `PeerServer.swift:752-758`(`sendEnvelope { env in var h = ...; env.hello = h }`)이며 여기엔 `capabilities` 대입 자체가 없다(protocolVersion/displayName/appVersion/peerID만 설정 — proto3 기본값인 빈 배열이 암묵 유지됨. "필드를 vec![]에서 채우기"가 아니라 "존재하지 않는 대입문을 신설"해야 하는, 원안과 다른 수정 패턴). (b) Swift 클라이언트의 Hello 생성(`PeerSession.swift:430-448` `sendHello`, "capabilities" grep 0건)도 미포함. (c) Rust CLI 클라이언트도 미포함 — `daemon/term-mesh-cli/src/peer.rs:56`에 `capabilities: vec![]`가 실제로 존재함을 grep으로 직접 확인했으나 P3의 4개 지점 어디에도 없다. **결론: P3을 "완료"로 표시해도 Swift host·Swift client·Rust CLI client 3개 구현체는 여전히 빈 capabilities를 보낸다.** P8이 "P3 완료"를 하드 선행조건으로 건다고 했을 때, 이 완료 판정이 실제로는 4개 구현체 중 1개만 커버한 상태로 내려질 위험이 있다 — 실패 방향이 fail-closed(기능이 그냥 비활성 상태로 남음)라 즉각적 보안·정합성 사고로 이어지진 않지만, R14가 요구하는 "롤아웃 순서"의 전제(선행조건 범위의 정확성) 자체가 틀렸다는 점에서 이번 감사에서 발견한 가장 심각한 사항으로 별도 플래그한다. 수정 방향: P3의 수정 지점을 (1) `daemon/term-meshd/src/peer/connection.rs:427` + `server.rs:344,707,1055,1261`(Rust host, 원안 유지), (2) `swift/PeerProto/Sources/PeerProto/PeerServer.swift:752-758`(Swift host, 신규 발견), (3) `swift/PeerProto/Sources/PeerProto/PeerSession.swift:430-448`(Swift client, 신규 발견), (4) `daemon/term-mesh-cli/src/peer.rs:51-56`(Rust CLI client, 신규 발견) 4개 실제 구현체로 재작성할 것을 권고.
- 감사 소견 처리: 리더가 P3의 근거·내용·수정 지점을 소견 권고대로 4개 구현체 기준으로 재작성 완료 (2026-07-09). 위 소견 원문은 감사 기록으로 보존.

### P4. Rust ReplayBuffer 패턴 이식 + attach/resize 스타일 보존
- 축: ②③ | Impact: H(산정 — R4 1순위 권고, "가장 적은 신규코드로 가장 체감되는 개선", architecture-verify 검증1 근거7이 동작검증된 참조구현으로 확인) | Effort: M(1단계 C15+C7 기준; 2단계 C3 포함 시 L) | 호환성: host-only(판단 — 비고 참조)
- LAN/WAN: 둘 다 유효, WAN서 재연결 빈도 영향 상대적으로 큼 | SSH-한정 여부: 아님
- 근거: `daemon/term-meshd/src/peer/surface.rs:43,51-75`@0fd6bd97(REPLAY_CAPACITY_BYTES=64KB raw byte ring buffer) / `Sources/GhosttyPaneSurfaceProvider.swift:312-331`@0fd6bd97(plain-text 스냅샷+Ctrl-L 강제리드로우, host 화면도 함께 깜빡임) / `swift/PeerProto/Sources/PeerProto/PeerServer.swift:899`@0fd6bd97(initialSeq=0 고정) — C15, C7, C3
- 내용: attach·재연결·리사이즈 세 상황 모두 host가 plain-text만 보내 ANSI 스타일이 유실되고, 이를 땜질하는 Ctrl-L 강제 주입이 host 로컬 화면(다른 사용자의 화면일 수 있음)까지 깜빡이게 만든다. Rust `PtySurface`는 이미 64KB raw-byte 링버퍼로 attach마다 재생해 스타일을 보존하는 동작 검증된 패턴을 갖고 있어, 이를 Swift host로 이식하면 가장 적은 신규 코드로 스타일 유실과 Ctrl-L 부작용을 동시에 없앤다. 단 리사이즈(§비용분석-3)는 "새 크기 기준 신선한 스냅샷"이 필요해 이 후보로는 해결되지 않는다 — 근본 해결은 cell-level GridSnapshot(부록C C21 참조)이 유일한 해법으로 남는다. `resumeFromSeq` 필드가 이미 proto에 있으므로, 1단계(C15+C7) 채택을 발판 삼아 2단계로 seq 기반 증분재생(C3)까지 단계적으로 확장한다 — R4 원문이 명시한 대로 배타적 선택이 아니다.
- 수정 지점:
  - Swift host(PeerServer) 측 surface별 raw-byte ring buffer 신설 — `daemon/term-meshd/src/peer/surface.rs:43`(REPLAY_CAPACITY_BYTES=64*1024)와 동일 용량으로 `swift/PeerProto/Sources/PeerProto/PeerServer.swift`의 attachments 관리 지점(`:676` 부근)에 추가
  - `Sources/GhosttyPaneSurfaceProvider.swift:312-331` — attach/resize 시 plain-text `readPaneSnapshot` 전송을 ring buffer 재생으로 교체, Ctrl-L 강제 주입 로직 제거
  - `swift/PeerProto/Sources/PeerProto/PeerServer.swift:899` — `r.initialSeq = 0` 고정을 ring buffer 도입에 맞춰 조정
  - (2단계, C3) `PeerServer.swift:899` 부근 — `resumeFromSeq` 실제 파싱+seq 기반 부분재생 신규 구현(호환성은 착수 전 host-only 여부 재확인 — 비고 참조)
- 기대 효과: attach/재연결 시 ANSI 스타일 100% 보존[산정, 참조구현 존재]; host 로컬 화면 부작용(Ctrl-L 깜빡임) 제거[산정]; 2단계 완료 시 짧은 blip 재전송 페이로드를 "놓친 만큼만"으로 절감[추정]. 검증에는 P5(C22) 필요(R15)
- 비고: R4 원문은 이 후보의 호환성을 "client(byte_seq 추적) 양쪽 업데이트 필요"라 서술하나, 같은 후보의 장단점 문단은 "무조건 전량재생"이라 byte_seq가 불요하다고도 서술한다. 부록A #7(hostToRelay가 이미 임의 바이트를 그대로 통과)에 근거해 1단계는 host-only가 코드 사실에 더 부합한다고 판단했다 — 착수 전 재확인 권고.
- 금지계약: 통과, 단 구현 시 준수사항 1건 — F1-F4·F6-F8·F12 해당없음(교체 대상인 plain-text 스냅샷·Ctrl-L 로직은 ESC/paste/Kitty/query_filter/OSC52/key-text분리와 무관). 아래 감사 소견의 F9 준수사항을 전제조건으로 "통과" 판정.
- 회귀 게이트: test_peer_input_esc_freeze_regression.py, test_peer_input_bracketed_paste_split_close.py(하드) — 근거는 아래 감사 소견 참조. 현재 draft에 이 필드가 누락돼 있었다.
- 롤아웃: 1단계(C15+C7, host-only 판단)는 client 변경 불요 — 구버전 client도 raw-byte replay를 있는 그대로 렌더링 가능(부록A #7 근거, 프레이밍 자체는 불변). 2단계(C3, resumeFromSeq)는 명시적으로 "양측" — client가 byte_seq를 추적해 attach 요청에 실어야 한다. `resumeFromSeq` 필드는 이미 proto에 존재해 신규 capability 게이팅(P3)이 하드 선행조건은 아니나(구버전 상대는 자동으로 0을 보내/받아 전체재생 폴백), seq 정합성(랩어라운드 등) 자체가 신규 버그 표면이라 2단계 착수 전 별도 회귀 테스트 신설이 필요하다. **호환성 라벨 자체가 t5 매트릭스·본문 비고에서 이미 "재확인 권고"로 불확정 표시돼 있으므로, 안전 감사 관점에서는 확정 전까지 1단계도 "양측"으로 보수적으로 취급할 것을 권고**.
- 검증수단: P5(원격 grid 조회 API) 필요 — 제안문이 이미 스스로 명시(R15 인지 확인됨). display_link/wakeup 타이밍 자체는 건드리지 않으므로(콘텐츠만 교체, 타이밍 무변경) h1/h3/h4 회귀확인은 불요.
- ⚠ 감사 소견: **F9(소켓 threading policy) 조건부 준수 필요** — ring buffer append가 `PtyTapHub` tap 콜백 경로(코드 주석상 "Ghostty의 IO reader thread에서 renderer_state.mutex 하에 호출되므로 non-blocking 필수", `GhosttyPaneSurfaceProvider.swift:8-11`)에서 매 tap마다("초당 수천 번") 실행될 것이므로, ring buffer 쓰기는 이 non-blocking 제약을 유지한 채(off-main) 이뤄져야 하며 MainActor 홉을 매 tap마다 추가해선 안 된다 — 이 제약이 제안문 수정 지점에 명시돼 있지 않아 구현 시 반드시 준수사항으로 못박을 것을 권고. 또한 pitfalls §5.5가 명시한 규칙("`GhosttyPaneSurfaceProvider.swift` 근방을 건드리는 어떤 성능 리팩터링도 기존 회귀 테스트를 하드 게이트로 돌려야 한다")을 P4가 정확히 충족하는 대상인데도(수정 지점이 `:312-331`) 현재 draft에 회귀 게이트 필드가 누락돼 있었다 — 위에 추가함. 마지막으로 순서 소견: P4는 검증에 P5를 필요로 하는데(자체 명시), 문서의 정렬 규칙(③ 선행조건 항목을 먼저 배열)과 달리 P4가 P5보다 앞서 나열돼 있다 — 정렬은 impact/effort 기준이지 착수 순서가 아니라는 점을 최종 제안서에 명시하거나, P4 착수는 P5 완료 후로 순서를 별도 고정할 것을 권고. 심각도: 중간(안전 위반은 아니나 구현 시 누락되면 hot-path 성능 저하 또는 검증 공백으로 이어질 수 있음).

### P5. 원격 grid 조회 API 신설
- 축: ②(검증 인프라) | Impact: H(산정, 검증완료 — R15 하드 요구사항의 직접 대상) | Effort: M | 호환성: host-only
- LAN/WAN: 둘 다 무관(검증 인프라 자체) | SSH-한정 여부: 아님
- 근거: `.xm/solver/problems/term-mesh-peer-workspace에서-원격-peer-pane의-화면-갱신이-느리/phases/05-close/summary.json:5`@0fd6bd97(`verification_passed: false`) — C22, R15
- 내용: 원격 relay pane의 grid 상태를 조회하는 host socket API가 없어 렌더링 축 변경의 자동검증이 원천적으로 불가능하다 — 과거 "원격 peer pane 화면 갱신 느림" fix가 이 공백 때문에 `04-verify` phase 자체가 없는 채로 "빌드만 성공, 동작 미검증"으로 마감된 선례가 있다. P4(렌더 축 제안)가 선정됐으므로 R15 규칙에 따라 이 API 신설을 반드시 함께 다룬다. 기존 read 계열 소켓 커맨드 패턴을 재사용하되 `AutoReplyPoller`류의 과거 교훈(동기 호출 금지, `SurfaceReadLease` 패턴 필요)을 그대로 적용한다.
- 수정 지점:
  - 신규 socket 커맨드 추가(기존 read/query 계열과 동일한 디스패치 테이블 — 정확한 파일은 explorer 후속 확인 필요) — 원격 pane의 현재 grid 텍스트/속성 스냅샷을 반환하는 `surface.query_grid`류 명령
  - 동기 `ghostty_surface_read_text` 직접 호출 금지, `SurfaceReadLease` 패턴 적용(CLAUDE.md 소켓 threading policy 참조)
  - `tests_v2/`에 이 API를 사용하는 검증 헬퍼 추가(향후 렌더 축 회귀테스트가 재사용)
- 기대 효과: P4를 포함한 향후 모든 렌더 축 제안이 "빌드 성공"이 아니라 "동작 검증됨"으로 완결 가능[산정]; 1회 구축으로 렌더 축 전체가 재사용하는 공통 검증 인프라
- 금지계약: 통과 — F1-F8·F11·F12 해당없음(신규 조회 API는 기존 상태를 읽기만 하며 ESC/paste/Kitty/query_filter/OSC52/key-text/acceptRelay/display-link 어느 계약도 변경하지 않음). **F9(소켓 threading policy) 자체 준수 확인** — 제안문이 이미 "동기 `ghostty_surface_read_text` 직접 호출 금지, `SurfaceReadLease` 패턴 적용"을 명시해 AutoReplyPoller 메인스레드 hang 재발 방지 교훈(pitfalls §4)을 스스로 정확히 반영했다. F10 해당없음.
- 검증수단: (메타) 본 항목 자체가 R15의 검증수단이라 자기 자신에 대한 필드는 순환 정의가 된다 — 아래 감사 소견 참조.
- ⚠ 감사 소견: P5 자체의 정확성을 누가 검증하는지가 새 리스크다. grid 조회 API가 실제 host grid 상태를 정확히 반영하지 못하면(구현 버그) 이를 딛고 서는 P4·P9 등 다른 렌더 축 제안의 자동검증 전체가 거짓 양성/거짓 음성을 낼 수 있다 — 검증 인프라 자체가 미검증이라는 순환 위험. 최초 구현 시에는 수동 2-노드 비교로 API 자체의 정확성을 먼저 검증한 뒤에만 다른 제안의 자동검증 수단으로 승격할 것을 권고(1회성 검증 선행 조건). 심각도: 낮음(인지 후 쉽게 완화 가능).

### P6. 재연결/슬립 복구 SLO — 타이머 통합 + 조기 배너
- 축: ③ | Impact: H(산정·추정 — R8 SLO "자동 복구 개시 ≤40초" 달성의 직접 수단) | Effort: M | 호환성: 양측(효과 조건 — 하트비트↔SSH 강제재시작 연동 여부 코드로 미확인)
- LAN/WAN: 둘 다 해당(특히 WAN/sleep-wake) | SSH-한정 여부: 부분적(SSH ServerAlive 계층은 Native TCP 도입 시 재설계 필요)
- 근거: `Sources/PeerRelaySession.swift:702-710`@0fd6bd97(앱 하트비트 10s/30s dead) / `Sources/PeerSSHTunnel.swift:244-245`@0fd6bd97(SSH ServerAlive 15s×3≈45s) / `Sources/PeerSSHTunnel.swift:339-364,368`@0fd6bd97(재연결 백오프) — C18
- 내용: 죽은 연결 감지 계층이 앱 하트비트(30-40초)와 SSH ServerAlive(45초)로 독립적으로 중첩돼 있고 연동 여부가 코드로 미확인이다 — 연동이 안 돼 있다면 사용자는 30-40초에 "끊김"을 인지하지만 실제 재연결은 45초까지 시작조차 안 되는 사각구간이 생긴다. R8 결론대로 "재연결을 더 빠르게"가 아니라 "더 빨리 알아채고 알리고, 감지-복구를 확실히 연결"하는 것이 우선이므로, 신규 UI·프로토콜 변경이 불요한 두 수단(타이머 통합, 즉시 배너)을 채택한다. 기존 `PeerRelayBanner`를 "확정 dead"가 아니라 첫 heartbeat 미스 시점(~10-15초)에 optimistic "재연결 중" 상태로 조기 발동시키면 신규 UI 없이 시각피드백 SLO(≤15초)를 달성한다. 타이머 단축(10s→5s 등)은 R6 idle 비용과 직접 트레이드오프이므로 P2 적용 후 재평가 대상으로 보류한다.
- 수정 지점:
  - `Sources/PeerRelaySession.swift:702-710` 부근(dead 판정 시 `transport.close()` 호출부) — SSH 터널 강제 재시작을 명시적으로 트리거하도록 연결(연동 여부 코드 확인이 선행)
  - `PeerRelayBanner`/`PeerRelayBannerPresenter` 관련 파일 — "확정 dead" 트리거 조건에 "첫 heartbeat 미스"(~10-15초) 시점의 optimistic 상태 추가
- 기대 효과: 자동 복구 개시가 최악 45초→30-40초로 단축[산정, 연동 성립 시]; 무피드백 구간(현재 30-40초)을 10-15초로 단축해 SLO(≤15초) 달성[산정, 신규 UI 불요]
- 금지계약: 통과 — F1-F5·F7·F8·F11·F12 해당없음(타이머·배너 UI 변경이며 ESC/paste/Kitty/query_filter/key-text/acceptRelay/display-link/쿼리왕복과 무관). F6 해당없음. F9 해당없음(배너 UI 갱신은 AppKit 상태 변경으로 MainActor 허용 범주). **F10(focus policy) 조건부 확인 필요** — 아래 감사 소견 참조.
- 롤아웃: **양측(효과 조건)** — 제안 라벨과 일치. 와이어 변경은 아니지만(client 로컬 로직 조정), "하트비트 dead 판정 → SSH 강제 재시작" 연동 여부가 코드로 미확인(R8 원문이 명시한 리스크)이므로 구현 착수 전 코드 확인이 사실상의 선행조건이다 — `transport.close()`↔SSH `terminationHandler` 연동 여부를 explorer로 먼저 확인하는 단계를 P6 착수 조건으로 명시 권고. CONTEXT[C2]의 "호스트측 재생 시맨틱=버전 사각지대" 패턴과는 다른 종류의 불확실성(재생 시맨틱이 아니라 감지-복구 연동 여부)이므로 해당 경고를 그대로 적용하지는 않는다.
- ⚠ 감사 소견: "확정 dead 이전 첫 heartbeat 미스 시점(~10-15초)에 조기 배너를 optimistic 발동"하는 부분이 기존 `PeerRelayBanner`(비모달 UI로 추정)를 재사용한다고 서술하나, 조기 발동이 윈도우 활성화·`makeFirstResponder` 등 focus 이동을 동반하지 않는지는 제안문에 명시가 없다 — 소켓 focus policy(F10)가 규정하는 "명시적 focus-intent 커맨드 외 focus 이동 금지"의 정신이 UI 트리거 조기화에도 동일하게 적용돼야 한다는 점을 구현 시 재확인 조건으로 권고(현재 통과 판정이나 조건부). 심각도: 낮음.

### P7. PtyData 브로드캐스트 배칭
- 축: ②④ | Impact: H(산정·추정 — R1 구간C가 지목한 배칭 부재, "초당 수천 번" 발동 가능) | Effort: M | 호환성: host-only(대칭 위해 client도 가능)
- LAN/WAN: 둘 다 유효(WAN 대역폭에도 도움) | SSH-한정 여부: 아님 — Native TCP 이후에도 유효
- 근거: `Sources/GhosttyPaneSurfaceProvider.swift:81-94`@0fd6bd97(PtyTapHub.broadcast, "초당 수천 번" 주석) / `swift/PeerProto/Sources/PeerProto/PeerServer.swift:926-947`@0fd6bd97(pumpByteStream, 1chunk=1Envelope) — C1
- 내용: PTY tap이 발동할 때마다(초당 수천 회 가능) 배칭 없이 개별 Envelope 인코딩+프레이밍+write() syscall이 그대로 나간다. 기존 검증된 `RelayResizeCoalescer`(24ms) 패턴을 `pumpByteStream`에 재사용해 4-8ms 코얼레싱 윈도우+최대 바이트 캡을 추가하면 syscall/Envelope 오버헤드를 줄인다. 이 변경은 PtyData 필드 자체를 바꾸지 않는 와이어 불변 변경이라 P3(capability 게이팅)의 선행조건 대상에서 명시적으로 제외되며, 입력측 이중 ESC 홀드(t3 신규발견)와도 완전히 별개 경로라 최적화금지목록의 ESC 판별 알고리즘을 건드리지 않는다(R13 충족).
- 수정 지점:
  - `swift/PeerProto/Sources/PeerProto/PeerServer.swift:926-947` — `pumpByteStream`의 1:1 매핑 루프에 코얼레싱 윈도우(4-8ms)+최대 바이트 캡 추가, `RelayResizeCoalescer`(`Sources/PeerRelaySession.swift:318-321`, delayMs:24) 패턴 참고
  - replay ring(P4 구현 시 신설)과 broadcast 양쪽 이중 clone 비용(`daemon/term-meshd/src/peer/surface.rs:233-238` 패턴 참고) 고려해 청크 크기 설계
- 기대 효과: 고빈도 PTY tap 구간의 syscall/Envelope 오버헤드 절감[추정, 임시계측(P10 또는 dlog) 권장]; WAN 대역폭 절감 부수효과[추정]
- 금지계약: 통과, 조건부 향후 주의 1건 — F1-F4(ESC prefix/peerPendingInputTail/bracketed-paste/Kitty) 해당없음: 수정 대상(`PeerServer.swift:926-947` pumpByteStream)은 호스트→클라이언트 **출력**(PtyData 브로드캐스트) 경로이고, ESC/paste 상태기계는 클라이언트→호스트 **입력** 재조립 경로(`GhosttyPaneSurfaceProvider.swift`, 별도 파일)에 있어 코드 경로가 겹치지 않는다(제안문 자체도 "입력측 이중 ESC 홀드와 완전히 별개 경로"라 정확히 서술). F6-F12 해당없음. **F5(query_filter.rs) 조건부** — 현재 스코프(Swift `pumpByteStream`)는 Rust `query_filter.rs`와 무관해 해당없음이 맞으나, 아래 감사 소견 참조.
- 회귀 게이트: test_peer_input_bracketed_paste_split_close.py(하드, 원 지시 지정) — 근거는 아래 감사 소견에서 명확히 함(코드 인접성이 아니라 신규 도입 위험 때문). test_peer_input_esc_freeze_regression.py는 코드 경로 비중첩으로 선택 사항.
- 검증수단: 수동 2-노드(고빈도 타이핑/paste 시 배칭 후에도 화면이 유실 없이 정확히 반영되는지) + 임시계측(P10 또는 dlog)으로 배칭 전후 RTT/처리량 비교 — 제안문이 이미 명시. h1/h3/h4 회귀확인은 불요(전송 cadence만 변경, 렌더러 자체의 display_link/wakeup 스케줄링은 건드리지 않음).
- ⚠ 감사 소견(2건):
  1. P7이 신설하는 코얼레싱 버퍼(4-8ms 윈도우)는 pitfalls §1.3 "Pattern C: 비정상 종료 경로의 cleanup 누락"(정상 종료엔 정리 로직이 있고 crash/disconnect엔 없으면 반드시 샌다 — tapHubs 누수가 실제 선례)과 동일 위험군을 새로 만든다. pane이 close/disconnect될 때 코얼레싱 버퍼에 아직 flush 안 된 잔여 바이트가 있으면 유실되거나 잘못된 surface로 흘러갈 수 있다 — `test_peer_input_bracketed_paste_split_close.py`가 정확히 이 시나리오(split/close 중 in-flight 데이터)를 재현하므로, 코드 인접성이 아니라 이 신규 위험 때문에 하드 게이트가 필요하다. 수정 방향: pane 종료 3개 경로(closeWorkspace/didCloseTab/didClosePane) 전부에서 코얼레싱 버퍼를 명시적으로 flush하도록 구현.
  2. "host-only(대칭 위해 client도 가능)"라는 서술이 향후 Rust `surface.rs` 브로드캐스트 경로로 배칭을 확장할 가능성을 열어둔다 — Rust는 PTY read 루프가 query_filter와 broadcast 양쪽에 동일 청크를 공급하는 구조(`surface.rs:160-238`)이므로, 확장 시 청크 재구성(coalescing) 방식에 따라 F5("PTY read 청크는 반드시 순서대로 process()에 공급... 여러 read를 동시에 읽어 병합 금지")를 건드릴 위험이 있다 — Rust 확장 착수 시점에 재감사가 필요한 조건으로 명시 권고. 심각도: 낮음(현재 스코프는 안전, 향후 확장 시에만 발동).

### P8. 전송계층 최적화 — LAN Native TCP 직결 + WAN 조건부 압축
- 축: ①③④ | Impact: H(C13 추정·잠재 — "가장 레버리지 크면서 가장 롤아웃 리스크도 큰 항목", C12는 M이나 병합 시 H로 상향) | Effort: L | 호환성: 와이어 변경(capability 필요, P3 하드 선행조건)
- LAN/WAN: C13=LAN 전용(WAN은 SSH 유지) / C12=WAN 유리·LAN 역효과 가능 — R12가 이 조합을 명시적으로 권고 | SSH-한정 여부: C13 자체가 SSH-한정 축의 핵심(SSH 우회 그 자체), C12는 SSH 유지 경로 위에 얹으므로 아님
- 근거: `Sources/PeerSSHTunnel.swift:228-255`@0fd6bd97(LAN도 SSH 터널 경유) / `docs/peer-federation-impl-status.md:46`@0fd6bd97(Native TCP D-3b TODO) / 압축 의존성 grep 0건(`daemon/Cargo.toml` 등) — C13, C12
- 내용: 오늘 시점 LAN·WAN 모두 100% 동일하게 SSH 터널을 경유하며 LAN 전용 Native TCP 직결 경로는 미구현이다(D-3b TODO). LAN 한정 Native TCP(SSH 폴백 유지)는 핸드셰이크·프레이밍·keepalive 오버헤드를 LAN에서 통째로 제거하고, WAN에서는 압축이 대역폭 절감에 유리하나 LAN에서는 역효과일 수 있음이 코드 근거로 확인돼 있다. R12 결정이 "LAN은 Native TCP로 오버헤드 제거, WAN은 SSH 유지+압축"의 상호보완 조합을 명시적으로 권고했으므로 하나의 전송계층 제안으로 묶는다. 두 항목 모두 새 capability이므로 P3 없이는 구버전 상대와 안전하게 조우할 수 없다.
- 수정 지점: (이번 제안서 스코프는 채택방향+선행조건 결정까지 — [D1]. 아래는 착수 시 진입점)
  - `Sources/PeerSSHTunnel.swift:228-255` — LAN 판정 로직 추가, 판정 시 SSH 우회하고 직결 TCP 경로로 분기(SSH 폴백 유지)
  - 프레이밍/전송 계층(`daemon/term-meshd/src/peer/framing.rs`, `swift/PeerProto/Sources/PeerProto/PeerServer.swift` 전송 담당부) — 압축 코덱 적용 지점, capability 협상 결과에 따라 조건부 활성화
- 기대 효과: LAN 연결수립시간·왕복지연·킵얼라이브 오버헤드 동시 절감[추정]; WAN 대역폭 절감[추정, 압축률 미측정]. 구체 구현·정량 검증은 [D1] 범위 밖(후속 프로젝트)
- 금지계약: 통과(현 스코프는 방향+선행조건 결정까지, [D1]) — F1-F4·F6-F8·F10-F12 해당없음(전송계층/프레이밍 변경이며 ESC/paste/Kitty/OSC52/key-text/acceptRelay/focus/display-link/쿼리왕복과 무관). F9 해당없음(NWConnection 기반 신규 transport는 기존 UnixSocketTransport와 동일 actor 패턴을 따를 것으로 예상되나 구현 스코프 밖이라 확정 못함 — 착수 시 재확인). **F5(query_filter.rs) 후속 구현 시 준수사항** — 아래 감사 소견 참조.
- 롤아웃: 제안 라벨(와이어 변경, P3 하드 선행조건) 정확 — 단 P3 감사 소견 참조: P3이 현재 스코프(Rust daemon host만)대로 "완료" 처리되면 P8의 실질 선행조건이 충족되지 않은 상태로 착수될 위험이 있다. **P8 착수 게이트는 "P3 태스크 완료"가 아니라 "4개 구현체(Rust host/client, Swift host/client) 전부에서 capabilities가 실제로 채워지고 상대측 capabilities를 읽어 분기하는지"로 재정의할 것을 권고.** C13(Native TCP)은 "구버전 호스트를 명시적으로 흉내낸 2-머신 환경" 검증이 필요하다고 pitfalls §5.5·제안문이 이미 명시 — 이 검증 없이는 SSH-vs-네이티브 분기 로직 자체가 실사용에서 한 번도 행사되지 않을 위험을 재확인.
- ⚠ 감사 소견: 압축 코덱을 프레이밍 계층 어디에 넣을지가 이번 제안 스코프 밖([D1])이라 구체 위치가 미정이다 — 만약 압축이 PTY read 청크를 재구성(더 큰 단위로 묶어 압축률을 높이는 방향)하는 형태로 구현되면 Rust 경로의 `query_filter.rs` 상태기계(청크 순서 보장 필요, F5)와 직접 충돌할 위험이 있다. "압축 코덱은 반드시 `query_filter.rs` 처리 이후(다운스트림)에 위치해야 한다"는 제약을 후속 구현 계획에 명시적으로 못박을 것을 권고(현재 제안문엔 이 제약이 없음). 심각도: 낮음(구현이 후속 프로젝트로 명확히 분리돼 있어 지금 당장의 위반은 아님, 계획 단계 권고).

### P9. Swift drop 가시화 + 자동 재동기화
- 축: ④(①일부 연관) | Impact: M(산정 — R11이 이미 "채택" 결정, 2단계 자동재스냅샷이 실질 권고안) | Effort: S | 호환성: host-only
- LAN/WAN: 둘 다 유효(WAN서 드롭 더 흔할 가능성) | SSH-한정 여부: 아님
- 근거: `Sources/GhosttyPaneSurfaceProvider.swift:70,81-94`@0fd6bd97(Swift bufferingNewest(256), 무로그 드롭) / `daemon/term-meshd/src/peer/connection.rs:393-397`@0fd6bd97(Rust는 Lagged 시 warn! 로그) / `Sources/GhosttyPaneSurfaceProvider.swift:312-331`@0fd6bd97(기존 리사이즈 재전송 경로 재사용) — C17
- 내용: 빠른 producer가 채널 용량을 넘으면 Rust는 경고 로그를 남기지만 Swift는 조용히 덮어써지고 로그·카운터가 전혀 없다 — 드롭 구간에 커서/색상 시퀀스가 걸리면 화면이 어긋나고 다음 재연결(수십 초)까지 자연 복구되지 않는다. R11이 이미 이번 스코프에서 2단계 채택을 결정했다: (1단계) Swift 드롭 경로에 카운터+dlog 추가, (2단계·실질 권고안) drop 감지 시 host가 기존 리사이즈 트리거 경로(clear+plain-text 스냅샷 재전송)를 해당 client에게만 자동 재호출 — 새 메시지 타입·필드 불요, 사용자는 화면이 짧게 깜빡였다 정상화되는 정도로만 체감한다. 사용자에게 "일부 출력을 놓쳤습니다"를 명시하는 배너나 문서화된 전체 배압 정책(C19)은 R11이 이미 후속분리를 결정했으므로 포함하지 않는다(부록C 참조).
- 수정 지점:
  - `Sources/GhosttyPaneSurfaceProvider.swift:70,81-94`(PtyTapHub.broadcast) — 드롭 발생 지점에 카운터 증가+dlog 추가
  - `daemon/term-meshd/src/peer/connection.rs:393-397`(RecvError::Lagged 처리부) — 기존 warn! 로그를 카운터로도 집계
  - drop 카운터 증가 시 `Sources/GhosttyPaneSurfaceProvider.swift:312-331`의 리사이즈 재전송 로직을 해당 client 대상으로 재호출하는 신규 트리거 추가(창 크기 변경 없이도 발동)
- 기대 효과: 드롭 발생 시 최소 가시성 확보[산정]; "영구 화면 어긋남"을 "일시적 깜빡임+자동 정상화"로 전환[산정, 기존 경로 재사용이라 신규 버그표면 최소]
- 금지계약: 통과 — F1-F5·F7·F8·F12 해당없음(드롭 카운터·dlog·기존 리사이즈 재전송 트리거 재사용이며 ESC/paste/Kitty/query_filter/key-text/acceptRelay/쿼리왕복과 무관). F6 해당없음. F10·F11 해당없음. **F9(소켓 threading policy) 조건부 준수 필요** — 아래 감사 소견 참조.
- 회귀 게이트: test_peer_input_bracketed_paste_split_close.py(하드) — pitfalls §5.5 파일-근접 규칙 적용(P4와 동일 근거, `GhosttyPaneSurfaceProvider.swift:312-331` 재사용 대상). 드롭 감지가 paste 스트림 중간에 발생할 때 클라이언트가 갑작스러운 clear+재전송을 올바르게 처리하는지도 이 테스트로 함께 확인할 가치가 있다. test_peer_input_esc_freeze_regression.py는 선택 사항.
- 검증수단: P5(원격 grid 조회 API) 권장 — "드롭 후 자동 재스냅샷이 host 실제 grid와 일치하는지"는 육안 확인보다 P5의 구조화 조회가 더 결정적 증거를 준다. 수동 2-노드(빠른 producer로 드롭 유발 후 화면 비교)로도 가능.
- ⚠ 감사 소견(2건):
  1. 축 라벨이 "④(①일부 연관)"으로만 표기돼 있으나, 내용 자체가 "드롭 후 화면을 host와 다시 일치시키는" 렌더링/화면 갱신(②) 메커니즘이다 — R15 렌더축 검증수단 요구가 라벨 누락으로 빠지지 않도록 위 검증수단 필드를 추가했다(P1·P2와 동일 클래스의 라벨 완결성 이슈).
  2. **F9(소켓 threading policy) 조건부** — drop 감지는 `PtyTapHub.broadcast()`(hot path, "초당 수천 번" 가능) 내부에서 트리거될 것이므로, 감지 즉시 리사이즈 재전송(MainActor 경유, `GhosttyPaneSurfaceProvider.swift:312-331`)을 **동기 await로 블로킹 호출**하면 hot path를 막게 된다 — fire-and-forget(Task 스폰 후 즉시 반환)으로 구현해야 한다는 제약이 수정 지점에 명시돼 있지 않다(P4의 F9 소견과 동일 클래스 문제). 심각도: 낮음(내용 설계는 이미 견고, 문서화·구현 디테일 보완 필요).

### P10. DataAck 정식 구현
- 축: ①(계측 인프라) | Impact: M(산정 — R9가 이미 "정식 구현 채택" 결정, 향후 입력 레이턴시 개선의 정량 검증 전제) | Effort: M | 호환성: 양측(효과 조건, advisory라 하위호환 유지)
- LAN/WAN: 둘 다 유효(WAN서 RTT 가변성 커서 계측 가치 더 큼) | SSH-한정 여부: 아님
- 근거: `swift/PeerProto/Sources/PeerProto/PeerSession.swift:35`@0fd6bd97 / `PeerServer.swift:847`@0fd6bd97(미구현 명시) / `proto/peer/v1/peer.proto:385-388`@0fd6bd97(DataAck advisory 필드) — C14
- 내용: 프로토콜이 RTT 측정용으로 설계해 둔 DataAck가 Swift·Rust 양쪽 다 미구현이다. R9가 이 항목만 "정식 구현 채택"으로 결정한 이유는 필드가 이미 존재하는 advisory 메시지이고 "host가 재연결 ring buffer를 trim"하는 이중 용도로 설계돼 P4 ring buffer와도 연결되며, "정식 벤치 하네스 구축"이 아니라 "이미 설계된 필드의 완성"이라 스코프 제약과 충돌하지 않기 때문이다. 구현 완료 시 keypress→remote-echo RTT를 상시 계측할 수 있게 되어 P7 등 다른 입력 레이턴시 개선의 효과를 실측으로 사후 검증하는 유일한 통로가 된다.
- 수정 지점:
  - `swift/PeerProto/Sources/PeerProto/PeerSession.swift:35` 부근 — DataAck 송신(주기적 advisory) 신규 구현
  - `swift/PeerProto/Sources/PeerProto/PeerServer.swift:847` 부근 — DataAck 수신 처리 신규 구현, ring buffer trim 연결(P4 연동 지점)
  - Rust측 대응 구현(`daemon/term-meshd/src/peer/` 세션/connection 처리부, 정확한 라인은 explorer 후속 확인 필요)
- 기대 효과: keypress→remote-echo RTT 상시 계측 통로 확보[산정, 현재 0→1]; P7 등 향후 입력 레이턴시 개선 효과의 실측 사후검증 가능[산정]
- 금지계약: 통과 — F1-F9·F11·F12 해당없음(RTT 계측용 advisory 메시지 송수신 신설이며 어느 계약과도 코드 경로가 겹치지 않음). F10 해당없음.
- 롤아웃: 제안 라벨(양측, advisory라 하위호환 유지) — 코드로 직접 확인해 검증했다. `swift/PeerProto/Sources/PeerProto/PeerServer.swift:844-850`에 `case (.ready, _): // Remaining payloads (DataAck, Error inbound, etc.)... Silent drop matches the Rust server's behavior.`라는 명시적 catch-all이 이미 존재해, 구버전(DataAck를 보내지 않는) 상대는 물론 신버전이 DataAck를 보내도 상대가 이를 처리 못 하면 조용히 드롭될 뿐 파싱 실패·크래시로 이어지지 않음을 코드 수준에서 확인했다(Rust측도 동일 동작이라고 이 주석이 직접 명시 — Rust 쪽 정확한 catch-all 라인 자체는 별도 확인 못 했으나, `match (&state, payload)`가 컴파일된다는 사실 자체가 DataAck를 포함한 모든 Payload variant가 최소한 어떤 형태로든 처리됨을 타입 시스템 차원에서 보장한다). 따라서 P10은 P3(capability 게이팅) 없이도 **기본 안전성은 이미 확보**돼 있다 — R14의 "와이어 변경은 capability 선행" 원칙을 엄밀히 적용해야 하는 대상은 아니다.
- ⚠ 감사 소견(긍정적 확인): proto 저장소 자체의 Evolution rule 3("신규 메시지는 capability로 게이트")을 형식적으로는 여전히 어기고 있으므로, 위생 차원에서 P3 완료 후 DataAck도 정식 capability로 등록할 것을 권고한다(하드 차단 사유는 아님, 개선 권고). 심각도: 낮음 — 오히려 이번 감사에서 유일하게 "우려가 코드로 이미 해소돼 있음"이 확인된 항목.

## 분석

### 분석 — 입력 레이턴시·렌더링 축 (t3)

**범위**: 이 분석은 architecture-verify 검증1(01-research/notes.md §architecture-verify)에서 확정된 GUI attach 데이터플레인 — Swift `PeerServer` + `GhosttyPaneSurfaceProvider`(라이브 Ghostty pane) — 을 기준으로 한다. `daemon/term-meshd/src/peer/*`(Rust)는 `tm-agent peer attach` 헤드리스 CLI 전용의 별도 데이터플레인(term-meshd가 직접 fork한 독립 셸 PTY, 라이브 pane 아님)이라 31-hop 트레이스 자체에는 포함되지 않는다 — 단, R4에서 다루는 `ReplayBuffer` 패턴은 이 Rust 경로에서 이미 동작 중인 참조 구현으로 인용한다.

---

#### R1 — hop별 지연 기여

**방법**: `01-research/notes.md` §architecture의 입력 경로 트레이스(1-16) + 출력/렌더 경로 트레이스(1-15) = 31 hop을 7개 구간으로 묶었다. 실측 벤치마크가 전무하다는 것이 조사 결론 자체이므로(notes.md §pitfalls "실측 벤치마크 전무 — 이 보고서의 모든 수치는 정적 코드분석 기반"), 아래 표는 **산정**(코드 상수·syscall 수·hop 수에서 계산 가능한 값)과 **추정**(정량 근거 없는 추론)만 사용하며 **실측** 태그는 어디에도 쓰지 않는다. 이하 hop 번호는 `입력#n`/`출력#n` 표기로 §architecture 원문 목록을 그대로 가리킨다.

| 구간 | hop 범위 | 지연 기여 추정 | 근거태그 | 근거 |
|---|---|---|---|---|
| A. 로컬 relay 프로세스 왕복 | 입력#1-3, 출력#12-13 (5 hop) | 5홉 중 3홉이 순수 로컬 커널 IPC(poll/read/write/flush, 네트워크 미개입) — 7개 구간 중 hop당 상대 비용이 가장 낮은 구간으로 산정. 절대 ms는 project 계측 없어 미상(추정) | 산정(hop·syscall 수) / 추정(절대 ms) | `daemon/term-mesh-peer-relay/src/main.rs:794,812-829`; notes.md §architecture 입력#1-3·출력#12-13 |
| B. 2차 프레이밍·로컬소켓 | 입력#4-7, 출력#9-11 (7 hop) | GCD DispatchQueue/Task.detached 스케줄링 홉 4회(입력#6-7, 출력#9,11) — A보다 hop 수가 많아 스케줄링 변동성이 상대적으로 큼. `RelayFrameSlots` 256슬롯(출력#10)은 정상 부하에선 대기 없음, 소켓 정체 시 무상한 큐잉 지연으로 전환 | 산정(hop 수 비교 + 세마포어 상수) | `Sources/PeerRelaySession.swift:204`(RelayFrameSlots limit=256); notes.md features §축① "정상 상태에선 무시할 수준이나, 소켓이 정체되면 여기서 큐잉 지연이 쌓인다" |
| C. peer 채널 직렬화 | 입력#8,12,13, 출력#1-4,8 (8 hop) | 8홉 중 5홉이 출력측(호스트 PTY tap→Envelope 인코딩)에 집중. 출력#1-2(`ptyTapCallback`→`broadcast`)는 코드 주석상 "초당 수천 번 발동" 가능하며 출력#3에 배칭이 전혀 없음 — protobuf 자체는 저비용이나 고빈도 시 왕복지연보다 누적 CPU/처리량 저하로 전이될 가능성 | 산정(hop 수 + 배칭 부재 확인) / 추정(고빈도 누적 영향의 절대 크기) | `Sources/GhosttyPaneSurfaceProvider.swift:81-94`(PtyTapHub.broadcast, "초당 수천 번" 주석); `swift/PeerProto/Sources/PeerProto/PeerServer.swift:926-947`(pumpByteStream, 1chunk=1Envelope, 배칭 없음) |
| D-1. 네트워크·SSH(LAN) | 입력#9-11, 출력#5-7 (6 hop) | LAN은 유닉스 소켓 직결 — 네트워크 구간 자체는 사실상 0에 수렴. host측 출력#5의 EAGAIN 1ms busy-poll 재시도는 정상 부하(수신측이 따라잡는 상태)에선 미발동 | 추정(LAN 왕복 자체 절대치) / 산정(재시도 간격 1ms 상수) | `Sources/PeerSSHTunnel.swift:228-255`(LAN도 SSH 터널 경유 확인); `swift/PeerProto/Sources/PeerProto/PeerServer.swift:632-639`("PoC keeps it simple" 주석) |
| D-2. 네트워크·SSH(WAN) | 입력#9-11, 출력#5-7 (D-1과 동일 6 hop, 네트워크 조건만 다름) | 네트워크 RTT에 전적으로 의존 — 코드 근거로 절대치 산정 불가(SSH 프레이밍/암호화 오버헤드 포함). 단 출력#5의 EAGAIN 1ms 재시도가 **역압(수신측이 못 따라갈 때) 상황에서 반복 발동해 지연을 배가시킬 위험**은 "Production code would use DispatchSourceWrite; PoC keeps it simple" 주석이 스스로 인정하는 실제 코드 결함 | 추정(RTT 절대치 — 범위조차 근거 없음, 실측 필요) / 산정(busy-poll 메커니즘 자체) | 동일 근거 + `Sources/PeerSSHTunnel.swift:244-245`(ServerAliveInterval=15s는 생사감지용, RTT와 무관하므로 별개) |
| E. host 재생 파서(일반 케이스) | 입력#15 일부, #16 | 상태머신 매치(`trailingIncompleteEscape` 등)+FFI 호출은 바이트 단위 비교 연산 — 일반(비-ESC) 키 입력 시 무시할 수준으로 추정. 조건부 보류는 아래 별도 표 | 추정(상태머신 매치 비용, 상수 없음) | `Sources/GhosttyPaneSurfaceProvider.swift:893,916`(trailingIncompleteEscape/peerEscapePrefixCouldComplete) |
| F. MainActor 홉 | 입력#14 (1 hop) | 로컬 타이핑엔 없는, peer 경로 전용 추가 홉(NSEvent는 이미 메인스레드이므로 로컬 입력은 이 홉 자체가 불필요). 액터 큐 스케줄링 지연은 메인스레드 혼잡도 의존 — 정량 근거 없음. 과거 MainActor hang 이력(AutoReplyPoller류, `ghostty_surface_read_text` 동기 호출)과 동일 리스크 클래스이나, 이 특정 홉이 실제로 지연을 유발한 사례는 미확인 | 추정 | `Sources/GhosttyPaneSurfaceProvider.swift:248-256`(input 클로저 MainActor.run); `CLAUDE.md` 소켓 threading policy(peer 예외 조항) |
| G. Ghostty 렌더 | 출력#14-15 (2 hop) | FFI 경계 내부, 코드로 전혀 관측 불가 — 순수 추정. occlusion 상태(가시/비가시, warm/cold realize)에 따라 이봉분포(bimodal) 노이즈 가능성 | 추정 | notes.md §architecture 출력#14-15 "[FFI 경계 안쪽, 미관측]"; §pitfalls 측정 함정 "occlusion 비결정성"(`ghostty.h:1167`) |

**hop 수 검산**: 5(A)+7(B)+8(C)+6(D, D-1/D-2는 동일 hop의 두 네트워크 조건이므로 1회만 계산)+2(E)+1(F)+2(G) = 31 — §architecture의 "입력 16 + 출력 15 ≈ 31 hop"과 정확히 일치하며 누락·중복 없음.

**조건부 추가 지연** (평상시 키 입력엔 미적용, 특정 조건에서만 발동):

| 조건 | 관련 구간 | 지연 | 근거태그 | 근거 |
|---|---|---|---|---|
| 단독 ESC — 호스트측 재조립 보류 | E (입력#15 확장) | **+120ms 고정** — `peerPendingTailFlushDelayNanos`. "진짜 단독 ESC"로 판별된 경우에만 발동 | 산정(코드 상수 직접 근거) | `Sources/GhosttyPaneSurfaceProvider.swift:729` |
| 단독 ESC — 클라이언트(relay 프로세스)측 stdin 보류 | A (입력#3 확장) | **+100ms 고정** — `ESC_FLUSH_TIMEOUT_MS`. 파이프라인상 위 호스트측 보류보다 **먼저** 발생(relay가 stdin을 먼저 읽음) | 산정(코드 상수 직접 근거) | `daemon/term-mesh-peer-relay/src/main.rs:745` |
| bracketed-paste idle timeout | E (입력#15 확장, paste 시나리오) | **+0.75s(750ms)** paste 완료 판별 대기, 최대 버퍼 8MiB. paste 흐름당 1회성이며 개별 키 입력 각각에는 미적용 | 산정(코드 상수 직접 근거) | `Sources/GhosttyPaneSurfaceProvider.swift:754,759` |

이 보고서가 처음 발견한 점: 단독 ESC 지연이 **client측(100ms)과 host측(120ms) 두 곳에서 독립적으로** 존재한다 — 둘 다 "ESC가 완성된 리터럴 키인지 이스케이프 시퀀스의 시작인지"라는 **동일한 모호성**을 각자 재판별한다. 파이프라인이 순차적이므로(relay가 먼저 읽고 보낸 뒤에야 host가 재조립) 진짜 단독 ESC keystroke 1회의 최악 경로는 이론상 100ms+120ms=**220ms**까지 산정된다. 다만 두 지연이 실제로 매번 순차 누적되는지, 발동 빈도가 얼마인지는 실측되지 않았다 — [산정 상한, 실제 스태킹 여부·빈도는 추정 요소를 포함하며 후속 계측이 필요].

**종합**: LAN에서는 A·B·C·E·F 구간(고정 hop, 대부분 로컬 IPC+스케줄링)이 왕복 지연의 대부분을 차지할 것으로 산정되며, 이들 구간 어디에도 기본 배칭이 없다는 점(특히 C의 출력#1-3)이 구조적 특징이다. WAN에서는 D-2(네트워크·SSH)가 지배적일 가능성이 높고, 특히 host측 EAGAIN busy-poll(출력#5)이 역압 상황에서 D-2 자체를 더 악화시키는 유일하게 코드로 확인된 WAN 전용 리스크다. 그러나 이 우선순위 판단 자체가 실측 없는 정적 분석 산물이므로 — CONTEXT.md [D3]가 요구하는 "가능한 항목은 실측으로 검증"을 만족하려면 위 표의 A~D 각 구간에 대한 임시 계측(§pitfalls가 경고하는 dlog 500/s 회로차단기 우회 필요)이 제안 채택 전 선행돼야 한다.

---

#### R2 — 로컬 에코 부재와 optimistic echo

**구조 제약**: relay 창은 로컬 PTY가 없는 진짜 Ghostty surface이며, "shell"로 실행되는 것이 `term-mesh-peer-relay` 프로세스다(`Sources/PeerRelayWorkspaceWindowController.swift:1441` TerminalSurface 생성). 이 아키텍처 전제상 클라이언트는 "방금 입력한 문자가 host의 셸/TUI에서 어떻게 처리될지" 알 방법이 전혀 없다 — 모든 화면 반영은 host 왕복(R1의 31-hop 전체)에 100% 의존한다. notes.md §architecture가 명시하듯 "client는 로컬 예측 echo를 전혀 하지 않으므로(design doc의 'host is source of truth' 불변식), 시각적 echo는 100% 이 왕복 전체에 의존한다" — 이는 우연한 누락이 아니라 명시적 설계 불변식이다.

**"host is source of truth"가 존재하는 이유**: 순수 셸 프롬프트라면 "타이핑한 문자를 그대로 보여준다"는 예측이 대체로 맞지만, 이 가정은 다음 경우 전부 깨진다 — 셸이 raw/cbreak 모드로 전환한 TUI 애플리케이션(커서 이동·부분 리드로우·팝업 등 임의 반응), 비밀번호 프롬프트(echo 자체가 꺼짐), 멀티바이트 UTF-8 조합/백스페이스(CJK·이모지의 컬럼 폭), readline 계열 라인 편집 바인딩(입력이 1:1 삽입이 아닐 수 있음). 클라이언트가 이를 정확히 예측하려면 사실상 host가 실행 중인 애플리케이션의 터미널 시맨틱을 클라이언트 쪽에도 재구현해야 한다.

**vim/TUI 오표시 위험 — 이미 실증된 버그로 뒷받침됨**: vim ESC freeze 버그(pitfalls §1.1)가 정확히 이 문제의 축소판이다. `trailingIncompleteEscape`/`peerEscapePrefixCouldComplete`(`Sources/GhosttyPaneSurfaceProvider.swift:893-930`)는 "ESC가 리터럴 키 입력인지 이스케이프 시퀀스의 시작인지"를 **host에서조차** 프레임 경계 문제로 오판했던 이력이다. optimistic echo는 이 판별을 클라이언트가 host보다 먼저, host의 실제 상태(vim의 현재 모드 등) 지식 없이 내려야 한다 — host가 가진 것보다 적은 정보로 동일 문제를 풀어야 하므로 오판 확률이 host측 구현보다 낮을 이유가 없다. vim은 ESC를 받아도 "ESC를 에코"하지 않고 모드를 바꿀 뿐이므로, "타이핑한 문자를 그대로 보여주는" 낙관적 모델은 vim 같은 TUI에서 태생적으로 틀린 화면을 보여준다.

**과거 입력 경로 버그 패턴과의 상호작용**: pitfalls §1.3이 분류한 회귀 패턴 A(버퍼링/디바운스가 제어 시퀀스 경계 오판과 충돌)와 B(키 인코딩 계층 변환 불일치)는 host 단독 구현에서 이미 3회 이상 실제로 발생했다 — vim ESC freeze, Kitty keyboard protocol press/release 이중처리(CHANGELOG:676), CSI-u 특수키 오인식(CHANGELOG:691). optimistic echo를 도입하면 "터미널 이스케이프 시퀀스를 해석해 시각적으로 예측한다"는 동일 부류의 상태기계를 **클라이언트에 독립적으로 하나 더** 추가하는 셈이다 — 버그 표면적을 사실상 두 배로 늘린다. 게다가 CONTEXT.md [C2]가 명시하듯 "호스트측 재생 시맨틱은 버전 체크 사각지대"다(architecture §5.1 항목3, `protocol_version` major-compat 체크는 와이어 스키마만 보고 재생 시맨틱 변경은 감지 못함). 클라이언트측 예측 로직에 새 버그가 생겨도 동일한 사각지대에 놓이며, "클라이언트 버전 × host 버전" 조합만 하나 더 늘어 재현 매트릭스가 커진다.

**결론**: "로컬 에코 없음"은 relay-process 아키텍처(진짜 Ghostty PTY가 필요하다는 제약을 우회하기 위해 client가 셸 대신 relay 바이너리를 스폰하는 구조, notes.md §architecture 병목 후보 표)에서 파생된 구조적 특성이며, 그 위에 "host is source of truth"라는 명시적 설계 불변식이 추가로 얹혀 있다. 전자(로컬 PTY 부재)는 아키텍처를 바꾸지 않는 한(예: libghostty가 PTY 없이 바이트를 직접 feed하는 API — 병목 후보 표가 제시한 가장 큰 blast-radius 방향) 불변이다. 후자(예측하지 않음)는 기술적으로는 변경 가능하지만, **일반적인 optimistic echo 도입은 권장하지 않는다** — vim 등 TUI 세션에서 구조적으로 틀린 화면을 보여줄 위험이 이미 실증된 버그 패턴과 정확히 겹치고, 버전 호환성 사각지대까지 그대로 상속하기 때문이다. 향후 재검토한다면 (a) TUI를 감지할 수 있는 좁은 컨텍스트로 스코프를 제한하고(순수 라인 버퍼링 셸 프롬프트만 — 이마저 비밀번호 프롬프트 등 예외가 남는다), (b) mosh 스타일의 "미확정 문자 시각적 구분(밑줄 등)+도착 시 정정" UI를 **별도 기능**으로 설계해야 하며, 이는 레이턴시 완화책이 아니라 그 자체로 새로운 제품 기능 개발 프로젝트로 다뤄야 한다. 체감 지연을 줄이는 더 안전한 방향은 R1에서 식별한 홉 자체의 수·비용을 줄이는 쪽(구간 B/C의 배칭·이벤트구동화, 병목 후보 표의 세션 멀티플렉싱)이며, 이는 optimistic echo와 달리 host측 정합성 불변식을 건드리지 않는다.

---

#### R4 — 스냅샷/재동기화 비용과 방향

**비용 분석**

1. **plain-text 스냅샷(스타일 유실)**: attach 시 host의 `readPaneSnapshot`이 일반 텍스트만 보내고 ANSI 스타일(색상·속성)은 유실된다(`Sources/GhosttyPaneSurfaceProvider.swift:312-331`, `docs/peer-federation-impl-status.md:171-175`와 코드 주석 일치). 이 경로는 (a) 최초 attach, (b) 매 재연결, (c) 실제 리사이즈 — 세 상황 모두에서 재사용되는 **단일 메커니즘**이다. 비용은 유실된 스타일 자체(즉각 체감되는 시각적 열화)와, 이를 땜질하려는 **부수 비용**으로 나뉜다 — host가 attach 후 100ms 지연을 두고 Ctrl-L을 주입해 TUI 앱이 스스로 리드로우하도록 유도하는데, 이는 (i) 모든 앱이 Ctrl-L을 "전체 리드로우"로 해석한다는 보장이 없는 관례적 땜질이고, (ii) 부작용으로 **host 로컬 화면도 함께 깜빡인다**(`Sources/GhosttyPaneSurfaceProvider.swift:230-239`) — 즉 원격 접속자의 스타일 손실을 고치려는 시도가 host를 쓰는 사용자(다른 사람일 수 있음)의 화면까지 흔든다.

2. **resumeFromSeq 미구현(initialSeq=0 고정)**: `swift/PeerProto/Sources/PeerProto/PeerServer.swift:899`가 `req.resumeFromSeq`를 읽지 않고 `r.initialSeq = 0`을 하드코딩한다. proto 스키마에는 이미 필드가 존재하므로, "이미 설계된 최적화가 host 구현에서 그냥 안 쓰이고 있다"는 것이 정확한 현황이다. 비용은 비대칭적이다 — 순간적 네트워크 blip(SSH keepalive 끊김 등) 후 재연결하면 실제로는 몇 바이트만 놓쳤어도 항상 전체 plain-text 뷰포트 스냅샷을 다시 받는다(짧은 끊김일수록 상대적 낭비가 큼); 반대로 장시간 끊김이면 어차피 증분 재생이 비현실적이므로 전체 재전송이 크게 나쁘지 않다. 여기에 멀티페인 워크스페이스의 leaf당 순차 handshake 비용(`Sources/PeerRelayWorkspaceWindowController.swift:1049-1075`, TaskGroup 없는 `for surfaceID in missingSurfaceIDs` 순차 루프)이 곱해져, N-pane 워크스페이스의 재연결은 이 스냅샷 비용을 N배로 지불한다.

3. **리사이즈 풀 리페인트**: 클라이언트(24ms, `RelayResizeCoalescer`, `Sources/PeerRelaySession.swift:318-321`)와 relay 바이너리(16ms, `RESIZE_COALESCE_MS`, `daemon/term-mesh-peer-relay/src/main.rs:33`) 두 단계로 실제 리사이즈 *이벤트*는 코얼레싱되지만, 코얼레싱을 통과한 이후에도 **매번** `ESC[2J`+plain-text 스냅샷 풀 재전송이 뒤따른다(`Sources/GhosttyPaneSurfaceProvider.swift:312-331`) — 코얼레싱은 "몇 번 다시 그리는가"만 줄일 뿐 "한 번 다시 그릴 때 얼마나 비싼가"는 그대로다. 드래그 리사이즈처럼 코얼레싱 윈도우(16-24ms)를 반복 트리거하는 시나리오에서는 짧은 간격으로 풀 리페인트가 연쇄돼 스터터로 체감될 후보로 지목된다.

세 항목의 근본 원인은 동일하다 — **host에 attach/resize 양쪽에서 재사용 가능한 "스타일 보존 스냅샷" 메커니즘이 하나도 없다**는 것. 아래 세 후보는 모두 이 공통 원인을 겨냥한다.

**개선 방향**

**후보 1 — Rust `ReplayBuffer` 패턴을 Swift에 그대로 이식(실용적 최소구현)**

Rust 경로는 이미 이 문제를 부분적으로 풀어놓은 상태다. `PtySurface`가 64KB raw-byte 링버퍼(`REPLAY_CAPACITY_BYTES`, `daemon/term-meshd/src/peer/surface.rs:43`)를 유지하다 attach마다 `connection.rs:341` `spawn_attach_relay()`가 그대로 재생한다. architecture-verify 검증1(항목7)이 확인한 대로 이건 raw byte라 **ANSI 스타일이 보존**되고, Swift의 plain-text 스냅샷보다 이미 우수하다. 단 Rust도 `resume_from_seq`를 읽지 않는 것은 Swift와 동일 — "seq 기반 dedup이 아니라 매 attach마다 최근 64KB 무조건 재생"이다.

- 장점: 새로 설계할 필요 없이 이미 다른 언어에서 동작 검증된 패턴을 옮기기만 하면 됨(구현 리스크 최소); ANSI 스타일 보존이라는 가장 체감되는 개선을 가장 적은 신규 코드로 달성; host가 attach 시 화면을 이미 정확히 재현하므로 위 §비용분석-1의 Ctrl-L 강제 리드로우(및 host 화면 부작용)를 없앨 잠재력이 있음.
- 단점: 여전히 "무조건 전량 재생"이라 짧은 blip에도 버퍼 전체를 다시 보냄 — resumeFromSeq 필드가 있는데도 활용 안 하는 낭비는 남음; ring buffer 자체가 surface당 상주 메모리를 추가함(자원 축과 직결, 이 항목 자체의 정량화는 이 섹션 범위 밖); 리사이즈는 "과거 바이트 재생"이 아니라 "새 크기 기준 현재 상태의 신선한 스냅샷"이 필요하므로 이 후보는 §비용분석-3(리사이즈)을 해결하지 못함.
- 호환성: `resume_from_seq` 필드가 이미 proto에 존재해 신규 필드 불요. 효과를 보려면 host(ring buffer 신설)+client(byte_seq 추적) 양쪽 업데이트가 필요하나, 구버전 상대와 마주치면 오늘과 동일한 현행 plain-text 스냅샷으로 자연 폴백 — 하위호환 유지.

**후보 2 — host ring buffer + 진짜 `resumeFromSeq` 활용(seq 기반 증분 재생)**

후보1의 ring buffer에 seq 인덱싱을 더해, 클라이언트가 마지막으로 받은 `byte_seq`를 attach 요청에 실어 보내면 host가 그 지점부터만 재생하는 버전. 이는 Rust에도 Swift에도 현재 존재하지 않는, **두 구현체 모두에게 신규 코드**다(architecture-verify 검증1 항목7 "seq 기반 dedup resume이 아니라... 무조건 재생"이 Rust에도 해당됨을 명시).

- 장점: 짧은 네트워크 blip에서 재전송 페이로드가 "놓친 만큼만"으로 줄어듦 — §비용분석-2가 지적한 비대칭 낭비를 정확히 겨냥해 해소; N-pane 워크스페이스 재연결 시 N배 비용에도 페이로드 절감 효과가 그대로 곱연산됨.
- 단점: 후보1 대비 신규 설계 범위가 넓음 — client가 byte_seq를 정확히 추적·보고해야 하고, host는 seq 기반 조회(랩어라운드·오래된 seq 요청 시 폴백 등) 로직을 새로 구현해야 함; 두 구현체 모두 미구현이라 참고할 기존 동작 검증 사례가 없음(후보1과 달리 "이미 어딘가에서 돌아가는 패턴"이 아님); 리사이즈 문제는 후보1과 마찬가지로 해결하지 못함.
- 호환성: 후보1과 동일 필드 재사용, 동일한 하위호환 폴백 구조. 다만 seq 정합성 로직 자체가 신규 버그 표면(랩어라운드, 오프바이원 등)을 열 수 있어 회귀 테스트 설계가 후보1보다 더 필요.

**후보 3 — cell-level `GridSnapshot`(스타일 보존 구조화 스냅샷) 신규 구현**

proto 스키마에 자리는 있으나(`docs/peer-federation-protocol.md`), 실제 송신 코드는 host 어느 쪽에서도(Rust `connection.rs`의 attach 처리, Swift `PeerServer.swift`의 `handleAttach`/resize 경로 모두) 발견되지 않았다 — 후보1과 결정적으로 다른 점은, 후보1은 "이미 동작하는 걸 옮기는" 것이지만 이건 **완전 신규 구현**이라는 것.

- 장점: cell 단위(문자+스타일 속성) 구조화 데이터라 raw-byte replay처럼 "옛 ANSI 시퀀스를 재해석시켜 현재 상태를 복원"할 필요가 없어 가장 근본적/완전한 해법; **리사이즈 케이스도 함께 해결 가능**(후보1·2와 달리) — 새 크기 기준 현재 grid를 그대로 구조화 전송하면 되므로 §비용분석-3도 이 경로로 흡수됨.
- 단점: 세 후보 중 엔지니어링 비용 최대 — 스키마상 필드만 있고 구현이 전무해 설계부터 시작; libghostty가 cell 단위 grid를 export하는 FFI API를 실제로 제공하는지 자체가 이번 조사 범위 밖에서 미확인(별도 선행 조사 필요); 압축이 스택 어디에도 없는 상태(`daemon/Cargo.toml` 등 zstd/gzip/lz4 의존성 grep 0건)에서 스타일 메타데이터까지 포함하면 payload가 plain-text보다 커질 수 있어 WAN에서 오히려 역효과 위험.
- 호환성: 필드 자체는 이미 있어 와이어 스키마 신규 추가는 불요하나, [C6]가 지적하듯 capability 게이팅이 미구현이라(`Hello.capabilities`가 모든 생성 지점에서 항상 빈 배열) 신버전 client가 구버전 host에 GridSnapshot을 기대했다가 못 받는 상황을 협상으로 구분할 방법이 없다 — capability 플러밍 선행 없이는 이 후보의 안전한 롤아웃 자체가 불가능(CONTEXT.md [C6] 그대로 적용).

**권고**: 1차 채택은 **후보1(Rust `ReplayBuffer` 패턴 이식)**을 권한다. 이미 코드베이스 안에 동작 검증된 참조 구현이 있어 설계 리스크가 가장 낮고, 가장 적은 신규 코드로 "ANSI 스타일 보존"이라는 가장 체감되는 개선을 달성하며, 부수적으로 host 화면까지 깜빡이게 만드는 현재의 Ctrl-L 강제 리드로우 땜질을 제거할 잠재력이 있다. `resumeFromSeq` 필드가 이미 proto에 있으므로 후보1을 발판 삼아 후보2(seq 기반 증분 재생)로 무중단 후속 확장이 가능하다 — 후보1과 후보2는 배타적 선택이 아니라 **단계적 관계**로 보는 것이 타당하다. 후보3(cell-level GridSnapshot)은 libghostty grid export API 존재 여부부터 미확인이고 이번 제안서의 스코프([D1] 산출물=제안 문서, 구현은 후속 프로젝트)를 넘는 선행 조사가 필요하므로, 이번 라운드에서는 "조사 필요" 항목으로 남기고 즉시 채택 후보에서는 제외할 것을 권한다 — 단, 리사이즈 풀 리페인트(§비용분석-3) 문제는 후보1·2 어느 쪽도 해결하지 못하므로, 리사이즈 축까지 근본적으로 개선하려면 결국 후보3(또는 그에 준하는 구조화 스냅샷)이 유일한 후보로 남는다는 점은 우선순위 결정(R5) 시 참고할 트레이드오프로 명시해 둔다.
### 분석 — 연결 수명주기·자원 사용 축 (t4)

R8(재연결/슬립 복구 SLO), R6(idle 상주 비용), R11(silent drop 가시화)을 다룬다. 세 항목 모두 실측(t6)이 "라이브 peer 세션 전무"로 막혀 있었으므로, 이하 수치는 전부 코드 상수 기반 산정 또는 추정이며 근거태그를 개별 명시한다. t6가 이미 계산해 둔 attach wall-clock 공식과 idle 대역폭 수치를 재사용하고, 부록B(t2)의 후보 번호(C#)를 교차 인용한다.

---

#### R8 — 재연결/슬립 복구 SLO

##### 현재 타이머 구조 — 중첩되지만 서로를 모르는 계층들

죽은 연결을 감지하는 계층은 과제 지시상 3겹(앱 하트비트·프로토콜 Ping·SSH keepalive) + 재연결 백오프 1겹으로 언급되지만, 코드로 명확히 확인되는 것은 사실 2겹뿐이다. `docs/peer-federation-protocol.md:85`가 기술하는 "프로토콜 레벨 Ping 15s/Pong 30s"는 실제 구현이 앱 레벨 하트비트(`Sources/PeerRelaySession.swift:702-710`, `swift/PeerProto/Sources/PeerProto/PeerSession.swift:112-132`, 10s 간격/30s dead)와 별도로 존재하는지 조사 단계에서 확인하지 못했다(notes.md 미확인 질문: "문서 표기와 실제 코드의 차이가 의도된 레이어 분리인지 단순 문서 미갱신인지 불확실"). 즉 "3계층"이 아니라 "2계층 + 문서에만 있을 수도 있는 유령 계층"일 가능성이 있다. 이하 타임라인은 과제가 지정한 4겹 전부를 반영해 최악치를 산정하되, 이 불확실성을 별도 리스크로 표기한다.

확인되는 두 계층과 백오프:

| 계층 | 주체 | 주기/임계값 | 근거 |
|---|---|---|---|
| 앱 레벨 하트비트 | client→host Ping, 30s 무응답 시 dead 판정 후 `transport.close()` | 10s 간격 / 30s dead | `Sources/PeerRelaySession.swift:702-710`, `PeerSession.swift:112-132` |
| SSH ServerAlive | ssh 프로세스 자체 keepalive | 15s × 3회 ≈ 45s | `Sources/PeerSSHTunnel.swift:244-245` |
| SSH 재연결 백오프 | `terminationHandler`→`scheduleReconnect` | 1,2,4,8,16,30,30…초, 최대 12회 | `Sources/PeerSSHTunnel.swift:339-364,368`(부록A #20 검증됨) |
| (미확인) 프로토콜 Ping | 문서 기술, 코드 실체 미확인 | 15s/30s(문서상) | `docs/peer-federation-protocol.md:85` — 별도 구현 여부 미확인 |

**핵심 리스크**: 연결 수명주기 시퀀스(§3)의 Reconnect 6·7번이 각각 "SSH 프로세스 종료 시 `terminationHandler`가 재연결을 개시"(6번)와 "앱 하트비트가 **별도로** 감지해 `transport.close()`"(7번)로 서술되어 있어, 두 메커니즘이 서로 다른 트리거라는 것은 코드 사실이다. 그러나 앱 하트비트의 `transport.close()`가 SSH 서브프로세스 자체를 강제 종료시켜 `terminationHandler`를 즉시 발화시키는지, 아니면 SSH는 자신의 45초 keepalive 타임아웃이 만료될 때까지 독립적으로 살아있는지는 코드로 확인되지 않았다(notes.md 미확인 질문 8번: "R8의 SLO 설정에 직접 영향"). 연동돼 있지 않다면 사용자는 ~30-40초 시점에 "연결 끊김"으로 인지하지만 실제 재연결 시도는 SSH 자체 감지가 끝나는 ~45초까지 시작조차 안 되는 5-15초의 사각 구간이 생긴다.

##### 최악 체감 정지 구간 산정 (T=0 = 호스트 슬립/네트워크 단절 시점)

1. **T+0 ~ T+30-40초**: 화면이 그냥 멈춘 것처럼 보인다. 이 구간엔 어떤 시각 피드백도 없다 — 배너(`PeerRelayBanner`/`PeerRelayBannerPresenter`, notes.md stack §1)는 존재하지만 "확정 dead" 판정 이후에만 걸리는 것으로 보이며, 조기 트리거 로직은 확인되지 않았다.
2. **T+~30-40초**: 앱 하트비트 dead 판정, `transport.close()` (산정, 위 표 근거).
3. **T+~45초**: SSH ServerAlive 자체 타임아웃 만료 — 2번과 연동이 확인되지 않은 경우 이 시점이 재연결 개시의 실제 하한이 된다(산정: 15×3).
4. **재연결 시도**: 백오프 1초 후 첫 시도. 네트워크가 실제로 돌아온 상태(수면/기상의 전형적 케이스)라면 1-2회 시도(1-3초) 내 성공 가능성이 높다. 호스트가 계속 응답하지 않으면 지수 백오프를 전부 소진할 때까지 최대 약 **241초(4분 1초)**가 누적된다(1+2+4+8+16+30×7=241, `PeerSSHTunnel.swift:339,368`) — 산정.
5. **터널 재개 후**: t6이 이미 계산해 둔 attach wall-clock 공식을 그대로 적용한다 — `핸드셰이크(≥2RTT) + listWorkspaces(1RTT) + N×[재핸드셰이크(2RTT)+attachSurface(1RTT)+acceptRelay 폴링(최대 100ms)]`(measurements.md 지표4). WAN RTT≈80ms 가정 시 N=1 약 0.58초, N=4 약 1.6초로 이미 5초 이내다(illustrative, 실측 아님).
6. **resumeFromSeq/GridSnapshot 미구현**(`PeerServer.swift:899`, 부록A #13 검증됨)이므로 재연결마다 스크롤백과 ANSI 스타일이 초기화된 plain-text 스냅샷으로 대체된다 — 정지 구간이 끝나도 "화면이 이전과 달라 보이는" 2차 위화감이 남는다.
7. Sleep/wake에 대한 별도 특수 처리 경로는 없다 — SSH 프로세스 종료 감지로 위 4-6번 경로를 그대로 탄다(`PeerSSHTunnel.swift:198-200,474-479`).

**따라서 핵심 결론**: 재연결 메커니즘 자체(핸드셰이크+attach, 5번)는 산정상 이미 수 초 이내로 빠르다. 체감 정지 구간의 실제 병목은 복구 메커니즘이 아니라 **감지 지연(30-45초)과 감지-복구 연동 불확실성**에 집중돼 있다 — SLO 개선 우선순위는 "재연결을 더 빠르게"가 아니라 "더 빨리 알아채고, 더 빨리 알리고, 감지와 복구를 확실히 연결하는 것"이어야 한다.

##### 제안 SLO 목표

| SLO 항목 | 목표 | 현재 상태(산정) | 주 병목 |
|---|---|---|---|
| 단절 시각 피드백 | ≤ 15초 | 없음 — 확정 dead 판정(30-40초)까지 무피드백 | 배너가 "확정 dead" 시점에만 트리거 |
| 자동 복구 개시 | ≤ 40초 | 최악 ~45초+α, 2번↔3번 연동 미확인이라 더 늘어날 가능성 있음 | 감지-복구 트리거 미연동(추정) |
| 화면 정상화(재연결 후, 소규모 워크스페이스) | ≤ 5초 | t6 산정: WAN 80ms, N=4 약 1.6초 — 이미 목표 이내 | N이 커지고 RTT가 나빠지면 초과(아래) |

N-pane 순차 구조의 실제 위험 구간: WAN RTT≈300ms(pitfalls §1.2가 실제 정합성 버그를 유발했던 "50-500ms 링크" 대역의 상단 근접치)에서는 pane당 비용이 약 1초로 늘어나, N=8이면 재연결 완료까지 약 9초가 걸려 5초 목표를 초과한다(산정: 3×0.3+0.1=1.0s/pane × 8 + 0.9s ≈ 8.9s). 우수한 WAN(80ms)에서는 문제없지만, 나쁜 WAN + 다중 pane 조합에서 목표가 깨진다는 뜻이다.

##### 달성 수단

1. **타이머 통합**: 앱 하트비트 dead 판정을 SSH 터널 강제 재시작의 명시적 트리거로 연결한다(현재 연동 여부부터 코드로 확인 필요 — 위 리스크). 연동되면 자동 복구 개시가 SSH 자체 감지(45초)가 아니라 앱 하트비트 시점(30-40초)으로 당겨진다.
2. **타이머 단축**: 하트비트 간격을 좁히면(예: 10s→5s, 30s→15-20s) 감지 지연이 절반 가까이 줄어들지만, 유휴 상태에서도 세션당 ping/pong 빈도가 늘어나 R6가 지적하는 idle 비용(아래 표 2번 항목)과 정면으로 충돌한다 — 두 축의 트레이드오프는 최종 제안서에서 함께 조정해야 한다.
3. **즉시 배너**: 신규 UI를 만들 필요 없이 기존 `PeerRelayBanner`/`PeerRelayBannerPresenter`를 "확정 dead"가 아니라 **첫 heartbeat 미스 시점**(~10-15초)에 optimistic "재연결 중" 상태로 조기 발동시킨다 — 시각 피드백 SLO(≤15초)를 감지 메커니즘 자체를 바꾸지 않고도 달성 가능.
4. **resumeFromSeq 구현**: 프로토콜에 이미 정의된 필드를 host(Swift)가 실제로 읽고 처리하도록 구현한다(부록B C3). Rust 경로의 `ReplayBuffer`(64KB, raw byte, ANSI 보존) 패턴이 이식 참고 대상이다(architecture-verify 검증1 근거7). 단 이 항목은 host+client 양쪽 업데이트가 필요한 계층이며(모듈 경계표), capability 게이팅이 현재 미구현(CONTEXT C6, pitfalls §5.2)이라 그 플러밍이 선행 조건이다.
5. **N-pane 병렬 재attach**: 냉시작 attach뿐 아니라 재연결 경로에도 `withThrowingTaskGroup` 적용(부록B C2)을 그대로 재사용하면, 위 "나쁜 WAN + 다중 pane" 초과 시나리오가 N배가 아니라 max(개별 pane 지연)로 수렴한다 — client 단독 배포, 와이어 변경 불요.

---

#### R6 — idle 상주 비용 항목표

relay 창이 열려 attach된 채로 입출력이 전혀 없는 상태에서도 확정적으로 발생하는 비용이다. 공통적으로, client가 pane마다 완전히 독립된 세션을 새로 여는 구조(architecture-verify 검증2 — host는 이미 다중 attach를 지원하지만 client가 그 기능을 쓰지 않음)이기 때문에 아래 항목 대부분이 **pane 수에 선형으로 곱해진다**는 것이 공통 패턴이다.

| 항목 | 비용 | 근거태그 | 근거 |
|---|---|---|---|
| `term-mesh-peer-relay` idle 폴링 웨이크업 | pane당 확정적으로 초당 10회(recv_timeout 100ms) — 완전 유휴에도 발생, N-pane이면 N배 | 산정 | `daemon/term-mesh-peer-relay/src/main.rs:667`(부록A #5 검증됨, 부록B C10) |
| 하트비트(앱 레벨, pane-세션당 독립) | 세션당 0.2 msg/s(Ping+Pong), 메시지 자체는 약 10-20B/frame→2-4B/s로 무시 가능한 수준이나, 세션 비공유 구조 때문에 N-pane 워크스페이스는 (N+1)개(각 pane + `subscriptionSession` 1개)의 독립 heartbeat 사이클이 병렬 존재 — **바이트가 아니라 wakeup 빈도가 (N+1)×0.2/s로 선형 증가하는 것이 진짜 비용** | 산정(t6 계산 재인용) | `Sources/PeerRelaySession.swift:702-710`, `PeerSession.swift:112-132`, host 수동응답 `PeerServer.swift:836-841`; N-pane 배수는 measurements.md(t6) 지표5, architecture-verify 검증2 |
| SSH ServerAlive 킵얼라이브 | 15초마다 패킷 1개(WAN/셀룰러 배터리 관련). 정확 바이트 수는 OpenSSH 내부 구현이라 코드로 확정 불가. pane별로 독립 SSH 터널이 뜨는지(N배 곱) 여부는 미확인 | 산정(주기·존재) + 추정(pane당 독립 개수) | `Sources/PeerSSHTunnel.swift:244-245` |
| pane당 상주 프로세스 + 2차 로컬 소켓 | pane 1개 attach = OS 프로세스 1개(`term-mesh-peer-relay`) + 전용 유닉스 소켓(`/tmp/term-mesh-relays-<uid>/<uuid>.sock`) + reader/writer 전용 DispatchQueue 2개 + 256슬롯 세마포어 구조체, 입출력 유무와 무관하게 attach 유지=프로세스 유지 | 산정 | `Sources/PeerRelaySession.swift:69-97,203,263,579` |
| GPU occlusion 미회수(확정) | peer relay 창 2종 모두 occlusion 알림 구독·`setRendererRealized` 호출이 전무(199줄+1654줄 전체 정독, grep 0건) — 정상 로컬 pane은 비가시 5초 후 회수되나 relay 창은 백그라운드로 가도 전혀 회수 안 됨. pane당 ~1.5-6MB는 별도 과거 조사 실측치 인용(그 조사 자체도 재검증 플래그 있음, 본 조사에서 재계측 안 함) | 산정(배선 부재, 확정) + 추정(바이트 수치) | pitfalls-verify 검증1, `Sources/PeerRelayWindowController.swift`(199줄 전체), `PeerRelayWorkspaceWindowController.swift`(1654줄 전체), `[[ghostty-metal-renderer-gpu-leak]]`(부록B C11) |
| Rust `ReplayBuffer` 64KB/surface(Rust 경로 한정) | `tm-agent peer attach`(headless, `TERMMESH_PEER_SOCKET` opt-in) 경로에서 surface당 고정 64KB `Mutex` 버퍼. attach 여부와 무관하게 spawn 시점부터 점유할 가능성(PtyManager 수명주기 미확인). Swift GUI 경로는 대응 버퍼가 아예 없음(스타일 유실과 맞바꾼 트레이드오프) | 산정(캡 자체) + 추정(수명주기) | `daemon/term-meshd/src/peer/surface.rs:43`(부록A #3 검증됨, 부록B C15) |
| 연결 목록 창 1초 폴링(조건부) | `PeerConnectionsWindowController`가 열려 있는 동안만 초당 1회 UI 갱신 — 창을 닫으면 0, 다른 항목과 달리 상시 비용 아님 | 산정 | `Sources/PeerConnectionsWindowController.swift:87` |
| Swift `PtyTapHub` 등록 콜백(호스트측, attach된 surface당) | 개별 비용은 미미하나 attach 유지 중 상시 존재, 정확한 바이트 비용은 미계측 | 추정 | `Sources/GhosttyPaneSurfaceProvider.swift:39-94` |

가장 확정적인 두 항목(10Hz 웨이크업, GPU occlusion 미배선)은 둘 다 즉시 축소 가능하고 와이어 변경이 불요하다(client-only 또는 host-only 단독 배포). 나머지 항목 대부분은 개별 비용이 작더라도 "세션 비공유" 구조(R8의 근본 원인이기도 함) 때문에 pane 수에 선형으로 곱해진다는 공통점이 있어, 세션 공유(부록B C8)가 구현되면 이 표의 heartbeat·프로세스·소켓 항목 대부분이 동시에 개선된다.

---

#### R11 — silent drop 가시화 결정

##### 현황: Swift와 Rust의 비대칭

빠른 producer(예: `cat bigfile`, `yes`)가 broadcast 채널 용량을 넘어서면 두 구현이 서로 다르게 반응한다.

- **Rust**: `tokio::broadcast`(capacity 1024) 구독자가 뒤처지면 `RecvError::Lagged(n)`을 받고 `tracing::warn!("attach relay lagged, missed {n} chunks")` 로그만 남긴 뒤 `continue`한다(`daemon/term-meshd/src/peer/connection.rs:393-397`, 부록A #25 검증됨) — 최소한 **로그로는 남는다**.
- **Swift**: 피어별 `AsyncStream<Data>`가 `.bufferingNewest(256)`이라 느린 소비자는 **가장 오래된 청크부터 조용히 덮어써진다** — 대응하는 로그도 카운터도 전혀 없다(`Sources/GhosttyPaneSurfaceProvider.swift:70,81-94`, 부록A #16 검증됨).

둘 다 공통적으로 **재동기화 메커니즘이 없다**. 문서(`docs/peer-federation-protocol.md:322-327`)가 기술한 "unacked_bytes > 8MiB 시 드롭 + `ERR_INTERNAL` + client의 `GridSnapshot` 재요청" 흐름은 코드 전수검색 결과 0건이며, 주석조차 "Protocol-level re-sync (GridSnapshot) lands in a later phase"라고 인정한다(pitfalls §5.2, CONTEXT C6). 즉 드롭이 발생하면 로그(Rust만) 외에는 아무 일도 일어나지 않는다.

##### 사용자 체감 증상 정의

이 드롭은 "텍스트 일부가 사라짐" 수준이 아니다. PtyData는 VT100 이스케이프 시퀀스를 포함한 순서 의존적 바이트 스트림이므로, 중간 청크가 통째로 빠지면 클라이언트측 Ghostty의 터미널 파서가 **불연속 스트림**을 받게 된다. 빠진 구간에 커서 이동·색상 변경·모드 전환 시퀀스가 걸쳐 있었다면, 이후 도착하는 정상 바이트들이 잘못된 파서 상태 위에서 해석되어 커서 위치 어긋남·색상 오염·유령 문자 등으로 나타날 수 있다. 그리고 이 상태는 **자연 복구되지 않는다** — 현재 유일한 전체 화면 재동기화 경로는 리사이즈 시 트리거되는 `ESC[2J`+plain-text 스냅샷 재전송(`GhosttyPaneSurfaceProvider.swift:312-331`)뿐이며, 이는 실제 창 크기 변경이 있어야만 발동하고 drop 감지와는 전혀 연결돼 있지 않다. 즉 사용자가 우연히 창 크기를 바꾸지 않는 한, 한 번 어긋난 화면은 다음 재연결(수십 초 소요, R8 참조)까지 그대로 남는다 — 사용자 입장에서는 원인 불명의 "화면이 이상해졌는데 아무것도 안 하면 안 고쳐지는" 버그로만 보인다. `[[terminal-mode-leak-sleep-ssh]]` 메모리가 기록한 "SSH 세션 생명주기와 터미널 모드 동기화가 독립적"이라는 구조적 문제와 증상 계열은 다르지만(저건 세션 종료 시 모드 잔존, 이건 연결 유지 중 스트림 중간 소실) "터미널 렌더링 상태 머신이 전제하는 바이트 연속성을 peer relay 경로가 조용히 깨뜨릴 수 있다"는 동일 범주의 위험이다.

##### 결정: 채택 — 2단계로 스코프를 나눈다

가시화 작업을 이번 제안서 스코프에 **포함한다**. 근거는 (1) 실패 시 증상이 사용자에게 원인 불명의 영구적 화면 오염으로 나타나고 (2) C3(임시 계측 수준 실측만 허용)에 카운터/dlog 추가가 정확히 부합하며 (3) 아래 1·2단계는 와이어 변경이 전혀 없는 host-only 작업이라 CONTEXT C1의 호환성 리스크가 사실상 0이기 때문이다(`PtyTapHub.broadcast()`와 `connection.rs`의 broadcast 구독 모두 100% 호스트측 코드 — architecture 용어 기준 "host"). 단, 우선순위는 낮은 노력·높은 확실성 항목부터 낮은 확실성 항목 순으로 계층화한다.

1. **즉시(host-only, 무배선 변경)**: Swift `.bufferingNewest` 드롭 경로에 카운터+dlog를 추가해 Rust와 동일한 최소 가시성을 확보한다(현재 Rust만 `warn!` 로그 보유, Swift는 전무). Rust의 기존 로그도 카운터로 집계해 `tm-agent`/상태 조회에서 노출 가능하게 만든다. 이 자체는 사용자에게 아무것도 보여주지 않지만, 향후 인시던트 상관분석과 R9(RTT 계측 스코프 결정)의 계측 기반으로 재사용 가능하다(부록B C17).
2. **후속(host-only, 무배선 변경, 이번 제안서의 핵심 권고)**: drop 감지 시 host가 리사이즈 트리거와 동일한 기존 경로(clear+plain-text 스냅샷 재전송, `GhosttyPaneSurfaceProvider.swift:312-331`)를 **해당 client에게만 자동으로 재호출**한다. 새 메시지 타입이나 필드가 필요 없다 — 이미 정의된 "스냅샷 재전송" 동작을 새로운 트리거(사용자의 리사이즈 대신 host의 drop 감지)로 발동시키는 것뿐이다. 사용자는 에러 메시지 없이 화면이 짧게 깜빡였다가 정상화되는 정도로만 체감한다. 이 항목이 R11의 실질적 권고안이다 — "영구 어긋남"을 "일시적 깜빡임"으로 바꾼다.
3. **기각(이번 제안서 범위 밖)**: 사용자에게 "일부 출력을 놓쳤습니다"를 명시하는 배너/메시지는 새 wire 필드·capability 게이팅(현재 미구현, CONTEXT C6·부록B C20)이 선행돼야 하는 데다, 2단계가 조용히 자동 복구되면 애초에 사용자가 배너를 볼 필요성 자체가 줄어든다 — effort 대비 이득이 불확실해 이번 제안서에서는 우선순위를 낮춘다. 배압 정책 전체(문서의 8MiB 임계치 등, 부록B C19)를 새로 설계하는 것도 같은 이유로 별도 후속 항목으로 분리한다.
### 실측 (t6)

기준 커밋: `0fd6bd97c7f5710c8680c65badf590e364d1c42b` (develop, 2026-07-09). 측정 시각: 2026-07-09 (오늘).

#### 환경 스냅샷

절차대로 3단계 확인 후 진행했다.

1. **term-mesh 앱 프로세스** (`pgrep -lf "term-mesh"`) — 3개 발견:
   - `/Applications/term-mesh.app/Contents/Resources/bin/term-meshd` (PID 1585, Release/프로덕션)
   - `/tmp/term-mesh-connect-peer-stability/.../term-mesh DEV connect-peer-stability.app/.../term-meshd` (PID 51030, 태그된 Debug 빌드)
   - `/Users/jinwoo/work/project/term-mesh/daemon/target/debug/term-meshd` (PID 68904, 소스트리 dev 데몬)
   → 앱/데몬 자체는 떠 있으나, 아래 2·3에서 보듯 **peer federation 관련 활성 세션은 전무**.

2. **peer 세션 존재 확인** — 3중 교차 검증, 전부 "없음":
   - `pgrep -lf term-mesh-peer-relay` → 프로세스 없음 (재확인: `ps aux | grep -i peer-relay`도 0건)
   - `/tmp/term-mesh-relays-501/` (세션별 relay 소켓 디렉토리, `PeerRelaySession.swift:579` 규약) → **비어있음** (최종 수정 Jul 8 22:09, 그 이후 재생성된 세션 없음)
   - `/tmp/term-mesh-peer-501/peer.sock` (Swift `PeerServerHost` 기본 경로, `PeerFederationSettings.swift:22`) → 소켓 파일 자체는 존재하나 **Jun 26 09:15 이후 미변경(13일 전 잔존 아티팩트)**이고 `lsof -U`로 열어본 결과 **현재 이 소켓을 열고 있는 프로세스가 0개** — 즉 host 측 peer 서버조차 지금 리스닝 중이 아님(단순히 클라이언트가 없는 게 아니라 서버 자체가 죽어있는 상태로 판단).
   - 참고로 `/tmp/tm-peer-swift-c3c-95A28645.sock`도 발견됐으나 문서화된 3개 채널 경로 어디에도 해당하지 않는 13일 전 임시/디버그 아티팩트로 판단해 무시.

3. **데몬** — `/tmp/term-meshd.sock` 존재(로컬 앱↔데몬 JSON-RPC 채널, peer federation과 무관한 채널 (c)), 3개 daemon 프로세스 모두 살아있음. peer federation 채널과는 별개이므로 이 항목은 지표 측정 가능성에 영향 없음.

**결론: 라이브 peer 세션이 전혀 없다(클라이언트 attach는 물론, host 서버 리스닝조차 없음).** 지시에 따라 새 세션을 만들려는 시도(앱 조작)는 하지 않았다. 이하 5개 지표 전부 이 부재가 1차 제약이 된다.

#### 지표

| # | 지표 | 방법/명령 | 값 또는 불가사유+대체근거 | 근거태그 |
|---|---|---|---|---|
| 1 | keypress → remote-echo RTT | 라이브 세션 필요(`DataAck` 기반 RTT 계측을 시도할 예정이었으나 프로토콜 상 미구현). 시도: 위 §환경 스냅샷 3중 확인 → 세션 없음. | **실측 불가**(사유: 라이브 peer 세션 부재). 코드 산정 하한: 평상 타이핑(단독 ESC 아님·백프레셔 없음) 경로에는 **코드가 강제하는 지연이 전혀 없다**. 왕복은 입력 16-hop + 출력 15-hop ≈ 31-hop(notes.md §architecture)이며, 그중 시간이 명시된 항목은 오직 3개의 **조건부** 게이트뿐: ESC_FLUSH_TIMEOUT_MS=100ms(`daemon/term-mesh-peer-relay/src/main.rs:745`, 단독 ESC pending 시에만), peerPendingTailFlushDelayNanos=120ms(`Sources/GhosttyPaneSurfaceProvider.swift:729`, host측 미완성 ESC-prefix 보류 시에만), EAGAIN 1ms 재시도(`swift/PeerProto/Sources/PeerProto/PeerServer.swift:637`·Rust `pty.rs:134`, 소켓/PTY 역압 시에만). 이 셋을 걷어내면 남는 31개 hop은 전부 로컬 syscall(read/write/poll)·액터/DispatchQueue 홉·protobuf 인코딩이며 코드상 최소보장시간이 없다 — 실질적 하한 공식은 **"2×네트워크 RTT(코드 밖 변수) + Ω(31개 syscall/스케줄링 홉, 개별 미계측)"**. 프로토콜이 RTT 측정용으로 설계한 `DataAck`(`proto/peer/v1/peer.proto:385-388` "Advisory: clients may send periodically for RTT measurement") 자체가 Swift/Rust 양쪽 다 미구현이라(notes.md 확인) 이 지표는 애초에 상시 계측 통로가 없는 상태다. | [R1][R9] |
| 2 | idle wakeup (`term-mesh-peer-relay` 10Hz recv_timeout 루프) | 프로세스 있었으면 `ps -o pid,%cpu,etime -p <pid>` 3회(10s 간격) 예정. `powermetrics`는 sudo라 처음부터 배제. | **실측 불가**(사유: `term-mesh-peer-relay` 프로세스 미기동 — Connect to Peer relay 창이 열려있지 않음). 코드 산정(확정치): `daemon/term-mesh-peer-relay/src/main.rs:667` `rx.recv_timeout(Duration::from_millis(100))`가 유휴 상태에서도 블로킹 recv를 100ms 타임아웃으로 감싸므로, 데이터 유입이 0이어도 **정확히 초당 10회(10Hz) wakeup이 결정론적으로 발생**한다. 이건 상수 기반 산술이라 런타임 실측 없이도 100% 확정치로 봐도 된다(실측이 확인할 수 있는 건 "정말 그 값인가"가 아니라 CPU%/전력 영향 쪽). | [R6] |
| 3 | PTY 청크 크기 분포 | `ptyTapCallback`(Swift) 또는 `surface.rs` read 루프(Rust)에 히스토그램 계측 추가 필요 — **프로덕션 코드 수정 금지 제약으로 시도하지 않음**. | **실측 불가**(사유: 계측 코드 부재 + 코드 수정 금지). 코드 산정: Rust 경로(`daemon/term-meshd/src/peer/surface.rs:35` `READ_BUF_SIZE: usize = 4096`)는 `read(2)` 1회당 **최대 4096바이트 상한**이 코드에 명시돼 있어 사실상 청크 크기 상한 겸 배칭 단위로 쓸 수 있다 — 단 이건 상한이지 평균/분포는 아니다(실제 분포는 PTY에 몇 바이트가 준비돼 있었는지에 달림, 그 자체는 미계측). Swift 경로(GUI 프로덕션 경로, `Sources/GhosttyPaneSurfaceProvider.swift:26-34` `ptyTapCallback`)는 Ghostty 코어 내부의 PTY read 배치 크기에 의존하며 FFI 경계 안쪽이라 **term-mesh 코드 리딩만으로는 상한조차 확정 불가**[추정, notes.md에 이미 동일하게 기재]. Rust와 Swift는 서로 다른 데이터플레인(각각 headless CLI attach 전용 vs 실사용 GUI 경로, architecture-verify 검증1)이므로 이 상한을 그대로 GUI 경로에 대입해 일반화하면 안 된다. | [R9] |
| 4 | attach wall-clock | 라이브 세션에서 신규 attach 실행 필요 — **앱 조작 금지 제약으로 시도하지 않음**(신규 Connect to Peer 트리거는 UI 조작에 해당). | **실측 불가**(사유: 라이브 peer 세션 부재 + 신규 attach 트리거 금지). 코드 산정 하한 공식(notes.md §architecture §3 근거): `핸드셰이크(최소 2 RTT, PeerSession.swift:162-180/PeerServer.swift:742-786) + listWorkspaces(1 RTT, PeerRelayWorkspaceWindowController.swift:301) + N×[pane당 순차 재핸드셰이크(2 RTT, PeerRelaySession.connect 재수행) + attachSurface(1 RTT) + acceptRelay 폴링 granularity(최대 100ms, PeerRelaySession.swift:721-755)] + (신규 생성 pane인 경우만) lazy-init 폴링 상한 300ms(10×30ms, GhosttyPaneSurfaceProvider.swift:144-149,153-158)`. pane N개는 `PeerRelayWorkspaceWindowController.swift:1049-1075`가 `TaskGroup` 없이 순차 `for-await` 루프임이 코드로 확정(부록A row #21)이라 **attach 시간이 pane 수에 선형 비례**하는 것은 산정이 아니라 코드 사실이다. N=1(단일 pane, warm) 기준 illustrative 시나리오(RTT는 **가정값**, 실측 아님): LAN RTT≈1ms → 6RTT+100ms ≈ **106ms**(100ms 폴링 granularity가 지배); WAN RTT≈80ms → 6×80ms+100ms ≈ **580ms**(네트워크 RTT가 지배). N=4 pane, WAN RTT≈80ms 예시: 3RTT(workspace) + 4×(3RTT+100ms) = 240ms+1360ms ≈ **1.6s**. | [R7][R10] |
| 5 | idle 대역폭(하트비트) | 라이브 세션 불필요 — 프로토콜 상수 + `peer.proto` 스키마 산술로 순수 계산. | **산정됨**(계산, 실측 아님 — 라이브 세션 있었어도 바이트 카운터 없이는 이 자체가 신규 계측 필요 항목이었을 것). 세션(pane)당: 앱 레벨 heartbeat는 client가 10초 간격 Ping을 보내고 host는 Pong만 수동 응답(`Sources/PeerRelaySession.swift:704-706`, `swift/PeerProto/Sources/PeerProto/PeerSession.swift:113-114`, host 수동성: `PeerServer.swift:836-841`) → **세션당 0.2 msg/s**(Ping+Pong 합산). 메시지 크기(`proto/peer/v1/peer.proto` 직접 확인): `Envelope{seq(uint64 varint,~1-2B) + oneof tag(field 50/51, 2바이트 태그+1바이트 length) + Ping{nonce:uint64 varint,~2-10B}}`(`peer.proto:25-60,446-452`) + 프레임 4바이트 length-prefix(`daemon/term-meshd/src/peer/framing.rs:13-27`) ≈ **세션당 약 10~20 bytes/frame → 약 2~4 bytes/s**(무시 가능한 수준). 단, client가 세션 멀티플렉싱을 쓰지 않는다는 게 이미 코드로 확정돼 있어(architecture-verify 검증2 — host는 다중 attach 지원하나 client가 pane마다 별도 세션 생성) N-pane 워크스페이스는 pane N개 + `subscriptionSession` 1개 = **(N+1)개의 독립 heartbeat 사이클이 병렬로 존재** → 총 바이트는 여전히 미미(N=8이어도 <40 B/s)하지만 **wakeup 횟수는 (N+1)×0.2/s로 선형 증가**(지표 2·R6과 연결되는 관찰 — idle 비용의 진짜 병목은 바이트가 아니라 wakeup 빈도). WAN 한정 추가 비용: SSH `ServerAliveInterval=15s`(`Sources/PeerSSHTunnel.swift:244-245`) keepalive 패킷은 OpenSSH 자체 구현(암호화/MAC 오버헤드 포함, term-mesh 코드 밖)이라 **정확 바이트 수는 코드 근거로 확정 불가** — 존재와 주기만 코드로 확정. | [R6][R9] |

#### R9 계측 전략 입력용 관찰

5개 지표 전부가 "라이브 세션 부재" 또는 "계측 코드 부재"로 실측이 막혔다는 사실 자체가 R9(상시 계측 vs 임시 계측 스코프 결정)에 직접적인 입력이 된다. 구체적으로 네 가지가 확인됐다. 첫째, 프로토콜이 RTT 측정용으로 이미 설계해 둔 `DataAck`(`proto/peer/v1/peer.proto:385-388`, "Advisory: clients may send periodically for RTT measurement and so the host can trim its reconnect ring buffer")가 Swift·Rust 양쪽 다 실제로는 미구현이다 — 지표 1(RTT)을 상시 계측하려면 이 필드부터 배선해야 하는데, 이는 "이번 제안서는 임시 계측만으로 완결"이라는 선택지를 좁힌다(임시 계측조차 프로토콜 필드 자체가 없으면 걸 곳이 마땅치 않다). 둘째, 입력·출력·attach 경로 전체를 통틀어 "몇 ms 걸렸는가"를 남기는 dlog/tracing이 전무하다 — 기존 계측은 전부 실패·라이프사이클(연결 성공/실패, focus, zoom, tapHub deinit)이지 타이밍이 아니다(notes.md §3 기존 계측 인벤토리). 셋째, 지표 3(PTY 청크 크기)은 Swift 경로가 Ghostty FFI 경계 안쪽이라 term-mesh 코드 수정만으로는 닿지 않고, 계측하려면 ghostty submodule 쪽 변경(더 무거운 롤아웃, xcframework 재빌드 필요)이 필요할 수 있다. 넷째, 지표 2(idle wakeup)의 CPU/전력 영향은 `powermetrics` 없이는 코드 밖에서 관찰할 방법이 없어, 무권한 대안은 살아있는 프로세스의 `ps etime/%cpu` 샘플링뿐인데 그마저 라이브 프로세스가 있어야 한다 — 이번처럼 세션이 없는 환경에서는 그 대안조차 막힌다.

#### R10 환경 한계 관찰

이번 실측은 단일 macOS 개발 워크스테이션에서 수행됐고, 라이브 LAN·WAN peer 세션 자체가 하나도 없어(§환경 스냅샷) 두 환경을 비교 실측하는 것이 애초에 불가능했다. 코드베이스가 이미 LAN·WAN을 100% 동일한 SSH 터널 코드 경로로 처리하므로(Native TCP D-3b는 아직 TODO — notes.md), "코드가 다르다"가 아니라 "네트워크 RTT/대역폭 특성만 다르다"가 정확한 표현이다. 위 지표 1·4에 넣은 LAN(~1ms)/WAN(~80ms) 수치는 illustrative 가정값이며 실측이 아니다 — 실제 SSH 터널 RTT는 지리적 거리·경로에 따라 수십~수백 ms까지 벌어질 수 있어, 지표 4의 "100ms 폴링 granularity가 지배하는 구간"과 "네트워크 RTT가 지배하는 구간" 사이의 실제 교차점은 이번 조사로는 확정할 수 없다. 또한 `tc`/`dummynet` 등 인위적 네트워크 지연 시뮬레이션 하네스가 저장소 전체에 전무함을 기존 조사가 이미 확인했다(notes.md §3 측정 함정, "재현 가능한 WAN 지연 시뮬레이션 하네스가 전무") — 재현 가능한 WAN 벤치마크 방법론 자체를 이번 제안서의 선행 과제로 포함할지 검토할 필요가 있다.

## 매트릭스와 결정

### 매트릭스 — 후보 산정 (t5)

**방법론 note**: 실측(t6)이 5개 지표 전부 "라이브 세션 부재"로 막혀 있으므로, 아래 impact/effort는 전부 **산정**(코드 상수·구조·검증완료 사실에서 도출) 또는 **추정**(정량 근거 없는 추론)이며 개별 근거태그를 impact 칸에 표기한다. 근거로는 R1의 hop 분해(구간 A-G)와 t3가 처음 발견한 "client측 ESC 홀드(100ms, `ESC_FLUSH_TIMEOUT_MS`)+host측 ESC 홀드(120ms, `peerPendingTailFlushDelayNanos`)가 독립적으로 이중 존재 — 이론상 최대 220ms 누적"이라는 관찰, t4/t6의 R6·R8·R9·R10 산정치(attach wall-clock N-선형 공식, WAN 4-pane≈1.6초, 10Hz idle wakeup 확정치, heartbeat (N+1)-선형 wakeup), architecture-verify/pitfalls-verify의 두 "확정" 검증(세션 멀티플렉싱 host 무변경 가능·GPU occlusion 미배선 확정)을 직접 활용했다. 220ms ESC 이중홀드 자체는 최적화금지목록이 보호하는 판별 알고리즘이라 이를 "고치는" 후보는 없으며, C1(배칭이 이 경로와 별개임을 확인)과 C16(optimistic echo가 이 모호성을 client가 더 적은 정보로 재현해야 하는 리스크)에만 근거로 인용된다.

**선행조건 규칙 적용**: CONTEXT [C6]은 capability 게이팅(C20)과 배압/재동기화(C19) 둘 다 와이어 변경 제안의 선행조건으로 명시하라고 요구한다. 다만 성격은 다르다 — C20은 **하드 선행조건**(협상 메커니즘 자체가 없으면 구버전 상대와의 안전 배포가 원천 불가)이고, C19는 pitfalls §5.5 "안전 롤아웃 순서"가 권고하는 **소프트 선행조건**(먼저 하는 편이 안전하다는 순서 권고이지, 없으면 다른 후보가 기술적으로 동작 자체를 안 하는 것은 아님)이다. 아래 표는 C6 요구대로 두 항목을 와이어 변경 후보(C12·C13, 그리고 조건부로 C3·C7·C19·C21의 GridSnapshot 경로)의 선행조건으로 명시하되 하드/소프트를 구분해 표기한다. **C1(PtyData 배칭)은 판단 결과 이 선행조건 대상에서 제외한다** — 모듈경계표가 명시하듯 배칭은 PtyData 필드 자체를 바꾸지 않고 빈도/크기 분포만 바꾸는 와이어 불변 변경이기 때문이다.

| C# | impact(H/M/L+근거태그) | effort(S/M/L) | 호환성{client-only\|host-only\|양측\|와이어} | LAN/WAN 효과 | SSH-한정 여부 | 비고 |
|---|---|---|---|---|---|---|
| C1 | H(산정·추정) — 축②④, R1 구간C(8홉 중 5홉 출력측 집중, "초당 수천 번" 발동 가능)가 지목한 배칭 부재 확인 + 고빈도 누적 CPU/처리량 영향 추정 | M | host-only(대칭 위해 client도 가능) | 둘 다 유효(WAN 대역폭에도 도움) | 아님(Native TCP 이후도 유효) | 와이어 불변(PtyData 필드 그대로, 빈도·크기 분포만 변화)이므로 **선행조건 규칙에서 제외 — 판단**. 참고 패턴 `RelayResizeCoalescer`(24ms) 재사용 가능. 이 배칭은 출력(PtyData broadcast) 경로 한정이며, 입력측 client(100ms)+host(120ms) 이중 ESC 홀드(t3 신규발견, 이론상 최대 220ms 누적)와는 완전히 별개 경로 — 최적화금지목록의 ESC 판별 알고리즘 자체는 건드리지 않음 |
| C2 | H(산정) — 축③, TaskGroup 부재로 attach 지연이 pane 수에 선형비례하는 것이 코드 사실(추정 아님), t6 지표4가 WAN N=8·RTT 300ms에서 약 8.9초로 R8 SLO(5초) 초과를 구체 산정 | S | client-only | 둘 다 유효(WAN서 효과 더 큼) | 아님 | R7 결정의 핵심 후보. C8(세션 공유)과 배타적이지 않음 — 결정 참조(병행 채택) |
| C3 | M(추정) — 축③, R4 후보2(seq 기반 증분 재생). 효과 자체는 후보1(C15) 위에 얹는 증분 개선이라 단독 impact는 중간 | L | 양측(효과 조건) | 둘 다 유효(WAN서 blip 재전송 절감 효과 더 큼) | 아님 | R4 권고: 후보1(C15) 선행 후 단계적 확장. 필드는 이미 proto에 존재하나 seq 정합성(랩어라운드 등) 신규 버그표면 — 회귀테스트 신설 필요. C19/C20의 하드 선행조건 대상은 아님(신규 필드 없음) |
| C4 | M(추정, 잠재 H이나 하향) — 축①④, R1 구간A+B(12/31 hop) 제거 잠재력이나 libghostty의 PTY 없는(PTY-less) 바이트 feed API 존재 자체가 미확인 | L | client-only | 둘 다 유효 | 아님 | **판단**: R4 후보3(GridSnapshot)과 동일하게 FFI 존재 여부가 미확인 상태 — R4가 후보3을 "조사 필요, 즉시채택 제외"로 내린 것과 동일 논리를 적용해 이번 라운드는 조사 항목으로 하향. ghostty fork 변경 시 서브모듈 push 정책 적용 + xcframework ReleaseFast 재빌드 필요(5개 병목표 후보 중 effort 최대, architecture §5 그대로) |
| C5 | M(산정·추정) — 축④(WAN 한정), R1 D-2가 지목한 유일한 코드확인 WAN 전용 리스크(주석이 스스로 "PoC keeps it simple" 자인) | S | host-only | WAN 전용 효과(LAN 정상부하 시 미발동) | 아님(Native TCP에도 역압 개념은 존재) | read 경로(`PeerServer.swift:596-615`)에 이미 `DispatchSourceRead` 대칭 패턴 존재 — 참고 구현 있어 effort 낮음 |
| C6 | M(산정·추정) — 축③, 폴링 구조 자체는 확인되나 실제 절감폭은 추정 | M | client-only | 둘 다 유효 | 아님 | 최적화금지목록 M등급 리스크(`acceptRelay` O_NONBLOCK) 직접 해당 — "어설픈 논블로킹 유지 시 첫 read EAGAIN에 세션 즉시종료 재현" 회귀 위험. C2의 순차 loop와 곱연산 관계라 C2와 결합 시 상승효과 |
| C7 | H(산정) — 축②③, 스타일 유실 + host측 Ctrl-L 부작용(다른 사용자 화면까지 영향)이 코드로 확정 | M | host-only(C15 경로 기준) | 둘 다 유효(WAN서 스냅샷 대역폭비용 더 큼) | 아님 | C15(후보1)와 묶어 처리 시 M. 후보3(cell-level GridSnapshot) 경로로 가면 C4·C21과 동일한 FFI 불확실성을 상속해 L로 상승 — R4 권고(후보1 우선)를 반영해 M으로 산정. 검증에는 C22(grid 조회 API) 선행 필요(R15) |
| C8 | H(산정) — 축③④, host 무변경 수용 가능이 architecture-verify 검증2로 **검증완료**, R6 heartbeat·프로세스·소켓 항목 대부분과 동시개선 | S(좁은 범위 기준; 완전통합 시 L) | client-only | 둘 다 유효(WAN서 handshake RTT 절감 효과 더 큼) | 아님 | R7 결정의 핵심 후보이자 이 매트릭스 전체에서 R6·R7을 동시에 해결하는 가장 파급력 큰 단일 후보. 결정 참조 — 좁은 범위(항목2+3, `PeerRelaySession.swift:836-842` 필터+팩토리 오버로드) 채택 권고 |
| C9 | L(추정) — R1 구간F, "이 특정 홉이 실제로 지연을 유발한 사례는 미확인" | M(조사 선행, 결과에 따라 가변) | host-only | 둘 다 유효하나 절대영향 미미 | 아님 | 원문 자체가 "구조적 제약일 가능성 높아 우선순위 낮음"으로 결론. Ghostty API 메인스레드 전용 여부 확인이 선행돼야 effort 자체가 확정됨(구조적 제약이면 채택 불가) |
| C10 | H(산정, 확정치) — 축④, 상수 기반 산술이라 실측 없이도 100% 확정(t6 지표2) | S | client-only | 둘 다 동일(네트워크 무관) | 아님 | R6 "가장 확정적인 두 항목" 중 하나. 즉시 축소 가능·와이어 변경 불요 |
| C11 | H(산정, 확정) — 축④, pitfalls-verify 검증1이 high confidence로 확정(199줄+1654줄 전체 정독, occlusion 배선 0건) | S | client-only | 둘 다 동일(네트워크 무관) | 아님 | R6 "가장 확정적인 두 항목" 중 나머지 하나. C10과 페어로 최우선 채택 권고. 바이트 수치(1.5-6MB/surface)는 재검증 플래그 있는 과거 조사 인용값 |
| C12 | M(추정) — 축①④, WAN 유리·LAN 역효과 가능성이 코드 근거(압축 의존성 grep 0건)로 명시되나 실측 절감폭 없음 | L(C20 선행 포함; 로직 자체만이면 M) | 와이어 변경(capability 필요) | WAN 유리 / LAN 역효과 가능 | 아님(Native TCP 이후도 유효 — 애플리케이션 레벨이라 전송계층 무관) | **C20 선행조건(하드)** — capability 없이 구버전 상대와 조우 시 안전 협상 불가. C19는 안전순서 권고(소프트) 대상이나 하드 의존은 아님 — 결정 참조(R12) |
| C13 | H(추정, 잠재) — 축①③④, "가장 레버리지 크면서 가장 롤아웃 리스크도 큰 항목"(pitfalls §5.3 원문) | L | 와이어 변경(capability 필요) | LAN 전용(WAN은 SSH 유지) | **이 후보 자체가 SSH-한정 축의 핵심**(SSH 우회 그 자체) | **C20 선행조건(하드)**. 안전 롤아웃 순서(pitfalls §5.5) 3번. "구버전 호스트를 명시적으로 흉내낸 2-머신 환경" 검증 필요 — R10 결정과 연동 |
| C14 | M(산정) — 인프라적(RTT 계측 통로 확보), 직접 체감은 아니나 향후 모든 입력 레이턴시 개선의 정량 검증 전제(t6 R9 관찰) | M | 양측(효과 조건, advisory라 하위호환 유지) | 둘 다 유효(WAN서 RTT 가변성 커서 계측 가치 큼) | 아님 | R9 결정의 직접 대상 — 결정 참조(정식 구현 채택). proto 주석상 "host가 재연결 ring buffer를 trim"하는 이중 용도라 C3·C15와도 연결 |
| C15 | H(산정) — 축③, R4 권고 1순위. "가장 적은 신규 코드로 가장 체감되는 개선"(ANSI 스타일 보존), architecture-verify 검증1 근거7이 이미 동작 검증된 참조 구현으로 확인 | S | host-only(판단 — 비고 참조) | 둘 다 유효(WAN서 재연결 빈도 영향 상대적으로 큼) | 아님 | **판단**: R4 원문이 이 후보 호환성 문단에 "client(byte_seq 추적) 양쪽 업데이트 필요"라 서술하나, 같은 후보의 장단점 문단은 "무조건 전량재생"이라 byte_seq 자체가 불요 — 후보2(C3) 설명 문구가 잘못 전재됐을 가능성. 부록A #7(hostToRelay가 이미 임의 바이트를 그대로 통과시킴)에 근거해 host-only가 코드 사실에 더 부합한다고 판단 — R4 원문 서술 불일치 가능성 있어 별도 확인 권고 |
| C16 | M(추정) — 축①, 이론상 체감개선 가능하나 정합성 리스크가 이를 상쇄(R2 정성 논증). t3 신규발견(client 100ms+host 120ms 이중 ESC 홀드, 이론상 최대 220ms 누적)이 "동일 모호성을 client가 host보다 적은 정보로 더 빨리 판단해야 하는" 구조적 어려움을 실증 | L | client-only | WAN서 이론상 이득·오판위험 동반 상승, LAN은 이득 자체 작음 | 아님 | **기각 권고**(R2 결론 그대로) — vim 등 TUI 오표시 위험이 실증된 버그 패턴(vim ESC freeze)과 정확히 겹치고 CONTEXT[C2] 버전 사각지대까지 상속. 매트릭스는 참고용, 채택 우선순위에서 제외 권장 |
| C17 | M(산정) — 인프라적, 직접 체감 없음이나 R9·C19 계측 기반으로 재사용 | S | host-only | 둘 다 유효(WAN서 드롭 더 흔할 가능성) | 아님 | R11이 이미 결정한 1단계(즉시 채택, draft.md 본문 기결정 사항). C19의 계측 기반으로도 재사용 가능 |
| C18 | H(산정·추정) — 축③, R8 SLO(자동 복구 개시 ≤40초) 달성의 직접 수단 | M | 양측(효과 조건, 불확실) | 둘 다 해당(특히 WAN/sleep-wake) | **부분적 SSH-한정**(SSH ServerAlive 계층은 Native TCP 도입 시 재설계 필요) | "프로토콜 Ping" 계층의 실체가 미확인(R8 원문 "2계층+유령계층 가능성") — 연동 여부 확인이 선행돼야 effort가 정확히 확정됨. 타이머 단축안은 R6 idle 비용과 정면 트레이드오프 |
| C19 | M(추정) — R11이 이미 이번 스코프에서 "기각/후속분리"로 결정(draft.md 본문 기결정), pitfalls §5.5의 "최우선 구현" 권고와 긴장관계 | L | 와이어 변경(capability 필요 가능성) | 둘 다 유효(WAN서 임계치 초과 더 흔함) | 아님 | **R11이 이미 이번 제안서 범위에서 우선순위를 낮춤**(effort 대비 이득 불확실, host-only 자동 재스냅샷으로 대체). pitfalls의 "다른 무엇보다 먼저" 권고는 조사단계 이상론이고 R11은 실행단계 실용적 결정 — C20과 달리 다른 후보의 **하드** 선행조건은 아니고 안전순서상 **권장**(소프트) 선행조건. 최종 제안서에서 이 긴장을 명시적으로 조율할 필요 |
| C20 | H(산정, 확정) — 압축(C12)·Native TCP(C13) 등 모든 와이어 변경 후보의 공통 선행조건, 미구현이 전수검색으로 확정 | M | 양측(4개 구현체 전부: Rust host/CLI client, Swift host/client) | 둘 다 무관하게 필요 | 아님 | **최우선 선행조건**. R12 결정에 직접 영향. 신규 필드는 없음(`Hello.capabilities` 필드 존재, 로직만 신규) — 생성 지점 4곳(`connection.rs:427`, `server.rs:344,707,1055,1261`) 동시 수정 필요 |
| C21 | M(추정, 잠재 H이나 하향) — 축②, 드래그 리사이즈 스터터 후보로 코드 확인(코얼레싱 이후에도 매번 풀 재전송)되나 근본 해결은 C4와 동일한 FFI 불확실성을 상속 | L | 와이어 변경(capability 필요, GridSnapshot 경로 기준) | 둘 다 유효(WAN서 풀스냅샷 대역폭비용 더 큼) | 아님 | **판단**: R4 원문이 "후보1·2 어느 쪽도 리사이즈 문제를 해결 못 하며 후보3만이 유일한 해"라 명시 — C4와 동일 논리로 이번 라운드 M 하향, "조사 필요" 카테고리로 분류. 단기 완화(코얼레싱 윈도우 조정)는 effort S이나 "몇 번 다시 그리는가"만 줄일 뿐 근본 해결은 아님(R4 원문 그대로) |
| C22 | H(산정, 검증완료) — R15 하드 요구사항의 직접 대상, 과거 "빌드만 성공·동작 미검증" 실선례 실재(solver 2026-06-02, `04-verify` phase 자체 부재가 구조적 물증) | M | host-only | 둘 다 무관(검증 인프라 자체) | 아님 | 렌더 축 제안(C1·C7·C15·C19·C21 등) 전체가 이 항목 없이는 동일하게 미검증 리스크로 랜딩 — 렌더 축 착수 전 선행 권고. 기존 read 계열 API 재사용 가능하나 `AutoReplyPoller` 교훈(동기 호출 금지, `SurfaceReadLease` 패턴 필요) 적용 필수 |

#### 매트릭스 요약

- impact 분포: H 11건(C1,C2,C7,C8,C10,C11,C13,C15,C18,C20,C22) · M 10건(C3,C4,C5,C6,C12,C14,C16,C17,C19,C21) · L 1건(C9)
- effort 분포: S 7건(C2,C5,C8,C10,C11,C15,C17) · M 8건(C1,C6,C7,C9,C14,C18,C20,C22) · L 7건(C3,C4,C12,C13,C16,C19,C21)
- 호환성 분포: client-only 7건(C2,C4,C6,C8,C10,C11,C16) · host-only 7건(C1,C5,C7,C9,C15,C17,C22) · 양측 4건(C3,C14,C18,C20) · 와이어 변경 4건(C12,C13,C19,C21) — capability 게이팅(C20)이 와이어 변경군 4건 중 C12·C13의 하드 선행조건
- "판단" 표기(원문 서술을 t5가 보정/명확화한 항목): C1(선행조건 규칙 제외), C4(impact 하향), C15(호환성 host-only 정정), C21(impact 하향) — 4건. 근거는 각 행 비고 참조

### 결정 (t5)

#### R7 — 멀티 pane attach 비용 해소 방향

**결정**: 좁은 세션 공유(C8 — `PeerRelaySession.swift:836-842` surfaceID 필터 + `PeerSession` 주입 팩토리 오버로드)를 attach 병렬화(C2 — `withThrowingTaskGroup`)와 **병행 채택**한다. subscriptionSession 완전 통합(메시지 라우팅 재설계까지 포함하는 범위)은 이번 라운드에서는 보류한다.

**사유**: host는 이미 다중 attach를 무제한 수용하도록 검증됐고(architecture-verify 검증2), 좁은 범위는 client 최소 변경(필터 1곳 + 팩토리 오버로드)만으로 N번 handshake를 1번으로 줄이며 동시에 R6이 지적한 (N+1)-선형 heartbeat wakeup 문제까지 함께 해소한다. attach 병렬화는 세션 공유와 배타적이지 않다 — 세션을 공유해도 각 pane의 `attachSurface` RPC 자체는 여전히 개별 호출이 필요하므로, 이를 TaskGroup으로 병렬화하면 t6이 계산한 "나쁜 WAN(RTT 300ms)+다중pane(N=8)" 시나리오(약 8.9초, 5초 SLO 초과)에 이중으로 효과가 난다. subscriptionSession 완전 통합은 effort가 한 단계 더 크고(non-PtyData 메시지 라우팅 재설계), 좁은 공유만으로 R6/R7의 핵심 병목(N-선형 handshake·wakeup)이 대부분 해소되므로 이번 제안서는 최소변경분만 채택 대상으로 삼는다.

#### R9 — 계측 전략 결정

**결정**: `DataAck`는 **정식 구현을 채택**한다(proto에 이미 설계된 advisory RTT 계측 필드의 최소 구현). 나머지(ESC 홀드 히트율, PTY tap→yield 지연, 리사이즈 풀리페인트 횟수 등 고빈도 타이밍)는 dlog+외부도구(powermetrics/nettop) 기반 **임시 계측**으로 한정한다.

**사유**: t6이 5개 지표 전부에서 실측을 시도했으나 매번 "라이브 세션 부재" 또는 "DataAck 미구현"이 근본 제약으로 반복 확인됐고, 특히 지표1(RTT)은 프로토콜이 이미 설계해 둔 계측 통로 자체가 없어 임시 계측조차 걸 곳이 마땅치 않다는 것이 R9 계측전략 입력용 관찰의 결론이다. `DataAck`는 proto에 필드가 이미 존재하는 advisory 메시지이고 "host가 재연결 ring buffer를 trim"하는 이중 용도로 설계되어 있어(C3·C15의 ring buffer 설계와 연결), 이 필드의 최소 구현은 "정식 벤치 하네스 구축"([D1]/[C3] 스코프 밖)이 아니라 "이미 설계된 프로토콜 필드의 완성"에 해당해 스코프 제약과 충돌하지 않는다. 반면 고빈도 타이밍 계측은 dlog 500 logs/sec 회로차단기 우회만으로 충분히 임시 계측 범위 내에 있고, PTY 청크 분포(Swift 경로)는 FFI 경계 안쪽이라 이번 스코프에서는 후속 과제로 분리한다.

#### R10 — LAN/WAN 목표 및 측정 환경

**결정**: LAN과 WAN에 **별도 목표를 설정**한다 — LAN은 폴링 granularity(100ms)가 지배하는 구간으로 더 낮은 절대 목표를, WAN은 RTT 구간(우수 ~80ms / 보통-나쁨 ~300ms)별로 이원화하고 pane 수(N) 종속 공식(C2/R7 결정과 연동해 "max(개별 attach 지연)로 수렴"하는 정성적 목표)으로 표현한다. 측정 환경은 실제 2-머신(로컬 LAN 1조합 + 원거리 WAN 1조합) **1회성 수동 계측**으로 규정하고, `tc`/`dummynet` 기반 정식 시뮬레이션 하네스 구축은 후속 과제로 분리한다.

**사유**: t6이 이미 나쁜 WAN(RTT 300ms)+다중pane(N=8) 조합에서 attach가 약 8.9초로 5초 목표를 초과하는 구체 사례를 산정해 뒀으므로, 단일 절대 목표는 이 사례에서 항상 깨져 무의미하다. 코드베이스가 LAN/WAN을 100% 동일 SSH 경로로 처리하는 현재 구조([D5] 확인됨, Native TCP는 C13으로 별도 검토 중)에서 "환경별 효과 차이 표기"([D5] 요구사항)를 만족하려면 목표 자체도 환경별로 나뉘는 것이 논리적으로 일관된다. 재현 가능한 WAN 지연 시뮬레이션 하네스가 저장소 전체에 전무함이 이미 확인됐으므로(§측정함정), 정식 하네스 구축([C3] 스코프 밖)과 이번 제안서 검증용 1회성 수동 측정을 구분해 후자만 이번 라운드에 포함한다.

#### R12 — 압축 도입 평가

**결정**: **조건부 채택** — C20(capability 게이팅) 완료를 선행 조건으로 하는 WAN 전용 조건부 압축. LAN에서는 기본 비활성.

**사유**: 압축은 WAN에서 대역폭 절감 효과가 실질적일 수 있으나, 코드 근거상(zstd/gzip/lz4 의존성 grep 0건 상태에서의 신규 도입) LAN에서는 "CPU 비용 대비 효과가 미미하거나 역효과일 수 있다"는 것이 이미 확인돼 있어 무조건 채택은 부적절하다. capability 게이팅이 없는 현재 상태로는 구버전 상대가 압축 프레임을 이해하지 못해 깨지는 리스크가 있으므로, C20 없이는 안전 배포 자체가 불가능하다(안전 롤아웃 순서 1번 규칙과 정확히 일치). C13(Native TCP, LAN 전용)과 조합하면 "LAN은 Native TCP로 SSH 오버헤드 자체를 없애고, WAN은 SSH 유지 경로에 압축을 얹는" 상호보완적 배치가 가능해 두 후보를 함께 설계하는 편이 낫다. 압축 알고리즘 선택이나 실측 절감폭은 이번 조사 범위 밖(실측 없음)이므로, 이번 제안서에서는 채택 방향과 선행조건까지만 결정하고 구체 구현은 후속 프로젝트로 넘긴다([D1] 범위 준수).

## R1-R15 커버리지

`context/REQUIREMENTS.md`가 요구하는 R1-R15 각각이 이 문서의 어느 섹션·제안에서 충족되는지 정리한다.

| R# | 요구사항 요약 | 충족 섹션/제안 |
|---|---|---|
| R1 | 입력 레이턴시 경로의 hop별 지연 기여 분석(31-hop) | §분석 › 입력 레이턴시·렌더링 축(t3) › R1 |
| R2 | "로컬 에코 없음(host is source of truth)" 구조 제약 명시 + optimistic echo 타당성·위험 평가 | §분석 › 입력 레이턴시·렌더링 축(t3) › R2; 기각 결정은 §부록 › 부록C(C16) |
| R3 | 개선 대상 데이터플레인 명시(GUI 1차 대상 / headless 포함 여부 / 두 데이터플레인 기능격차·이식기회) | §분석 › 입력 레이턴시·렌더링 축(t3) › R1의 "범위" 문단(GUI 확정, headless는 31-hop 트레이스에서 제외하되 참조구현으로 인용) + §제안 P4(Rust ReplayBuffer→Swift 이식으로 기능격차 해소) |
| R4 | attach/리사이즈/재연결 스냅샷·resumeFromSeq 미구현의 비용 분석 + 개선방향(후보1/2/3) 결정 근거 | §분석 › 입력 레이턴시·렌더링 축(t3) › R4 + §제안 P4(후보1 채택) + §부록 › 부록C(C21, 후보3/GridSnapshot 보류) |
| R5 | 제안별 impact/effort/호환성 4단계 + LAN/WAN 효과차이 + SSH-한정 vs Native TCP 이후에도 유효 구분 표기 | §제안 P1-P10 전 항목의 축/Impact/Effort/호환성 필드 + LAN/WAN·SSH-한정 여부 필드 자체 |
| R6 | idle 상주 비용 항목화(10Hz wakeup, 하트비트 중첩, GPU occlusion 미배선 등) | §분석 › 연결 수명주기·자원 사용 축(t4) › R6 + §제안 P2 |
| R7 | 멀티 pane attach 비용(순차 handshake) 해소 방향 결정 | §매트릭스와 결정 › 결정(t5) › R7 + §제안 P1 |
| R8 | 재연결/슬립 복구 SLO 설정(목표치·달성 수단) | §분석 › 연결 수명주기·자원 사용 축(t4) › R8 + §제안 P6 |
| R9 | 계측 전략 결정(DataAck 정식구현 vs dlog/외부도구 임시계측 범위) | §분석 › 실측(t6) › R9 계측 전략 입력용 관찰 + §매트릭스와 결정 › 결정(t5) › R9 + §제안 P10 |
| R10 | LAN/WAN 별도 수치 목표 여부 + 측정 환경(2-머신, 인위 지연) 결정 | §분석 › 실측(t6) › R10 환경 한계 관찰 + §매트릭스와 결정 › 결정(t5) › R10 |
| R11 | silent drop 가시화 여부 결정(Swift 무로그 드롭 vs Rust Lagged 로그) | §분석 › 연결 수명주기·자원 사용 축(t4) › R11 + §제안 P9 |
| R12 | 압축 도입 평가(WAN 조건부, capability 게이팅 선행, LAN 역효과 가능성) | §매트릭스와 결정 › 결정(t5) › R12 + §제안 P8 |
| R13 | 모든 제안의 "최적화 금지 계약" 위반 여부 점검 + 관련 회귀 테스트 하드 게이트 지정 | §감사 요약(F1-F12 대조표 + P#별 판정 표, 위반 0건 집계) |
| R14 | 와이어/시맨틱 변경 제안의 롤아웃 순서(capability 게이팅·배압/재동기화 플러밍 선행조건 명시) | §제안 P3(롤아웃 필드) + P8(P3 의존 재정의) + §감사 요약 "심각 위반" 단락(P3 스코프 오류 발견·재정의) |
| R15 | 렌더링/화면 갱신 축 제안의 검증 가능성 명시(검증 수단 + h1/h3/h4 회귀 확인) | §제안 P5(원격 grid 조회 API 신설) + P1/P2/P4/P9의 검증수단 필드 + §감사 요약(검증수단 신규 추가 4건 — 라벨 누락 보정) |

## 감사 요약

**감사 범위 고지**: 지시서는 금지 계약을 "13개 항목"이라 언급했으나, 원문(`01-research/notes.md` §최적화 금지 목록 + §최적화하면 안 되는 계약 목록 표)을 직접 센 결과 두 목록 모두 정확히 **12개 항목**(F1-F12, 아래 표)이었다. 지어내지 않고 원문에 실재하는 12개 전부를 기준으로 감사했다.

| ID | 항목 | 심각도(원문) |
|---|---|---|
| F1 | ESC 프리픽스 완성판별(`trailingIncompleteEscape`/`peerEscapePrefixCouldComplete`) 불변조건 | H |
| F2 | `peerPendingInputTail` prelude 처리 순서 | H |
| F3 | bracketed-paste idle-timeout/`finalFlush` 시맨틱 | H |
| F4 | Kitty keyboard protocol press/release 필터·CSI-u 매핑 | H |
| F5 | `query_filter.rs` 스트리밍 상태기계(청크 순서·병렬화 금지) | H |
| F6 | OSC 52 클립보드 응답 무조건 drop | H(보안) |
| F7 | `ghostty_surface_key`/`ghostty_surface_text` 경로 분리 | M |
| F8 | `acceptRelay()` O_NONBLOCK→blocking 전환 로직 | M |
| F9 | 소켓 threading policy(고빈도 텔레메트리 off-main / AppKit·Ghostty만 MainActor) | H |
| F10 | 소켓 focus policy(명시적 focus-intent 외 focus 이동 금지) | H |
| F11 | 앱 레벨 display link·수동 `ghostty_surface_draw` 폴링 루프 금지 | M |
| F12 | 터미널 제어 쿼리 응답 daemon PTY 경계 즉시처리(클라이언트 왕복 금지) | H |

### P#별 판정 표

| P# | 금지계약 | 회귀 게이트 | 롤아웃 | 검증수단 | 소견 수 | 최고 심각도 |
|---|---|---|---|---|---|---|
| P1 | 통과 | 추가(bracketed_paste_split_close) | 해당없음(client-only) | 추가(수동 2-노드) | 1 | 중 |
| P2 | 통과 | 해당없음 | 해당없음(client-only) | 추가(방법론 공백 지적) | 2 | 중 |
| P3 | 통과 | 해당없음 | 기존 라벨 유지 + 범위 재정의 권고 | 해당없음 | 1 | **심각(범위 오류)** |
| P4 | 통과(조건부: F9) | 추가(esc_freeze+bracketed_paste) | 보수적 "양측" 권고 | 기존 유지(P5 의존) + 순서 소견 | 1 | 중 |
| P5 | 통과 | 해당없음 | 해당없음(host-only) | 메타(자기순환 리스크) | 1 | 낮음 |
| P6 | 통과(조건부: F10) | 해당없음 | 기존 라벨 유지 + 착수조건 추가 | 해당없음 | 1 | 낮음 |
| P7 | 통과(조건부: F5 향후) | 추가(bracketed_paste_split_close) | 해당없음(host-only, 와이어불변) | 추가(수동+임시계측) | 2 | 낮음 |
| P8 | 통과(조건부: F5 후속) | 해당없음 | 기존 라벨 유지 + P3 의존 재정의 | 해당없음(축② 아님) | 1 | 중 |
| P9 | 통과(조건부: F9) | 추가(bracketed_paste_split_close) | 해당없음(host-only, 기존메커니즘) | 추가(P5 권장) | 2 | 낮음 |
| P10 | 통과 | 해당없음 | 기존 라벨 유지, **코드검증으로 안전 확인** | 해당없음(축② 아님) | 1 | 낮음(긍정) |

**집계**: 금지계약 12개 항목 × 10개 제안 = 120개 개별 대조 중 위반/예외 0건(전부 통과 또는 해당없음). "통과"이되 구현 시 준수사항이 붙는 조건부 통과 5건(P4/F9, P6/F10, P7/F5, P8/F5, P9/F9) — 전부 채택 차단 사유가 아니라 구현 디테일 권고. 회귀 게이트 신규 추가 4건(P1/P4/P7/P9, 전부 `test_peer_input_bracketed_paste_split_close.py` 하드 게이트, P4만 esc_freeze도 포함). 검증수단 신규 추가 4건(P1/P2/P7/P9 — 전부 축 라벨이 누락하고 있던 렌더축② 성격을 감사가 보정). ⚠ 감사 소견 총 **13건**.

**심각 위반**: 금지 계약(R13) 위반은 0건. 다만 **P3(Capability 게이팅)에서 R14 관점의 심각한 스코프 오류를 발견**했다 — "수정 지점" 4곳(`PeerServer.swift:344,707,1055,1261`)이 실제로는 전부 Rust `daemon/term-meshd/src/peer/server.rs`(grep으로 직접 확인)였고, 정작 Swift host(`PeerServer.swift:752-758`)·Swift client(`PeerSession.swift:430-448`)·Rust CLI client(`peer.rs:51-56`, 여기도 `capabilities: vec![]` 확인)는 어디에도 포함돼 있지 않다. 즉 P3을 "완료"로 표시해도 4개 구현체 중 3개는 여전히 빈 capabilities를 보낸다. 실패 방향은 fail-closed(기능 비활성으로 남을 뿐 안전사고는 아님)이지만, P8이 이 "완료"를 하드 선행조건으로 삼는 구조라 롤아웃 순서 판단 자체의 신뢰성을 해친다 — 이번 감사에서 가장 비중 있게 다뤄야 할 사항으로 별도 보고한다. 그 외 긍정적으로 확인된 사항: P10(DataAck)의 하위호환 주장은 `PeerServer.swift:844-850`의 기존 catch-all(`Silent drop matches the Rust server's behavior`)로 코드 수준에서 실제로 안전함을 확인했다.

## 부록

### 부록A — 인용 재확인 표 (t1)

| # | 인용 (조사 시점) | 판정(유효/이동) | 현재 위치 | 비고 |
|---|---|---|---|---|
| 1 | `daemon/term-meshd/src/peer/surface.rs:35` — READ_BUF_SIZE = 4096 | 유효 | 35 | `const READ_BUF_SIZE: usize = 4096;` 정확 일치 |
| 2 | `daemon/term-meshd/src/peer/surface.rs:39` — BROADCAST_CAPACITY = 1024 | 유효 | 39 | `const BROADCAST_CAPACITY: usize = 1024;` 정확 일치 |
| 3 | `daemon/term-meshd/src/peer/surface.rs:43` — REPLAY_CAPACITY_BYTES = 64KB | 유효 | 43 | `const REPLAY_CAPACITY_BYTES: usize = 64 * 1024;` 정확 일치 |
| 4 | `daemon/term-mesh-peer-relay/src/main.rs:33` — RESIZE_COALESCE_MS = 16 | 유효 | 33 | `const RESIZE_COALESCE_MS: u64 = 16;` 정확 일치 |
| 5 | `daemon/term-mesh-peer-relay/src/main.rs:667` — recv_timeout(100ms) idle 폴링 루프 | 유효 | 667 | `rx.recv_timeout(Duration::from_millis(100))` 정확 일치 |
| 6 | `daemon/term-mesh-peer-relay/src/main.rs:745` — ESC_FLUSH_TIMEOUT_MS = 100 | 유효 | 745 | `const ESC_FLUSH_TIMEOUT_MS: i32 = 100;` 정확 일치 |
| 7 | `Sources/PeerRelaySession.swift:836-842` — hostToRelay가 `.ptyData(surfaceID, byteSeq)`를 `_`로 버리고 data만 전달 | 유효 | 836-842 | `let hostToRelay = Task.detached {...}` (824) 내부, `case .ptyData(_, _, let data):`(837) → `writer.enqueue(payload: data)`(839) 확인 |
| 8 | `Sources/PeerRelaySession.swift:204` — RelayFrameSlots 256 슬롯 | 유효 | 204 | `private let slots = RelayFrameSlots(limit: 256)` 정확 일치 |
| 9 | `Sources/PeerRelaySession.swift:721-755` — acceptRelay 100ms×100 폴링 | 유효 | 721-755 | "Poll up to 100 × 100ms = 10s"(723) + `Thread.sleep(forTimeInterval: 0.1)`(751) 확인 |
| 10 | `Sources/PeerRelaySession.swift:318-321` — RelayResizeCoalescer 24ms | 유효 | 318-321 | `init(..., delayMs: UInt64 = 24)`(318) 정확 일치 |
| 11 | `swift/PeerProto/Sources/PeerProto/PeerServer.swift:632-639` — write EAGAIN 시 Task.sleep(1ms) busy-poll + "PoC keeps it simple" 주석 | 유효 | 632-639 | 서술 내용은 633-639에 위치(632는 직전 `if n>0` 블록의 닫는 괄호). "PoC keeps it simple" 주석(635-636) + `Task.sleep(nanoseconds: 1_000_000)`(637) 확인 |
| 12 | `swift/PeerProto/Sources/PeerProto/PeerServer.swift:926-947` — pumpByteStream 청크당 1 Envelope, 배칭 없음 | 유효 | 926-947 | 함수 전체 정확 일치. `for await bytes in attachment.byteStream`마다 `sendEnvelope` 1회 호출, 배칭 로직 없음 확인 |
| 13 | `swift/PeerProto/Sources/PeerProto/PeerServer.swift:899` 부근 — handleAttach가 resumeFromSeq 미사용, initialSeq=0 고정 | 유효 | 899 | `r.initialSeq = 0`(899) 정확 일치. 주변 handleAttach 본문에 resumeFromSeq 참조 없음 |
| 14 | `swift/PeerProto/Sources/PeerProto/PeerServer.swift:676` 부근 — attachments: [Data: PeerSurfaceAttachment] (단일 세션 다중 attach) | 유효 | 676 | `private var attachments: [Data: PeerSurfaceAttachment] = [:]` 정확 일치 |
| 15 | `Sources/GhosttyPaneSurfaceProvider.swift:729` — peerPendingTailFlushDelayNanos = 120ms | 유효 | 729 | `private let peerPendingTailFlushDelayNanos: UInt64 = 120_000_000` 정확 일치 |
| 16 | `Sources/GhosttyPaneSurfaceProvider.swift:81-94` — PtyTapHub.broadcast, AsyncStream bufferingNewest(256) | 유효 | 81-94 | `PtyTapHub` 클래스 선언 39행, `func broadcast(_ bytes: Data)`(81) 및 `bufferingNewest(256)` 주석(83) 확인 |
| 17 | `Sources/GhosttyPaneSurfaceProvider.swift:248-256` — input 클로저 MainActor.run 홉 | 유효 | 248-256 | `let input: @Sendable (Data) async -> Void = { [weakTS] bytes in await MainActor.run {...} }` 정확 일치 |
| 18 | `Sources/GhosttyPaneSurfaceProvider.swift:312-331` — 리사이즈 시 ESC[2J+plain-text 풀 스냅샷 재전송 | 유효 | 312-331 | `sizeChanged` 체크 후 ESC[2J 브로드캐스트(317) + `readPaneSnapshot(ptr)` 재전송(328-329) 확인 |
| 19 | `Sources/GhosttyPaneSurfaceProvider.swift:893-930` — trailingIncompleteEscape/peerEscapePrefixCouldComplete | 유효 | 893, 916 | `trailingIncompleteEscape`(893) · `peerEscapePrefixCouldComplete`(916) 두 함수 모두 인용 범위 내 확인 |
| 20 | `Sources/PeerSSHTunnel.swift:368` — 재연결 백오프 min(30, 1<<...) | 유효 | 368 | `let delaySec = min(30, 1 << min(attempt - 1, 5))` 정확 일치 |
| 21 | `Sources/PeerRelayWorkspaceWindowController.swift:1049-1075` — missingSurfaceIDs 순차 for-await 루프 (TaskGroup 없음) | 유효 | 1049-1076 | `for surfaceID in missingSurfaceIDs { let slot = try await spawnPaneSlot(...) ... }`(1072-1076) 순차 루프 확인, TaskGroup 미사용. 루프 닫는 괄호가 1076으로 인용 범위보다 1행 아래 |
| 22 | `Sources/PeerRelayWorkspaceWindowController.swift:1441` — TerminalSurface 생성(relay 프로세스 shell) | 유효 | 1441 | `TerminalSurface(` 생성자 호출 시작 정확 일치 (command: session.relayLaunchCommand) |
| 23 | `daemon/term-meshd/src/main.rs:277-285` — TERMMESH_PEER_SOCKET opt-in peer::serve spawn | 유효 | 277-285 | `std::env::var("TERMMESH_PEER_SOCKET")` 체크 + `tokio::spawn(peer::serve(path, shutdown_rx.clone()))` 정확 일치 |
| 24 | `daemon/term-meshd/src/peer/connection.rs:427` — host_hello capabilities: vec![] | 유효 | 427 | `capabilities: vec![],` 정확 일치 (host_hello 함수 내, 415행부터 시작) |
| 25 | `daemon/term-meshd/src/peer/connection.rs:393-397` — RecvError::Lagged 시 경고 로그만 남기고 continue | 유효 | 393-397 | `Err(broadcast::error::RecvError::Lagged(n)) => { tracing::warn!(...); continue; }` 정확 일치 |
| 26 | `Sources/PeerRelayWindowController.swift:51, 78-89` — TerminalSurface 직접 생성 + hostedView 직접 부착 (occlusion 배선 없음) | 유효 | 51, 78-89 | `self.terminalSurface = TerminalSurface(`(51) + `container.addSubview(hostedView)` 및 NSLayoutConstraint 직결(78-89) 확인. occlusion/rendererRealized 관련 배선 없음 |
| 27 | `GhosttyTerminalView.swift:210, 246` 부근 — TerminalSurface.rendererRealized 기본 true, setRendererRealized는 외부 opt-in | 유효 | 210, 242 | `final class TerminalSurface`(210) 정확 일치. `rendererRealized = true` 기본값은 242행(인용 앵커 246과 4행 차이, "부근" 표현 범위 내). `setRendererRealized` 함수 정의 자체는 1043행(별도) — 239행 주석 "Toggled via `setRendererRealized`"가 외부 opt-in 성격을 설명 |

#### 요약

- 유효: 27 / 27
- 이동: 0
- 서술 불일치: 0
- 참고: #11, #21, #27은 인용된 라인 범위/앵커가 실제 핵심 코드 위치와 1~4행 오차가 있으나(주석·괄호 등 인접 라인 포함 때문), 서술된 코드 내용 자체는 모두 인용 범위 내 또는 그 바로 인접(부근 명시분)에서 확인됨. 이동으로 분류하지 않음.

### 부록B — 병목/개선 후보 전수 목록 (t2)

근거: `phases/01-research/notes.md` (stack/features/architecture/pitfalls 4개 조사 원문 + architecture-verify/pitfalls-verify 검증 부록), 기준 커밋 `0fd6bd97`(부록A와 동일). C1-C9는 architecture §4 병목 후보 표 9건 전량, C10-C18은 CONTEXT.md·requirements가 지정한 필수 포함 항목, C19-C22는 notes.md 전문에서 추가로 수집한 후보. 전 항목이 notes.md 원문에 이미 존재하는 근거를 인용하므로 [신규] 태그 대상 없음.

| C# | axis(①입력/②렌더/③수명주기/④자원) | 위치(file:line) | 개선 가설 | 출처(notes 섹션) |
|---|---|---|---|---|
| C1 | ②④ | `Sources/GhosttyPaneSurfaceProvider.swift:81-94`(PtyTapHub.broadcast) + `swift/PeerProto/Sources/PeerProto/PeerServer.swift:926-947`(pumpByteStream) | PTY tap 발동마다(코드 주석상 초당 수천 회 가능) 개별 Envelope+프레임+write() syscall이 나가며 배칭 윈도우가 전무하다. `pumpByteStream`에 4-8ms 코얼레싱 윈도우 + 최대 바이트 캡을 추가하면(기존 `RelayResizeCoalescer` 24ms 패턴 재사용 가능) syscall/Envelope 오버헤드를 줄일 수 있다. 단 replay ring과 broadcast 양쪽에 각각 clone되는 이중 할당 비용(`surface.rs:233-238`)도 함께 움직이므로 청크 크기 설계 시 고려 필요 | architecture §4 (병목표 row1) |
| C2 | ③ | `Sources/PeerRelayWorkspaceWindowController.swift:1049-1075`(`for surfaceID in missingSurfaceIDs`) | pane N개 attach가 `TaskGroup` 없이 순차 `await`로 처리되어 attach 지연이 pane 수에 선형 비례한다. `withThrowingTaskGroup`로 팬아웃하고 동시성 상한을 적용하면 멀티페인 워크스페이스의 체감 attach 시간을 단축 가능 | architecture §4 (병목표 row2), requirements R7 |
| C3 | ③ | `swift/PeerProto/Sources/PeerProto/PeerServer.swift:899`(handleAttach, `r.initialSeq = 0` 고정) | 프로토콜에 정의된 `resumeFromSeq` 필드를 host가 전혀 읽지 않아 재연결마다 풀 재attach + plain-text 스냅샷을 반복한다. host에 surface별 ring buffer를 신설하고 `resumeFromSeq` 처리 + cell-level `GridSnapshot` 구현을 추가하면 재연결 비용과 스타일 유실을 동시에 해소 가능 | architecture §4 (병목표 row3), architecture §3 (Reconnect 8) |
| C4 | ①④ | `Sources/PeerRelaySession.swift:1-12`(헤더 주석, 아키텍처 전체) | pane마다 로컬 OS 프로세스(`term-mesh-peer-relay`) + 2차 로컬 유닉스소켓 + 2차 프레이밍이 붙는 이중 홉 구조는 순전히 "진짜 Ghostty엔 PTY가 필요하다"는 제약을 우회하기 위한 것이다. libghostty가 PTY 없이 바이트를 직접 feed하는 API를 제공/추가할 수 있는지 조사하면 입력 레이턴시(hop 31개→감소)와 상주 자원(프로세스+소켓 2벌) 모두 개선 가능하나, FFI 신규 함수 + xcframework 재빌드가 필요해 5개 후보 중 엔지니어링 비용이 최대다 | architecture §4 (병목표 row4), architecture §1 (입력경로 트레이스 전체) |
| C5 | ④ | `swift/PeerProto/Sources/PeerProto/PeerServer.swift:632-639`(`AcceptedUnixConnection.write`) | EAGAIN 시 `Task.sleep(1ms)` 재시도로 busy-poll하며, 코드 주석 자체가 "Production code would use DispatchSourceWrite; PoC keeps it simple"라 자인한다. read 경로(`:596-615`)와 대칭으로 `DispatchSourceWrite` 기반 이벤트 구동으로 교체하면 WAN 역압 상황의 CPU 스핀과 지연을 제거 가능 | architecture §4 (병목표 row5) |
| C6 | ③ | `Sources/PeerRelaySession.swift:721-755`(`acceptRelay`) | relay 프로세스 접속 대기가 100ms 간격 폴링·최대 10초이며 pane마다 반복돼 C2(순차 attach)와 곱으로 늘어난다. listener fd에 `DispatchSourceRead`를 적용해 이벤트 구동화하면 attach 지연을 줄일 수 있다. 단 pitfalls의 "acceptRelay O_NONBLOCK 로직" 경고(최적화 금지 목록)대로 진짜 비동기로 재설계해야 하며 어설픈 논블로킹 유지는 첫 read EAGAIN 시 세션 즉시 종료를 재현시킨다 | architecture §4 (병목표 row6) |
| C7 | ②③ | `Sources/GhosttyPaneSurfaceProvider.swift:171-239, 1539-1580`(`readPaneSnapshot`, forceRedrawOnAttach) | attach 시 스냅샷이 plain-text뿐(ANSI 스타일 없음)이고, 강제 리드로우(Ctrl-L 주입)가 host 로컬 화면까지 깜빡이게 만든다. C3의 GridSnapshot 구현과 묶어서 처리하면 attach 시 스타일 유실과 host측 부작용을 동시에 제거 가능 | architecture §4 (병목표 row7) |
| C8 | ③④ | `Sources/PeerRelayWorkspaceWindowController.swift:301`(subscriptionSession) vs `:1435`(spawnPaneSlot의 개별 `PeerRelaySession.connect`) + `Sources/PeerRelaySession.swift:836-842`(hostToRelay가 surfaceID를 `_`로 버림) | 워크스페이스당 이미 인증된 `subscriptionSession`이 있음에도 pane마다 완전히 별도의 `PeerSession`+`NWConnection`을 새로 열어 handshake를 N번 더 한다. host는 이미 세션 하나에서 다중 attach를 지원하는 구조(`PeerServer.swift:676` attachments 딕셔너리, 세션당 attach 개수 제한 없음)이므로, client가 `hostToRelay`를 `where sid == self.surfaceID` 필터로 바꿔 subscriptionSession을 재사용하면 host 변경 없이 client 단독 배포로 즉시 handshake 비용과 커넥션 수를 절감 가능 | architecture §4 (병목표 row8), architecture-verify 검증2 |
| C9 | ① | `Sources/GhosttyPaneSurfaceProvider.swift:248-256`(input 클로저 `MainActor.run`) | 원격 Input마다 강제 `MainActor.run` 홉이 추가되는데, 로컬 타이핑 경로에는 이 홉이 없다(NSEvent가 이미 메인스레드이므로). Ghostty API가 실제로 메인스레드 전용인지 확인 후에만 최적화를 검토해야 하며, 구조적 제약일 가능성이 높아 우선순위는 낮음 | architecture §4 (병목표 row9) |
| C10 | ④ | `daemon/term-mesh-peer-relay/src/main.rs:667` | `term-mesh-peer-relay` 프로세스가 idle 상태에도 내부 채널을 `rx.recv_timeout(Duration::from_millis(100))`로 폴링해 완전 유휴 상태에서도 초당 10회 wakeup을 유발한다. 코드에서 바로 식별 가능한 확정적 비용이므로 timeout 확대 또는 블로킹 recv/조건변수 기반 이벤트 전환으로 idle CPU/전력 소모를 즉시 축소 가능 | features §4(축④ idle), requirements R6 |
| C11 | ④ | `Sources/PeerRelayWindowController.swift`(전체 199줄) + `Sources/PeerRelayWorkspaceWindowController.swift`(1654줄, occlusion 관련 검색 0건) | peer relay 창 2종 모두 `NSWindow.didChangeOcclusionStateNotification` 구독이나 `setRendererRealized`/`setSurfaceVisibleForRenderer` 호출이 전혀 없다(pitfalls-verify 검증1, high confidence). `TerminalSurface`를 직접 인스턴스화해 `GhosttySurfaceScrollView` 포탈(occlusion 구동 경로)을 경유하지 않기 때문 — GPU 누수 수정 자체(`ghostty_surface_set_renderer_realized`, upstream `858e257f0`)는 트리에 이미 존재하나 peer relay 창엔 미배선 상태다. 두 컨트롤러에 occlusion 알림 구독 + `setRendererRealized` 호출을 추가하면 백그라운드 방치된 relay 창의 GPU 자원(surface당 추정 1.5-6MB)을 회수 가능 | pitfalls-verify 검증1, pitfalls §4(알려진 자원 이슈) |
| C12 | ①④ | `daemon/Cargo.toml`, `daemon/term-meshd/Cargo.toml`, `daemon/peer-proto/Cargo.toml`, `swift/PeerProto/Package.swift`(zstd/gzip/lz4/deflate 의존성 grep 0건) | 프레이밍 계층 전 구간이 비압축 Protobuf다. WAN에서는 압축이 대역폭(자원)과 체감 전송 지연(입력) 모두 개선할 수 있으나 LAN에서는 CPU 비용 대비 효과가 미미하거나 역효과일 수 있어 환경별 조건부 채택이 필요하다. capability negotiation(C20)이 선행되어야 구버전 상대와 안전하게 협상 가능 | stack §3(압축/배칭 현황), requirements R12 |
| C13 | ①③④ | `Sources/PeerSSHTunnel.swift:228-255`(`ssh -L` 터널링) + `docs/peer-federation-impl-status.md:46`(Native TCP D-3b TODO) | 오늘 시점 LAN·WAN 모두 100% 동일하게 SSH 터널을 경유하며, LAN 전용 Native TCP 직결 경로(D-3b)는 아직 미구현이다. SSH 자체의 핸드셰이크·프레이밍·keepalive(`ServerAliveInterval=15`, WAN/셀룰러 배터리 비용)가 baseline 레이턴시와 상주 자원 비용에 포함돼 있으므로, LAN 한정 Native TCP 경로를 구현하면(SSH 폴백 유지) 연결 수립 시간·데이터 왕복 지연·킵얼라이브 오버헤드를 동시에 낮출 수 있다. 단 새 전송 계층은 그 자체로 새 capability이며 지금 없는 협상 메커니즘(C20)이 선행돼야 우아한 폴백이 가능 | 통신채널명세 §2(a), architecture §3(2), requirements R5/R10 |
| C14 | ① | `swift/PeerProto/Sources/PeerProto/PeerSession.swift:35`, `PeerServer.swift:847`(주석상 "미구현/unhandled" 명시) | RTT 측정용으로 프로토콜에 설계된 `DataAck`가 Swift/Rust 양쪽 다 미구현 상태다. 이 때문에 keypress→remote-echo RTT를 비롯한 축① 레이턴시 지표 전반이 임시 계측 없이는 측정 불가능하다. `DataAck`를 실제로 구현하면 상시 RTT 계측을 확보해 이후 모든 입력 레이턴시 개선의 효과를 정량 검증할 수 있게 된다(R9의 스코프 결정 필요) | 지표 후보 §2(축①), requirements R9 |
| C15 | ③ | `daemon/term-meshd/src/peer/surface.rs:43,51-75`(ReplayBuffer, raw byte, ANSI 보존) | Rust `PtySurface`는 attach마다 최근 64KB를 raw byte 그대로 재생해 ANSI 스타일이 보존되는 반면, Swift host(`PeerServer`)는 대응하는 재생 버퍼가 없어 plain-text 스냅샷만 보낸다(C3/C7과 직결). Rust의 기존 ReplayBuffer 구현 패턴을 Swift host로 이식하면 GridSnapshot 전체 재설계 없이도 재연결 시 스타일 유실 문제를 우선 완화할 수 있다(단 Rust도 `resume_from_seq`는 읽지 않아 "매 attach마다 무조건 최근 64KB 재생"이므로 seq 기반 dedup은 별도 작업) | architecture-verify 검증1(근거7) |
| C16 | ① | `docs/peer-federation-impl-status.md:62-71`(data flow 다이어그램) | relay 창은 로컬 PTY가 없는 진짜 Ghostty surface이고 로컬 에코가 원천적으로 없어, 모든 키 피드백이 host 왕복(RTT) 전체에 의존한다. "로컬 에코 없음" 아키텍처가 변경 불가능한 구조적 한계인지, 클라이언트측 낙관적(optimistic) echo 같은 완화책이 타당한지 먼저 결론을 내야 한다 — 타당하다면 client가 입력 즉시 임시 렌더링 후 host 응답 도착 시 정정하는 방식으로 체감 레이턴시를 줄일 수 있으나, host가 source of truth라는 기존 설계 불변식과 충돌 여부를 먼저 검토해야 함 | features §축①(1-6), requirements R2 |
| C17 | ④ | `Sources/GhosttyPaneSurfaceProvider.swift:70`(Swift `AsyncStream.bufferingNewest(256)`, 조용히 드롭) vs `daemon/term-meshd/src/peer/connection.rs:394`(Rust `tracing::warn!("attach relay lagged, missed {n} chunks")`) | 느린 피어에 대한 드롭 처리가 비대칭적이다 — Rust는 드롭 시 경고 로그가 있으나 Swift는 대응하는 로그/카운터가 전무해 드롭이 발생해도 사용자·운영자 모두 인지할 수단이 없다. Swift 쪽에도 드롭 카운터 + dlog를 추가하면 최소 비용으로 가시성을 확보할 수 있고, 이후 C19(배압/재동기화)의 계측 기반으로도 재사용 가능(R11의 스코프 결정 필요) | features §축④(Active), requirements R11 |
| C18 | ③ | `Sources/PeerRelaySession.swift:704-706`(앱 heartbeat 10s/30s dead) + `docs/peer-federation-protocol.md:85`(프로토콜 Ping 15s/30s) + `Sources/PeerSSHTunnel.swift:244-245`(SSH ServerAliveInterval 15s×3회≈45s) | 죽은 연결을 감지하는 계층이 앱 하트비트·프로토콜 Ping·SSH keepalive 3개가 서로 독립적으로 중첩돼 있다. 이들이 겹치면 호스트가 슬립에 들어간 뒤 화면이 얼어붙은 것처럼 보이다가 정리되기까지 최악의 경우 수십 초가 걸릴 수 있다. 재연결/슬립복구 체감 시간의 SLO를 먼저 설정한 뒤 3계층을 통합하거나 타임아웃을 재조정하면 사용자가 "멈춘 것처럼" 느끼는 구간을 단축 가능(R8) | architecture §3(Reconnect 6-7), requirements R8 |
| C19 | ②④ | `docs/peer-federation-protocol.md:322-327`(unacked_bytes>8MiB 드롭+ERR_INTERNAL+client GridSnapshot 재요청, 코드 전수검색 0건) | 문서화된 배압/재동기화 메커니즘이 코드 어디에도 없다 — 실제 동작은 `connection.rs:393-397`처럼 `RecvError::Lagged` 시 경고 로그만 남기고 `continue`할 뿐, 클라이언트에 에러도 강제 재동기화도 없다. 이 메커니즘을 실제로 구현하면 과부하 시 조용히 드롭되고 영영 재동기화되지 않는 현재 결함(화면 불일치가 사용자에게 보이지 않게 누적되는 문제)을 해소할 수 있다. C1/C10 등 배칭·빈도 최적화보다 먼저 구현하는 편이 안전하다는 것이 조사 결론(안전 롤아웃 순서 4번) | pitfalls §5.2(안전장치 2건 표, 배압/재동기화 행), CONTEXT C6 |
| C20 | ③ | `proto/peer/v1/README.md:32`(Evolution rule 3) vs `daemon/term-meshd/src/peer/connection.rs:427` + `swift/PeerProto/Sources/PeerProto/PeerServer.swift:344,707,1055,1261`(전부 `capabilities: vec![]`/빈 배열 고정) | capability 기반 신규기능 게이팅이 스키마상 준비만 되어 있고 실동작하지 않는다(capabilities를 읽고 분기하는 코드 전수검색 0건). 압축(C12)·배칭(C1)·Native TCP(C13) 같은 wire-level 성능개선을 무중단으로 배포하려면 이 플러밍을 먼저 구현해야 신버전 클라이언트가 구버전 호스트를 만났을 때(또는 반대) 우아하게 폴백할 수 있다 — 다른 와이어 변경 후보들의 공통 선행 조건 | 의존성/버전제약 §6, pitfalls §5.2(Capability 게이팅 행), CONTEXT C6 |
| C21 | ② | `Sources/GhosttyPaneSurfaceProvider.swift:312-331`(리사이즈 시 `ESC[2J`+plain-text 풀 스냅샷 재전송) | 리사이즈는 클라이언트 24ms(`RelayResizeCoalescer`)와 relay 바이너리 16ms(`RESIZE_COALESCE_MS`) 두 단계로 코얼레싱되지만, 코얼레싱 이후에도 매번 화면을 지우고 plain-text 뷰포트 스냅샷 전체를 재전송하며 스타일(색상/속성)이 유실된다. 드래그 리사이즈 중 반복 스터터의 후보로 지목됨 — C3/C7의 GridSnapshot(cell-level, 스타일 보존) 구현과 결합해 처리하면 코얼레싱 효과가 풀 리페인트에도 실제로 이어질 수 있다(R4) | architecture §2(출력/렌더 경로 트레이스 4번), requirements R4, draft.md 부록A #18 |
| C22 | ② | `.xm/solver/problems/term-mesh-peer-workspace에서-원격-peer-pane의-화면-갱신이-느리/phases/05-close/summary.json:5`(`verification_passed: false`) | 원격 relay pane의 렌더링 결과를 조회하는 host socket API가 없어(tests_v2 기준) 렌더 축 변경의 자동검증이 원천적으로 불가능한 구조적 공백이 실재한다 — 과거 "원격 peer pane 화면 갱신 느림" fix(포커스 재적용 기반 redraw 트리거)가 이 공백 때문에 "빌드만 성공, 동작 미검증" 상태로 solved 마감된 선례가 있다. 렌더 축(C1/C7/C19/C21 등) 최적화에 착수하기 전에 grid 상태 조회 API 신설을 선행하지 않으면 새 최적화도 동일하게 미검증 상태로 랜딩될 위험이 있다 | pitfalls-verify 검증2, architecture §2(관련 기존 이슈) |

#### 요약

- 후보 총 22건 (필수 포함 18건 + 자유 수집 4건: C19 배압/재동기화, C20 capability 게이팅, C21 리사이즈 풀 리페인트, C22 grid 조회 API 부재)
- 축별 분포(복수 축 병기 포함 중복 집계): ①입력 6건(C4,C9,C12,C13,C14,C16) · ②렌더 5건(C1,C7,C19,C21,C22) · ③수명주기 9건(C2,C3,C6,C7,C8,C13,C15,C18,C20) · ④자원 10건(C1,C4,C5,C8,C10,C11,C12,C13,C17,C19)
- [신규] 태그: 0건 (전 항목 notes.md 원문 근거 인용)

### 부록C — 탈락 후보 (t7)

| C# | 탈락 사유 | 재고 조건 |
|---|---|---|
| C4 | matrix가 이미 "조사 항목으로 하향, 즉시채택 제외"로 판단(잠재 impact H이나 하향) — libghostty PTY-less 바이트 feed API 존재 자체가 미확인이라 effort(L) 산정의 전제부터 불확실 | libghostty가 PTY 없이 바이트를 직접 feed하는 FFI API를 제공/추가 가능한지 선행 조사(ghostty submodule) 완료 후 |
| C5 | Impact M/Effort S로 매력적이나(read측에 이미 DispatchSourceRead 대칭 패턴 존재) WAN 역압 상황 한정 효과라 H등급 8건에 밀려 10개 상한 안에 들지 못함 | P1(C2 병렬화)·P8(전송계층) 적용 후에도 WAN 역압이 실측/보고로 유의미하게 남아 있는지 확인되면 다음 라운드 최우선 채택 |
| C6 | Impact M/Effort M이며 최적화금지목록 M등급 회귀위험(`acceptRelay` O_NONBLOCK — 어설픈 재설계 시 첫 read EAGAIN에 세션 즉시종료 재현) 보유. C2와 곱연산 관계로 상승효과는 있으나 리스크 프로파일이 달라 P1과 묶지 않음 | P1(C2) 적용 후 실측으로 acceptRelay 대기시간이 여전히 유의미한지 확인 + O_NONBLOCK 회귀 방지 테스트 설계 완료 후 |
| C9 | Impact L(매트릭스 유일) — "이 특정 홉이 실제로 지연을 유발한 사례는 미확인", "구조적 제약일 가능성 높아 우선순위 낮음"이 원문 결론 | Ghostty API가 실제로 메인스레드 전용인지 여부 확인(조사 완료) 후 구조적 제약이 아님이 밝혀지면 재검토 |
| C16 | R2가 명시적으로 기각 결론 — vim 등 TUI 오표시 위험이 실증된 버그 패턴(vim ESC freeze)과 정확히 겹치고 CONTEXT[C2] 버전 사각지대까지 상속. t3 신규발견(client 100ms+host 120ms 이중 ESC 홀드)이 "client가 host보다 적은 정보로 더 빨리 판단해야 하는" 구조적 어려움을 실증 | (a) TUI를 감지 가능한 좁은 컨텍스트로 스코프 제한 + (b) mosh 스타일 "미확정 문자 시각적 구분+정정" UI를 레이턴시 완화책이 아닌 별도 제품기능 프로젝트로 설계할 경우에 한해 재검토 |
| C19 | R11(draft.md 189행 부근, §분석 t4)이 이미 "채택 — 2단계"로 결정하며 문서화된 전체 배압 정책(unacked_bytes>8MiB+ERR_INTERNAL+GridSnapshot 재요청)은 "이번 제안서 범위 밖 후속 프로젝트로 분리"를 명시. P9(C17+R11 2단계 자동재스냅샷)의 경량 대안으로 이미 대체됨. C20의 하드 선행조건 대상도 아님(매트릭스 C19 비고) | P9의 경량 자동재스냅샷 운영 중 한계가 드러나거나, P3(C20) 완료 후 완전한 배압 프로토콜이 실제로 필요해지면 재검토 |
| C21 | matrix가 이미 "조사 필요 카테고리로 하향"으로 판단 — C4와 동일한 FFI(cell-level grid export) 불확실성을 상속, R4 원문이 "후보1·2(C15/C3) 어느 쪽도 리사이즈를 해결 못 하며 후보3만이 유일한 해"라 명시 | cell-level grid export API(libghostty FFI) 존재 확인 후, 또는 단기 완화(코얼레싱 윈도우 조정, effort S)만이라도 P4 적용 후 별도 검토 가능 |
