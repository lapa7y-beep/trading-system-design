# Trading System Design

KIS Open API 기반 자동매매 시스템의 설계 문서 저장소.

## 구조

```
docs/
├── INDEX.md                 ← 전체 지도 (여기서 시작)
├── architecture/            ← 시스템 구조 설계
├── pipelines/               ← 3대 파이프라인 상세
├── specs/                   ← 스펙 문서 (매니페스트, 노드, 엣지)
├── decisions/               ← 설계 결정 기록 (ADR)
└── references/              ← 참고 자료, API 메모
```

## 운영 규칙

1. **INDEX.md가 진실의 원천** — 모든 문서의 현재 상태(draft/stable/deprecated)를 여기서 관리
2. **대화 → 문서** — Claude 대화에서 설계가 바뀌면 해당 .md 수정 후 commit
3. **decisions/에 이유 기록** — "무엇"은 architecture/에, "왜"는 decisions/에
