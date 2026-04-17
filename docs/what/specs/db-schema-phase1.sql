-- ============================================================================
-- ATLAS Phase 1 — Database Schema (PostgreSQL 16 + TimescaleDB)
-- ============================================================================
-- Version: 1.0
-- Created: 2026-04-16
-- Scope: docs/what/decisions/011-phase1-scope.md
--
-- Phase 1 테이블 수: 6개
--   1. market_ohlcv      — 일봉/분봉 시세
--   2. trades            — 체결 내역
--   3. positions         — 현재 포지션
--   4. daily_pnl         — 일별 손익
--   5. audit_events      — 감사 로그 (append-only)
--   6. order_tracker     — 주문 추적 (idempotency)
--
-- Phase 2+ 테이블 28개는 본 파일에 포함하지 않음.
-- ============================================================================

-- 구현 여정: Step 09에서 이 DDL 적용. Step 0~8은 InMemoryStorageAdapter. ADR-012 참조.
-- ---------------------------------------------------------------------------
-- 0. Extensions
-- ---------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS timescaledb;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
-- pgvector, AGE 는 Phase 2+


-- ---------------------------------------------------------------------------
-- 1. market_ohlcv — 시세 (hypertable)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS market_ohlcv (
    ts           TIMESTAMPTZ      NOT NULL,
    symbol       VARCHAR(10)      NOT NULL,
    interval     VARCHAR(8)       NOT NULL,   -- '1d', '1m', '5m'
    open         NUMERIC(15, 2)   NOT NULL,
    high         NUMERIC(15, 2)   NOT NULL,
    low          NUMERIC(15, 2)   NOT NULL,
    close        NUMERIC(15, 2)   NOT NULL,
    volume       BIGINT           NOT NULL,
    trading_value NUMERIC(20, 2),
    source       VARCHAR(20)      NOT NULL DEFAULT 'kis_rest',
    ingested_at  TIMESTAMPTZ      NOT NULL DEFAULT NOW(),
    PRIMARY KEY (ts, symbol, interval)
);

SELECT create_hypertable('market_ohlcv', 'ts', if_not_exists => TRUE);

CREATE INDEX IF NOT EXISTS idx_ohlcv_symbol_interval_ts
    ON market_ohlcv (symbol, interval, ts DESC);


-- ---------------------------------------------------------------------------
-- 2. order_tracker — 주문 idempotency + 추적
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS order_tracker (
    order_uuid       UUID             PRIMARY KEY,
    correlation_id   UUID             NOT NULL,
    symbol           VARCHAR(10)      NOT NULL,
    side             VARCHAR(4)       NOT NULL,   -- 'buy', 'sell'
    order_type       VARCHAR(16)      NOT NULL,   -- 'limit', 'market'
    price            NUMERIC(15, 2),
    quantity         INT              NOT NULL,
    strategy_name    VARCHAR(64)      NOT NULL,
    strategy_version VARCHAR(16)      NOT NULL,
    broker           VARCHAR(16)      NOT NULL,   -- 'mock', 'kis_paper', 'kis_live'
    broker_order_id  VARCHAR(32),

    status           VARCHAR(20)      NOT NULL DEFAULT 'submitted',
    -- 'submitted', 'accepted', 'partially_filled', 'filled',
    -- 'cancelled', 'rejected', 'expired'

    filled_quantity  INT              NOT NULL DEFAULT 0,
    avg_fill_price   NUMERIC(15, 2),
    last_error       TEXT,

    created_at       TIMESTAMPTZ      NOT NULL DEFAULT NOW(),
    updated_at       TIMESTAMPTZ      NOT NULL DEFAULT NOW(),

    CHECK (side IN ('buy', 'sell')),
    CHECK (order_type IN ('limit', 'market')),
    CHECK (filled_quantity >= 0 AND filled_quantity <= quantity)
);

CREATE INDEX IF NOT EXISTS idx_order_tracker_status   ON order_tracker (status) WHERE status NOT IN ('filled', 'cancelled', 'rejected', 'expired');
CREATE INDEX IF NOT EXISTS idx_order_tracker_symbol   ON order_tracker (symbol, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_order_tracker_corr     ON order_tracker (correlation_id);


-- ---------------------------------------------------------------------------
-- 3. trades — 체결 내역 (immutable)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS trades (
    trade_id         UUID             PRIMARY KEY DEFAULT uuid_generate_v4(),
    order_uuid       UUID             NOT NULL REFERENCES order_tracker(order_uuid),
    correlation_id   UUID             NOT NULL,
    symbol           VARCHAR(10)      NOT NULL,
    side             VARCHAR(4)       NOT NULL,
    fill_price       NUMERIC(15, 2)   NOT NULL,
    fill_quantity    INT              NOT NULL,
    fee              NUMERIC(15, 2)   NOT NULL DEFAULT 0,
    tax              NUMERIC(15, 2)   NOT NULL DEFAULT 0,    -- 증권거래세 0.23%
    broker_trade_id  VARCHAR(32),
    executed_at      TIMESTAMPTZ      NOT NULL,
    recorded_at      TIMESTAMPTZ      NOT NULL DEFAULT NOW()
);

-- 체결 기록은 수정 불가
CREATE OR REPLACE FUNCTION trades_immutable()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'trades is immutable; no UPDATE/DELETE allowed';
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trades_no_update BEFORE UPDATE ON trades
    FOR EACH ROW EXECUTE FUNCTION trades_immutable();
CREATE TRIGGER trades_no_delete BEFORE DELETE ON trades
    FOR EACH ROW EXECUTE FUNCTION trades_immutable();

CREATE INDEX IF NOT EXISTS idx_trades_symbol_time ON trades (symbol, executed_at DESC);
CREATE INDEX IF NOT EXISTS idx_trades_order       ON trades (order_uuid);
CREATE INDEX IF NOT EXISTS idx_trades_corr        ON trades (correlation_id);


-- ---------------------------------------------------------------------------
-- 4. positions — 현재 보유 포지션
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS positions (
    symbol            VARCHAR(10)      PRIMARY KEY,
    quantity          INT              NOT NULL,
    avg_entry_price   NUMERIC(15, 2)   NOT NULL,
    entry_fee         NUMERIC(15, 2)   NOT NULL DEFAULT 0,
    opened_at         TIMESTAMPTZ      NOT NULL,
    last_updated_at   TIMESTAMPTZ      NOT NULL DEFAULT NOW(),
    fsm_state         VARCHAR(20)      NOT NULL,
    -- 'IDLE', 'ENTRY_PENDING', 'IN_POSITION', 'EXIT_PENDING', 'ERROR', 'SAFE_MODE'
    strategy_name     VARCHAR(64)      NOT NULL,

    CHECK (quantity >= 0),
    CHECK (fsm_state IN ('IDLE', 'ENTRY_PENDING', 'IN_POSITION', 'EXIT_PENDING', 'ERROR', 'SAFE_MODE'))
);

CREATE INDEX IF NOT EXISTS idx_positions_state ON positions (fsm_state);


-- ---------------------------------------------------------------------------
-- 5. daily_pnl — 일별 손익
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS daily_pnl (
    trade_date       DATE             PRIMARY KEY,
    starting_equity  NUMERIC(15, 2)   NOT NULL,
    ending_equity    NUMERIC(15, 2)   NOT NULL,
    realized_pnl     NUMERIC(15, 2)   NOT NULL DEFAULT 0,
    unrealized_pnl   NUMERIC(15, 2)   NOT NULL DEFAULT 0,
    total_fee        NUMERIC(15, 2)   NOT NULL DEFAULT 0,
    total_tax        NUMERIC(15, 2)   NOT NULL DEFAULT 0,
    trade_count      INT              NOT NULL DEFAULT 0,
    win_count        INT              NOT NULL DEFAULT 0,
    loss_count       INT              NOT NULL DEFAULT 0,
    recorded_at      TIMESTAMPTZ      NOT NULL DEFAULT NOW()
);


-- ---------------------------------------------------------------------------
-- 6. audit_events — 감사 로그 (append-only, immutable)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS audit_events (
    event_id         BIGSERIAL        PRIMARY KEY,
    event_type       VARCHAR(40)      NOT NULL,
    -- 'order_submitted', 'order_filled', 'order_rejected',
    -- 'risk_check_failed', 'fsm_transition', 'cli_command',
    -- 'daemon_started', 'daemon_stopped', 'halt_executed',
    -- 'strategy_loaded', 'broker_error', 'system_error'

    severity         VARCHAR(8)       NOT NULL,
    -- 'debug', 'info', 'warn', 'error', 'critical'

    symbol           VARCHAR(10),
    correlation_id   UUID,
    actor            VARCHAR(32),                 -- OS user or 'system'
    payload          JSONB            NOT NULL DEFAULT '{}'::jsonb,
    occurred_at      TIMESTAMPTZ      NOT NULL DEFAULT NOW(),

    CHECK (severity IN ('debug', 'info', 'warn', 'error', 'critical'))
);

-- append-only
CREATE OR REPLACE FUNCTION audit_immutable()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'audit_events is append-only';
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER audit_no_update BEFORE UPDATE ON audit_events
    FOR EACH ROW EXECUTE FUNCTION audit_immutable();
CREATE TRIGGER audit_no_delete BEFORE DELETE ON audit_events
    FOR EACH ROW EXECUTE FUNCTION audit_immutable();

CREATE INDEX IF NOT EXISTS idx_audit_time     ON audit_events (occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_type     ON audit_events (event_type, occurred_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_severity ON audit_events (severity, occurred_at DESC)
    WHERE severity IN ('error', 'critical');
CREATE INDEX IF NOT EXISTS idx_audit_corr     ON audit_events (correlation_id);
CREATE INDEX IF NOT EXISTS idx_audit_symbol   ON audit_events (symbol, occurred_at DESC)
    WHERE symbol IS NOT NULL;


-- ---------------------------------------------------------------------------
-- 업데이트 트리거 (order_tracker, positions)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER order_tracker_updated_at
    BEFORE UPDATE ON order_tracker
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE OR REPLACE FUNCTION set_last_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.last_updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER positions_updated_at
    BEFORE UPDATE ON positions
    FOR EACH ROW EXECUTE FUNCTION set_last_updated_at();


-- ---------------------------------------------------------------------------
-- 편의 뷰
-- ---------------------------------------------------------------------------

-- 오늘의 체결 요약
CREATE OR REPLACE VIEW v_today_trades AS
SELECT
    symbol,
    side,
    COUNT(*)                         AS trade_count,
    SUM(fill_quantity)               AS total_quantity,
    SUM(fill_price * fill_quantity)  AS total_value,
    SUM(fee + tax)                   AS total_cost
FROM trades
WHERE executed_at >= CURRENT_DATE
GROUP BY symbol, side;

-- 미체결 주문
CREATE OR REPLACE VIEW v_open_orders AS
SELECT order_uuid, symbol, side, order_type, price, quantity,
       filled_quantity, status, created_at
FROM order_tracker
WHERE status IN ('submitted', 'accepted', 'partially_filled')
ORDER BY created_at DESC;

-- 최근 오류
CREATE OR REPLACE VIEW v_recent_errors AS
SELECT event_id, event_type, severity, symbol, payload, occurred_at
FROM audit_events
WHERE severity IN ('error', 'critical')
  AND occurred_at >= NOW() - INTERVAL '24 hours'
ORDER BY occurred_at DESC;


-- ---------------------------------------------------------------------------
-- 끝 — Phase 1 스키마 완료
-- ---------------------------------------------------------------------------
-- 검증용 쿼리:
--   SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename;
--   → 예상 6개: audit_events, daily_pnl, market_ohlcv, order_tracker, positions, trades
