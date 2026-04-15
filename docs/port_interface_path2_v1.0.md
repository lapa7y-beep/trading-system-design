# Port Interface Design — Path 2: Knowledge Building

## 문서 정보

| 항목 | 값 |
|------|-----|
| 문서 ID | port_interface_path2_v1.0 |
| Path | Path 2: Knowledge Building |
| 선행 문서 | boundary_definition_v1.0, port_interface_path1_v1.0 |
| 작성일 | 2026-04-15 |
| 상태 | Draft |

---

## 1. Path 2 개요

### 1.1 책임 범위

Knowledge Building Path는 외부 정보를 수집하여 구조화된 지식으로 변환하고, 트레이딩 의사결정을 위한 인과 추론과 검색 인터페이스를 제공한다.

Path 1(Realtime Trading)이 "손"이라면, Path 2는 "두뇌의 장기 기억"이다. 실시간 매매에 직접 개입하지 않으며, Shared Store를 통해 간접적으로 다른 Path에 지식을 제공한다.

### 1.2 노드 구성 (6개)

| 노드 ID | 역할 | runMode | LLM Level |
|---------|------|---------|-----------|
| ExternalCollector | 외부 데이터 수집 (DART, 뉴스, 공시) | batch | L0 (없음) |
| DocumentParser | 비정형 문서 → 정형 데이터 변환 | batch | L1 (도구) |
| OntologyMapper | 정형 데이터 → 온톨로지 트리플 매핑 | batch | L1 (도구) |
| CausalReasoner | 인과 관계 추론 (LangGraph agent) | agent | L2 (제약 에이전트) |
| KnowledgeIndex | 지식 검색 인덱스 관리 | stateful-service | L0 (없음) |
| KnowledgeScheduler | 파이프라인 오케스트레이션 | event | L0 (없음) |

### 1.3 데이터 흐름 요약

```
ExternalCollector → DocumentParser → OntologyMapper → CausalReasoner
                                                           ↓
                                                    KnowledgeIndex
                                                           ↓
                                                 [KnowledgeStore] (Shared)
```

### 1.4 접촉하는 Shared Store (3개)

| Store | 용도 | 접근 방식 |
|-------|------|----------|
| KnowledgeStore | 온톨로지 트리플, 인과 그래프 저장 | Read/Write |
| MarketDataStore | 수치 데이터 참조 (가격, 재무) | Read Only |
| ConfigStore | 수집 스케줄, 소스 목록, LLM 파라미터 | Read Only |

---

## 2. Port Interface 정의 (5개 Port)

### 2.1 DataSourcePort — 외부 데이터 수집 규격

외부 정보원과의 연결을 추상화한다. DART API든, 뉴스 크롤러든, RSS 피드든 이 포트 규격만 맞추면 교체 가능.

```python
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum


class SourceType(Enum):
    DART_FILING = "dart_filing"       # DART 전자공시
    NEWS_ARTICLE = "news_article"     # 뉴스 기사
    EARNINGS_CALL = "earnings_call"   # 실적 발표
    SUPPLY_CHAIN = "supply_chain"     # 공급망 정보
    MACRO_INDICATOR = "macro_indicator"  # 거시경제 지표
    SEC_FILING = "sec_filing"         # SEC 공시 (해외)


@dataclass(frozen=True)
class RawDocument:
    """수집된 원시 문서"""
    source_id: str              # 소스 고유 ID (e.g., DART-20260415-삼성전자)
    source_type: SourceType
    title: str
    content: str                # 원문 텍스트
    url: str                    # 원본 URL
    published_at: datetime
    collected_at: datetime = field(default_factory=datetime.now)
    metadata: dict = field(default_factory=dict)
    # metadata 예시: {"company": "005930", "filing_type": "분기보고서"}


@dataclass(frozen=True)
class CollectionResult:
    """수집 결과 요약"""
    source_type: SourceType
    total_found: int
    collected: int
    skipped: int                # 중복 등으로 건너뛴 수
    errors: list[str]
    duration_seconds: float


class DataSourcePort(ABC):
    """
    외부 데이터 수집 인터페이스.
    
    DART API든, 네이버 뉴스 크롤러든, Bloomberg API든
    이 규격만 맞추면 교체 가능.
    
    Core는 이 클래스만 import한다.
    """

    @abstractmethod
    async def collect(
        self,
        source_type: SourceType,
        since: datetime,
        symbols: list[str] | None = None
    ) -> list[RawDocument]:
        """
        지정 소스에서 문서 수집.
        since: 이 시점 이후 문서만 수집
        symbols: 특정 종목 필터 (None이면 전체)
        """
        ...

    @abstractmethod
    async def collect_by_query(
        self,
        query: str,
        source_types: list[SourceType] | None = None,
        max_results: int = 50
    ) -> list[RawDocument]:
        """
        키워드 기반 문서 수집.
        여러 소스 타입을 동시에 검색 가능.
        """
        ...

    @abstractmethod
    async def health_check(self) -> dict[SourceType, bool]:
        """
        각 소스별 연결 상태 확인.
        Returns: {SourceType.DART_FILING: True, SourceType.NEWS_ARTICLE: False, ...}
        """
        ...
```

**Adapters:**
- DARTAdapter — DART OpenAPI (dart-fss 라이브러리)
- NaverNewsAdapter — 네이버 뉴스 검색 API
- RSSFeedAdapter — RSS/Atom 피드 수집기
- MockSourceAdapter — 테스트용 (로컬 JSON 파일)

---

### 2.2 DocumentParserPort — 문서 파싱 규격

비정형 텍스트를 정형 데이터로 변환한다. 단순 정규식부터 LLM 기반 추출까지 구현체에 따라 다르지만, 포트 규격은 동일.

```python
@dataclass(frozen=True)
class ParsedEntity:
    """추출된 개체"""
    entity_type: str            # "company" | "person" | "product" | "metric"
    value: str                  # "삼성전자" | "영업이익" | "Galaxy S26"
    confidence: float           # 0.0 ~ 1.0
    context: str                # 원문에서의 주변 문맥 (50자)
    position: tuple[int, int]   # 원문에서의 (start, end) 위치


@dataclass(frozen=True)
class ParsedRelation:
    """추출된 관계"""
    subject: str                # "삼성전자"
    predicate: str              # "supplies_to" | "reports_revenue" | "competes_with"
    object: str                 # "애플"
    confidence: float
    evidence: str               # 근거 문장


@dataclass(frozen=True)
class ParsedDocument:
    """파싱 완료된 문서"""
    source_id: str
    entities: list[ParsedEntity]
    relations: list[ParsedRelation]
    summary: str                # 문서 요약 (max 500자)
    key_metrics: dict           # {"영업이익": "15.8조원", "YoY": "+12.3%"}
    sentiment: float            # -1.0 (극도 부정) ~ +1.0 (극도 긍정)
    parsed_at: datetime = field(default_factory=datetime.now)


class DocumentParserPort(ABC):
    """
    비정형 문서 → 정형 데이터 변환.
    
    정규식 기반 파서든, LLM 기반 추출기든
    이 규격만 맞추면 교체 가능.
    """

    @abstractmethod
    async def parse(self, document: RawDocument) -> ParsedDocument:
        """
        단일 문서 파싱.
        RawDocument → ParsedDocument (개체, 관계, 요약, 감성)
        """
        ...

    @abstractmethod
    async def parse_batch(
        self,
        documents: list[RawDocument],
        concurrency: int = 5
    ) -> list[ParsedDocument]:
        """
        배치 파싱. concurrency로 동시 처리 수 제어.
        LLM 기반 파서의 경우 API rate limit 고려.
        """
        ...

    @abstractmethod
    async def get_supported_types(self) -> list[SourceType]:
        """
        이 파서가 처리 가능한 소스 타입 목록.
        Returns: [SourceType.DART_FILING, SourceType.NEWS_ARTICLE, ...]
        """
        ...
```

**Adapters:**
- RegexParserAdapter — 정규식 + 규칙 기반 (DART 공시 전용)
- LLMParserAdapter — Claude/Gemma 기반 범용 추출 (L1 도구 수준)
- HybridParserAdapter — 정규식 1차 + LLM 2차 (권장)
- MockParserAdapter — 테스트용

---

### 2.3 OntologyPort — 온톨로지 매핑/저장 규격

추출된 개체와 관계를 온톨로지 트리플(Subject-Predicate-Object)로 변환하고 Knowledge Graph에 저장한다.

```python
@dataclass(frozen=True)
class OntologyTriple:
    """온톨로지 트리플 (SPO)"""
    subject: str                # "samsung_electronics"
    predicate: str              # "has_revenue"
    object: str                 # "15.8T_KRW_Q1_2026"
    source_id: str              # 근거 문서 ID
    confidence: float
    valid_from: datetime        # 유효 시작일
    valid_until: datetime | None = None  # 만료일 (None = 현재 유효)
    triple_id: str = ""         # 시스템 생성 ID


class OntologyNodeType(Enum):
    COMPANY = "company"
    PERSON = "person"
    PRODUCT = "product"
    METRIC = "metric"
    EVENT = "event"
    SECTOR = "sector"
    SUPPLY_CHAIN = "supply_chain"


@dataclass(frozen=True)
class OntologyNode:
    """온톨로지 노드"""
    node_id: str
    node_type: OntologyNodeType
    label: str                  # 사람이 읽는 이름
    properties: dict            # {"stock_code": "005930", "sector": "반도체"}
    created_at: datetime = field(default_factory=datetime.now)


@dataclass(frozen=True)
class GraphQuery:
    """그래프 질의"""
    subject: str | None = None
    predicate: str | None = None
    object: str | None = None
    min_confidence: float = 0.5
    valid_at: datetime | None = None  # 특정 시점 기준 유효 트리플만
    limit: int = 100


class OntologyPort(ABC):
    """
    온톨로지 그래프 저장/조회.
    
    PostgreSQL + Apache AGE든, Neo4j든, 인메모리든
    이 규격만 맞추면 교체 가능.
    """

    @abstractmethod
    async def upsert_triples(
        self, triples: list[OntologyTriple]
    ) -> int:
        """
        트리플 삽입/갱신 (upsert).
        동일 SPO가 존재하면 confidence, valid_until 갱신.
        Returns: 실제 변경된 트리플 수
        """
        ...

    @abstractmethod
    async def query(self, q: GraphQuery) -> list[OntologyTriple]:
        """
        SPO 패턴 매칭 질의.
        None 필드는 와일드카드.
        예: query(subject="삼성전자", predicate=None, object=None)
            → 삼성전자의 모든 관계 반환
        """
        ...

    @abstractmethod
    async def get_neighbors(
        self,
        node_id: str,
        depth: int = 1,
        predicate_filter: list[str] | None = None
    ) -> list[OntologyTriple]:
        """
        N-hop 이웃 탐색.
        depth=2면 2단계까지 연결된 트리플 반환.
        predicate_filter로 특정 관계만 필터 가능.
        """
        ...

    @abstractmethod
    async def get_node(self, node_id: str) -> OntologyNode | None:
        """노드 메타데이터 조회."""
        ...

    @abstractmethod
    async def upsert_nodes(self, nodes: list[OntologyNode]) -> int:
        """노드 삽입/갱신. Returns: 변경된 노드 수."""
        ...

    @abstractmethod
    async def invalidate_stale(
        self, before: datetime, source_type: SourceType | None = None
    ) -> int:
        """
        오래된 트리플 무효화 (valid_until 설정).
        삭제하지 않고 만료 처리하여 이력 보존.
        Returns: 무효화된 트리플 수
        """
        ...

    @abstractmethod
    async def stats(self) -> dict:
        """
        그래프 통계.
        Returns: {"total_nodes": 1234, "total_triples": 5678,
                  "by_predicate": {"supplies_to": 100, ...},
                  "stale_ratio": 0.12}
        """
        ...
```

**Adapters:**
- PostgresAGEAdapter — PostgreSQL + Apache AGE 그래프 확장 (권장)
- Neo4jAdapter — Neo4j 전용 (미래)
- InMemoryGraphAdapter — 테스트/프로토타입용
- MockOntologyAdapter — 테스트용

---

### 2.4 LLMPort — LLM 호출 규격

CausalReasoner 노드가 사용하는 LLM 호출 인터페이스. boundary_definition에서 정의한 Constrained Agent 원칙을 강제한다.

```python
class LLMRole(Enum):
    """LLM 역할 제한 — Constrained Agent 원칙"""
    EXTRACTOR = "extractor"           # L1: 정보 추출 도구
    SUMMARIZER = "summarizer"         # L1: 요약 도구
    CAUSAL_REASONER = "causal_reasoner"  # L2: 인과 추론 에이전트
    CLASSIFIER = "classifier"         # L1: 분류 도구


@dataclass(frozen=True)
class LLMRequest:
    """LLM 호출 요청"""
    role: LLMRole
    prompt: str
    context: list[str] = field(default_factory=list)  # 참조 문서/트리플
    max_tokens: int = 2000
    temperature: float = 0.1    # 추론용은 낮게
    response_format: str = "json"  # "json" | "text"


@dataclass(frozen=True)
class LLMResponse:
    """LLM 호출 응답"""
    content: str
    model: str                  # 실제 사용된 모델명
    usage: dict                 # {"input_tokens": 500, "output_tokens": 200}
    latency_ms: int
    cached: bool = False        # 캐시 히트 여부


@dataclass(frozen=True)
class CausalLink:
    """인과 관계"""
    cause: str                  # "반도체 수출 증가"
    effect: str                 # "삼성전자 영업이익 개선"
    mechanism: str              # "메모리 반도체 가격 상승으로 인한 매출 증대"
    strength: float             # 0.0 ~ 1.0 (인과 강도)
    confidence: float           # 0.0 ~ 1.0 (추론 확신도)
    evidence_ids: list[str]     # 근거 문서 ID 목록
    temporal_lag: str | None = None  # "1Q" | "즉시" | "6개월"


class LLMPort(ABC):
    """
    LLM 호출 인터페이스.
    
    Claude API든, 로컬 Gemma든, OpenAI든
    이 규격만 맞추면 교체 가능.
    
    핵심 제약: role 필드로 허용된 작업만 수행.
    CAUSAL_REASONER 역할만 multi-step reasoning 허용.
    나머지는 단일 호출 도구(L1) 수준.
    """

    @abstractmethod
    async def complete(self, request: LLMRequest) -> LLMResponse:
        """
        단일 LLM 호출.
        role에 따라 system prompt가 자동 설정됨.
        """
        ...

    @abstractmethod
    async def reason_causal(
        self,
        entities: list[str],
        context_triples: list[OntologyTriple],
        question: str
    ) -> list[CausalLink]:
        """
        인과 추론 전용 메서드.
        LLMRole.CAUSAL_REASONER만 사용 가능.
        
        entities: 분석 대상 개체 목록
        context_triples: 관련 온톨로지 트리플
        question: 추론 질문
        
        Returns: 추론된 인과 관계 목록
        """
        ...

    @abstractmethod
    async def extract_structured(
        self,
        text: str,
        schema: dict
    ) -> dict:
        """
        구조화된 정보 추출 (L1 도구 수준).
        schema: 추출할 필드 정의 (JSON Schema 형태)
        Returns: schema에 맞는 추출 결과
        """
        ...

    @abstractmethod
    async def get_model_info(self) -> dict:
        """
        현재 사용 중인 모델 정보.
        Returns: {"model": "claude-sonnet-4-...", "provider": "anthropic",
                  "max_context": 200000, "supports_json": True}
        """
        ...
```

**Adapters:**
- ClaudeAdapter — Anthropic Claude API (운영)
- GemmaLocalAdapter — 로컬 Gemma (MLX-LM, 비용 절감)
- OpenAIAdapter — OpenAI GPT (대안)
- MockLLMAdapter — 테스트용 (고정 응답)

---

### 2.5 SearchIndexPort — 지식 검색 인덱스 규격

구축된 지식을 다른 Path에서 검색할 수 있게 하는 인터페이스. Strategy Development Path와 Realtime Trading Path가 이 포트를 통해 지식을 조회한다.

```python
@dataclass(frozen=True)
class SearchQuery:
    """검색 질의"""
    query: str                  # 자연어 질의 또는 키워드
    filters: dict = field(default_factory=dict)
    # filters 예시: {"source_type": "dart_filing", "company": "005930",
    #                "date_range": ["2026-01-01", "2026-04-15"]}
    top_k: int = 10
    include_triples: bool = True   # 관련 온톨로지 트리플 포함 여부
    include_causal: bool = False   # 인과 관계 포함 여부


@dataclass(frozen=True)
class SearchResult:
    """검색 결과 단건"""
    document_id: str
    title: str
    snippet: str                # 관련 부분 발췌 (max 200자)
    relevance_score: float      # 0.0 ~ 1.0
    source_type: SourceType
    published_at: datetime
    related_triples: list[OntologyTriple] = field(default_factory=list)
    related_causal: list[CausalLink] = field(default_factory=list)


@dataclass(frozen=True)
class SearchResponse:
    """검색 응답"""
    results: list[SearchResult]
    total_found: int
    query_time_ms: int


class SearchIndexPort(ABC):
    """
    지식 검색 인덱스.
    
    Elasticsearch든, PostgreSQL FTS든, Meilisearch든
    이 규격만 맞추면 교체 가능.
    """

    @abstractmethod
    async def index_document(
        self,
        parsed: ParsedDocument,
        triples: list[OntologyTriple] | None = None,
        causal_links: list[CausalLink] | None = None
    ) -> str:
        """
        파싱된 문서를 검색 인덱스에 등록.
        관련 트리플/인과관계도 함께 인덱싱.
        Returns: 인덱싱된 문서 ID
        """
        ...

    @abstractmethod
    async def search(self, query: SearchQuery) -> SearchResponse:
        """
        지식 검색.
        자연어 질의 + 필터 조합.
        """
        ...

    @abstractmethod
    async def get_company_profile(
        self, symbol: str
    ) -> dict:
        """
        종목별 지식 프로필 조회.
        Returns: {"company": "삼성전자", "sector": "반도체",
                  "recent_events": [...], "supply_chain": [...],
                  "causal_factors": [...], "sentiment_trend": [...]}
        """
        ...

    @abstractmethod
    async def reindex_all(self) -> dict:
        """
        전체 재인덱싱 (온톨로지 스키마 변경 시).
        Returns: {"total_indexed": 5000, "duration_seconds": 120}
        """
        ...

    @abstractmethod
    async def stats(self) -> dict:
        """
        인덱스 통계.
        Returns: {"total_documents": 5000, "total_triples": 12000,
                  "index_size_mb": 250, "last_updated": "..."}
        """
        ...
```

**Adapters:**
- PostgresFTSAdapter — PostgreSQL Full Text Search + pgvector (권장, 스택 통일)
- ElasticsearchAdapter — Elasticsearch (대규모)
- MeilisearchAdapter — Meilisearch (경량)
- MockSearchAdapter — 테스트용

---

## 3. Domain Types 정의 (Path 2 전용)

### 3.1 Enum 정의

```python
class SourceType(Enum):
    DART_FILING = "dart_filing"
    NEWS_ARTICLE = "news_article"
    EARNINGS_CALL = "earnings_call"
    SUPPLY_CHAIN = "supply_chain"
    MACRO_INDICATOR = "macro_indicator"
    SEC_FILING = "sec_filing"

class OntologyNodeType(Enum):
    COMPANY = "company"
    PERSON = "person"
    PRODUCT = "product"
    METRIC = "metric"
    EVENT = "event"
    SECTOR = "sector"
    SUPPLY_CHAIN = "supply_chain"

class LLMRole(Enum):
    EXTRACTOR = "extractor"
    SUMMARIZER = "summarizer"
    CAUSAL_REASONER = "causal_reasoner"
    CLASSIFIER = "classifier"
```

### 3.2 Core Data Types (8종)

| Type | 용도 | 주요 필드 |
|------|------|----------|
| RawDocument | 수집된 원시 문서 | source_id, source_type, content, url, published_at |
| ParsedEntity | 추출된 개체 | entity_type, value, confidence, context |
| ParsedRelation | 추출된 관계 | subject, predicate, object, confidence, evidence |
| ParsedDocument | 파싱 완료 문서 | entities, relations, summary, key_metrics, sentiment |
| OntologyTriple | 온톨로지 SPO | subject, predicate, object, confidence, valid_from |
| OntologyNode | 온톨로지 노드 | node_id, node_type, label, properties |
| CausalLink | 인과 관계 | cause, effect, mechanism, strength, temporal_lag |
| SearchResult | 검색 결과 | document_id, snippet, relevance_score, related_triples |

---

## 4. 데이터 흐름 (Edge 정의, 9개)

### 4.1 내부 Edge (Path 2 내부)

| # | Source → Target | Edge Type | 데이터 | 설명 |
|---|----------------|-----------|--------|------|
| 1 | ExternalCollector → DocumentParser | DataFlow | list[RawDocument] | 수집 문서 전달 |
| 2 | DocumentParser → OntologyMapper | DataFlow | list[ParsedDocument] | 파싱 결과 전달 |
| 3 | OntologyMapper → CausalReasoner | DataFlow | list[OntologyTriple] | 신규 트리플 전달 |
| 4 | CausalReasoner → KnowledgeIndex | DataFlow | list[CausalLink] | 인과 관계 인덱싱 |
| 5 | OntologyMapper → KnowledgeIndex | DataFlow | list[ParsedDocument] | 문서 인덱싱 |
| 6 | KnowledgeScheduler → ExternalCollector | Command | CollectionConfig | 수집 시작 명령 |

### 4.2 Shared Store Edge (외부 연결)

| # | Source → Target | Edge Type | 데이터 | 설명 |
|---|----------------|-----------|--------|------|
| 7 | OntologyMapper → KnowledgeStore | DataPipe | OntologyTriple | 트리플 영속화 |
| 8 | CausalReasoner → KnowledgeStore | DataPipe | CausalLink | 인과 관계 영속화 |
| 9 | ExternalCollector ← MarketDataStore | ConfigRef | 종목 코드 목록 | 수집 대상 종목 참조 |

---

## 5. Shared Store 스키마 (Path 2 기여분)

### 5.1 KnowledgeStore

```sql
-- 온톨로지 트리플 테이블
CREATE TABLE ontology_triples (
    triple_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    subject         TEXT NOT NULL,
    predicate       TEXT NOT NULL,
    object          TEXT NOT NULL,
    source_id       TEXT NOT NULL,       -- 근거 문서 ID
    confidence      FLOAT NOT NULL,
    valid_from      TIMESTAMPTZ NOT NULL,
    valid_until     TIMESTAMPTZ,         -- NULL = 현재 유효
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(subject, predicate, object, source_id)
);

-- 인과 관계 테이블
CREATE TABLE causal_links (
    link_id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    cause           TEXT NOT NULL,
    effect          TEXT NOT NULL,
    mechanism       TEXT,
    strength        FLOAT NOT NULL,      -- 0.0 ~ 1.0
    confidence      FLOAT NOT NULL,
    evidence_ids    TEXT[] NOT NULL,      -- 근거 문서 ID 배열
    temporal_lag    TEXT,                 -- "1Q", "즉시", "6개월"
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    expires_at      TIMESTAMPTZ          -- 인과 관계 유효 기간
);

-- 파싱된 문서 저장
CREATE TABLE parsed_documents (
    source_id       TEXT PRIMARY KEY,
    source_type     TEXT NOT NULL,
    title           TEXT,
    summary         TEXT,
    key_metrics     JSONB,
    sentiment       FLOAT,
    entities        JSONB,               -- 추출된 개체 목록
    relations       JSONB,               -- 추출된 관계 목록
    parsed_at       TIMESTAMPTZ DEFAULT NOW()
);

-- 인덱스
CREATE INDEX idx_triples_subject ON ontology_triples(subject);
CREATE INDEX idx_triples_predicate ON ontology_triples(predicate);
CREATE INDEX idx_triples_valid ON ontology_triples(valid_from, valid_until);
CREATE INDEX idx_causal_cause ON causal_links(cause);
CREATE INDEX idx_causal_effect ON causal_links(effect);
CREATE INDEX idx_parsed_source_type ON parsed_documents(source_type);
```

---

## 6. Safeguard 적용

### 6.1 Path 2 Safeguard Chain

```
ExternalCollector
    → [RateLimitGuard]      외부 API 호출 속도 제한
    → [DeduplicationGuard]  중복 문서 수집 방지
    → DocumentParser
    → [SchemaValidator]     파싱 결과 스키마 검증
    → OntologyMapper
    → [ConsistencyGuard]    트리플 일관성 검증 (순환 참조, 모순 감지)
    → CausalReasoner
    → [ConfidenceGate]      confidence < threshold 인과 관계 폐기
    → KnowledgeIndex
```

### 6.2 LLM 안전장치 (Constrained Agent)

| 제약 | 적용 대상 | 규칙 |
|------|----------|------|
| Role 제한 | 모든 LLM 호출 | role 필드 필수, 미지정 시 거부 |
| Token 상한 | CausalReasoner | max_tokens ≤ 4000 (단일 추론) |
| Fallback | LLM 장애 시 | 최근 캐시 응답 반환, 캐시 없으면 건너뜀 |
| Audit | 모든 LLM 호출 | request/response 전문 로깅 (Watchdog Path) |
| Rate Limit | 외부 LLM API | 분당 호출 수 제한 (ConfigStore에서 읽음) |

---

## 7. Adapter Mapping 요약

| Port | 운영 Adapter | 개발 Adapter | 테스트 Adapter |
|------|-------------|-------------|---------------|
| DataSourcePort | DARTAdapter + NaverNewsAdapter | DARTAdapter (sandbox) | MockSourceAdapter |
| DocumentParserPort | HybridParserAdapter | LLMParserAdapter | MockParserAdapter |
| OntologyPort | PostgresAGEAdapter | InMemoryGraphAdapter | MockOntologyAdapter |
| LLMPort | ClaudeAdapter | GemmaLocalAdapter | MockLLMAdapter |
| SearchIndexPort | PostgresFTSAdapter | PostgresFTSAdapter | MockSearchAdapter |

**YAML 설정 예시:**

```yaml
# settings.yaml — Path 2 어댑터 바인딩
path2_knowledge:
  data_source:
    implementation: DARTAdapter
    params:
      api_key: ${DART_API_KEY}
      rate_limit_per_minute: 100

  document_parser:
    implementation: HybridParserAdapter
    params:
      regex_first: true
      llm_fallback: true

  ontology:
    implementation: PostgresAGEAdapter
    params:
      dsn: ${POSTGRES_DSN}
      graph_name: "trading_knowledge"

  llm:
    implementation: ClaudeAdapter
    params:
      model: "claude-sonnet-4-20250514"
      max_concurrent: 5
      cache_ttl_hours: 24

  search_index:
    implementation: PostgresFTSAdapter
    params:
      dsn: ${POSTGRES_DSN}
      embedding_model: "multilingual-e5-large"
```

---

## 8. 다음 단계

- Port Interface Path 3 (Strategy Development) 설계
- Edge Contract Definition (전체 Path 간 엣지 스키마)
- CausalReasoner LangGraph StateGraph 상세 설계
