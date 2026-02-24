term-mesh
AI Agent Control Plane for macOS
PRD v2.0 — Hybrid Native (libghostty) Edition
버전
날짜
플랫폼
상태
v2.0
2025년 7월
macOS 13 Ventura+
Draft (Architecture Pivot)

--------------------------------------------------------------------------------
v1.1 → v2.0 변경 요약 (하이브리드 네이티브 아키텍처 전환)
이 버전은 기존 Tauri + xterm.js 기반의 단일 웹뷰 아키텍처를 폐기하고, 터미널 엔진은 libghostty를 활용한 완전한 Swift/AppKit 네이티브로, **복잡한 시각화 UI는 WKWebView**로 분리하는 하이브리드 마이크로 프론트엔드 아키텍처를 채택했습니다.
기능
v1.1 스택 (Tauri)
v2.0 스택 (Hybrid Native)
변경 사유
터미널 렌더링
xterm.js + WebGL
Swift + libghostty (Metal API)
궁극의 성능, 메모리 획기적 절감, 네이티브 Vibrancy
관제 UI (히트맵)
Tauri 메인 웹뷰 내 통합
터미널 측면 분할 WKWebView
렌더링 부하 격리, 기존 React 생태계(Chart.js) 유지
데스크톱 셸
Tauri (Rust)
AppKit (Swift)
완벽한 macOS 네이티브 탭/분할 및 단축키 제어
백엔드 통신
Tauri IPC
Rust Core ↔ Swift FFI / Unix Sockets
데몬화된 백그라운드 리소스/파일 모니터링

--------------------------------------------------------------------------------
1. 배경 및 전략적 포지셔닝
1.1 왜 하이브리드 네이티브인가 (cmux 아키텍처 벤치마킹)
AI 에이전트를 다수 병렬로 실행하는 환경에서는 터미널 렌더링 성능이 핵심입니다. 기존 xterm.js는 다중 세션에서 DOM/WebGL 오버헤드가 발생하지만, libghostty는 Metal을 통한 직접 GPU 가속으로 이 문제를 해결합니다. 반면, 복잡한 히트맵이나 차트를 Swift로 직접 그리는 것은 개발 비용이 큽니다. 따라서 "터미널은 가장 빠른 네이티브로, 시각화는 가장 유연한 웹으로" 구현하는 하이브리드 전략을 취합니다.

--------------------------------------------------------------------------------
2. 제품 비전
"가장 강력한 네이티브 터미널 엔진(libghostty) 위에서 AI 에이전트를 병렬로 실행하고, 분할된 웹뷰 대시보드로 시스템 리소스와 파일 히트맵을 100% 완벽하게 관제한다."

--------------------------------------------------------------------------------
3. 기능 요구사항
F-01. 샌드박스 워크트리 오케스트레이션
Priority: P0 | git2-rs (Rust Daemon) 에이전트가 메인 코드베이스를 직접 수정하지 못하도록 물리적 격리 환경을 생성합니다.
• 기술 구현:
    ◦ Rust 데몬이 git2-rs로 워크트리를 생성 (../term-mesh_wt_[UUID]).
    ◦ AppKit이 새 세션 생성을 요청하면, Rust가 워크트리를 준비하고 CWD를 고정한 뒤 Swift로 반환하여 libghostty가 해당 경로에서 PTY를 시작하도록 오케스트레이션.
F-02. 멀티 에이전트 네이티브 터미널 인터페이스 (Powered by libghostty)
Priority: P0 | Swift + AppKit + libghostty 기술 구현:
• PTY & 렌더링: libghostty의 C API를 Swift 앱에 연결하여 GPU(Metal) 기반의 터미널 렌더링 수행.
• 수직형 사이드바 탭 (cmux 스타일): 상단 탭 대신 수직형 사이드바를 채택하여 여러 에이전트의 상태(Git 브랜치, 실행 중인 포트 등)를 한눈에 파악.
• 네이티브 분할(Split): AppKit의 네이티브 뷰 분할을 사용하여 여러 터미널 패널을 오버헤드 없이 자유롭게 분할.
• 시각적 알림 링: 에이전트가 입력을 대기할 때(OSC 9/99/777 감지) 해당 터미널 창 테두리에 파란색 링 표시.
F-03 & F-04. 예산 관리(Budget Guard) 및 리소스 모니터링
Priority: P1 | Rust Daemon ↔ WKWebView
• 기술 구현: Rust 백그라운드 데몬이 sysinfo로 프로세스를 모니터링하고, Claude Code의 JSONL 로그를 증분 파싱하여 실제 API 토큰 사용량과 비용을 계산합니다.
• UI 연동: 모니터링된 데이터는 터미널 화면 옆에 분할되어 있는 WKWebView (React) 대시보드로 실시간 스트리밍되어 차트 형태로 렌더링됩니다.
• 임계값 초과 시 Rust가 프로세스에 SIGSTOP을 보내고, Swift 프론트엔드를 통해 macOS 네이티브 알림(UNNotification)을 트리거합니다.
F-05. FSEvents 파일 접근 히트맵 대시보드
Priority: P1 | macOS FSEvents + WKWebView
• 기술 구현: Rust notify 크레이트로 파일 변화 이벤트(생성/수정/접근)를 100% 정확도로 추적합니다.
• 마이크로 프론트엔드 분할 뷰: 터미널 창 옆에 인앱 브라우저처럼 띄워진 웹뷰 대시보드에서 기존에 기획한 React UI를 실행합니다.
• 폴더 트리 색상 오버레이, 1분 단위 타임라인, 핫파일 TOP 5 바 차트 등 복잡한 UI 요소를 웹 기술(React/Chart.js)로 손쉽고 미려하게 렌더링합니다.

--------------------------------------------------------------------------------
4. 하이브리드 기술 아키텍처 (Hybrid Native)
4.1 레이어 구조 역할 분담
레이어
기술 스택
역할 및 특장점
Native Shell
Swift / AppKit
앱 생명주기 관리, 수직형 탭, 창 분할, NSVisualEffectView (Vibrancy) 제어
Terminal Engine
libghostty (Metal)
C API를 통한 궁극의 PTY 입출력 및 텍스트/유니코드 GPU 렌더링
UI Dashboard
WKWebView + React
파일 히트맵, 토큰 사용량 차트, 프로세스 모니터링 시각화 전담
Core Logic
Rust (uniffi / Socket)
FSEvents(notify), 토큰 계산(tiktoken), Git 격리(git2), 리소스 추적
4.2 데이터 흐름 아키텍처
1. [Terminal] libghostty가 에이전트의 출력을 네이티브로 렌더링함과 동시에, OSC 제어 문자열을 가로채어 상태(알림 대기 등)를 AppKit에 전달.
2. [Backend] Rust 데몬은 워크트리 디렉토리의 FSEvents를 수집하고, 활성화된 PID의 리소스를 추적하며, Claude Code JSONL 로그에서 실제 API 사용량/비용을 파싱하여 로컬 소켓과 HTTP를 통해 브로드캐스트.
3. [Dashboard] 터미널 패널 옆에 위치한 WKWebView가 Rust 데몬으로부터 데이터를 받아 React 상태를 업데이트하고 차트를 실시간으로 다시 그림.

--------------------------------------------------------------------------------
5. 개발 로드맵 (수정됨)
Phase 1 — Native Foundation (4주)
• W1: Swift + AppKit 뼈대 구축 및 libghostty C API 연동 (단일 네이티브 터미널 렌더링 성공).
• W2: cmux 스타일의 수직형 사이드바 및 네이티브 창 분할(Split) UI 구현.
• W3: Rust 백그라운드 데몬 통신 브릿지 (FFI 또는 로컬 소켓) 구축.
• W4: git2-rs 워크트리 샌드박스 로직을 Rust 데몬에 통합, 세션 생성 시 CWD 격리 적용.
Phase 2 — Hybrid Dashboard & Monitoring (4주)
• W5: WKWebView 통합 및 React 프론트엔드 연동 (마이크로 프론트엔드 환경 구축).
• W6: Rust notify를 활용한 FSEvents 추적을 React 히트맵 UI에 실시간 바인딩.
• W7: sysinfo 기반 Budget Guard(SIGSTOP/SIGCONT) 및 JSONL 기반 API 비용 추적 로직 구현, 대시보드 차트 적용.
• W8: 에이전트 응답 대기 상태(OSC 시퀀스) 파악 로직 및 파란색 링 / 시스템 알림(UNNotification) 연동.

--------------------------------------------------------------------------------
6. 비기능 요구사항

6.1 성능
• 동시 세션: 최소 8개 터미널 세션을 GPU 프레임 드롭 없이 동시 렌더링 (libghostty Metal).
• 데몬 메모리: term-meshd 상주 메모리 50 MB 이하 (모니터링 + 파일 워처 + 사용량 추적 포함).
• 대시보드 레이턴시: RPC/HTTP 요청 → UI 반영까지 200 ms 이내 (로컬 Unix Socket / localhost HTTP).
• 파일 워처: FSEvents 이벤트 수집 → 히트맵 반영 지연 1초 이내.
• 사용량 스캔: JSONL 증분 파싱 (byte offset 기반), 10 MB+ 로그 파일에서도 스캔 사이클 100 ms 이내.

6.2 안정성
• 데몬 라이프사이클: 앱 시작 시 자동 기동, 종료 시 graceful shutdown. 고아 프로세스 재사용 (ping 확인).
• 소켓 복구: 비정상 종료 시 stale 소켓 파일 자동 정리 후 재생성.
• 워크트리 정리: 탭 종료 시 자동 삭제, 앱 강제 종료 시에도 다음 실행 시 orphan 워크트리 감지/정리.
• Budget Guard 안전장치: SIGSTOP 후 사용자 확인 없이 자동 SIGCONT 하지 않음. macOS 네이티브 알림으로 즉시 통보.

6.3 보안
• 워크트리 격리: 에이전트가 원본 리포지토리를 직접 수정 불가 (물리적 파일 시스템 격리).
• 소켓 접근: Unix Domain Socket은 파일 퍼미션으로 현재 사용자만 접근 가능.
• HTTP 대시보드: localhost 바인딩 전용 (외부 네트워크 노출 없음). CORS permissive는 로컬 전용.
• 민감 정보: .env, 크레덴셜 파일은 워치 대상에서 제외하지 않으나, 대시보드에 파일 내용을 노출하지 않음 (경로명/이벤트 타입만 표시).

6.4 호환성
• macOS: 13 Ventura 이상 (Metal 2 필수).
• Xcode: 15+ (Swift 5.9+).
• Rust: stable 1.75+ (edition 2021).
• libghostty: Zig 0.15+ 빌드 필요.

6.5 라이선스
• AGPL-3.0-or-later (cmux fork 기반).
• 모든 파생 저작물은 동일 라이선스로 소스 공개 의무.

--------------------------------------------------------------------------------
7. 성공 지표

7.1 정량 지표
지표                          목표값                  측정 방법
동시 에이전트 세션 수          ≥ 8개                  수동 테스트 (8개 탭 동시 실행)
터미널 렌더링 FPS             ≥ 60 FPS               Instruments Metal Trace
데몬 RSS 메모리               ≤ 50 MB                Activity Monitor / ps aux
대시보드 데이터 갱신 주기       ≤ 2초                  WKWebView 폴링 + HTTP 폴링 간격
API 비용 정확도               ≥ 99%                  JSONL 파싱 결과 vs Anthropic 청구서 대조
워크트리 생성/삭제 성공률       100%                   자동화 테스트 (create → verify → remove)
Budget Guard 반응 시간         ≤ 3초                  임계값 초과 → SIGSTOP 발송까지

7.2 정성 지표
• 단일 창에서 모든 에이전트의 상태를 한눈에 파악 가능 (수직 사이드바 + 알림 링).
• 대시보드 Split 모드에서 터미널과 모니터링을 동시에 확인하며 작업 가능.
• 새 탭 생성 → 워크트리 격리 → 에이전트 실행까지 수동 개입 없이 자동화.
• 실제 API 비용을 실시간으로 확인하여 예산 초과 전 사전 대응 가능.

--------------------------------------------------------------------------------
8. 핵심 의존성 (Updated)
Tauri를 제거하고 네이티브 셸 + Rust 백엔드 구조로 변경됨에 따라 의존성이 개편되었습니다.
컴포넌트
패키지 / 크레이트
용도
Native UI
Swift, AppKit, WKWebView
데스크톱 셸, 창 관리, 대시보드 웹뷰 컨테이너
Terminal
libghostty
초고속 Metal 기반 GPU 터미널 에뮬레이터 엔진
Rust FFI
uniffi (선택적)
Swift와 Rust 데몬 간의 안정적인 바인딩 생성
Watcher
notify 6.x
macOS FSEvents 기반 워크트리 변경 감지
Git
git2-rs 0.19
워크트리 자동 생성 및 격리
Monitor
sysinfo
CPU/메모리 모니터링, 프로세스 트래킹
Usage
JSONL 파싱 (자체 구현)
Claude Code 로그에서 실제 API 토큰/비용 추출
Dashboard
React 18, Chart.js, Tailwind
복잡한 데이터(히트맵, 비용) 시각화

--------------------------------------------------------------------------------
term-mesh PRD v2.0 — Hybrid Native (libghostty) Edition 가장 빠른 터미널과 가장 유연한 시각화의 결합으로 AI 에이전트 관제의 새로운 표준을 세웁니다.
