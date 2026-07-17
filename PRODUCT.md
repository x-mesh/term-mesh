# Product

## Register

product

## Users

터미널과 여러 CLI agent를 동시에 사용하는 개발자. 작업 흐름을 끊지 않고 프로젝트 동기화 상태, 충돌, 신뢰된 device, 복구 작업을 확인하고 제어해야 한다.

## Product Purpose

term-mesh는 terminal workspace와 agent 작업을 한곳에서 운영하는 macOS 도구다. Project Sync UI는 동기화의 현재 상태와 필요한 조치를 명확히 보여주되, background progress가 app activation이나 현재 pane focus를 바꾸지 않아야 한다.

## Brand Personality

차분함, 고밀도, 신뢰성. 개발 도구답게 정확하고 짧은 문구를 사용하며 장식보다 상태와 다음 행동을 우선한다.

## Anti-references

장식적인 SaaS dashboard, 과도한 card grid, glassmorphism, 불필요한 animation, 큰 hero metric, terminal 작업보다 시각 효과가 앞서는 UI를 피한다.

## Design Principles

- 상태와 다음 행동을 한눈에 구분한다.
- background telemetry는 사용자의 focus와 작업 맥락을 건드리지 않는다.
- 기존 Settings와 panel component vocabulary를 재사용한다.
- 파괴적이거나 복구 불가능한 행동은 결과를 먼저 설명하고 명시적으로 확인받는다.
- 전체 path, secret, 긴 identifier를 화면과 log에 노출하지 않는다.

## Accessibility & Inclusion

macOS native keyboard navigation과 VoiceOver 의미를 유지한다. 색상만으로 상태를 구분하지 않는다. system reduced motion 설정을 존중하고, 본문 text contrast는 WCAG AA를 충족한다.
