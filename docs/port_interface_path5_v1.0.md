# Port Interface Design — Path 5: Watchdog & Operations

## 문서 정보

| 항목 | 값 |
|------|-----|
| 문서 ID | port_interface_path5_v1.0 |
| Path | Path 5: Watchdog & Operations |
| 선행 문서 | boundary_definition_v1.0, port_interface_path1~4_v1.0 |
| 작성일 | 2026-04-15 |
| 상태 | Draft |

---

## 1. Path 5 개요

### 1.1 책임 범위

Watchdog & Operations Path는 전체 시스템의 건강 상태 감시, 이상 감지, 감사 로깅, 운영 명령 처리, 알림 전송을 담당한다.

다른 4개 Path가 "비즈니스 로직"이라면, Path 5는 "관제탑"이다. 모든 Path의 이벤트를 수신하고, 이상을 감지하면 즉시 개입한다. boundary_definition에서 정의한 Watchdog 3-Channel(시스템 헬스, 매매 감사, 보안 모니터) 아키텍처를 구현한다.

### 1.2 노드 구성 (6개)

| 노드 ID | 역할 | runMode | LLM Level |
|---------|------|---------|-----------|
| HealthMonitor | 시스템 헬스체크 (전 노드/서비스) | poll | L0 (없음) |
| AuditLogger | 모든 이벤트 불변 감사 로깅 | stream | L0 (없음) |
| AnomalyDetector | 이상 패턴 감지 (급변, 이탈) | event | L1 (도구) |
| AlertDispatcher | 다채널 알림 발송 | event | L0 (없음) |
| CommandController | 외부 운영 명령 수신/실행 | stateful-service | L0 (없음) |
| DailyReporter | 일일/주간 운영 리포트 생성 | batch | L1 (도구) |

### 1.3 Watchdog 3-Channel 아키텍처

```
Channel 1: System Health
  HealthMonitor → 노드/서비스 상태 폴링 → 장애 감지 → AlertDispatcher

Channel 2: Trade Audit
  AuditLogger → 모든 주문/체결/상태 전이 불변 기록 → AnomalyDetector

Channel 3: Security Monitor
  CommandController → 인증된 명령만 수락 → 감사 로깅 → 실행
```

### 1.4 접촉하는 Shared Store (3개)

| Store | 용도 | 접근 방식 |
|-------|------|----------|
| AuditStore | 감사 로그, 이벤트 이력 | Write Only (append) |
| ConfigStore | 알림 설정, 임계값, 명령 권한 | Read Only |
| PortfolioStore | 포지션/손익 참조 (이상 감지용) | Read Only |

---

## 2. Port Interface 정의 (5개 Port)

### 2.1 HealthCheckPort — 시스템 헬스체크 규격

전체 시스템 구성 요소의 가용성과 성능을 모니터링한다.

```python
from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum


class ComponentStatus(Enum):
    HEALTHY = "healthy"
    DEGRADED = "degraded"         # 동작하지만 느리거나 불안정
    UNHEALTHY = "unhealthy"       # 응답 없거나 에러
    UNKNOWN = "unknown"           # 아직 체크 안 됨


class ComponentType(Enum):
    NODE = "node"                 # HR-DAG 노드
    ADAPTER = "adapter"           # 포트 어댑터
    SHARED_STORE = "shared_store" # 공유 저장소
    EXTERNAL_API = "external_api" # 외부 API (KIS, DART 등)
    INFRASTRUCTURE = "infra"      # Redis, PostgreSQL 등


@dataclass(frozen=True)
class HealthStatus:
    """개별 컴포넌트 헬스 상태"""
    component_id: str             # "kis_mcp_adapter"
    component_type: ComponentType
    status: ComponentStatus
    latency_ms: int | None = None
    last_checked: datetime = field(default_factory=datetime.now)
    message: str = ""             # "Connection timeout after 5s"
    metadata: dict = field(default_factory=dict)
    # metadata 예시: {"uptime_hours": 72, "error_count_1h": 3}


@dataclass(frozen=True)
class SystemHealth:
    """시스템 전체 헬스 요약"""
    overall: ComponentStatus      # 최악의 컴포넌트 상태
    components: list[HealthStatus]
    healthy_count: int
    degraded_count: int
    unhealthy_count: int
    checked_at: datetime = field(default_factory=datetime.now)


class HealthCheckPort(ABC):
    """
    시스템 헬스체크 인터페이스.

    HTTP 기반이든, 프로세스 내부 체크든
    이 규격만 맞추면 교체 가능.
    """

    @abstractmethod
    async def check_component(
        self, component_id: str
    ) -> HealthStatus:
        """단일 컴포넌트 헬스체크."""
        ...

    @abstractmethod
    async def check_all(self) -> SystemHealth:
        """
        전체 시스템 헬스체크.
        모든 등록된 컴포넌트를 병렬로 체크.
        """
        ...

    @abstractmethod
    async def register_component(
        self, component_id: str,
        component_type: ComponentType,
        check_fn: callable | None = None,
        endpoint: str | None = None
    ) -> bool:
        """
        모니터링 대상 컴포넌트 등록.
        check_fn: 커스텀 체크 함수 (내부 노드용)
        endpoint: HTTP 헬스체크 URL (외부 서비스용)
        """
        ...

    @abstractmethod
    async def get_history(
        self, component_id: str, hours: int = 24
    ) -> list[HealthStatus]:
        """컴포넌트별 헬스 이력."""
        ...

    @abstractmethod
    async def get_uptime(
        self, component_id: str, days: int = 30
    ) -> dict:
        """
        가용률 계산.
        Returns: {"uptime_pct": 99.95, "total_downtime_minutes": 21,
                  "incidents": [{"start": "...", "end": "...", "duration_min": 15}]}
        """
        ...
```

**Adapters:**
- InternalHealthAdapter — asyncio 기반 내부 체크 (운영)
- HTTPHealthAdapter — HTTP endpoint 폴링
- MockHealthAdapter — 테스트용

---

### 2.2 AuditPort — 감사 로깅 규격

모든 시스템 이벤트를 불변 로그로 기록한다. 주문, 체결, 상태 전이, 설정 변경, 명령 실행 등 모든 행위를 추적.

```python
class AuditEventType(Enum):
    # 주문/매매 관련
    ORDER_SUBMITTED = "order_submitted"
    ORDER_FILLED = "order_filled"
    ORDER_CANCELLED = "order_cancelled"
    ORDER_REJECTED = "order_rejected"

    # 리스크 관련
    RISK_CHECK_PASSED = "risk_check_passed"
    RISK_CHECK_REDUCED = "risk_check_reduced"
    RISK_CHECK_REJECTED = "risk_check_rejected"
    TRADING_HALTED = "trading_halted"
    TRADING_RESUMED = "trading_resumed"

    # 전략 관련
    STRATEGY_DEPLOYED = "strategy_deployed"
    STRATEGY_RETIRED = "strategy_retired"
    STRATEGY_PARAM_CHANGED = "strategy_param_changed"
    SIGNAL_GENERATED = "signal_generated"
    CONFLICT_RESOLVED = "conflict_resolved"

    # 시스템 관련
    SYSTEM_STARTED = "system_started"
    SYSTEM_STOPPED = "system_stopped"
    COMPONENT_UNHEALTHY = "component_unhealthy"
    COMPONENT_RECOVERED = "component_recovered"
    CONFIG_CHANGED = "config_changed"

    # 보안 관련
    COMMAND_RECEIVED = "command_received"
    COMMAND_EXECUTED = "command_executed"
    COMMAND_REJECTED = "command_rejected"
    AUTH_FAILURE = "auth_failure"

    # LLM 관련
    LLM_CALL_MADE = "llm_call_made"
    LLM_CALL_FAILED = "llm_call_failed"


class AuditSeverity(Enum):
    INFO = "info"
    WARNING = "warning"
    ERROR = "error"
    CRITICAL = "critical"


@dataclass(frozen=True)
class AuditEvent:
    """감사 이벤트"""
    event_id: str                 # UUID
    event_type: AuditEventType
    severity: AuditSeverity
    source_path: str              # "path1" | "path2" | ... | "path5"
    source_node: str              # "TradingFSM" | "RiskBudgetManager" | ...
    timestamp: datetime
    actor: str                    # "system" | "user:jdw" | "strategy:ma_cross"
    payload: dict                 # 이벤트 상세 데이터
    correlation_id: str | None = None  # 관련 이벤트 연결 (주문→체결 추적)


@dataclass(frozen=True)
class AuditQuery:
    """감사 로그 조회 조건"""
    event_types: list[AuditEventType] | None = None
    severity: AuditSeverity | None = None
    source_path: str | None = None
    source_node: str | None = None
    actor: str | None = None
    correlation_id: str | None = None
    start_time: datetime | None = None
    end_time: datetime | None = None
    limit: int = 100


class AuditPort(ABC):
    """
    감사 로깅 인터페이스.

    PostgreSQL이든, Elasticsearch든, 파일이든
    이 규격만 맞추면 교체 가능.

    핵심 원칙: Write-only append. 기록된 이벤트는 수정/삭제 불가.
    """

    @abstractmethod
    async def log(self, event: AuditEvent) -> str:
        """
        감사 이벤트 기록.
        불변 저장 — 한 번 기록되면 수정/삭제 불가.
        Returns: event_id
        """
        ...

    @abstractmethod
    async def log_batch(self, events: list[AuditEvent]) -> int:
        """배치 기록. Returns: 기록된 이벤트 수."""
        ...

    @abstractmethod
    async def query(self, q: AuditQuery) -> list[AuditEvent]:
        """감사 로그 조회. 읽기 전용."""
        ...

    @abstractmethod
    async def get_trail(
        self, correlation_id: str
    ) -> list[AuditEvent]:
        """
        상관 ID 기반 이벤트 체인 추적.
        예: 주문 생성 → 리스크 검증 → 체결 → 포지션 갱신
        """
        ...

    @abstractmethod
    async def get_stats(
        self, hours: int = 24
    ) -> dict:
        """
        감사 통계.
        Returns: {"total_events": 1500,
                  "by_type": {"order_filled": 45, "signal_generated": 200, ...},
                  "by_severity": {"info": 1400, "warning": 80, "error": 20},
                  "by_path": {"path1": 600, "path2": 300, ...}}
        """
        ...
```

**Adapters:**
- PostgresAuditAdapter — PostgreSQL (운영, immutable table)
- TimescaleAuditAdapter — TimescaleDB (시계열 최적화, 미래)
- FileAuditAdapter — JSON Lines 파일 (개발)
- MockAuditAdapter — 테스트용

---

### 2.3 AlertPort — 알림 발송 규격

이상 감지, 시스템 장애, 리스크 위반 등의 이벤트를 운영자에게 전달한다. 다채널 동시 발송 지원.

```python
class AlertChannel(Enum):
    TELEGRAM = "telegram"
    DISCORD = "discord"
    SLACK = "slack"
    EMAIL = "email"
    CONSOLE = "console"           # 개발용


class AlertPriority(Enum):
    LOW = "low"                   # 참고 (일일 요약에 포함)
    MEDIUM = "medium"             # 즉시 알림 (업무 시간)
    HIGH = "high"                 # 즉시 알림 (항상)
    CRITICAL = "critical"         # 반복 알림 + 확인 요구


@dataclass(frozen=True)
class Alert:
    """알림 메시지"""
    alert_id: str
    priority: AlertPriority
    title: str                    # "일일 손실 한도 도달"
    body: str                     # 상세 내용
    source_path: str
    source_node: str
    channels: list[AlertChannel] | None = None  # None = 설정 기반 자동 선택
    metadata: dict = field(default_factory=dict)
    created_at: datetime = field(default_factory=datetime.now)


@dataclass(frozen=True)
class AlertDeliveryResult:
    """알림 발송 결과"""
    alert_id: str
    channel: AlertChannel
    success: bool
    delivered_at: datetime | None = None
    error: str | None = None


@dataclass(frozen=True)
class ApprovalRequest:
    """운영자 승인 요청"""
    request_id: str
    title: str
    description: str
    action: str                   # "deploy_strategy" | "resume_trading" | "update_limits"
    payload: dict                 # 승인 시 실행할 데이터
    timeout_minutes: int = 30
    channels: list[AlertChannel] | None = None
    created_at: datetime = field(default_factory=datetime.now)


class ApprovalStatus(Enum):
    PENDING = "pending"
    APPROVED = "approved"
    REJECTED = "rejected"
    EXPIRED = "expired"


class AlertPort(ABC):
    """
    다채널 알림 인터페이스.

    Telegram이든, Discord든, Slack이든
    이 규격만 맞추면 교체 가능.
    """

    @abstractmethod
    async def send(self, alert: Alert) -> list[AlertDeliveryResult]:
        """
        알림 발송.
        channels 미지정 시 priority에 따라 자동 선택.
        Returns: 채널별 발송 결과
        """
        ...

    @abstractmethod
    async def request_approval(
        self, request: ApprovalRequest
    ) -> str:
        """
        운영자 승인 요청 발송.
        Returns: request_id
        """
        ...

    @abstractmethod
    async def check_approval(
        self, request_id: str
    ) -> ApprovalStatus:
        """승인 상태 확인."""
        ...

    @abstractmethod
    async def send_daily_summary(
        self, summary: dict
    ) -> list[AlertDeliveryResult]:
        """
        일일 요약 발송.
        summary: {"pnl": ..., "trades": ..., "alerts": ..., "health": ...}
        """
        ...

    @abstractmethod
    async def get_delivery_history(
        self, hours: int = 24
    ) -> list[AlertDeliveryResult]:
        """발송 이력 조회."""
        ...
```

**Adapters:**
- TelegramAlertAdapter — Telegram Bot API (운영 기본)
- DiscordAlertAdapter — Discord Webhook (운영 보조)
- SlackAlertAdapter — Slack Webhook (미래)
- ConsoleAlertAdapter — 콘솔 출력 (개발)
- MockAlertAdapter — 테스트용

---

### 2.4 CommandPort — 운영 명령 수신/실행 규격

외부에서 시스템을 제어하는 명령을 수신하고 인증/인가 후 실행한다. boundary_definition의 4계층 보안 모델(Command & Control Security)을 구현.

```python
class CommandType(Enum):
    # 거래 제어
    HALT_TRADING = "halt_trading"
    RESUME_TRADING = "resume_trading"
    CLOSE_POSITION = "close_position"
    CLOSE_ALL = "close_all"

    # 전략 제어
    DEPLOY_STRATEGY = "deploy_strategy"
    RETIRE_STRATEGY = "retire_strategy"
    UPDATE_PARAMS = "update_params"

    # 시스템 제어
    RESTART_NODE = "restart_node"
    RELOAD_CONFIG = "reload_config"

    # 조회 (읽기 전용)
    STATUS = "status"
    POSITIONS = "positions"
    HEALTH = "health"


class CommandRiskLevel(Enum):
    READ_ONLY = "read_only"       # 즉시 실행
    LOW = "low"                   # 로깅 후 즉시 실행
    MEDIUM = "medium"             # 확인 후 실행
    HIGH = "high"                 # 승인 필요 (ApprovalRequest)
    CRITICAL = "critical"         # 이중 인증 + 승인


# 명령별 리스크 매핑
COMMAND_RISK_MAP = {
    CommandType.STATUS: CommandRiskLevel.READ_ONLY,
    CommandType.POSITIONS: CommandRiskLevel.READ_ONLY,
    CommandType.HEALTH: CommandRiskLevel.READ_ONLY,
    CommandType.RELOAD_CONFIG: CommandRiskLevel.LOW,
    CommandType.UPDATE_PARAMS: CommandRiskLevel.MEDIUM,
    CommandType.DEPLOY_STRATEGY: CommandRiskLevel.MEDIUM,
    CommandType.RETIRE_STRATEGY: CommandRiskLevel.MEDIUM,
    CommandType.HALT_TRADING: CommandRiskLevel.LOW,      # 안전 방향이므로 낮음
    CommandType.RESUME_TRADING: CommandRiskLevel.MEDIUM,
    CommandType.CLOSE_POSITION: CommandRiskLevel.HIGH,
    CommandType.CLOSE_ALL: CommandRiskLevel.CRITICAL,
    CommandType.RESTART_NODE: CommandRiskLevel.HIGH,
}


@dataclass(frozen=True)
class Command:
    """운영 명령"""
    command_id: str
    command_type: CommandType
    issuer: str                   # "user:jdw" | "system:watchdog"
    params: dict = field(default_factory=dict)
    # params 예시:
    #   CLOSE_POSITION: {"symbol": "005930", "strategy_id": "ma_cross"}
    #   DEPLOY_STRATEGY: {"strategy_id": "breakout_v2", "version": "1.0.0"}
    issued_at: datetime = field(default_factory=datetime.now)


class CommandResult(Enum):
    EXECUTED = "executed"
    PENDING_APPROVAL = "pending_approval"
    REJECTED = "rejected"
    FAILED = "failed"


@dataclass(frozen=True)
class CommandResponse:
    """명령 실행 결과"""
    command_id: str
    result: CommandResult
    message: str
    data: dict = field(default_factory=dict)
    executed_at: datetime = field(default_factory=datetime.now)


class CommandPort(ABC):
    """
    운영 명령 인터페이스.

    Telegram 봇이든, REST API든, CLI든
    이 규격만 맞추면 교체 가능.
    """

    @abstractmethod
    async def receive(self) -> Command | None:
        """
        다음 명령 수신 (polling 방식).
        Returns: 대기 중인 명령 또는 None
        """
        ...

    @abstractmethod
    async def on_command(
        self, callback: callable
    ) -> None:
        """
        명령 수신 콜백 등록 (event 방식).
        callback(command: Command) -> CommandResponse
        """
        ...

    @abstractmethod
    async def execute(
        self, command: Command
    ) -> CommandResponse:
        """
        명령 실행.
        1) 리스크 레벨 판단
        2) READ_ONLY/LOW → 즉시 실행
        3) MEDIUM → 확인 로깅 후 실행
        4) HIGH/CRITICAL → 승인 요청 후 대기
        """
        ...

    @abstractmethod
    async def get_command_history(
        self, limit: int = 50
    ) -> list[tuple[Command, CommandResponse]]:
        """명령 실행 이력."""
        ...

    @abstractmethod
    async def get_pending_approvals(self) -> list[Command]:
        """승인 대기 중인 명령 목록."""
        ...
```

**Adapters:**
- TelegramCommandAdapter — Telegram 봇 명령 수신 (운영)
- RESTCommandAdapter — HTTP REST API (미래, 대시보드 연동)
- CLICommandAdapter — 명령줄 인터페이스 (개발)
- MockCommandAdapter — 테스트용

---

### 2.5 AnomalyDetectionPort — 이상 감지 규격

시스템과 매매 활동에서 비정상 패턴을 감지한다.

```python
class AnomalyType(Enum):
    # 매매 이상
    RAPID_FIRE_ORDERS = "rapid_fire_orders"       # 단시간 대량 주문
    UNUSUAL_POSITION_SIZE = "unusual_position_size"
    LOSS_STREAK = "loss_streak"                   # 연속 손실
    STRATEGY_DEVIATION = "strategy_deviation"     # 전략 신호 대비 비정상 행동

    # 시세 이상
    PRICE_SPIKE = "price_spike"                   # 급등/급락
    VOLUME_ANOMALY = "volume_anomaly"             # 비정상 거래량
    SPREAD_WIDENING = "spread_widening"           # 스프레드 급확대

    # 시스템 이상
    LATENCY_SPIKE = "latency_spike"               # 응답 지연 급증
    ERROR_RATE_SPIKE = "error_rate_spike"          # 에러율 급증
    MEMORY_LEAK = "memory_leak"                   # 메모리 누수 의심
    RECONCILIATION_MISMATCH = "recon_mismatch"    # 포지션-계좌 불일치


@dataclass(frozen=True)
class Anomaly:
    """감지된 이상"""
    anomaly_id: str
    anomaly_type: AnomalyType
    severity: AuditSeverity
    description: str
    detected_at: datetime
    affected_components: list[str]   # ["path1.TradingFSM", "adapter.KISAdapter"]
    evidence: dict                   # 감지 근거 데이터
    suggested_action: str            # "halt_trading" | "alert_only" | "investigate"
    auto_resolved: bool = False


class AnomalyDetectionPort(ABC):
    """
    이상 감지 인터페이스.

    규칙 기반이든, 통계 기반이든, ML 기반이든
    이 규격만 맞추면 교체 가능.
    """

    @abstractmethod
    async def analyze_event(
        self, event: AuditEvent
    ) -> Anomaly | None:
        """
        개별 이벤트 분석.
        이상 감지 시 Anomaly 반환, 정상이면 None.
        """
        ...

    @abstractmethod
    async def analyze_window(
        self, events: list[AuditEvent],
        window_minutes: int = 5
    ) -> list[Anomaly]:
        """
        시간 윈도우 기반 패턴 분석.
        연속 이벤트에서 이상 패턴 탐지.
        """
        ...

    @abstractmethod
    async def get_active_anomalies(self) -> list[Anomaly]:
        """현재 활성(미해결) 이상 목록."""
        ...

    @abstractmethod
    async def resolve_anomaly(
        self, anomaly_id: str, resolution: str
    ) -> bool:
        """이상 해결 처리."""
        ...

    @abstractmethod
    async def get_anomaly_history(
        self, hours: int = 24,
        anomaly_type: AnomalyType | None = None
    ) -> list[Anomaly]:
        """이상 감지 이력."""
        ...
```

**Adapters:**
- RuleBasedAnomalyAdapter — 규칙/임계값 기반 (MVP)
- StatisticalAnomalyAdapter — Z-score / IQR 기반 (운영)
- LLMAssistedAnomalyAdapter — LLM 보조 패턴 분석 (L1)
- MockAnomalyAdapter — 테스트용

---

## 3. Domain Types 정의 (Path 5 전용)

### 3.1 Enum 정의

```python
class ComponentStatus(Enum):
    HEALTHY = "healthy"
    DEGRADED = "degraded"
    UNHEALTHY = "unhealthy"
    UNKNOWN = "unknown"

class AuditEventType(Enum):
    ORDER_SUBMITTED = "order_submitted"
    ORDER_FILLED = "order_filled"
    # ... (22종 — 전체 목록은 2.2절 참조)

class AuditSeverity(Enum):
    INFO = "info"
    WARNING = "warning"
    ERROR = "error"
    CRITICAL = "critical"

class AlertPriority(Enum):
    LOW = "low"
    MEDIUM = "medium"
    HIGH = "high"
    CRITICAL = "critical"

class AlertChannel(Enum):
    TELEGRAM = "telegram"
    DISCORD = "discord"
    SLACK = "slack"
    EMAIL = "email"
    CONSOLE = "console"

class CommandType(Enum):
    HALT_TRADING = "halt_trading"
    RESUME_TRADING = "resume_trading"
    # ... (12종 — 전체 목록은 2.4절 참조)

class CommandRiskLevel(Enum):
    READ_ONLY = "read_only"
    LOW = "low"
    MEDIUM = "medium"
    HIGH = "high"
    CRITICAL = "critical"

class AnomalyType(Enum):
    RAPID_FIRE_ORDERS = "rapid_fire_orders"
    # ... (11종 — 전체 목록은 2.5절 참조)
```

### 3.2 Core Data Types (14종)

| Type | 용도 | 주요 필드 |
|------|------|----------|
| HealthStatus | 컴포넌트 상태 | component_id, status, latency_ms |
| SystemHealth | 전체 시스템 상태 | overall, components, healthy/degraded/unhealthy count |
| AuditEvent | 감사 이벤트 | event_type, severity, source, actor, payload, correlation_id |
| AuditQuery | 로그 조회 조건 | event_types, severity, time range |
| Alert | 알림 메시지 | priority, title, body, channels |
| AlertDeliveryResult | 발송 결과 | channel, success, error |
| ApprovalRequest | 승인 요청 | action, payload, timeout |
| Command | 운영 명령 | command_type, issuer, params |
| CommandResponse | 명령 결과 | result, message, data |
| Anomaly | 감지된 이상 | anomaly_type, severity, evidence, suggested_action |
| COMMAND_RISK_MAP | 명령-리스크 매핑 | CommandType → CommandRiskLevel (상수) |
| ComponentType | 컴포넌트 분류 | NODE, ADAPTER, SHARED_STORE, EXTERNAL_API, INFRA |
| ApprovalStatus | 승인 상태 | PENDING, APPROVED, REJECTED, EXPIRED |
| CommandResult | 실행 결과 | EXECUTED, PENDING_APPROVAL, REJECTED, FAILED |

---

## 4. 데이터 흐름 (Edge 정의, 13개)

### 4.1 내부 Edge (Path 5 내부)

| # | Source → Target | Edge Type | 데이터 | 설명 |
|---|----------------|-----------|--------|------|
| 1 | HealthMonitor → AlertDispatcher | Event | HealthStatus (UNHEALTHY) | 장애 알림 |
| 2 | AuditLogger → AnomalyDetector | DataFlow | AuditEvent stream | 이상 감지 입력 |
| 3 | AnomalyDetector → AlertDispatcher | Event | Anomaly | 이상 알림 |
| 4 | CommandController → AuditLogger | DataFlow | Command + Response | 명령 감사 기록 |
| 5 | AuditLogger → DailyReporter | DataFlow | 일일 이벤트 집계 | 리포트 소스 |
| 6 | DailyReporter → AlertDispatcher | Command | PerformanceReport | 일일 요약 발송 |

### 4.2 Cross-Path Edge (모든 Path로부터 수신)

| # | Source → Target | Edge Type | 데이터 | 설명 |
|---|----------------|-----------|--------|------|
| 7 | Path 1 → AuditLogger | Event | 주문/체결/상태전이 이벤트 | 매매 감사 |
| 8 | Path 2 → AuditLogger | Event | 수집/파싱/LLM 호출 이벤트 | 지식 감사 |
| 9 | Path 3 → AuditLogger | Event | 전략 배포/백테스트 이벤트 | 전략 감사 |
| 10 | Path 4 → AuditLogger | Event | 리스크/리밸런싱 이벤트 | 포트폴리오 감사 |
| 11 | CommandController → Path 1 | Command | halt/resume/close | 거래 제어 |
| 12 | CommandController → Path 3 | Command | deploy/retire | 전략 제어 |
| 13 | CommandController → Path 4 | Command | update_limits | 리스크 제어 |

---

## 5. Shared Store 스키마 (Path 5 기여분)

### 5.1 AuditStore

```sql
-- 감사 이벤트 테이블 (append-only, 삭제/수정 금지)
CREATE TABLE audit_events (
    event_id        UUID PRIMARY KEY,
    event_type      TEXT NOT NULL,
    severity        TEXT NOT NULL,
    source_path     TEXT NOT NULL,
    source_node     TEXT NOT NULL,
    timestamp       TIMESTAMPTZ NOT NULL,
    actor           TEXT NOT NULL,
    payload         JSONB NOT NULL,
    correlation_id  UUID,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

-- 삭제/수정 방지 트리거
CREATE OR REPLACE FUNCTION prevent_audit_modification()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'Audit events are immutable. DELETE and UPDATE are prohibited.';
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER no_update_audit
    BEFORE UPDATE OR DELETE ON audit_events
    FOR EACH ROW EXECUTE FUNCTION prevent_audit_modification();

-- 헬스 체크 이력
CREATE TABLE health_history (
    id              BIGSERIAL PRIMARY KEY,
    component_id    TEXT NOT NULL,
    component_type  TEXT NOT NULL,
    status          TEXT NOT NULL,
    latency_ms      INT,
    message         TEXT,
    checked_at      TIMESTAMPTZ DEFAULT NOW()
);

-- 알림 발송 이력
CREATE TABLE alert_history (
    alert_id        UUID PRIMARY KEY,
    priority        TEXT NOT NULL,
    title           TEXT NOT NULL,
    channels        TEXT[] NOT NULL,
    delivery_results JSONB,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

-- 명령 실행 이력
CREATE TABLE command_history (
    command_id      UUID PRIMARY KEY,
    command_type    TEXT NOT NULL,
    risk_level      TEXT NOT NULL,
    issuer          TEXT NOT NULL,
    params          JSONB,
    result          TEXT NOT NULL,
    message         TEXT,
    issued_at       TIMESTAMPTZ,
    executed_at     TIMESTAMPTZ DEFAULT NOW()
);

-- 이상 감지 이력
CREATE TABLE anomaly_history (
    anomaly_id      UUID PRIMARY KEY,
    anomaly_type    TEXT NOT NULL,
    severity        TEXT NOT NULL,
    description     TEXT,
    evidence        JSONB,
    suggested_action TEXT,
    resolved        BOOLEAN DEFAULT FALSE,
    resolution      TEXT,
    detected_at     TIMESTAMPTZ DEFAULT NOW(),
    resolved_at     TIMESTAMPTZ
);

-- 인덱스
CREATE INDEX idx_audit_type ON audit_events(event_type);
CREATE INDEX idx_audit_timestamp ON audit_events(timestamp);
CREATE INDEX idx_audit_correlation ON audit_events(correlation_id);
CREATE INDEX idx_audit_source ON audit_events(source_path, source_node);
CREATE INDEX idx_health_component ON health_history(component_id, checked_at);
CREATE INDEX idx_anomaly_type ON anomaly_history(anomaly_type, detected_at);

-- TimescaleDB 확장 (선택사항, 대규모 운영 시)
-- SELECT create_hypertable('audit_events', 'timestamp');
-- SELECT create_hypertable('health_history', 'checked_at');
```

---

## 6. Safeguard 적용

### 6.1 Path 5 자체 Safeguard

```
모든 외부 명령 수신
    → [AuthGuard]            인증 검증 (issuer 확인)
    → [RiskLevelGate]        명령 리스크 레벨 판단
        → READ_ONLY/LOW:     즉시 실행 + 로깅
        → MEDIUM:            확인 로깅 + 실행
        → HIGH:              승인 요청 → 대기 → 승인 시 실행
        → CRITICAL:          이중 인증 + 승인 → 실행
    → [AuditLogger]          모든 명령/결과 불변 기록
```

### 6.2 Watchdog 자동 개입 규칙

| 감지 조건 | 자동 행동 | 알림 |
|----------|----------|------|
| 컴포넌트 UNHEALTHY 3회 연속 | circuit breaker 활성화 | HIGH |
| 일일 손실 한도 도달 | halt_trading 자동 실행 | CRITICAL |
| 포지션-계좌 불일치 | reconcile + 신규 주문 차단 | HIGH |
| LLM 연속 실패 5회 | LLM 캐시 모드 전환 | MEDIUM |
| 단시간 대량 주문 감지 | 주문 속도 제한 강화 | HIGH |
| 에러율 > 10% (5분 윈도우) | 영향 노드 격리 + 알림 | CRITICAL |

---

## 7. Adapter Mapping 요약

| Port | 운영 Adapter | 개발 Adapter | 테스트 Adapter |
|------|-------------|-------------|---------------|
| HealthCheckPort | InternalHealthAdapter | InternalHealthAdapter | MockHealthAdapter |
| AuditPort | PostgresAuditAdapter | FileAuditAdapter | MockAuditAdapter |
| AlertPort | TelegramAlertAdapter | ConsoleAlertAdapter | MockAlertAdapter |
| CommandPort | TelegramCommandAdapter | CLICommandAdapter | MockCommandAdapter |
| AnomalyDetectionPort | StatisticalAnomalyAdapter | RuleBasedAnomalyAdapter | MockAnomalyAdapter |

**YAML 설정 예시:**

```yaml
path5_watchdog:
  health_check:
    implementation: InternalHealthAdapter
    params:
      check_interval_seconds: 30
      unhealthy_threshold: 3
      timeout_ms: 5000

  audit:
    implementation: PostgresAuditAdapter
    params:
      dsn: ${POSTGRES_DSN}
      table_prefix: "audit_"
      immutable: true

  alert:
    implementation: TelegramAlertAdapter
    params:
      bot_token: ${TELEGRAM_BOT_TOKEN}
      chat_id: ${TELEGRAM_CHAT_ID}
      priority_routing:
        low: ["console"]
        medium: ["telegram"]
        high: ["telegram", "discord"]
        critical: ["telegram", "discord", "email"]

  command:
    implementation: TelegramCommandAdapter
    params:
      bot_token: ${TELEGRAM_BOT_TOKEN}
      authorized_users: ["jdw"]
      approval_timeout_minutes: 30

  anomaly_detection:
    implementation: StatisticalAnomalyAdapter
    params:
      window_minutes: 5
      z_score_threshold: 3.0
      min_events_for_detection: 10
```

---

## 8. 전체 Port Interface 완료 현황

| Path | 문서 | Port 수 | Domain Type 수 | Edge 수 | 상태 |
|------|------|---------|---------------|---------|------|
| Path 1: Realtime Trading | port_interface_path1_v1.0 | 4 | 6 | 9 | ✅ 완료 |
| Path 2: Knowledge Building | port_interface_path2_v1.0 | 5 | 8 | 9 | ✅ 완료 |
| Path 3: Strategy Development | port_interface_path3_v1.0 | 5 | 10 | 12 | ✅ 완료 |
| Path 4: Portfolio Management | port_interface_path4_v1.0 | 5 | 12 | 11 | ✅ 완료 |
| Path 5: Watchdog & Operations | port_interface_path5_v1.0 | 5 | 14 | 13 | ✅ 완료 |
| **합계** | | **24** | **50** | **54** | |

---

## 9. 다음 단계 (Agenda 4번~)

- **4번: Edge Contract Definition** — 54개 Edge의 데이터 스키마 통합 정의
- **5번: System Manifest** — 전체 노드(~31개) + Port(24개) + Adapter 매핑 통합
- **6번: Node Blueprint Catalog** — 각 노드 상세 전개
- **7~8번: Pipeline 상세 + Shared Store 스키마 통합**
- **9번: Graph IR YAML** — 실행 가능한 Single Source of Truth
