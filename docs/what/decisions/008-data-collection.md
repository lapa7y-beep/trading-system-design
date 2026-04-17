# ADR-008: 데이터 수집 원칙 및 파이프라인 구조

> **목적**: KIS REST API + APScheduler 기반 시세 수집 원칙과 정형/비정형 파이프라인 구조를 확정한다.
> **층**: What

> 상태: stable  
> 날짜: 2026-04-16

---

## 결정

### 정형 데이터 저장 원칙
**한정 기간만 제공되는 수치 데이터만 저장한다.**  
언제든 API/웹으로 접근 가능한 데이터는 저장하지 않고 필요 시 실시간 조회한다.

### 비정형 데이터 구조 원칙
**IngestPort ABC를 구현하는 파서 어댑터 플러그인 구조.**  
파서가 늘어나도 파이프라인 코어를 건드리지 않는다.

---

## 정형 데이터 — 저장 항목 (Phase별)

### Phase 1 — 확정
| 항목 | 출처 | 주기 | 저장소 |
|------|------|------|--------|
| OHLCV 일봉 | KIS 일자별 시세 API | 장 마감 후 배치 | TimescaleDB |
| OHLCV 분봉 (1·5·30분) | KIS 시분별 시세 API | 장중 주기 폴링 | TimescaleDB |
| 업종·지수 (KOSPI 등) | KIS 지수 API | 장 마감 후 배치 | TimescaleDB |
| 기관·외인 수급 | KIS 투자자별 API | 장 마감 후 배치 | TimescaleDB |
| 프로그램 매매 | KIS 프로그램매매 API | 장 마감 후 배치 | TimescaleDB |
| FSM 상태 전이 이력 | 시스템 생성 | 이벤트 발생 즉시 | PostgreSQL |
| 주문·체결 이력 | KIS/Kiwoom 응답 | 체결 즉시 | PostgreSQL |
| 감사 로그 | 시스템 생성 | 이벤트 발생 즉시 | PostgreSQL |

### Phase 3 — 확정
| 항목 | 저장소 |
|------|--------|
| 시나리오 정의 | PostgreSQL |
| 종목군 정의 | PostgreSQL |

### 저장 안 함 (실시간 조회)
- 재무제표 → DART API 실시간 조회
- 종목 기본정보 → KIS API 실시간 조회
- 공시 목록·원문 → DART API 실시간 조회

---

## 비정형 데이터 — IngestPort 플러그인 구조

### IngestPort ABC (구현 필수 메서드 3개)
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

새 파서 = IngestPort 상속 후 3개 메서드만 구현 → 코어 파이프라인 자동 연결.

### 파이프라인 코어 (불변)
```
IngestPort.fetch() → parse() → 청킹 → 임베딩 → pgvector 저장
                                      → 원문 저장 + 메타데이터 태깅
                                      → 중복 감지 (URL·해시 기반)
```

### 현재 미정 항목
- 크롤링 대상 사이트 목록
- 직접 입력 UI 설계
- 임베딩 모델 선택 (로컬 LLM vs API)
- 수집 주기

→ Phase 5에서 파서 하나씩 추가. 코어 변경 없음.

---

## 정형 파이프라인 컴포넌트

```
APScheduler → KIS 수집기 → 파서(정규화·검증) → upsert → TimescaleDB
```

- 스케줄러: APScheduler (cron 기반)
- 수집기: KIS REST API 어댑터 (rate limit, 재시도 포함)
- 파서: 응답 정규화, 타입 검증, 이상값 필터
- DB 저장: upsert (중복 방지), hypertable 자동 파티셔닝
