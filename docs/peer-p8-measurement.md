# P8 측정 — SSH 터널 오버헤드 실측

**목적**: P8(LAN Native TCP + WAN 압축)을 구현할 가치가 있는지를 추정이 아니라
숫자로 판정한다. `docs/peer-perf-proposal.md`의 P8 impact는 전 항목 `[추정]`이고
저장소에 벤치 하네스가 전무했다(`:423`). 이 문서는 그 공백을 메운다.

하네스: `scripts/peer-bench.sh` + `tm-agent peer bench`(`daemon/term-mesh-cli/src/peer.rs`).

## 사전등록 판정 규칙 (측정 전에 고정 — 결과 합리화 방지)

입력→에코 RTT p50에서 SSH가 direct 대비:
- **< ~2ms 추가** → **P8-LAN 기각** (SSH 오버헤드 무시할 만함, 최고 리스크 작업 절약)
- **> ~10ms 추가** → **진행**: auth/pairing 선행 → 그 다음 Native TCP
- **2~10ms** → 2차 지표(감지 가능성·재연결·배터리)와 함께 재평가

압축(WAN): 전형 세션 + 대량 리페인트의 PtyData 볼륨·압축률 측정. WAN 링크가
병목이고 페이로드가 크고 압축 가능할 때만 근거 성립. 아니면 드롭.

## 측정 방법

동일 term-meshd를 두 번 측정해 SSH hop의 per-op 비용만 격리:
- **B (direct)**: 데몬의 실제 `TERMMESH_PEER_SOCKET`에 직접 attach (SSH 없음).
- **A (ssh)**: `ssh -L`로 forward한 소켓에 attach.

지표: `wire`(Ping/Pong 순수 왕복), `rtt`(입력→PTY 에코, 체감 타이핑 지연),
`throughput`(대량 host→client 버스트 bytes/s). 각 지표 p50/p95, warmup 3 제외.

로opback A/B의 논리: 실 LAN에서는 SSH와 Native TCP가 **같은 네트워크 RTT**를
낸다. 차이는 SSH hop의 framing/crypto/버퍼링 per-op 비용뿐이고, 그게 바로
loopback delta가 격리하는 값 = Native TCP가 없앨 수 있는 값이다.

## 결과 — loopback 다회 측정 (2026-07-15, macOS)

> ⚠ **소표본 주의**: 최초 25샘플 1회 측정은 SSH가 echo에 +3.5ms를 붙이는 것처럼
> 보였으나(direct p50 0.073 vs ssh 3.636), 이는 소표본 노이즈였다. 300샘플 × 3회로
> 재측정하니 결론이 뒤집혔다. 아래가 신뢰 가능한 결과다.

`./scripts/peer-bench.sh localhost` (MODE=all ITERS=300), rtt(echo) ms:

| run | direct p50 | ssh p50 | SSH Δp50 | direct max | ssh max |
|----:|-----------:|--------:|---------:|-----------:|--------:|
| A | 3.773 | 3.957 | +0.18 | **270.7** | 8.9 |
| B | 3.591 | 3.853 | +0.26 | **176.7** | 9.0 |
| C | 3.513 | 4.776 | +1.26 | 11.9 | **203.6** |

wire(Ping/Pong) p50: direct ~0.01ms, ssh ~0.08ms → SSH +0.07ms.

### 해석 (3회 300샘플 기준)

1. **SSH echo 오버헤드는 무시할 만하다 (p50 +0.18~1.26ms).** 최초 25샘플의
   +3.56ms는 허상이었다 — wire ping SSH 비용이 +0.07ms인데 echo만 50x 비쌀 리
   없다는 게 이미 신호였다. P8이 없앨 전송계층 비용은 사실상 없다.

2. **~3.5ms echo p50은 host측 고정 바닥이다** — SSH 유무와 무관하게 direct도
   ssh도 ~3.5-4.8ms. 코드상 원인: `daemon/term-meshd/src/peer/surface.rs:168-261`의
   PTY reader가 `async_fd.readable().await → libc::read → filter.process →
   tx.send(chunk)`로 흐르는데 **인위적 타이머·코얼레서가 없다**(grep상 데몬 peer
   모듈에 coalesce 0건; `layout.rs:655` PUSH_DEBOUNCE 120ms는 layout 전용). 3.5ms는
   왕복 멀티홉 tokio/kqueue 스케줄링(Input→conn reader→PTY write→line-discipline
   에코→master readable→broadcast→conn writer→client)의 park/unpark 누적이다. 튜닝
   가능한 단일 노브가 아니라 아키텍처(홉 수)에 내재. 그리고 3.5ms는 지각 임계
   (~50-100ms) 한참 아래라 체감되지 않는다.

3. **꼬리(echo max 200~550ms)는 echo 경로 특정 — 클라 노이즈 아님(대조로 확인).**
   같은 클라이언트·소켓·run에서 wire(Ping/Pong)는 p99 0.02ms·**max 0.03ms**로 꼬리가
   전무한데 echo만 max 211/551/9.8ms(direct-only 3회). 클라이언트 디스케줄이 원인이면
   같은 루프의 wire ping에도 꼬리가 나와야 하지만 안 난다 → 꼬리는 **echo 경로 특정**.
   단 wire는 단일 스레드, rtt는 별도 reader 스레드+채널이라 threading이 달라 200ms+
   꼬리의 데몬/클라 귀속 일부는 데몬 내부 타임스탬프로 확정이 남는다.
   반면 **median 3.7ms(vs wire 0.006ms, ~600배)는 매 샘플 절반에 일관**되므로 데몬
   PTY 경로(macOS PTY 왕복 + `surface.rs:154`의 별도 tokio reader task 웨이크업)가
   거의 확실하다. 어느 쪽이든 SSH·전송과 무관.

4. **throughput 절대치(2-3 MB/s)는 전송 무관** — PTY+broadcast 오버헤드가 한계.

## 결과 2 — 지연 계층 완전 국소화 (해결)

같은 데몬+전송을 두고 데몬 surface만 바꿔(`TERMMESH_PEER_SURFACES`) 각 계층 비용을 분리:

| 계층 | 측정 방법 | echo p50 |
|------|-----------|---------:|
| 커널 PTY 순수 echo | Python 마이크로벤치 (ICANON off, sleep child) | 0.003 ms |
| SSH hop (전송) | wire ping direct↔ssh delta | +0.07 ms |
| **term-mesh 데몬 릴레이 경로** | `cat` surface (커널 echo만 탐) | **0.160 ms** |
| relay + 최소 shell | `bash --norc` surface | 0.176 ms |
| relay + 내 zsh (plugins) | `zsh -l` surface | **4.889 ms** |

(마이크로벤치: `scratchpad/pty-rtt.py`. macOS 커널 PTY echo p50 0.003ms, 프로세스
echo(`cat`) 0.018ms — 둘 다 3.7ms의 주인이 아님.)

**핵심**: term-mesh peer 릴레이(데몬 tokio reader + broadcast + writer + unix 소켓 +
SSH)의 왕복 비용은 **0.16-0.18ms로 빠르다.** `bash --norc`를 같은 릴레이로 치면 p50
0.176ms·max 7ms로 스냅. 앞서 본 3.7-4.9ms median + 200-350ms 스파이크는 **전송도,
데몬도, 커널 PTY도 아니라 데몬이 띄운 인터랙티브 shell(zsh)의 키당 처리**다 — 이
환경의 zsh는 zsh-autosuggestions + zsh-syntax-highlighting이 키마다 전체 라인을
재계산해 +4.7ms를 더한다(`zsh -l` 4.889ms vs `bash --norc` 0.176ms로 확증).

즉 "느릴 때 100x"는 실재하나 그 주인은 **원격 shell 설정**이지 term-mesh가 아니다.
로컬 터미널에서도 같은 zsh 플러그인은 같은 비용을 낸다(로컬은 네트워크가 없어 덜
의식될 뿐). **term-mesh가 고칠 릴레이 지점 없음.**

## 최종 판정

- **P8(Native TCP / SSH 제거): 무의미.** 전송 비용 +0.2ms, 릴레이는 이미 0.16ms.
  판정 규칙(p50 delta < 2ms) + auth 선행 + 최고 롤아웃 리스크 → **기각 확정.**
- **peer 릴레이 성능은 이미 좋다** (echo 왕복 0.16ms). 병목은 원격 shell = 사용자 환경.
- 타이핑이 느리게 느껴지면 대책은 term-mesh가 아니라 원격 shell 플러그인 경량화
  (syntax-highlighting async 모드, autosuggestions off 등).

## 결과 3 — macOS ↔ Linux 데몬 비교

Linux(jw-server, x86_64, kernel 6.17) 로컬에서 동일 측정(마이크로벤치 `scripts/pty-rtt.py`,
데몬 로컬 bench). echo p50 기준:

| 계층 | macOS | Linux |
|------|------:|------:|
| 커널 PTY 순수 echo (마이크로벤치) | 0.003 ms | 0.022 ms |
| relay wire (PTY 없음) | ~0.010 ms | 0.026 ms |
| **relay + cat** (커널 echo만) | **0.160 ms** | **0.314 ms** |
| relay + `bash --norc` | 0.176 ms | 0.488 ms |
| relay + `zsh -l` (plugins) | 4.889 ms | (zsh 미가용, 미측정) |

**양 OS 모두 term-mesh 릴레이 왕복은 sub-0.5ms로 빠르다.** Linux가 macOS보다 ~2x
느리지만(VPS CPU/스케줄링 차이 추정) 둘 다 shell 비용(4.9ms) 앞에선 무의미. 커널
PTY도 양쪽 다 sub-0.03ms. 즉 **어느 OS에서도 3.7ms의 주인은 relay·전송·PTY가 아니라
인터랙티브 shell**임이 재확인된다.

(네트워크 경유(ssh -L Tailscale) 측정도 해봤으나 wire baseline이 ~2ms로 흔들려 로컬
측정이 더 깨끗함. 하네스는 두 방식 다 지원.)

## 최종 결론 (확정)

- **P8(Native TCP / SSH 제거): 무의미.** SSH echo +0.2ms, 릴레이 이미 0.16-0.31ms. 기각.
- **term-mesh peer 릴레이는 이미 빠르다** (echo 왕복 macOS 0.16ms / Linux 0.31ms). 병목 아님.
- **타이핑 지연의 주인은 원격 인터랙티브 shell** (zsh-autosuggestions + syntax-highlighting).
  전송·auth·OS와 무관. term-mesh가 고칠 릴레이 지점 없음. 대책은 원격 shell 경량화.
