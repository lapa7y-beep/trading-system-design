# ADR-001: Hexagonal Architecture 채택

> 상태: ✅ stable
> 날짜: 2026-03

## 맥락

증권사(KIS), 데이터소스, 알림채널 등 외부 의존성이 많다. 교체·테스트 시 핵심 로직에 영향이 가면 안 된다.

## 결정

Hexagonal Architecture 채택. 6개 Port를 Python ABC로 정의, Adapter를 YAML로 교체.

## 6개 Port

- BrokerPort — 증권사 연결
- MarketDataPort — 시장 데이터
- StrategyPort — 전략 인터페이스
- NotifierPort — 알림
- StoragePort — 저장
- ClockPort — 시간 제어 (실시간 ↔ 백테스트)

## 근거

- ClockPort Mock 교체만으로 백테스트 가능
- 증권사 추가 시 BrokerPort Adapter만 구현
- 외부 API 없이 전략 로직 단독 테스트

## 기각된 대안

- Layered: 외부 의존성 교체 어려움
- Clean Architecture: 1인 프로젝트에 과도
