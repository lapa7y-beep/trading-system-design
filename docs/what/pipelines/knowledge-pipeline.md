# 지식 파이프라인 — Phase 2+ 자리예약

> **층**: What
> **상태**: reserved (Phase 1 스코프 제외, Port 시그니처만 확정)
> **최종 수정**: 2026-04-19
> **목적**: Phase 2+ 활성화 대상인 지식파이프라인의 구조를 지금 고정하여, Phase 1 노드들이 **끼워넣을 수 있는 구조**로 성립하는지 검증한다.
> **근거**: HR-DAG 재귀전개 원칙, System Manifest 8 도메인 중 "지식데이터" 도메인.

## 1. Phase 1에서 이 문서의 역할

Phase 1은 `graph_ir_phase1.yaml`의 `meta.paths_active: [path1]`만 활성. 지식파이프라인(Path 2)은 `paths_deferred`. 따라서 이 문서는:

1. **Port 시그니처**만 지금 확정 — Phase 1 StrategyEngine이 나중에 `KnowledgePort`를 Optional 주입받을 수 있는 자리를 열어둠
2. **데이터 플로우 스케치**만 제공 — 실제 구현은 Phase 2
3. **경로간 직접엣지 금지 원칙 검증** — Path 2가 Path 1에 침범하지 않는 구조로 설계됨을 확인

**Phase 1 코드베이스에는 `KnowledgePort` 인터페이스 파일만 생성하고, Adapter는 작성하지 않는다.**

## 2. 데이터 플로우 (Phase 2+ 설계)

```
┌─────────────────────────────────────────────┐
│  외부 소스 (6 Ingest Adapter)                │
│  DART · 뉴스 · 공급망 · 리포트 · 공시 · SNS   │
└──────────────────┬──────────────────────────┘
                   │ IngestPort
                   ▼
          ┌─────────────────┐
          │ IngestReceiver  │    RawDoc {source, ts, text, meta}
          └────────┬────────┘
                   ▼
          ┌─────────────────┐
          │ DocumentParser  │    ParsedDoc {entities, events, triples_raw}
          └────────┬────────┘
                   ▼
          ┌─────────────────┐
          │ OntologyMapper  │    엔티티 정규화, Triple 생성
          └────────┬────────┘
                   ▼
          ┌─────────────────────────────────┐
          │      KnowledgeStore              │  Shared Store F
          │   [triples · entities · events]  │  Neo4j or PG JSONB (ADR 필요)
          └────────┬────────────────────────┘
                   │ query
                   ▼
          ┌─────────────────┐
          │ CausalReasoner  │  로컬 Gemma 4 (MLX-LM)
          │ (LLM participle)│  CausalHypothesis 생성
          └────────┬────────┘
                   ▼ (KnowledgePort 경유)
                   │
   ┌═══════════════┴═══════════════════════┐
   │          경로간 경계 (간접연결)        │
   └═══════════════┬═══════════════════════┘
                   ▼
          ┌─────────────────┐
          │ StrategyEngine  │  Path 1 노드가 KnowledgePort.query_hypothesis()
          │ (Path 1)        │  를 optional로 호출. 결과 없어도 동작.
          └─────────────────┘
```

## 3. 온톨로지 스키마 초안

```yaml
# ontology/schema_v1.yaml (Phase 2 작성 예정)

entities:
  Company:
    id: str  # KRX 종목코드 (005930 등)
    properties: [name, krx_code, sector_id, listed_date]
  Sector:
    id: str  # KRX 업종코드
    properties: [name, parent_sector]
  Supplier:
    id: str  # 사업자등록번호
    properties: [name, country]
  Event:
    id: uuid
    properties: [ts, event_type, severity, source]
  Indicator:
    id: str  # "KOSPI", "USD_KRW", "WTI" 등
    properties: [name, unit, frequency]

predicates:
  belongs_to:        # Company → Sector
  supplies_to:       # Supplier → Company
  affected_by:       # Company → Event
  correlates_with:   # Indicator → Indicator
  triggers_risk_in:  # Event → Sector
  owns_subsidiary:   # Company → Company
```

**Triple 예시**:

```
(005930)       ─[belongs_to]──────────►  (KRX_반도체)
(005930)       ─[supplies_to]──────────► (APPL_US)
                                          properties: {confidence: 0.82,
                                                       source: DART_공시_20260315,
                                                       extracted_at: 2026-03-16T09:00}

(Event_Taiwan_Earthquake_20260401) ─[triggers_risk_in]──► (KRX_반도체)
                                    properties: {confidence: 0.71,
                                                 llm_model: gemma-4-mlx,
                                                 hypothesis_id: H-20260401-03}
```

## 4. 업데이트 주기 / 버전

| 레이어 | 주기 | 버전 방식 | 저장 |
|--------|------|---------|------|
| 스키마 (entities/predicates) | 분기 | `ontology/schema_vX.Y.yaml` Semver | Git |
| 인스턴스 (종목/섹터) | 일 1회 (장마감 후) | 스냅샷 + diff | KnowledgeStore |
| 이벤트 Triple | 실시간 (수집 즉시) | append-only, WAL | KnowledgeStore |
| CausalHypothesis | LLM 호출 시 | `hypothesis_id` + generated_at | KnowledgeStore |

## 5. LLM Role Separation

```
┌────────────────────────────────────────────────┐
│ 전략엔진 (뇌 · Path 1 · 결정적)                 │
│    ▲                                            │
│    │ KnowledgePort.query_hypothesis()           │
│    │ timeout 500ms · 결과 없어도 동작            │
│    │                                            │
│  CausalReasoner (참모 · Path 2 · 판단 주체 아님)│
│    - 가설만 제공                                │
│    - hallucination 허용                         │
│    - confidence < threshold 자동 무시 (전략 책임)│
│                                                 │
│  KIS 어댑터 (손 · Path 1 어댑터 · 실행만)       │
└────────────────────────────────────────────────┘
```

**원칙**:
- LLM은 **판단 주체가 아니다**. 가설 생성기.
- StrategyEngine은 CausalHypothesis를 **참고자료로만** 읽음. 매매 결정권은 항상 StrategyEngine.
- LLM 호출 실패(timeout, 빈 결과)는 StrategyEngine의 동작에 **영향 없음**.

## 6. KnowledgePort 시그니처 (Phase 1에서 인터페이스만 고정)

```python
# atlas/core/ports/knowledge.py (Phase 1에서 빈 ABC만 생성)

from abc import ABC, abstractmethod
from dataclasses import dataclass
from datetime import datetime
from typing import Literal

@dataclass(frozen=True)
class CausalHypothesis:
    """LLM이 생성한 인과 가설. 불변 객체."""
    hypothesis_id: str
    cause_entity: str          # "Event_Taiwan_Earthquake_20260401"
    effect_entity: str         # "005930"
    direction: Literal["positive", "negative", "unknown"]
    confidence: float          # 0.0 ~ 1.0
    evidence_triple_ids: list[str]
    generated_at: datetime
    llm_model: str             # "gemma-4-mlx"

class KnowledgePort(ABC):
    """
    Phase 2+ 활성. Phase 1은 인터페이스만 존재.
    StrategyEngine이 optional 주입받아 비차단 참조용으로 호출.
    """

    @abstractmethod
    async def query_hypothesis(
        self,
        symbol: str,
        timeout_ms: int = 500,
        min_confidence: float = 0.7,
    ) -> list[CausalHypothesis]:
        """
        종목에 대한 현재 활성 인과 가설 반환.
        timeout 초과 시 빈 리스트 반환 (예외 아님).
        min_confidence 미만은 필터링 후 반환.
        """
        ...
```

**Phase 1 StrategyEngine의 대응 코드** (인터페이스만 있고 어댑터 없음):

```python
# atlas/core/nodes/strategy_engine.py

class StrategyEngine:
    def __init__(
        self,
        strategy_loader: StrategyRuntimePort,
        storage: StoragePort,
        knowledge: KnowledgePort | None = None,   # Phase 1 = None
    ):
        self._knowledge = knowledge

    async def evaluate(self, bundle, snapshot):
        # Phase 1 기본 전략 실행
        signal = self._strategy.evaluate(bundle, snapshot)
        
        # Phase 2+ 활성화 시에만 호출
        if self._knowledge is not None and signal is not None:
            hypotheses = await self._knowledge.query_hypothesis(
                symbol=signal.symbol,
                timeout_ms=500,
            )
            # 가설을 signal.metadata에 주석으로만 기록. 결정 변경 X.
            signal = signal.with_metadata(hypotheses=hypotheses)
        
        return signal
```

## 7. TrustGraph 미채택 재확인

| 항목 | TrustGraph | ATLAS 방식 |
|------|-----------|-----------|
| 아키텍처 | GraphRAG + Apache Pulsar + LLM 자동 추출 | Ontology + 로컬 Gemma 4 + KnowledgeStore |
| 레이턴시 | 수초 (매매 부적합) | 500ms timeout (매매 비차단) |
| 결정론 | 비결정 (LLM 매 호출 다름) | 비결정 허용, 단 참모 역할로 격리 |
| Hallucination 리스크 | 금융 수치에 직접 영향 우려 | StrategyEngine이 confidence threshold로 필터 |
| 용도 | 실시간 매매 부적합 | 백그라운드 지식 구축 + 비차단 참조 |

**결론**: TrustGraph는 Phase 2+에서도 채택하지 않음. 자체 OntologyMapper + KnowledgeStore 구조 유지.

## 8. 실패 모드 (Phase 2+ 기준)

| ID | 실패 | 탐지 | 방어 |
|----|------|------|------|
| F9 | DART/뉴스 API 단절 | IngestPort healthcheck | stale 플래그, 마지막 성공 ts 노출 |
| F10 | 온톨로지 불일치 (미정규화 엔티티) | 스키마 validator | unknown 버킷으로 격리, 수동 검토 큐 |
| F11 | LLM 응답 지연 | 500ms timeout | 빈 결과 반환, StrategyEngine 폴백 |
| F12 | Triple 중복 삽입 | `(source+triple_hash)` 유니크 제약 | append-only 멱등 |
| F13 | LLM hallucination | confidence 스코어 | StrategyEngine threshold 필터 |

## 9. 경로간 직접엣지 금지 검증

Path 1 (수치) ↔ Path 2 (지식) 간 통신:

| 방향 | 허용 여부 | 메커니즘 |
|------|---------|---------|
| Path 2 → Path 1 (KnowledgeStore write) | ❌ 직접 금지 | Path 2 내부에서만 write |
| Path 1 → KnowledgeStore (read) | ✅ 허용 | StrategyEngine이 KnowledgePort.query_hypothesis() 호출 (non-blocking) |
| Path 1 → Path 2 (직접 호출) | ❌ 절대 금지 | — |
| Path 2 → Path 1 노드 호출 | ❌ 절대 금지 | — |

**확정**: KnowledgePort는 **읽기 전용** 경로. Path 1이 Path 2의 내부 상태에 쓰기 접근은 없음.

## 10. 미결 이슈 (ADR 작성 필요)

| ADR 후보 | 이슈 | Phase 1 영향 |
|----------|------|-------------|
| ADR-014 | KnowledgeStore 기술 선정 (Neo4j vs PG JSONB vs RDF) | 없음 (Port만 있으면 됨) |
| ADR-015 | 온톨로지 스키마 v1.0 확정 | 없음 |
| ADR-016 | Ingest Adapter 우선순위 (DART 우선 vs 뉴스 우선) | 없음 |

**Phase 1은 위 ADR 없이 진행 가능**. Port 자리만 예약.

---

*End of Document — Knowledge Pipeline Reserved Spec*
