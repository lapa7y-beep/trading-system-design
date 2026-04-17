# Seam 분류 심화 — ATLAS Port별 교체 난이도 분석

**기반 문헌**: Feathers, *Working Effectively with Legacy Code* (2004), Ch.4.
**SSoT**: `docs/specs/port-signatures-phase1.md`, `docs/specs/adapter-spec-phase1.md`

---

## 1. Seam 유형 — ATLAS는 전부 Object Seam

Python Protocol + 런타임 DI + YAML 설정. 타입 안전성은 mypy + pydantic으로 보강.

## 2. Object Seam의 4 하위 유형

| 하위 유형 | 특성 | 해당 Port |
|---------|------|---------|
| **Replaceable** | 환경별 Adapter 교체 일상적 | MarketDataPort, BrokerPort |
| **Stateful** | 내부 상태(연결, 세션) 보유 | StoragePort, MarketDataPort(WS) |
| **Observational** | 주 흐름 무영향, 실패 허용 | AuditPort |
| **Deterministic** | 비결정성(시간) 격리 | ClockPort |

## 3. 6 Port 분류

### 3.1 MarketDataPort — Replaceable + Stateful

- Adapter 3개: KISWebSocketAdapter / KISRestAdapter / CSVReplayAdapter
- 교체 난이도: **중**
- 핵심 리스크: WebSocket 재연결 중 bar 누락
- Stub 경로: FakeMarketData(Step 0) → CSVReplayAdapter(Step 3) → KIS(Step 11b)

### 3.2 BrokerPort — Replaceable + Stateful

- Adapter 2개: MockBrokerAdapter / KISPaperBrokerAdapter
- 교체 난이도: **높음** (Phase 1 최고 위험)
- 핵심 리스크: intent_id 기반 중복주문방지, 부분체결, 취소 지연
- Stub 경로: FakeBroker(Step 0) → MockBrokerAdapter(Step 7) → KISPaper(Step 11b)

### 3.3 StoragePort — Stateful

- Adapter 2개: InMemoryStorageAdapter / PostgresStorageAdapter
- 교체 난이도: **중**
- 핵심 리스크: InMemory → Postgres 교체 시 크래시 복구 동작 첫 노출
- Stub 경로: InMemoryStorageAdapter(Step 0) → PostgresStorageAdapter(Step 9)

### 3.4 ClockPort — Deterministic

- Adapter 2개: WallClockAdapter / HistoricalClockAdapter
- 교체 난이도: **낮음**
- 핵심: datetime.now() 직접 호출 금지, 모든 시간 로직 ClockPort 경유
- Stub 경로: WallClockAdapter(Step 0부터 실제), HistoricalClockAdapter(테스트용)

### 3.5 StrategyRuntimePort — Replaceable (약)

- Adapter 1개: FileSystemStrategyLoader
- 교체 난이도: **낮음** (Phase 1 단일 Adapter)
- Phase 2 대비: 다중 전략 병렬 실행 시 시그니처 확장 가능성

### 3.6 AuditPort — Observational

- Adapter 2개: StdoutAuditAdapter / PostgresAuditAdapter
- 교체 난이도: **최저**
- 핵심: 실패해도 주 흐름 무영향. 비동기 처리 가능.
- Stub 경로: StdoutAuditAdapter(Step 0부터 실제) → PostgresAuditAdapter(Step 9)

## 4. 교체 난이도 종합 매트릭스

| Port | 유형 | 난이도 | Adapter 수 | Port 변경 위험 |
|------|------|-------|----------|-------------|
| MarketDataPort | Replaceable+Stateful | 중 | 3 | 중 |
| BrokerPort | Replaceable+Stateful | **높음** | 2 | **높음** |
| StoragePort | Stateful | 중 | 2 | 중 |
| ClockPort | Deterministic | 낮음 | 2 | 낮음 |
| StrategyRuntimePort | Replaceable(약) | 낮음 | 1 | 중(Phase 2) |
| AuditPort | Observational | 최저 | 2 | 최저 |

**집중 대상**: BrokerPort. intent_id, 부분체결, 취소 응답 지연 등 엣지 케이스를 시그니처 수준에서 수용해야 함.

## 5. Step 2 착수 전 체크리스트

- [ ] 6 Port 메서드 시그니처가 `port-signatures-phase1.md`에 확정
- [ ] BrokerPort의 Order에 intent_id 포함
- [ ] StoragePort 메서드가 트랜잭션 경계 미가정
- [ ] ClockPort 외 datetime.now() 직접 호출 금지 명시
- [ ] AuditPort.log_event() 실패 시 비전파 명시
- [ ] StrategyRuntimePort.evaluate() 순수 함수 명시
- [ ] 각 Port에 대응 FakeAdapter 이름 확정

## 6. 관련 문서

- `docs/decisions/012-implementation-methodology.md` — 방법론 (상위)
- `docs/references/seam-map.md` — Seam 위치 지도
- `docs/specs/port-signatures-phase1.md` — Port 시그니처 SSoT
- `docs/specs/adapter-spec-phase1.md` — Adapter 명세 SSoT
