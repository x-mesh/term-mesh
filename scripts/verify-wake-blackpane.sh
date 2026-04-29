#!/usr/bin/env bash
# verify-wake-blackpane.sh — sleep/wake black pane 검증 자동 분석 헬퍼
#
# 사전 조건: Debug 빌드 실행 중 + kiro agent 4개 attach 완료 상태
# 사용법:   ./scripts/verify-wake-blackpane.sh [--tag <name>] [--cycles <N>] [--expected-drawn <N>]
#
# dlog 포맷 (DebugEventLog.swift): "HH:mm:ss.SSS <message>"
# 관련 dlog:
#   workspace.willSleep teams=N agents=N agentPaused=bool
#   workspace.didWake   teams=N agents=N agentPaused=bool
#   team.drawAgentSurfaces reason=wake drawn=N paused=bool

set -euo pipefail

# ── 색상 ──────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
    BOLD='\033[1m'; RESET='\033[0m'
else
    GREEN=''; YELLOW=''; RED=''; BOLD=''; RESET=''
fi

# ── 기본값 ────────────────────────────────────────────────────────────────────
TAG="wake-blackpane-verify"
CYCLES=5
EXPECTED_DRAWN=4

# ── 인자 파싱 ─────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

sleep/wake 후 kiro-cli agent pane black 회귀 fix를 자동 검증합니다.
사전 조건: Debug 빌드 실행 중 + kiro agent ${EXPECTED_DRAWN}개 attach 완료

OPTIONS:
  --tag <name>            Debug 앱 태그 (기본: ${TAG})
  --cycles <N>            sleep/wake 반복 횟수 (기본: ${CYCLES})
  --expected-drawn <N>    wake 후 기대 drawn 수 (기본: ${EXPECTED_DRAWN})
  --log <path>            로그 파일 경로 직접 지정 (기본: 자동 감지)
  -h, --help              이 도움말 출력

PASS 판정 (사이클당):
  - workspace.willSleep 1라인 이상
  - workspace.didWake   1라인 이상
  - team.drawAgentSurfaces reason=wake drawn≥1

WARN: drawn>0 이지만 expected-drawn 미만
FAIL: didWake 없음 또는 drawn=0

예시:
  $(basename "$0")
  $(basename "$0") --tag my-test --cycles 3
  $(basename "$0") --expected-drawn 2
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tag)            TAG="$2";            shift 2 ;;
        --cycles)         CYCLES="$2";         shift 2 ;;
        --expected-drawn) EXPECTED_DRAWN="$2"; shift 2 ;;
        --log)            OVERRIDE_LOG="$2";   shift 2 ;;
        -h|--help)        usage; exit 0 ;;
        *) echo "Unknown option: $1"; usage; exit 1 ;;
    esac
done

# ── 로그 파일 결정 ────────────────────────────────────────────────────────────
resolve_log() {
    # 1. --log 직접 지정
    if [[ -n "${OVERRIDE_LOG:-}" ]]; then
        echo "$OVERRIDE_LOG"
        return
    fi
    # 2. reload.sh 가 남긴 마지막 경로 파일
    local last_path_file="/tmp/term-mesh-last-debug-log-path"
    if [[ -f "$last_path_file" ]]; then
        local p
        p=$(cat "$last_path_file")
        if [[ -f "$p" ]]; then
            echo "$p"
            return
        fi
    fi
    # 3. 태그 기반 추론
    local tag_log="/tmp/term-mesh-debug-${TAG}.log"
    if [[ -f "$tag_log" ]]; then
        echo "$tag_log"
        return
    fi
    # 4. 기본 untagged
    echo "/tmp/term-mesh-debug.log"
}

LOG=$(resolve_log)

# ── 배너 ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}=== sleep/wake black pane verification ===${RESET}"
echo "Tag:            ${TAG}"
echo "Log:            ${LOG}"
echo "Cycles:         ${CYCLES}"
echo "Expected drawn: ${EXPECTED_DRAWN}"
echo ""

if [[ ! -f "$LOG" ]]; then
    echo -e "${RED}ERROR: 로그 파일을 찾을 수 없습니다: ${LOG}${RESET}"
    echo "  → ./scripts/reload.sh --tag ${TAG} 로 앱을 먼저 실행하세요."
    exit 1
fi

# ── 사이클별 검증 함수 ────────────────────────────────────────────────────────

# 로그에서 지정 시각 이후 라인만 추출
# macOS stat -f %z = 파일 크기(바이트) — 사이클 시작 오프셋 저장에 활용
declare -a CYCLE_RESULTS=()   # "PASS" / "WARN" / "FAIL"
declare -a FAIL_LOGS=()       # FAIL 사이클의 dlog 발췌

run_cycle() {
    local cycle_num="$1"
    local log_offset="$2"   # 이 사이클 시작 시점의 파일 크기(바이트)

    echo ""
    echo -e "${BOLD}Cycle ${cycle_num}/${CYCLES}:${RESET}"
    echo "  지금 Mac을 Sleep 하세요 (Apple 메뉴 → Sleep 또는 lid 닫기)"
    echo "  Wake 후 term-mesh 창이 복구되면 Enter를 누르세요..."
    read -r _

    # 사이클 시작 이후 새로 추가된 라인만 추출 (tail +N은 라인 기준이므로 바이트 오프셋 → 라인 수로 변환)
    local new_lines
    new_lines=$(tail -c +"$((log_offset + 1))" "$LOG" 2>/dev/null || true)

    local will_sleep did_wake draw_line drawn_val
    will_sleep=$(echo "$new_lines" | grep -E "workspace\.willSleep" | tail -1 || true)
    did_wake=$(echo "$new_lines"   | grep -E "workspace\.didWake"   | tail -1 || true)
    draw_line=$(echo "$new_lines"  | grep -E "team\.drawAgentSurfaces reason=wake" | tail -1 || true)

    # drawn= 값 추출
    drawn_val=0
    if [[ -n "$draw_line" ]]; then
        drawn_val=$(echo "$draw_line" | grep -oE 'drawn=[0-9]+' | grep -oE '[0-9]+' || echo 0)
    fi

    # ── 개별 항목 출력 ──
    if [[ -n "$will_sleep" ]]; then
        echo -e "  willSleep: ${GREEN}✓${RESET}  ${will_sleep}"
    else
        echo -e "  willSleep: ${YELLOW}–${RESET}  (미감지 — 디스플레이 sleep만 했을 가능성)"
    fi

    if [[ -n "$did_wake" ]]; then
        echo -e "  didWake:   ${GREEN}✓${RESET}  ${did_wake}"
    else
        echo -e "  didWake:   ${RED}✗${RESET}  (미감지 — fix 진입 불가)"
    fi

    if [[ "$drawn_val" -ge "$EXPECTED_DRAWN" ]]; then
        echo -e "  drawn=${drawn_val}:   ${GREEN}✓${RESET}  ${draw_line}"
    elif [[ "$drawn_val" -gt 0 ]]; then
        echo -e "  drawn=${drawn_val}:   ${YELLOW}⚠ WARN${RESET}  expected=${EXPECTED_DRAWN}  ${draw_line}"
    else
        if [[ -n "$draw_line" ]]; then
            echo -e "  drawn=0:   ${RED}✗${RESET}  ${draw_line}"
        else
            echo -e "  drawn=?:   ${RED}✗${RESET}  (team.drawAgentSurfaces 라인 없음)"
        fi
    fi

    # ── 판정 ──
    local verdict
    if [[ -z "$did_wake" ]] || [[ "$drawn_val" -eq 0 ]]; then
        verdict="FAIL"
        echo -e "  → ${RED}FAIL${RESET}"
        FAIL_LOGS+=("--- Cycle ${cycle_num} FAIL dlog ---")
        local fail_excerpt
        fail_excerpt=$(echo "$new_lines" | grep -E "workspace\.(willSleep|didWake)|team\.drawAgentSurfaces" || echo "(관련 라인 없음)")
        FAIL_LOGS+=("$fail_excerpt")
    elif [[ "$drawn_val" -lt "$EXPECTED_DRAWN" ]]; then
        verdict="WARN"
        echo -e "  → ${YELLOW}WARN${RESET} (drawn=${drawn_val} < expected=${EXPECTED_DRAWN})"
    else
        verdict="PASS"
        echo -e "  → ${GREEN}PASS${RESET}"
    fi

    CYCLE_RESULTS+=("$verdict")
}

# ── 메인 루프 ─────────────────────────────────────────────────────────────────
echo "준비가 되면 Enter를 눌러 검증을 시작하세요..."
read -r _

for i in $(seq 1 "$CYCLES"); do
    # 사이클 시작 시점 파일 오프셋 기록
    cycle_offset=$(wc -c < "$LOG" 2>/dev/null || echo 0)
    run_cycle "$i" "$cycle_offset"
done

# ── 종합 결과 ─────────────────────────────────────────────────────────────────
pass_count=0
fail_count=0
warn_count=0
for r in "${CYCLE_RESULTS[@]}"; do
    case "$r" in
        PASS) ((pass_count++)) ;;
        FAIL) ((fail_count++)) ;;
        WARN) ((warn_count++)) ;;
    esac
done

echo ""
echo -e "${BOLD}=== Summary ===${RESET}"
echo -e "PASS: ${GREEN}${pass_count}/${CYCLES}${RESET}"
[[ $warn_count -gt 0 ]] && echo -e "WARN: ${YELLOW}${warn_count}/${CYCLES}${RESET}"
echo -e "FAIL: ${RED}${fail_count}/${CYCLES}${RESET}"

# 최종 verdict
echo ""
if [[ $fail_count -eq 0 && $warn_count -eq 0 ]]; then
    echo -e "${BOLD}Final verdict: ${GREEN}PASS${RESET}"
elif [[ $fail_count -eq 0 && $warn_count -gt 0 ]]; then
    echo -e "${BOLD}Final verdict: ${YELLOW}WARN${RESET} (drawn 수 부족 — agent 수 확인 필요)"
elif [[ $pass_count -eq 0 && $fail_count -eq 0 ]]; then
    echo -e "${BOLD}Final verdict: ${YELLOW}INCONCLUSIVE${RESET} (재현 불가 — Method B 사용 권장)"
elif [[ $fail_count -gt 0 ]]; then
    echo -e "${BOLD}Final verdict: ${RED}FAIL${RESET}"
fi

# FAIL 사이클 dlog 발췌
if [[ ${#FAIL_LOGS[@]} -gt 0 ]]; then
    echo ""
    echo -e "${RED}FAIL 사이클 dlog 발췌:${RESET}"
    for line in "${FAIL_LOGS[@]}"; do
        echo "  $line"
    done
fi

# 마지막 20라인 relevant dlog
echo ""
echo -e "${BOLD}Last 20 relevant dlog lines:${RESET}"
grep -E "workspace\.(willSleep|didWake|screensDidSleep|screensDidWake)|team\.drawAgentSurfaces" "$LOG" \
    | tail -20 \
    | while IFS= read -r line; do
        if echo "$line" | grep -qE "drawAgentSurfaces.*drawn=[1-9]"; then
            echo -e "  ${GREEN}${line}${RESET}"
        elif echo "$line" | grep -qE "FAIL|drawn=0"; then
            echo -e "  ${RED}${line}${RESET}"
        else
            echo "  $line"
        fi
    done

echo ""
