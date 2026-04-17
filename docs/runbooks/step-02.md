# Step 02 — Port 추상화 도입

## 1. 목적

6 Port Protocol 정의 + FakeAdapter 6개 생성 + Orchestrator를 의존성 주입(DI) 구조로 전환. 이 Step 이후 Port 시그니처는 Phase 1 종료까지 불변.

**★ Phase 1에서 가장 중요한 구조적 경계점.**

## 2. 합격 기준 매핑

- Phase 1 합격기준: (구조적 경계점 — 직접 기여 없음)
- 기여 방식: Plug & Play Principle의 물리적 구현. 이후 모든 Stub Replacement의 전제.

## 3. 착수 전 체크리스트

- [ ] Step 01 테스트 전부 통과
- [ ] `docs/references/seam-classification.md` §5 체크리스트 7항목 전부 통과:
  - [ ] 6 Port 메서드 시그니처가 SSoT에 확정
  - [ ] BrokerPort의 Order에 `intent_id` 필드 존재
  - [ ] StoragePort 메서드가 트랜잭션 경계 미가정
  - [ ] ClockPort 외 datetime.now() 직접 호출 금지 명시
  - [ ] NotifierPort.alert() 실패 시 비전파 명시
  - [ ] StrategyPort.evaluate() 순수 함수 명시
  - [ ] 각 Port에 대응 FakeAdapter 이름 확정
- [ ] §4 참조 문서 정독 완료

## 4. 참조 문서 (읽을 순서)

1. `docs/specs/ports-phase1.md` — **전체 정독** (30분)
   - 6 Port의 모든 메서드 시그니처. 이 문서가 이 Step의 핵심.
2. `docs/references/seam-classification.md` — §3 (6 Port 분류), §5 (체크리스트) (15분)
3. `docs/references/seam-map.md` — §2 Seam 목록, §4 Adapter 목록 (10분)
4. `docs/specs/domain-types-phase1.md` — 전체 20개 타입 정독 (15분)
   - Step 0에서 4개만 읽었으나, Port 시그니처에 나머지 타입이 참조될 수 있음

**이 Step에서 읽지 않는 문서**: fsm-design (Step 8), db-schema (Step 9), cli-design (Step 10)

## 5. 작업 단계

1. `atlas/ports/` 디렉토리 생성
2. 6 Port Protocol 파일 생성:
   - `atlas/ports/market_data_port.py`
   - `atlas/ports/broker_port.py`
   - `atlas/ports/storage_port.py`
   - `atlas/ports/notifier_port.py`
   - `atlas/ports/clock_port.py`
   - `atlas/ports/strategy_port.py`
3. `atlas/adapters/` 디렉토리 생성
4. FakeAdapter 6개 생성 (Step 0 stub 코드를 Adapter 클래스로 래핑):
   - `atlas/adapters/fake_market_data.py`
   - `atlas/adapters/fake_broker.py`
   - `atlas/adapters/in_memory_storage.py`
   - `atlas/adapters/console_notifier.py`
   - `atlas/adapters/system_clock.py`
   - `atlas/adapters/fake_clock.py` (테스트용)
5. `atlas/orchestrator.py` 수정 — 생성자에서 Port 인터페이스 주입 받도록
6. `config/phase1.yaml` 생성 — Enabling Point 5개 (Adapter mode 선택)
7. 테스트 갱신: FakeAdapter 주입으로 전환
8. `pytest tests/ -v` 전체 통과 확인

## 6. 완료 조건

- [ ] `atlas/ports/` 에 6개 Protocol 파일 존재
- [ ] `atlas/adapters/` 에 7개 Adapter 파일 존재 (Fake 6 + FakeClock)
- [ ] `config/phase1.yaml` 에 5개 Enabling Point 존재
- [ ] `pytest tests/ -v` 기존 + 신규 테스트 전부 통과
- [ ] `python -m atlas.orchestrator` 출력이 Step 0과 동일 (행동 불변)
- [ ] Port 시그니처가 ports-phase1.md SSoT와 일치
- [ ] seam-map.md §1 Filter Status: 전부 `stub` 유지
- [ ] PROGRESS.md: Step 02 체크

## 7. 커밋

```bash
git add -A
git commit -m "Step 02: Introduce 6 Port Protocols + FakeAdapters + DI orchestrator

Observable change: (structural — behavior unchanged, DI wiring established)
Fitness criteria:  (foundation — Plug & Play Principle now physical)
Port changes:      INITIAL — 6 Ports defined (immutable from this point)
Tests added:       tests/step_02/test_port_contracts.py"
```
