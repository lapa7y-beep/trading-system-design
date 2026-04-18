# ADR-013 — ATLAS 운전사-브로커 경계 확정 + OrderExecutor 분해

> **상태**: Accepted
> **날짜**: 2026-04-17
> **범위**: Phase 1 (Path 1 확장)
> **대체**: 일부 개념이 ADR-010, ADR-011과 겹치나 본 ADR이 최신

---

## 1. 결정 요약

ATLAS는 증권사(Broker)의 클라이언트이고, Broker는 거래소(Exchange)의 클라이언트다.
ATLAS는 실제 주문 처리·체결·잔고 계산을 하지 않으며, 오직 조회·요청·미러링·기록만 한다.
이 관점을 코드와 문서 전반에 관철하기 위해 다음 변경을 확정한다.

1. **3계층 경계 명시**: ATLAS (L1) · Broker (L2) · Exchange (L3)
2. **OrderExecutor 분해**: "요청 + 수신 + 기록" 복합 책임을 분해
3. **ExecutionEventPort 신설**: 체결 통보 수신 전용 Port
4. **ExecutionReceiver 노드 신설**: 체결 이벤트 구독 및 PortfolioStore 갱신
5. **reconcile 개념 재정의**: "대칭 검증"이 아니라 "증권사 기준 캐시 갱신"

---

## 2. 배경

### 2.1 문제 인식

이전 설계는 ATLAS 내부 DB와 증권사 계좌를 동등한 권위를 가진 두 출처처럼 다뤘다.
`AccountPort.reconcile()`이라는 이름이 "두 출처를 일치시킨다"는 대칭 관계를 암시했다.

그러나 본질은:

- 잔고의 진실은 증권사(KIS/Kiwoom) 계좌 시스템
- 주문 체결의 진실은 거래소(KRX) 매칭 결과
- 시세의 진실은 거래소
- ATLAS의 DB는 전부 이들의 **캐시 또는 ATLAS 자체 기록**

운전사-자동차 비유로 표현하면:
- ATLAS = 운전사 (감각·인지·판단·조작·미러링·기록)
- Broker = 자동차 (엔진·계기판·조작장치)
- Exchange = 도로·교통체계 (실제 움직임이 일어나는 곳)

운전사는 엔진 내부 연소를 제어하지 않는다. 페달에 입력을 주고, 계기판을 읽고, 머릿속에 상태를 추적할 뿐이다.

### 2.2 현재 OrderExecutor의 책임 복합

현재 OrderExecutor 한 노드가 세 가지 성격이 다른 일을 동시에 수행한다:

1. **요청 (pull)**: `OrderPort.submit()` 호출 — ATLAS가 증권사에게 요청
2. **수신 (push)**: KIS H0STCNI0 WebSocket 체결 통보 구독
3. **기록**: trades 테이블 INSERT, TradingFSM에 이벤트 emit

이 혼재는:
- 테스트를 어렵게 만든다 (3역할을 동시에 검증해야 함)
- 장애 격리가 불가능하다 (수신 실패가 요청에 영향)
- 책임 경계가 Port와 일치하지 않는다 (OrderPort는 pull인데 노드는 push+pull 혼합)

---

## 3. 결정 내용

### 3.1 3계층 경계 명시

| 계층 | 실체 | ATLAS 관계 |
|------|------|------------|
| Exchange | KRX · ExchangeEngine(가상) · CSVReplay(백테스트) | ATLAS 외부, Broker 통해 간접 접근 |
| Broker | KIS · Kiwoom · SyntheticBroker · MockBroker | ATLAS 외부, Adapter로 연결 |
| ATLAS | 5 Path + 공유저장소 + Port 추상화 | 내부 |

### 3.2 OrderExecutor 분해

이전:
```
OrderExecutor:
  on_approved_signal(signal):
    1. OrderRequest 생성
    2. OrderPort.submit()
    3. 체결 통보 WebSocket 수신
    4. trades INSERT
    5. TradingFSM emit
    6. audit 기록
```

이후:
```
OrderExecutor (책임 축소):
  on_approved_signal(signal):
    1. OrderRequest 생성
    2. order_tracker INSERT
    3. OrderPort.submit()
    4. 응답 수신 (ACK/REJECT만)
    5. order_tracker UPDATE
    6. audit 기록

ExecutionReceiver (신설):
  on_execution_event(event):   # ExecutionEventPort 구독
    1. TradeRecord 생성
    2. trades INSERT
    3. PortfolioStore 갱신 (cash, positions)
    4. TradingFSM에 execution_event emit
    5. audit 기록
```

### 3.3 ExecutionEventPort 신설

```python
class ExecutionEventPort(ABC):
    @abstractmethod
    async def subscribe(self, handler: Callable[[ExecutionEvent], None]) -> None:
        """체결 통보 구독. 증권사가 체결 발생 시 handler 호출."""

    @abstractmethod
    async def unsubscribe(self) -> None:
        """구독 해제."""
```

구현체 3개:
- `MockExecutionEventAdapter` — MockOrderAdapter 체결 후 in-process emit
- `KISPaperExecutionEventAdapter` — KIS H0STCNI0 WebSocket 구독
- `SyntheticExecutionEventAdapter` — ExchangeEngine 체결 이벤트 구독

### 3.4 reconcile 재정의

이전: `AccountPort.reconcile()` — "내부 DB ↔ 브로커 일관성 검증" (대칭)

이후: 개념 자체 폐기. 진실은 항상 증권사.
- 평상시: ExecutionReceiver가 체결 이벤트로부터 PortfolioStore 갱신 (증권사 기준)
- 부팅 시: TradingFSM이 AccountPort.get_balance/get_positions() 호출해서 PortfolioStore 초기화
- 주기 검증: TradingFSM이 일정 주기로 AccountPort 조회해서 PortfolioStore 갱신 (불일치 시 증권사 기준으로 덮어쓰기)

`reconcile` 메서드 자체는 유지하되 의미를 "증권사 기준으로 캐시 갱신"으로 명확화.

### 3.5 증권사 push 채널 현실 반영

KIS API 조사 결과:
- 시세: WebSocket push 있음 (H0STASP0 등)
- **체결 통보: WebSocket push 있음 (H0STCNI0)** → ExecutionEventPort로 수용
- 잔고 변경: **push 채널 없음** → 체결 이벤트로부터 유도

따라서 "AccountEventPort"는 신설하지 않는다. 잔고는 체결 이벤트의 부산물로 계산한다.
이것이 정확성이 필요한 경우(부팅·주기 검증), AccountPort의 pull 조회로 증권사 기준 덮어쓰기.

---

## 4. 영향받는 구조

### 4.1 Path 1 노드 (6 → 7)

| 이전 (6개) | 이후 (7개) |
|-----------|-----------|
| MarketDataReceiver | MarketDataReceiver |
| IndicatorCalculator | IndicatorCalculator |
| StrategyEngine | StrategyEngine |
| RiskGuard | RiskGuard |
| OrderExecutor (3역할) | OrderExecutor (요청만, 축소) |
| — | **ExecutionReceiver (신설)** |
| TradingFSM | TradingFSM |

### 4.2 Port (7 → 8)

추가: `ExecutionEventPort`

### 4.3 Adapter (16 → 19)

추가: `MockExecutionEventAdapter`, `KISPaperExecutionEventAdapter`, `SyntheticExecutionEventAdapter`

### 4.4 엣지 (14 → 16)

```
추가 엣지:
  ExecutionEventPort ──[execution_event]──> ExecutionReceiver   (DataFlow)
  ExecutionReceiver ──[execution_event]──> TradingFSM          (Event)

변경 엣지:
  OrderExecutor ──[execution_event]──> TradingFSM             (삭제, ExecutionReceiver로 이관)
  OrderExecutor ──[execution_event]──> AuditLogger            (삭제, ExecutionReceiver로 이관)
```

### 4.5 DB 스키마 (변경 없음)

`trades`, `positions`, `order_tracker` 테이블은 그대로. 쓰는 주체만 달라진다.

---

## 5. 폐기된 대안

### 5.1 AccountEventPort 신설

**검토**: 증권사가 잔고 변경을 push로 알려주는 전용 Port.

**폐기 이유**: KIS API에 해당 채널이 없음. 체결 이벤트로 충분. 불필요한 Port 신설은 과잉.

### 5.2 PolicyStore, PnLStore, AccountMirrorStore 분할

**검토**: PortfolioStore의 책임을 3개 저장소로 분할.

**폐기 이유**:
- Phase 1에서 한도는 config.yaml 하드코딩 (PolicyStore 불필요)
- daily_pnl은 PortfolioStore 내 테이블로 충분 (PnLStore 불필요)
- AccountMirror는 PortfolioStore의 기존 역할과 동일 (이름만 바꾸는 것은 과잉)

Phase 2에서 Path 4(포트폴리오)가 본격화되면 재검토한다.

### 5.3 인프라 독립 카테고리

**검토**: ATLAS를 설계·운영·인프라 3층으로 구분.

**폐기 이유**: 인프라는 "기술 스택 선택"이지 실행 단위가 아니다. 운영 영역의 기술 스택 섹션으로 충분.

### 5.4 Path 1 10노드 확장안 (S2, A2, R1, P4-1 신설)

**검토**: 이벤트 기반 재설계로 10+1 노드.

**폐기 이유**: 과잉 설계. 실제 필요한 분해는 OrderExecutor의 "요청 vs 수신" 하나뿐.
나머지 7노드 확장은 Phase 2 확장점으로 연기.

---

## 6. 수용 기준

본 ADR 수용 시 다음이 참이어야 한다:

- [ ] graph_ir_phase1.yaml: nodes 7, ports 8, adapters_primary 12 반영
- [ ] port-signatures-phase1.md: ExecutionEventPort ABC 명세
- [ ] adapter-spec-phase1.md: §6 ExecutionEventPort 어댑터 3개 명세
- [ ] path1-node-blueprint.md: OrderExecutor 축소 + ExecutionReceiver §신설
- [ ] path1-design.md: 14 → 16 엣지, Port 라벨 갱신
- [ ] config-schema-phase1.md: execution_event mode 3종 선택 규칙
- [ ] error-handling-phase1.md: ExecutionEventPort 에러 처리
- [ ] test-strategy-phase1.md: ExecutionReceiver 단위 테스트
- [ ] boot-shutdown.md: ExecutionEventPort.subscribe() Boot Step 8 반영
- [ ] INDEX.md: 수치 갱신 (7 Port→8, 16 Adapter→19)

## 7. Phase 2+ 확장점 (참고)

본 ADR은 Phase 1 범위에 한정. Phase 2+에서 다음이 자연스럽게 추가된다:

- Path 4 PolicyMaker 노드 + PolicyStore (동적 한도 정책)
- Path 5 Watchdog 강화 (Telegram 알림, Discord 통보)
- Path 2 지식구축 (DART, 뉴스, 온톨로지)
- Path 3 전략개발 (LLM 전략 생성, 최적화)
- Path 6 Market Intelligence (MarketContext) — system-overview에서 Path 6 언급 정리

---

*ADR-013 — ATLAS 운전사-브로커 경계 확정. Phase 1 확장 1노드·1Port·3Adapter로 최소화.*
