# ADR-006: PostgreSQL + TimescaleDB 스택 선정

> **목적**: 데이터 저장소로 PostgreSQL + TimescaleDB를 선정한 근거와 Redis 분리 계획을 기록한다.
> **층**: What

> 상태: stable  
> 날짜: 2026-04-16  
> 결정자: jdw

---

## 결정

**Docker Compose 서비스 2개만 운용한다.**

```
postgres   — PostgreSQL 16 + 확장 3개 (TimescaleDB, pgvector, AGE)
redis      — Redis 7 (실시간 버퍼 + FSM 상태 캐시)
```

---

## 확정 스택 상세

### postgres — PostgreSQL 16 단일 인스턴스

| 확장 | 담당 데이터 | 핵심 요구사항 | 비고 |
|------|-------------|---------------|------|
| **TimescaleDB** | 시계열 시세 (OHLCV, 재무) | 시간 범위 쿼리, 자동 파티셔닝, 압축, 보존 정책 | 백테스팅 시 직접 쿼리 — 변환 불필요 |
| **pgvector** | 비정형 임베딩 (뉴스·공시 텍스트) | 벡터 유사도 검색, RAG 지원 | 별도 서비스 없이 SQL로 접근 |
| **AGE** | 그래프·온톨로지 (공급망·인과관계) | 관계 탐색, 경로 탐색 쿼리 | Cypher 쿼리 지원 |
| **(기본 PG)** | FSM 상태, 주문·체결 이력, 감사 로그 | ACID 트랜잭션, 영속화 필수 | FSM 전이 + 주문 단일 트랜잭션 가능 |

### redis — Redis 7 (별도 서비스)

| 용도 | 핵심 요구사항 |
|------|---------------|
| 실시간 이벤트 버퍼 | ms 응답, pub/sub + 영속 (Streams) |
| FSM 상태 캐시 | 빠른 상태 조회, PostgreSQL 영속화와 이중 운용 |
| 체결통보 임시 버퍼 | WebSocket 수신 → 처리 전 임시 보관 |

---

## 이 선택의 핵심 이유

1. **운영 단순성** — 서비스 2개. 모니터링·백업·장애 대응 대상이 최소
2. **SQL 통합** — 시계열·벡터·그래프·트랜잭션을 단일 SQL로 조인 가능
3. **백테스팅 연계** — TimescaleDB 히스토리 데이터를 ClockPort mock이 직접 쿼리
4. **FSM 안전성** — FSM 상태 전이 + 주문 이력을 단일 PG 트랜잭션으로 원자적 처리

---

## 변경 가능성 (점진적 분리 경로)

규모가 커지면 아래 순서로 분리한다. **현 단계에서는 변경하지 않는다.**

| 조건 | 변경 내용 |
|------|-----------|
| 비정형 데이터 수백만 건 초과, 벡터 검색 latency 문제 | pgvector → **ChromaDB** 또는 **Qdrant** 분리 |
| 그래프 노드 수만 건 초과, 복잡한 경로 탐색 빈번 | AGE → **Neo4j** Docker 컨테이너 추가 |
| 이벤트 처리량 급증, Redis 메모리 한계 | Redis Streams → **Kafka** 전환 |

---

## 기각된 대안

| 대안 | 기각 이유 |
|------|-----------|
| InfluxDB | 별도 서비스 추가, SQL 조인 불가, PG 생태계 이탈 |
| ChromaDB (초기부터) | 별도 서비스, pgvector로 충분한 초기 규모 |
| Neo4j (초기부터) | 별도 서비스, AGE로 충분한 초기 규모 |
| Kafka | 1인 프로젝트에 과도, Redis Streams로 충분 |
| SQLite | 동시 접근·확장성 한계, 프로덕션 부적합 |

---

## Docker Compose 구성 (기준)

```yaml
services:
  postgres:
    image: timescale/timescaledb-ha:pg16  # TimescaleDB + pgvector 포함
    # AGE는 별도 설치 스크립트
    environment:
      POSTGRES_DB: trading
      POSTGRES_USER: trading
      POSTGRES_PASSWORD: ${PG_PASSWORD}
    volumes:
      - postgres_data:/var/lib/postgresql/data
      - ./sql/init.sql:/docker-entrypoint-initdb.d/init.sql

  redis:
    image: redis:7-alpine
    command: redis-server --appendonly yes  # AOF 영속화
    volumes:
      - redis_data:/data

volumes:
  postgres_data:
  redis_data:
```

---

## 참조

- TimescaleDB 선택 근거: 백테스팅 ClockPort mock이 직접 쿼리 (변환 없음)
- pgvector 선택 근거: Phase 5 Knowledge 파이프라인까지 충분, 분리 기준 명확
- AGE 선택 근거: PostgreSQL 확장, 초기 온톨로지 규모에 적합, Neo4j 전환 기준 명확
- Redis 선택 근거: FSM 상태 캐시 + 이벤트 버퍼 이중 역할, Kafka 불필요
