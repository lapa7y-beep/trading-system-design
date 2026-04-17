# ATLAS 용어 사전

> **목적**: ATLAS 시스템 고유 용어와 약어를 정의한다.
> **층**: What
> **최종 수정**: 2026-04-16

## 시스템 고유 용어

| 용어 | 정의 |
|------|------|
| **HR-DAG** | Hierarchical Recursive DAG. 전체 시스템 설계 방식. 계층적+재귀적 전개 |
| **Isolated Path** | 5개 고립 경로. 경로 간 직접 Edge 없음. Shared Store 경유만 허용 |
| **Shared Store** | 경로 간 데이터 교환 매개. 8개 (MarketData, Portfolio, Config, Knowledge, Strategy, Watchlist, MarketIntel, Audit) |
| **Graph IR** | 노드·엣지·스키마를 YAML로 표현한 중간 표현. Single Source of Truth |
| **PathCanvas** | LiteGraph.js 기반 노드·엣지 시각적 편집 UI. Graph IR과 연동 |
| **Code Generator** | Graph IR YAML → Python 코드 자동 생성. 노드 명세 확정 후 구현 |
| **runMode** | 노드 실행 방식. batch / poll / stream / event / stateful-service / agent |
| **L0 / L1 / L2** | LLM 관여도. L0=없음, L1=보조, L2=핵심 |
| **Plug & Play** | YAML 한 줄로 어댑터 교체. 노드 교체 시 Edge 계약만 유지하면 됨 |
| **IngestPort** | 비정형 데이터 수집 플러그인 인터페이스. fetch/parse/get_metadata 3개 메서드 |
| **OrderPort** | 주문 제출/취소/조회 추상화. submit/cancel/get_order_status. OrderExecutor가 사용. (BrokerPort 분리 결과) |
| **AccountPort** | 계좌 조회·일관성 검증 추상화. get_balance/get_positions/get_position/reconcile. RiskGuard, TradingFSM이 사용. (BrokerPort 분리 결과) |
| **ExchangeEngine** | 가상거래소 핵심 코어. PriceGen + OrderBook + MarketRules 통합. SyntheticMarket/Order/Account 3 Adapter가 공유 |
| **MarketContext** | Path 6이 생성하는 종목별 시장 인텔리전스 종합 객체. entry_safe / exit_urgent 포함 |

---

## FSM 관련

| 용어 | 정의 |
|------|------|
| **종목군 FSM** | 레벨 1. 시나리오 단위 그룹 관리. 5개 상태 |
| **개별 종목 FSM** | 레벨 2. 종목별 포지션 상태 관리. 13개 상태 |
| **포지션 키** | (종목코드 + 증권사). KIS와 Kiwoom 독립 인스턴스 |
| **RECONCILING** | 잔고 불일치 조사 중 상태. 30초 대사에서 감지 시 자동 전이 |
| **PENDING_APPROVAL** | Telegram 승인 대기 상태. 타임아웃 시 자동 취소 → IDLE |
| **시나리오 mutex** | 종목당 활성 시나리오 1개. 동시 진입 차단 |

---

## 아키텍처 패턴

| 용어 | 정의 |
|------|------|
| **Hexagonal Architecture** | Ports & Adapters. 코어 로직이 인프라에 의존하지 않음 |
| **WAL 패턴** | Write-Ahead Log. 주문 전 이벤트 선기록. 장애 복구 용도 |
| **E2E Budget** | 시세 수신~주문 제출 전체 시간 한도. 지정가 500ms / 시장가 200ms |
| **TradingContext** | E2E 체인 전체에 전파되는 컨텍스트. chain_started_at, price_observed_at 포함 |
| **Circuit Breaker** | 연속 실패 시 안전 모드 전환. 신규 주문 차단, 기존 포지션 보호 |
| **ApprovalGate** | SEMI_AUTO 모드의 비동기 승인 대기 노드. StrategyEngine → RiskGuard 사이 |

---

## KIS API 관련

| 용어 | 정의 |
|------|------|
| **tr_id** | KIS API 거래 ID. 모의(VTTC*)와 실전(TTTC*) 구분 |
| **H0STCNI0** | KIS WebSocket 실시간 체결통보 (실전) |
| **H0STCNI9** | KIS WebSocket 실시간 체결통보 (모의) |
| **H0STASP0** | KIS WebSocket 실시간 호가 |
| **H0STMKO0** | KIS WebSocket 장운영정보 (VI/CB) |
| **EGW00123** | KIS API 에러 코드. 토큰 만료 → 재발급 후 재시도 |
| **ORD_DVSN** | 주문 구분 코드. 00=지정가, 01=시장가, 02=조건부 등 24종 |
| **VI** | 변동성완화장치. 발동 중 시장가 주문 차단, 지정가만 허용 |
| **CB** | 서킷브레이커. KOSPI 8%/15%/20% 하락 시 발동 |

---

## 약어

| 약어 | 풀이 |
|------|------|
| ADR | Architecture Decision Record |
| FSM | Finite State Machine |
| OHLCV | Open / High / Low / Close / Volume |
| MDD | Maximum Drawdown (최대 낙폭) |
| CAGR | Compound Annual Growth Rate (연환산 수익률) |
| KIS | Korea Investment & Securities (한국투자증권) |
| DART | Data Analysis, Retrieval and Transfer System (전자공시시스템) |
| RAG | Retrieval-Augmented Generation |
| WAL | Write-Ahead Log |
| DI | Dependency Injection |
