# Step Runbook 시스템

## 개요

이 디렉토리에는 Phase 1의 17개 Step 각각에 대한 **실행 절차서(Runbook)** 가 있다. 매일 아침 해당 Step의 Runbook을 열어 체크리스트부터 확인하고, 저녁에 커밋하면 하루치 작업이 완결된다.

## 문서 3층 구조에서의 위치

```
What 층 (기존 설계)  — docs/decisions, docs/architecture, docs/specs
  └─ "시스템이 무엇인가" — 5차 검증 188항목 정합성 보존

How 층 (방법론)      — docs/decisions/012-implementation-methodology.md
  └─ "어떻게 증분하는가" — 세 원칙, 어휘, 안티패턴

Run 층 (Runbook)     — docs/runbooks/ ← 이 디렉토리
  └─ "지금 무엇을 하는가" — 매일 실행
```

Runbook은 What 층의 문서를 **포인터로 참조**한다. 내용을 복제하지 않는다.

## 파일 목록

| 파일 | 역할 |
|------|------|
| README.md | 본 파일. 사용법 및 규칙 |
| TEMPLATE.md | 7섹션 표준 템플릿 |
| PROGRESS.md | 17 Step 진행 상태 + Daily Log |
| step-00.md ~ step-11b.md | 17개 Step Runbook |

## 매일 반복 루프

```
아침 (10분):
  1. PROGRESS.md → 오늘 Step 번호 확인
  2. step-NN.md 열기
  3. §3 착수 전 체크리스트 확인
  4. §4 참조 문서 정독 (30분~1시간)

오전~오후 (4~6시간):
  5. §5 작업 단계 순서대로 구현
  6. 중간중간 pytest 실행

저녁 (30분):
  7. §6 완료 조건 전부 체크
  8. seam-map.md 해당 Stub 행 갱신
  9. PROGRESS.md 체크박스 + Daily Log 한 줄
  10. §7 커밋 메시지로 커밋 + 푸시
```

## 규칙

1. **Runbook을 건너뛰지 않는다**. Step은 순서대로 진행. 이전 Step 미완료 시 다음 Step 착수 불가.
2. **§6 완료 조건 전부 통과해야 커밋**. 일부만 통과한 채로 커밋하지 않음.
3. **기존 설계 변경 발견 시 ADR 발행**. Runbook 내부에서 기존 스펙의 결함을 발견하면 즉시 구현 중단 → ADR 발행 → SSoT 갱신 → Runbook 갱신 → 재개.
4. **매주 금요일 주간 회고**. PROGRESS.md 하단에 주간 회고 추가. 안티패턴 4개 중 감지 여부 점검.
5. **Step 0은 80줄 이하, 의존성 0**. Walking Skeleton이 비대해지면 안티패턴 3.
