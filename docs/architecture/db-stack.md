# DB 스택 및 저장소 구조

> 상태: stable  
> 날짜: 2026-04-16  
> 연관 ADR: 006

---

## 1. 확정 스택

Docker Compose 서비스 2개만 운용한다.

```yaml
services:
  postgres:   # PostgreSQL 16 + TimescaleDB + pgvector + AGE
  redis:      # Redis 7
```

### postgres — 4가지 역할

| 확장 | 담당 데이터 | 용도 |
|------|-----------|------|
| TimescaleDB | OHLCV, 수급, 체결이력 | 시계열 쿼리, 자동 파티셔닝, 백테스팅 직접 쿼리 |
| pgvector | 뉴스·공시 텍스트 임베딩 | RAG, 벡터 유사도 검색 |
| AGE | 공급망·인과관계 그래프 | Cypher 쿼리, 온톨로지 탐색 |
| 기본 PG | FSM 상태, 주문·체결, 감사 로그 | ACID 트랜잭션, 영속화 |

### redis — 2가지 역할

| 용도 | 내용 |
|------|------|
| 실시간 이벤트 버퍼 | ms 응답, pub/sub + Streams 영속 |
| FSM 상태 캐시 | 빠른 상태 조회, PostgreSQL과 이중 운용 |

---

## 2. 정형 데이터 저장 원칙

**한정 기간만 제공되는 수치 데이터만 저장한다.**

### 저장하는 것 (Phase 1)

| 항목 | 주기 | 저장소 |
|------|------|--------|
| OHLCV 일봉 | 장 마감 후 배치 | TimescaleDB |
| OHLCV 분봉 (1·5·30분) | 장중 폴링 | TimescaleDB |
| 업종·지수 (KOSPI 등) | 장 마감 후 배치 | TimescaleDB |
| 기관·외인 수급 | 장 마감 후 배치 | TimescaleDB |
| 프로그램 매매 | 장 마감 후 배치 | TimescaleDB |
| FSM 상태 전이 이력 | 이벤트 즉시 | PostgreSQL |
| 주문·체결 이력 | 체결 즉시 | PostgreSQL |
| 감사 로그 | 이벤트 즉시 | PostgreSQL |

### 저장하지 않는 것 (언제든 API 조회 가능)

- 재무제표 → DART API 실시간 조회
- 종목 기본정보 → KIS API 실시간 조회
- 공시 목록·원문 → DART API 실시간 조회

---

## 3. 비정형 데이터 구조

**IngestPort ABC 플러그인 구조** — 파서만 추가하면 코어 파이프라인 자동 연결.

```python
class IngestPort(ABC):
    @abstractmethod
    def fetch(self) -> list[RawDocument]: ...

    @abstractmethod
    def parse(self, raw: RawDocument) -> ParsedDocument: ...

    @abstractmethod
    def get_metadata(self, doc: ParsedDocument) -> DocumentMetadata: ...
```

**파이프라인 코어 (불변):**
```
IngestPort.fetch() → parse() → 청킹 → 임베딩 → pgvector 저장
                                      → 원문 저장 + 메타데이터 태깅
                                      → 중복 감지 (URL·해시 기반)
```

### 현재 미정

- 크롤링 대상 사이트 목록
- 임베딩 모델 선택 (로컬 LLM vs API)
- 수집 주기

---

## 4. 점진적 분리 경로

현재 불필요. 규모 증가 시 아래 순서로 분리한다.

| 조건 | 변경 |
|------|------|
| 비정형 수백만 건 초과, 벡터 검색 latency 문제 | pgvector → ChromaDB |
| 그래프 노드 수만 건 초과 | AGE → Neo4j |
| 이벤트 처리량 급증, Redis 한계 | Redis → Kafka |

---

## 5. Docker Compose 기준

```yaml
services:
  postgres:
    image: timescale/timescaledb-ha:pg16
    environment:
      POSTGRES_DB: trading
      POSTGRES_USER: trading
      POSTGRES_PASSWORD: ${PG_PASSWORD}
    volumes:
      - postgres_data:/var/lib/postgresql/data

  redis:
    image: redis:7-alpine
    command: redis-server --appendonly yes
    volumes:
      - redis_data:/data

volumes:
  postgres_data:
  redis_data:
```
