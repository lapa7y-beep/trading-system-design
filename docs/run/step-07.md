# Step 07 — MockOrderAdapter + MockAccountAdapter + OrderExecutor 실제

## 1. 목적

inline stub (Step 0)를 MockOrderAdapter + MockAccountAdapter로 교체. OrderExecutor가 OrderPort.submit()을 호출하여 체결 응답 수신. RiskGuard가 AccountPort.get_balance()를 호출하여 잔고 확인.

> **BrokerPort 분리 적용**: 이 Step에서 OrderPort + AccountPort 두 어댑터를 동시에 도입한다.
> 두 어댑터는 in-process 상태(MockAccountState)를 공유하므로 함께 구현·테스트한다.

## 2. 합격 기준 매핑

- Phase 1 합격기준: 2
- 기여 방식: 모의투자 5일 무사고 — 체결 시뮬레이션 + 잔고 일관성 필요

## 3. 착수 전 체크리스트

- [ ] 이전 Step 테스트 전부 통과 (`pytest tests/ -v`)
- [ ] §4 참조 문서 정독 완료

## 4. 참조 문서 (읽을 순서)

1. `docs/what/specs/adapter-spec-phase1.md` — §5.1 MockOrderAdapter, §5b.1 MockAccountAdapter — Mock 체결 + 계좌 명세 (10분)
2. `docs/what/architecture/path1-design.md` — §2.5 OrderExecutor — 주문 실행 로직 (10분)
3. `docs/what/specs/error-handling-phase1.md` — §3.5 OrderExecutor, §4.2 OrderPort, §4.2b AccountPort — 에러 처리 (5분)
4. `docs/what/specs/domain-types-phase1.md` — §3.5 Order, §3.6 Portfolio — 타입 확인 (5분)
5. `docs/what/specs/port-signatures-phase1.md` — §3.2 OrderPort, §3.2b AccountPort — ABC 시그니처 (5분)

**이 Step에서 읽지 않는 문서**: fsm-design (Step 8), db-schema (Step 9)

## 5. 작업 단계

> Step 착수 직전에 상세화. §4 참조 문서 정독 후 구체적 파일 수정 목록 작성.

핵심 작업:
- `adapters/order/mock_order.py` — MockOrderAdapter 구현
- `adapters/account/mock_account.py` — MockAccountAdapter 구현 + MockAccountState (공유 상태)
- OrderExecutor가 OrderPort 주입받아 submit() 호출
- RiskGuard가 AccountPort 주입받아 get_balance() 호출
- Reconciler 테스트 (in-process이므로 항상 일관)

## 6. 완료 조건

- [ ] 관찰 기준: (착수 전 상세화)
- [ ] 테스트: `pytest tests/ -v` 전체 녹색
- [ ] Port 불변: Port 시그니처 변경 없음
- [ ] seam-map.md: OrderPort, AccountPort 두 행 갱신 완료
- [ ] PROGRESS.md: 체크박스 + Daily Log

## 7. 커밋

```bash
git add -A
git commit -m "Step 07: MockOrderAdapter + MockAccountAdapter + OrderExecutor 실제

Observable change: (착수 전 상세화)
Fitness criteria:  2
Port changes:      none
Tests added:       tests/step_07/test_*.py"
```
