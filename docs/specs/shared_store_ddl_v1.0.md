# Shared Store Schema — DDL 통합

## 문서 정보

| 항목 | 값 |
|------|-----|
| 문서 ID | shared_store_ddl_v1.0 |
| 선행 문서 | system_manifest_v1.0, port_interface_path1~6, order_lifecycle_spec |
| 작성일 | 2026-04-15 |
| 상태 | Draft |
| DB | PostgreSQL 16+ (TimescaleDB, Apache AGE, pgvector 확장) |

---

## 1. 스토어 전체 현황

| # | Store | 테이블 수 | 주 Writer | 핵심 역할 |
|---|-------|---------|----------|----------|
| 1 | MarketDataStore | 3 | Path 1B | 시세, OHLCV, 시세 스냅샷 |
| 2 | PortfolioStore | 5 | Path 1B/1C/4 | 포지션, 손익, 체결, 리밸런싱, 리스크 이벤트 |
| 3 | ConfigStore | 3 | 외부(YAML/관리자) | 전략 파라미터, 시스템 설정, 스케줄 |
| 4 | KnowledgeStore | 3 | Path 2 | 온톨로지 트리플, 인과관계, 파싱 문서 |
| 5 | StrategyStore | 4 | Path 3 | 전략 코드, 메타, 백테스트, 최적화 |
| 6 | AuditStore | 5 | Path 5 | 감사 이벤트, 헬스, 알림, 명령, 이상 |
| 7 | WatchlistStore | 4 | Path 1A | 워치리스트, 상태 이력, 청산 이력, 프로파일 |
| 8 | MarketIntelStore | 6 | Path 6 | 수급, 호가, 시장환경, 종목상태, 기업이벤트, 컨텍스트 |
| | **합계** | **33** | | |

---

## 2. 공통 설정

```sql
-- 확장 모듈
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";          -- gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS "timescaledb";       -- 시계열 최적화
CREATE EXTENSION IF NOT EXISTS "age";               -- 그래프 DB
CREATE EXTENSION IF NOT EXISTS "vector";            -- pgvector 임베딩

-- 공통 함수
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;
```

---

## 3. Store 1: MarketDataStore

```sql
-- ============================================================
-- MarketDataStore — 시세 데이터
-- Writer: Path 1B MarketDataReceiver
-- Reader: Path 1A, 2, 3, 4, 6
-- ============================================================

-- 3.1 실시간 시세 (최근 N일, TimescaleDB hypertable)
CREATE TABLE market_quotes (
    symbol          TEXT NOT NULL,
    price           INT NOT NULL,
    change          INT,
    change_pct      FLOAT,
    volume          BIGINT,
    amount          BIGINT,
    open_price      INT,
    high            INT,
    low             INT,
    prev_close      INT,
    ask_price       INT,
    bid_price       INT,
    recorded_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
SELECT create_hypertable('market_quotes', 'recorded_at');
CREATE INDEX idx_quotes_symbol ON market_quotes(symbol, recorded_at DESC);

-- 3.2 일봉 OHLCV (전 종목, 장기 보관)
CREATE TABLE market_ohlcv (
    symbol          TEXT NOT NULL,
    trade_date      DATE NOT NULL,
    open_price      INT NOT NULL,
    high            INT NOT NULL,
    low             INT NOT NULL,
    close_price     INT NOT NULL,
    volume          BIGINT NOT NULL,
    amount          BIGINT,
    adjusted        BOOLEAN DEFAULT TRUE,   -- 수정주가 여부
    PRIMARY KEY (symbol, trade_date)
);
CREATE INDEX idx_ohlcv_date ON market_ohlcv(trade_date);

-- 3.3 시세 스냅샷 (수집 주기별)
CREATE TABLE market_snapshots (
    snapshot_id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    cycle           INT NOT NULL,
    quote_count     INT NOT NULL,
    quotes          JSONB NOT NULL,         -- 전체 Quote 배열
    recorded_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
SELECT create_hypertable('market_snapshots', 'recorded_at');

-- 보존 정책
-- market_quotes: 30일 보존 후 자동 삭제
-- market_ohlcv: 영구 보존
-- market_snapshots: 7일 보존
SELECT add_retention_policy('market_quotes', INTERVAL '30 days');
SELECT add_retention_policy('market_snapshots', INTERVAL '7 days');
```

---

## 4. Store 2: PortfolioStore

```sql
-- ============================================================
-- PortfolioStore — 포지션, 손익, 체결
-- Writer: Path 1B OrderExecutor, 1C PositionMonitor, 4 PositionAggregator
-- Reader: Path 1, 4, 5
-- ============================================================

-- 4.1 포지션
CREATE TABLE positions (
    symbol          TEXT NOT NULL,
    strategy_id     TEXT NOT NULL,
    side            TEXT NOT NULL DEFAULT 'long',
    quantity        INT NOT NULL,
    avg_price       FLOAT NOT NULL,
    entry_date      DATE NOT NULL,
    updated_at      TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (symbol, strategy_id)
);
CREATE TRIGGER trg_positions_updated
    BEFORE UPDATE ON positions
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- 4.2 체결 기록
CREATE TABLE trades (
    trade_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id        TEXT NOT NULL,
    symbol          TEXT NOT NULL,
    side            TEXT NOT NULL,          -- "buy" | "sell"
    quantity        INT NOT NULL,
    price           FLOAT NOT NULL,
    commission      FLOAT DEFAULT 0,
    securities_tax  FLOAT DEFAULT 0,
    strategy_id     TEXT,
    slippage_bps    FLOAT,                 -- 슬리피지 (bps)
    traded_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_trades_symbol ON trades(symbol, traded_at DESC);
CREATE INDEX idx_trades_strategy ON trades(strategy_id, traded_at DESC);
CREATE INDEX idx_trades_order ON trades(order_id);

-- 4.3 일일 손익
CREATE TABLE daily_pnl (
    date            DATE PRIMARY KEY,
    total_equity    FLOAT NOT NULL,
    cash            FLOAT NOT NULL,
    invested        FLOAT,
    daily_pnl       FLOAT NOT NULL,
    daily_return_pct FLOAT NOT NULL,
    realized_pnl    FLOAT,
    unrealized_pnl  FLOAT,
    by_strategy     JSONB,                 -- {"ma_cross": 50000, "breakout": -20000}
    by_symbol       JSONB,                 -- {"005930": 30000}
    recorded_at     TIMESTAMPTZ DEFAULT NOW()
);

-- 4.4 리밸런싱 이력
CREATE TABLE rebalance_history (
    rebalance_id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    trigger_type    TEXT NOT NULL,          -- "scheduled" | "drift" | "manual"
    before_snapshot JSONB,
    after_snapshot  JSONB,
    orders_executed JSONB,
    executed_at     TIMESTAMPTZ DEFAULT NOW()
);

-- 4.5 리스크 이벤트
CREATE TABLE risk_events (
    event_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    event_type      TEXT NOT NULL,          -- "order_rejected" | "trading_halted" | "limit_breach"
    symbol          TEXT,
    details         JSONB NOT NULL,
    resolved        BOOLEAN DEFAULT FALSE,
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    resolved_at     TIMESTAMPTZ
);
CREATE INDEX idx_risk_events_type ON risk_events(event_type, created_at DESC);
```

---

## 5. Store 3: ConfigStore

```sql
-- ============================================================
-- ConfigStore — 시스템 설정 (외부 관리, 런타임 Read Only)
-- Writer: 외부 (YAML 동기화 스크립트 또는 관리자)
-- Reader: 전 Path
-- ============================================================

-- 5.1 시스템 설정 (key-value)
CREATE TABLE system_config (
    config_key      TEXT PRIMARY KEY,
    config_value    JSONB NOT NULL,
    description     TEXT,
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);
CREATE TRIGGER trg_config_updated
    BEFORE UPDATE ON system_config
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- 초기 데이터 예시
INSERT INTO system_config (config_key, config_value, description) VALUES
('risk_limits', '{
    "max_portfolio_loss_pct": -5.0,
    "max_single_position_pct": 20.0,
    "max_sector_exposure_pct": 40.0,
    "max_daily_trades": 50,
    "max_single_order_amount": 50000000
}', '리스크 한도'),
('watchlist_limits', '{
    "max_watching": 30,
    "max_in_position": 10,
    "stale_watching_days": 5,
    "blacklist_default_days": 7,
    "consecutive_loss_blacklist": 3
}', '워치리스트 제한'),
('exit_rules_default', '{
    "stop_loss_pct": -3.0,
    "take_profit_pct": 5.0,
    "trailing_stop_pct": 2.0,
    "trailing_activation_pct": 1.5,
    "max_holding_minutes": 360,
    "force_close_before_close_minutes": 3
}', '기본 청산 규칙'),
('market_close_rules', '{
    "new_order_cutoff_minutes": 3,
    "exit_only_minutes": 10,
    "force_close_minutes": 1
}', '마감 임박 규칙'),
('api_rate_limits', '{
    "kis_rest_per_second": 20,
    "kis_rest_per_minute": 100,
    "llm_per_minute": 30
}', 'API 호출 제한'),
('adapter_config', '{
    "broker": "KISMCPAdapter",
    "market_data": "KISWebSocketAdapter",
    "env": "demo"
}', '어댑터 설정');

-- 5.2 종목 목록 (관심 유니버스)
CREATE TABLE symbol_universe (
    symbol          TEXT PRIMARY KEY,
    name            TEXT NOT NULL,
    market          TEXT NOT NULL,          -- "kospi" | "kosdaq"
    sector          TEXT,
    market_cap      BIGINT,
    is_active       BOOLEAN DEFAULT TRUE,
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);

-- 5.3 스케줄 설정
CREATE TABLE schedules (
    schedule_id     TEXT PRIMARY KEY,
    cron_expr       TEXT NOT NULL,          -- "0 6 * * 1-5"
    target_node     TEXT NOT NULL,          -- "external_collector"
    params          JSONB,
    enabled         BOOLEAN DEFAULT TRUE,
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);
```

---

## 6. Store 4: KnowledgeStore

```sql
-- ============================================================
-- KnowledgeStore — 온톨로지, 인과관계
-- Writer: Path 2 OntologyMapper, CausalReasoner
-- Reader: Path 1A, 2, 3
-- ============================================================

-- 6.1 온톨로지 트리플
CREATE TABLE ontology_triples (
    triple_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    subject         TEXT NOT NULL,
    predicate       TEXT NOT NULL,
    object          TEXT NOT NULL,
    source_id       TEXT NOT NULL,
    confidence      FLOAT NOT NULL CHECK (confidence BETWEEN 0 AND 1),
    valid_from      TIMESTAMPTZ NOT NULL,
    valid_until     TIMESTAMPTZ,           -- NULL = 현재 유효
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE(subject, predicate, object, source_id)
);
CREATE INDEX idx_triples_subject ON ontology_triples(subject);
CREATE INDEX idx_triples_predicate ON ontology_triples(predicate);
CREATE INDEX idx_triples_object ON ontology_triples(object);
CREATE INDEX idx_triples_valid ON ontology_triples(valid_from, valid_until);
CREATE INDEX idx_triples_confidence ON ontology_triples(confidence) WHERE valid_until IS NULL;

-- 6.2 인과 관계
CREATE TABLE causal_links (
    link_id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    cause           TEXT NOT NULL,
    effect          TEXT NOT NULL,
    mechanism       TEXT,
    strength        FLOAT NOT NULL CHECK (strength BETWEEN 0 AND 1),
    confidence      FLOAT NOT NULL CHECK (confidence BETWEEN 0 AND 1),
    evidence_ids    TEXT[] NOT NULL,
    temporal_lag    TEXT,                   -- "1Q" | "즉시" | "6개월"
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    expires_at      TIMESTAMPTZ
);
CREATE INDEX idx_causal_cause ON causal_links(cause);
CREATE INDEX idx_causal_effect ON causal_links(effect);
CREATE INDEX idx_causal_confidence ON causal_links(confidence DESC);

-- 6.3 파싱된 문서
CREATE TABLE parsed_documents (
    source_id       TEXT PRIMARY KEY,
    source_type     TEXT NOT NULL,
    title           TEXT,
    summary         TEXT,
    key_metrics     JSONB,
    sentiment       FLOAT,
    entities        JSONB,
    relations       JSONB,
    embedding       vector(1024),          -- pgvector 임베딩 (검색용)
    parsed_at       TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_parsed_type ON parsed_documents(source_type);
CREATE INDEX idx_parsed_embedding ON parsed_documents USING ivfflat (embedding vector_cosine_ops)
    WITH (lists = 100);
```

---

## 7. Store 5: StrategyStore

```sql
-- ============================================================
-- StrategyStore — 전략 코드, 백테스트, 최적화
-- Writer: Path 3 StrategyRegistry
-- Reader: Path 1B StrategyLoader, Path 3
-- ============================================================

-- 7.1 전략 메타데이터
CREATE TABLE strategies (
    strategy_id     TEXT PRIMARY KEY,
    name            TEXT NOT NULL,
    version         TEXT NOT NULL,
    strategy_type   TEXT NOT NULL,
    status          TEXT NOT NULL DEFAULT 'draft',
    author          TEXT DEFAULT 'system',
    description     TEXT,
    params_def      JSONB NOT NULL,
    target_symbols  TEXT[],
    target_timeframe TEXT DEFAULT '1d',
    tags            TEXT[],
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);
CREATE TRIGGER trg_strategies_updated
    BEFORE UPDATE ON strategies
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE INDEX idx_strategies_status ON strategies(status);

-- 7.2 전략 소스 코드 (버전별)
CREATE TABLE strategy_codes (
    strategy_id     TEXT NOT NULL,
    version         TEXT NOT NULL,
    source_code     TEXT NOT NULL,
    entry_class     TEXT NOT NULL,
    dependencies    TEXT[],
    checksum        TEXT NOT NULL,          -- SHA256
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (strategy_id, version)
);

-- 7.3 백테스트 결과
CREATE TABLE backtest_results (
    result_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    strategy_id     TEXT NOT NULL,
    version         TEXT NOT NULL,
    config          JSONB NOT NULL,
    total_return    FLOAT,
    cagr            FLOAT,
    sharpe_ratio    FLOAT,
    sortino_ratio   FLOAT,
    max_drawdown    FLOAT,
    calmar_ratio    FLOAT,
    win_rate        FLOAT,
    profit_factor   FLOAT,
    total_trades    INT,
    alpha           FLOAT,
    beta            FLOAT,
    information_ratio FLOAT,
    trades          JSONB,
    equity_curve    JSONB,
    duration_seconds FLOAT,
    executed_at     TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_backtest_strategy ON backtest_results(strategy_id, version);

-- 7.4 최적화 결과
CREATE TABLE optimization_results (
    optimization_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    strategy_id     TEXT NOT NULL,
    config          JSONB NOT NULL,
    best_params     JSONB NOT NULL,
    best_score      FLOAT,
    all_trials      JSONB,
    param_importance JSONB,
    overfitting_score FLOAT,
    duration_seconds FLOAT,
    executed_at     TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_optimization_strategy ON optimization_results(strategy_id);
```

---

## 8. Store 6: AuditStore

```sql
-- ============================================================
-- AuditStore — 불변 감사 로그
-- Writer: Path 5 AuditLogger (APPEND ONLY)
-- Reader: Path 5 (READ ONLY)
-- ============================================================

-- 8.1 감사 이벤트 (불변 — DELETE/UPDATE 금지)
CREATE TABLE audit_events (
    event_id        UUID PRIMARY KEY,
    event_type      TEXT NOT NULL,
    severity        TEXT NOT NULL,          -- "info" | "warning" | "error" | "critical"
    source_path     TEXT NOT NULL,
    source_node     TEXT NOT NULL,
    event_timestamp TIMESTAMPTZ NOT NULL,
    actor           TEXT NOT NULL,
    payload         JSONB NOT NULL,
    correlation_id  UUID,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);
SELECT create_hypertable('audit_events', 'event_timestamp');

-- 불변 트리거
CREATE OR REPLACE FUNCTION prevent_audit_modification()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'Audit events are immutable. DELETE and UPDATE are prohibited.';
END;
$$ LANGUAGE plpgsql;
CREATE TRIGGER no_modify_audit
    BEFORE UPDATE OR DELETE ON audit_events
    FOR EACH ROW EXECUTE FUNCTION prevent_audit_modification();

CREATE INDEX idx_audit_type ON audit_events(event_type, event_timestamp DESC);
CREATE INDEX idx_audit_correlation ON audit_events(correlation_id);
CREATE INDEX idx_audit_source ON audit_events(source_path, source_node);
CREATE INDEX idx_audit_severity ON audit_events(severity, event_timestamp DESC);

-- 보존 정책: 90일 보존 후 cold storage 이동 (삭제 아님)
-- SELECT add_retention_policy('audit_events', INTERVAL '90 days');

-- 8.2 헬스 체크 이력
CREATE TABLE health_history (
    id              BIGSERIAL,
    component_id    TEXT NOT NULL,
    component_type  TEXT NOT NULL,
    status          TEXT NOT NULL,
    latency_ms      INT,
    message         TEXT,
    checked_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
SELECT create_hypertable('health_history', 'checked_at');
SELECT add_retention_policy('health_history', INTERVAL '30 days');
CREATE INDEX idx_health_component ON health_history(component_id, checked_at DESC);

-- 8.3 알림 발송 이력
CREATE TABLE alert_history (
    alert_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    priority        TEXT NOT NULL,
    title           TEXT NOT NULL,
    body            TEXT,
    channels        TEXT[] NOT NULL,
    delivery_results JSONB,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

-- 8.4 명령 실행 이력
CREATE TABLE command_history (
    command_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    command_type    TEXT NOT NULL,
    risk_level      TEXT NOT NULL,
    issuer          TEXT NOT NULL,
    params          JSONB,
    result          TEXT NOT NULL,
    message         TEXT,
    issued_at       TIMESTAMPTZ,
    executed_at     TIMESTAMPTZ DEFAULT NOW()
);

-- 8.5 이상 감지 이력
CREATE TABLE anomaly_history (
    anomaly_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    anomaly_type    TEXT NOT NULL,
    severity        TEXT NOT NULL,
    description     TEXT,
    affected_components TEXT[],
    evidence        JSONB,
    suggested_action TEXT,
    resolved        BOOLEAN DEFAULT FALSE,
    resolution      TEXT,
    detected_at     TIMESTAMPTZ DEFAULT NOW(),
    resolved_at     TIMESTAMPTZ
);
CREATE INDEX idx_anomaly_type ON anomaly_history(anomaly_type, detected_at DESC);
```

---

## 9. Store 7: WatchlistStore

```sql
-- ============================================================
-- WatchlistStore — 관심종목 생명주기
-- Writer: Path 1A WatchlistManager
-- Reader: Path 1C
-- ============================================================

-- 9.1 워치리스트
CREATE TABLE watchlist (
    symbol          TEXT PRIMARY KEY,
    name            TEXT NOT NULL,
    status          TEXT NOT NULL DEFAULT 'candidate',
    priority        INT NOT NULL DEFAULT 50,
    source          TEXT NOT NULL,
    screener_score  FLOAT DEFAULT 0.0,
    entry_conditions JSONB,
    price_at_add    FLOAT,
    consecutive_losses INT DEFAULT 0,
    blacklisted_until TIMESTAMPTZ,
    metadata        JSONB DEFAULT '{}',
    added_at        TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);
CREATE TRIGGER trg_watchlist_updated
    BEFORE UPDATE ON watchlist
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE INDEX idx_watchlist_status ON watchlist(status);
CREATE INDEX idx_watchlist_priority ON watchlist(status, priority DESC);

-- 9.2 상태 전이 이력
CREATE TABLE watchlist_history (
    id              BIGSERIAL PRIMARY KEY,
    symbol          TEXT NOT NULL,
    old_status      TEXT,
    new_status      TEXT NOT NULL,
    reason          TEXT,
    metadata        JSONB,
    changed_at      TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_wh_symbol ON watchlist_history(symbol, changed_at DESC);

-- 9.3 청산 이력
CREATE TABLE exit_history (
    exit_id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    symbol          TEXT NOT NULL,
    exit_type       TEXT NOT NULL,
    entry_price     FLOAT NOT NULL,
    exit_price      FLOAT NOT NULL,
    quantity        INT NOT NULL,
    pnl_pct         FLOAT NOT NULL,
    holding_seconds INT,
    reason          TEXT,
    post_action     TEXT,
    strategy_id     TEXT,
    executed_at     TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_exit_symbol ON exit_history(symbol, executed_at DESC);
CREATE INDEX idx_exit_strategy ON exit_history(strategy_id);

-- 9.4 스크리닝 프로파일
CREATE TABLE screener_profiles (
    profile_id      TEXT PRIMARY KEY,
    name            TEXT NOT NULL,
    market          TEXT NOT NULL DEFAULT 'all',
    conditions      JSONB NOT NULL,
    max_results     INT DEFAULT 30,
    min_score       FLOAT DEFAULT 0.0,
    timeframe       TEXT DEFAULT 'pre_market',
    exclude_symbols TEXT[],
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);
CREATE TRIGGER trg_screener_updated
    BEFORE UPDATE ON screener_profiles
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();
```

---

## 10. Store 8: MarketIntelStore

```sql
-- ============================================================
-- MarketIntelStore — 시장 인텔리전스
-- Writer: Path 6 전체 (5개 노드)
-- Reader: Path 1B/1C, Path 3
-- ============================================================

-- 10.1 수급 스냅샷
CREATE TABLE supply_demand (
    symbol          TEXT NOT NULL,
    foreign_net     INT,
    institution_net INT,
    program_net     INT,
    individual_net  INT,
    volume_power    FLOAT,
    short_sale_ratio FLOAT,
    credit_balance_ratio FLOAT,
    snapshot_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
SELECT create_hypertable('supply_demand', 'snapshot_at');
CREATE INDEX idx_sd_symbol ON supply_demand(symbol, snapshot_at DESC);
SELECT add_retention_policy('supply_demand', INTERVAL '30 days');

-- 10.2 호가 분석
CREATE TABLE orderbook_analysis (
    symbol          TEXT NOT NULL,
    bid_ask_ratio   FLOAT,
    spread_bps      FLOAT,
    large_sell_wall BOOLEAN DEFAULT FALSE,
    large_buy_wall  BOOLEAN DEFAULT FALSE,
    sell_wall_price INT,
    buy_wall_price  INT,
    liquidity_score FLOAT,
    imbalance       TEXT,
    analyzed_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
SELECT create_hypertable('orderbook_analysis', 'analyzed_at');
CREATE INDEX idx_ob_symbol ON orderbook_analysis(symbol, analyzed_at DESC);
SELECT add_retention_policy('orderbook_analysis', INTERVAL '7 days');

-- 10.3 시장 환경
CREATE TABLE market_regime (
    regime          TEXT NOT NULL,
    kospi_pct       FLOAT,
    kosdaq_pct      FLOAT,
    cb_active       BOOLEAN DEFAULT FALSE,
    sidecar_active  BOOLEAN DEFAULT FALSE,
    vi_count        INT DEFAULT 0,
    foreign_net_total BIGINT,
    program_net_total BIGINT,
    sectors         JSONB,
    recorded_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
SELECT create_hypertable('market_regime', 'recorded_at');
SELECT add_retention_policy('market_regime', INTERVAL '90 days');

-- 10.4 종목 상태
CREATE TABLE stock_state (
    symbol          TEXT PRIMARY KEY,
    name            TEXT,
    trading_status  TEXT NOT NULL DEFAULT 'tradable',
    warning_level   TEXT NOT NULL DEFAULT 'none',
    margin_rate     FLOAT DEFAULT 0.4,
    is_credit_ok    BOOLEAN DEFAULT TRUE,
    tick_size       INT,
    upper_limit     INT,
    lower_limit     INT,
    is_ex_dividend  BOOLEAN DEFAULT FALSE,
    is_ex_rights    BOOLEAN DEFAULT FALSE,
    vi_active       BOOLEAN DEFAULT FALSE,
    sector_code     TEXT,
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);
CREATE TRIGGER trg_stock_state_updated
    BEFORE UPDATE ON stock_state
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE INDEX idx_ss_status ON stock_state(trading_status);

-- 10.5 기업 이벤트
CREATE TABLE corporate_events (
    event_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    symbol          TEXT NOT NULL,
    event_type      TEXT NOT NULL,
    record_date     DATE,
    ex_date         DATE,
    details         JSONB,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);
CREATE INDEX idx_ce_symbol ON corporate_events(symbol);
CREATE INDEX idx_ce_ex_date ON corporate_events(ex_date);

-- 10.6 MarketContext 캐시 (종목별 종합)
CREATE TABLE market_context_cache (
    symbol          TEXT PRIMARY KEY,
    context         JSONB NOT NULL,
    entry_safe      BOOLEAN,
    exit_urgent     BOOLEAN,
    caution_reasons TEXT[],
    updated_at      TIMESTAMPTZ DEFAULT NOW()
);
CREATE TRIGGER trg_context_cache_updated
    BEFORE UPDATE ON market_context_cache
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE INDEX idx_mcc_safe ON market_context_cache(entry_safe);
CREATE INDEX idx_mcc_urgent ON market_context_cache(exit_urgent) WHERE exit_urgent = TRUE;
```

---

## 11. 주문 추적 테이블 (PortfolioStore 보조)

order_lifecycle_spec에서 정의한 OrderTracker 영속화.

```sql
-- OrderExecutor가 관리하는 주문 추적 (PortfolioStore에 포함)
CREATE TABLE order_tracker (
    order_id        TEXT PRIMARY KEY,
    symbol          TEXT NOT NULL,
    side            TEXT NOT NULL,
    order_division  TEXT NOT NULL,          -- "00"~"24"
    exchange        TEXT NOT NULL DEFAULT 'KRX',
    state           TEXT NOT NULL DEFAULT 'draft',
    requested_qty   INT NOT NULL,
    filled_qty      INT DEFAULT 0,
    remaining_qty   INT,
    avg_fill_price  FLOAT DEFAULT 0,
    total_commission FLOAT DEFAULT 0,
    strategy_id     TEXT,
    correlation_id  TEXT,                  -- 진입-청산 연결
    fills           JSONB DEFAULT '[]',    -- 부분 체결 이력
    error_code      TEXT,
    error_message   TEXT,
    created_at      TIMESTAMPTZ DEFAULT NOW(),
    submitted_at    TIMESTAMPTZ,
    last_event_at   TIMESTAMPTZ,
    completed_at    TIMESTAMPTZ
);
CREATE INDEX idx_ot_symbol ON order_tracker(symbol, created_at DESC);
CREATE INDEX idx_ot_state ON order_tracker(state) WHERE state NOT IN ('filled', 'cancelled', 'rejected');
CREATE INDEX idx_ot_correlation ON order_tracker(correlation_id);
```

---

## 12. Apache AGE 그래프 (KnowledgeStore 보조)

온톨로지 그래프 탐색용. 관계형 테이블과 병행 사용.

```sql
-- AGE 그래프 생성
SELECT * FROM ag_catalog.create_graph('trading_knowledge');

-- 노드 레이블
SELECT * FROM cypher('trading_knowledge', $$
    CREATE (:Company {symbol: '005930', name: '삼성전자', sector: '반도체'})
$$) AS (v agtype);

-- 관계 레이블
SELECT * FROM cypher('trading_knowledge', $$
    MATCH (a:Company {symbol: '005930'}), (b:Company {symbol: '000660'})
    CREATE (a)-[:COMPETES_WITH {confidence: 0.9}]->(b)
$$) AS (e agtype);

-- 탐색 예시: 삼성전자의 2-hop 이웃
SELECT * FROM cypher('trading_knowledge', $$
    MATCH (a:Company {symbol: '005930'})-[r*1..2]-(b)
    RETURN a.name, type(r), b.name, r.confidence
$$) AS (source agtype, rel agtype, target agtype, conf agtype);
```

---

## 13. 스키마 버전 관리

```sql
CREATE TABLE schema_version (
    version         TEXT PRIMARY KEY,
    description     TEXT,
    applied_at      TIMESTAMPTZ DEFAULT NOW()
);

INSERT INTO schema_version (version, description) VALUES
('1.0.0', 'Initial schema — 8 stores, 33 tables, 3 extensions');
```

---

## 14. 통계 요약

| Store | 테이블 | 인덱스 | Hypertable | 트리거 | 보존정책 |
|-------|--------|--------|-----------|--------|---------|
| MarketDataStore | 3 | 2 | 2 | 0 | 2 |
| PortfolioStore | 5+1 | 5 | 0 | 1 | 0 |
| ConfigStore | 3 | 0 | 0 | 1 | 0 |
| KnowledgeStore | 3 | 7 | 0 | 0 | 0 |
| StrategyStore | 4 | 3 | 0 | 1 | 0 |
| AuditStore | 5 | 5 | 2 | 1 | 1 |
| WatchlistStore | 4 | 4 | 0 | 2 | 0 |
| MarketIntelStore | 6 | 7 | 3 | 2 | 3 |
| **합계** | **34** | **33** | **7** | **8** | **6** |

---

*End of Document — Shared Store DDL v1.0*
*8 Stores | 34 Tables | 33 Indexes | 7 Hypertables | 8 Triggers | 6 Retention Policies*
*PostgreSQL 16 + TimescaleDB + Apache AGE + pgvector*
