# Trading System Design

KIS Open API 기반 자동매매 시스템의 설계 문서 저장소.

## 구조

```
docs/
├── INDEX.md                 ← 전체 지도 (여기서 시작)
├── architecture/            ← 시스템 구조 설계
├── pipelines/               ← 데이터 경로별 파이프라인 상세
├── specs/                   ← 스펙 문서 (매니페스트, 노드, 엣지)
├── decisions/               ← 설계 결정 기록 (ADR)
└── references/              ← 참고 자료, API 메모, 용어 사전
```

## 운영 규칙

1. **문서 상태는 draft / stable 2개만** — 본인이 읽어보고 맞으면 stable. 형식적 리뷰 없음.
2. **동기화는 의미 있는 변경만** — 구조적 결정이 바뀌었을 때만 commit. 브레인스토밍은 문서화 안 해도 됨.
3. **연쇄 변경은 Claude가 추적** — "변경사항 정리해줘" 하면 영향받는 문서 전부 찾아서 같이 수정.
4. **새 대화 시작법** — INDEX.md 첨부 + "이어서 하자".

## 기술 스택

Python 3.11+ / asyncio / FastAPI / transitions / pandas-ta / pydantic / PostgreSQL+TimescaleDB / Redis / ChromaDB / Docker Compose / Grafana / LiteGraph.js
