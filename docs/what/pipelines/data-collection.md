# 시세 데이터 수집 파이프라인 (정형·비정형·CSV)

> **목적**: KIS REST API 기반 정형 데이터 수집과 비정형 데이터 IngestPort 플러그인 구조를 정의한다.
> **층**: What
> **상태**: stable
> **최종 수정**: 2026-04-16
> **구현 여정**: Step 03(CSVReplayAdapter)에서 CSV 형식 활용. ADR-012 §6 참조.
> **관련 ADR**: 008
> **연계 문서**: 이 파이프라인의 배경 ADR: `docs/what/decisions/008-data-collection.md`

## 1. 정형 데이터 수집 파이프라인

### 구성

```
APScheduler (cron 기반)
    │
    ↓
KIS 수집기 (REST API 어댑터)
    │  rate limit 준수, 재시도 포함
    ↓
파서 (응답 정규화·타입 검증·이상값 필터)
    │
    ↓
upsert → TimescaleDB
         (중복 방지, hypertable 자동 파티셔닝)
```

### Phase 1 수집 항목

| 항목 | KIS API | 주기 | 비고 |
|------|---------|------|------|
| OHLCV 일봉 | 일자별 시세 조회 | 장 마감 후 | 전 관심종목 |
| OHLCV 분봉 1분 | 시분별 시세 조회 | 장중 주기 | 관심종목 |
| OHLCV 분봉 5분 | 시분별 시세 조회 | 장중 주기 | 관심종목 |
| OHLCV 분봉 30분 | 시분별 시세 조회 | 장중 주기 | 관심종목 |
| KOSPI·업종 지수 | 지수 조회 | 장 마감 후 | |
| 기관·외인 수급 | 투자자매매동향 | 장 마감 후 | |
| 프로그램 매매 | 프로그램매매 조회 | 장 마감 후 | |

### 시스템 생성 데이터 (직접 저장)

| 항목 | 저장 시점 | 저장소 |
|------|----------|--------|
| FSM 상태 전이 이력 | 전이 즉시 | PostgreSQL |
| 주문 이력 | 주문 제출 시 | PostgreSQL |
| 체결 이력 | 체결 시 | PostgreSQL |
| 감사 로그 | 이벤트 즉시 | PostgreSQL (불변) |

---

## 2. 비정형 데이터 수집 파이프라인

### IngestPort 플러그인 구조

새 소스 추가 = IngestPort 상속 후 3개 메서드 구현 → 코어 자동 연결.

```python
class IngestPort(ABC):
    @abstractmethod
    def fetch(self) -> list[RawDocument]:
        """원문 수집"""

    @abstractmethod
    def parse(self, raw: RawDocument) -> ParsedDocument:
        """정제·구조화"""

    @abstractmethod
    def get_metadata(self, doc: ParsedDocument) -> DocumentMetadata:
        """소스·날짜·태그 반환"""
```

### 파이프라인 코어 (불변)

```
fetch() → parse() → 청킹 → 임베딩 모델 → pgvector 저장
                           → 원문 저장 (FileStorage)
                           → 중복 감지 (URL·해시 기반)
```

### 현재 미정 항목

- 크롤링 대상 사이트 목록 (뉴스, 공시 외)
- 직접 입력 UI 설계 (개인 메모, 리서치 자료)
- 임베딩 모델 선택

---

## 3. 정형·비정형 교차 검증 (Phase 5 이후)

**현재 구현 불가.** 두 데이터가 모두 존재해야 의미 있음.

구현 조건:
1. 정형 데이터 수집기 운영 중
2. 비정형 데이터 파이프라인 운영 중

구현 예정 유형:
- 이벤트 기반: 공시 발표 전후 수치 변화 패턴
- 감성·수치 상관: 뉴스 감성 점수 ↔ RSI·수급 상관계수
- 시나리오 사전 검증: LLM 생성 시나리오 전제조건을 과거 데이터로 검증

→ 상세: `docs/archive/phase3/009-cross-validation.md`
