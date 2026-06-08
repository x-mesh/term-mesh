---
name: tm-debug
description: term-mesh DEV의 렌더/peer 라이브 디버그 루프. 활성 태그의 debug 로그를 증상 구간만 잘라 분석하고, 최소 수정안을 사용자 확인 후 reload.sh로 재빌드해 재검증한다. "로그 봐줘", "peer 안 보임/깜빡임", "blank pane", "redraw 안 됨", "화면 일부 안 보임", "pane 렌더 버그", "reload 후 확인" 같은 term-mesh DEV 디버깅 요청에 사용.
metadata:
  version: "1.0.0"
---

# tm-debug — term-mesh 라이브 디버그 루프

term-mesh DEV의 렌더/peer 시각 버그를 잡는 **반자동 루프**다. 사람이 증상을 재현하고("로그 봐줘"/"계속"), 스킬은 그 구간의 debug 로그를 해석해 가설과 최소 수정안을 낸다. 수정 적용과 `reload.sh` 재빌드 전에는 **반드시 사용자 확인**을 받는다.

## 언제 쓰나

- term-mesh DEV에서 pane/peer가 안 보이거나, 깜빡이거나, 일부만 그려지거나, redraw가 안 될 때
- 사용자가 증상을 재현하고 "로그 봐줘" / "계속"이라고 할 때
- `reload.sh --tag X`로 띄운 빌드를 디버깅 중일 때

이 스킬은 term-mesh DEV 전용이다(`reload.sh`, `/tmp/term-mesh-debug-*.log` 경로 의존). 다른 프로젝트엔 적용하지 않는다.

## 루프 (6단계)

```
1. 감지   → 활성 태그 + debug 로그 경로 찾기
2. 구간   → 증상 시각 부근만 추출 (전체 덤프 금지)
3. 가설   → 서브시스템 신호 해석 → 근본원인 후보
4. 게이트 → 최소 수정안(파일:라인/diff 요지) 제시 → 사용자 확인  ⛔ 여기서 멈춤
5. reload → 확인 후 reload.sh --tag <같은 태그>로 재빌드
6. 재검증 → 사용자 재현 → 해결이면 cleanup 안내, 아니면 1로
```

핵심 규칙: **4단계 게이트를 건너뛰지 않는다.** 분석·가설·수정안까지는 자동, 적용/reload는 사용자 승인 후.

---

## 1. 감지 — 활성 태그 / 로그 경로

`reload.sh`는 마지막 빌드의 debug 로그 경로를 `/tmp/term-mesh-last-debug-log-path`에 기록한다. 이걸 1순위로 쓴다.

```bash
# 활성 debug 로그 경로 (1순위: reload.sh가 기록한 경로)
LOG="$(cat /tmp/term-mesh-last-debug-log-path 2>/dev/null)"
# 2순위: 가장 최근 수정된 태그 로그
[ -f "$LOG" ] || LOG="$(ls -t /tmp/term-mesh-debug-*.log 2>/dev/null | head -1)"
echo "log: $LOG"

# 현재 태그 (로그 파일명에서 역산: term-mesh-debug-<slug>.log)
TAG="$(basename "$LOG" .log | sed 's/^term-mesh-debug-//')"
echo "tag: $TAG"
```

태그가 여러 개거나 모호하면 추측하지 말고 사용자에게 어느 태그인지 확인한다. `--tag`는 reload 시 동일 값을 유지해야 한다(병렬 빌드 오염 방지).

## 2. 구간 추출 — 증상 발생 시각만

로그는 `HH:MM:SS.mmm subsystem.event key=value ...` 포맷이라 시각 상관이 쉽다. **전체를 읽지 말 것** — 컨텍스트 낭비 + 노이즈.

```bash
# 마지막 N초 구간만 (증상은 보통 직전 입력/리사이즈 직후)
tail -n 200 "$LOG"

# 특정 분(分) 구간만, 렌더 관련 서브시스템만
grep -E '^14:09:' "$LOG" | grep -E 'portal\.(sync|bonsplit)|peer\.|redraw|surface'
```

사용자가 "지금 재현했어"라고 하면 → 직전 입력 시각 이후 구간을 본다. 시각을 모르면 `tail`로 꼬리부터.

## 3. 로그 해설표 (서브시스템 신호)

> 포맷·필드는 `reload.sh`가 내보내는 현재 로그 기준. 로그 스키마가 바뀌면 이 표를 갱신할 것.

### `portal.sync.result` — pane 동기화 결과 (렌더 가시성의 핵심)

| 필드 | 의미 | 주목 신호 |
|---|---|---|
| `hide` | 이 pane을 숨김 처리했는가 | `hide=1`인데 보여야 할 pane이면 = blank pane 원인 후보 |
| `entryVisible` | 엔트리(레이아웃)상 보이는가 | `entryVisible=0` + 사용자는 보여야 함 = 레이아웃 누락 |
| `hostedHidden` | hosted view가 가려졌는가 | `hostedHidden=1` = 표면은 있는데 가림 |
| `target` vs `raw` | 목표 프레임 vs 원본 | 둘이 다르면 = 리사이즈/anchor 보정 중 |
| `hostBounds` | 호스트 윈도우 경계 | target이 hostBounds 밖 = 화면 밖으로 밀림 |

**판독 예**: `hide=1 entryVisible=0 hostedHidden=1` 인 pane이 "안 보이는 그 pane"이면 → sync가 의도적으로 숨긴 것. 왜 `hide=1`이 됐는지(앞선 레이아웃 계산)를 역추적.

### `portal.bonsplit.container` — split 컨테이너 프레임

| 필드 | 의미 |
|---|---|
| `frame=x,y WxH` | 컨테이너 실제 프레임 |
| `anchor=x,y WxH` | 앵커(기준) 프레임 |
| `host=x,y WxH` | 호스트 좌표계 |

`frame`의 H가 0이거나 음수 / `anchor`와 크게 어긋남 = 레이아웃 붕괴 → blank/clipped pane.

## 4. 알려진 증상 → 신호 매핑

| 증상 | 1순위 확인 신호 | 흔한 근본원인 |
|---|---|---|
| pane 일부가 blank | `portal.sync.result hide=1`/`entryVisible=0`, bonsplit `frame` H=0 | 레이아웃 계산이 pane을 0높이/숨김 처리 |
| 화면 줄이면 일부 안 보임 | 리사이즈 직후 `target` vs `hostBounds` | 리사이즈 시 anchor/clip 보정 누락 |
| 엔터 쳐야 보임 | 입력 이벤트 직후에야 `sync.result entryVisible=1` 전환 | redraw가 입력 트리거에만 걸림(주기적 sync 누락) |
| peer pane 갱신 느림/안 보임 | `peer.*` 이벤트 간격, sync 호출 빈도 | peer relay 수신 후 redraw 스케줄 누락 |
| peer 복붙 한글 깨짐 | 인코딩 이슈 → 별도 `/tm-encoding` 후보 참조 | UTF-8 청크 경계 분리 / bracketed-paste 프레이밍 (이 스킬 범위 밖) |

매핑에 없는 증상이면 추측하지 말고, 구간 로그에서 증상 시각과 가장 가까운 이상 신호를 근거로 가설을 세운다.

## 5. 수정 게이트 (⛔ 필수 정지점)

근본원인 후보가 서면, **적용 전에** 다음을 제시하고 사용자 확인을 받는다:

- 근본원인 한 줄
- 수정 위치: `파일:라인` + diff 요지 (최소 변경, 무관 코드 손대지 않음)
- 이 수정이 어떤 신호를 정상화하는지(예: `hide=1` → `0` 기대)

확인 전에는 파일을 고치지도, reload 하지도 않는다.

## 6. reload 재빌드 + 재검증

확인 후 동일 태그로 재빌드:

```bash
./scripts/reload.sh --tag "$TAG"
```

빌드 로그는 `/tmp/term-mesh-xcodebuild-<slug>.log`. 빌드 성공 후 사용자에게 재현 요청 → 해결이면 종료, 아니면 1단계로 (이번 구간 로그를 새로 추출).

해결되면 stale 태그 정리를 안내한다(`reload.sh`가 cleanup 명령을 출력한다). **로그/빌드 산출물 삭제는 사용자 확인 후에만.**

## 후속 (선택)

근본원인을 확정해 의미 있는 교훈이 남으면, 사용자에게 mem-mesh 기록(WHY/WHAT/IMPACT 포맷) 또는 `/xm:humble` 회고를 제안한다. 강요하지 않는다.

## 안전 규칙

- 수정은 최소 diff. 증상과 무관한 리팩터/정리 금지.
- `reload.sh`는 항상 `--tag <현재 태그>`로 — 새 태그를 임의 생성하면 빌드가 난립한다.
- 삭제(로그/소켓/빌드)는 사용자 확인 후.
- 로그 전체 덤프 금지 — 항상 증상 구간만.
