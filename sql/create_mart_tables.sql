-- ============================================================
-- PulseTrack: Business Data Mart
-- Question 7 - Data Mart Design and Implementation
-- Source: Gold Enterprise Data Warehouse
-- ============================================================

BEGIN;

CREATE SCHEMA IF NOT EXISTS mart;

-- ============================================================
-- 1. CAMPAIGN DAILY
-- Grain: One date and campaign
-- ============================================================

CREATE TABLE IF NOT EXISTS mart.campaign_daily (
    date_key BIGINT NOT NULL
        REFERENCES gold.dim_date(date_key),

    campaign_key BIGINT NOT NULL
        REFERENCES gold.dim_campaign(campaign_key),

    impressions BIGINT NOT NULL DEFAULT 0,
    clicks BIGINT NOT NULL DEFAULT 0,

    all_conversions BIGINT NOT NULL DEFAULT 0,
    eligible_conversions BIGINT NOT NULL DEFAULT 0,

    eligible_base_revenue_usd NUMERIC(24, 4)
        NOT NULL DEFAULT 0,

    eligible_adjustment_usd NUMERIC(24, 4)
        NOT NULL DEFAULT 0,

    refreshed_at TIMESTAMPTZ NOT NULL
        DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (date_key, campaign_key)
);


-- ============================================================
-- 2. ADVERTISER DAILY
-- Grain: One date and historical advertiser version
-- ============================================================

CREATE TABLE IF NOT EXISTS mart.advertiser_daily (
    date_key BIGINT NOT NULL
        REFERENCES gold.dim_date(date_key),

    advertiser_key BIGINT NOT NULL
        REFERENCES gold.dim_advertiser(advertiser_key),

    impressions BIGINT NOT NULL DEFAULT 0,
    clicks BIGINT NOT NULL DEFAULT 0,

    all_conversions BIGINT NOT NULL DEFAULT 0,
    eligible_conversions BIGINT NOT NULL DEFAULT 0,

    eligible_base_revenue_usd NUMERIC(24, 4)
        NOT NULL DEFAULT 0,

    eligible_adjustment_usd NUMERIC(24, 4)
        NOT NULL DEFAULT 0,

    refreshed_at TIMESTAMPTZ NOT NULL
        DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (date_key, advertiser_key)
);


-- ============================================================
-- 3. CREATIVE DAILY
-- Grain: One date and creative
-- Attributed conversion metrics use touchpoint weights.
-- ============================================================

CREATE TABLE IF NOT EXISTS mart.creative_daily (
    date_key BIGINT NOT NULL
        REFERENCES gold.dim_date(date_key),

    creative_key BIGINT NOT NULL
        REFERENCES gold.dim_creative(creative_key),

    impressions BIGINT NOT NULL DEFAULT 0,
    clicks BIGINT NOT NULL DEFAULT 0,

    attributed_conversions BIGINT NOT NULL DEFAULT 0,

    weighted_conversion_credit NUMERIC(24, 10)
        NOT NULL DEFAULT 0,

    attributed_revenue_usd NUMERIC(24, 4)
        NOT NULL DEFAULT 0,

    refreshed_at TIMESTAMPTZ NOT NULL
        DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (date_key, creative_key)
);


-- ============================================================
-- 4. PARTNER DAILY
-- Grain: One date and partner group
-- Unresolved partners remain a separate group.
-- ============================================================

CREATE TABLE IF NOT EXISTS mart.partner_daily (
    date_key BIGINT NOT NULL
        REFERENCES gold.dim_date(date_key),

    partner_group_code TEXT NOT NULL,

    partner_key BIGINT
        REFERENCES gold.dim_partner(partner_key),

    clicks BIGINT NOT NULL DEFAULT 0,

    attributed_conversions BIGINT NOT NULL DEFAULT 0,

    weighted_conversion_credit NUMERIC(24, 10)
        NOT NULL DEFAULT 0,

    attributed_revenue_usd NUMERIC(24, 4)
        NOT NULL DEFAULT 0,

    refreshed_at TIMESTAMPTZ NOT NULL
        DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (date_key, partner_group_code),

    CONSTRAINT chk_partner_group
        CHECK (BTRIM(partner_group_code) <> '')
);


-- ============================================================
-- 5. ACCOUNT MANAGER DAILY
-- Grain: Date, historical manager, advertiser version
-- ============================================================

CREATE TABLE IF NOT EXISTS mart.account_manager_daily (
    date_key BIGINT NOT NULL
        REFERENCES gold.dim_date(date_key),

    account_manager_key BIGINT NOT NULL
        REFERENCES gold.dim_account_manager(account_manager_key),

    advertiser_key BIGINT NOT NULL
        REFERENCES gold.dim_advertiser(advertiser_key),

    impressions BIGINT NOT NULL DEFAULT 0,
    clicks BIGINT NOT NULL DEFAULT 0,

    all_conversions BIGINT NOT NULL DEFAULT 0,
    eligible_conversions BIGINT NOT NULL DEFAULT 0,

    eligible_base_revenue_usd NUMERIC(24, 4)
        NOT NULL DEFAULT 0,

    eligible_adjustment_usd NUMERIC(24, 4)
        NOT NULL DEFAULT 0,

    refreshed_at TIMESTAMPTZ NOT NULL
        DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (
        date_key,
        account_manager_key,
        advertiser_key
    )
);


-- ============================================================
-- 6. ADJUSTMENT DAILY
-- Grain: Adjustment date and campaign group
-- Keeps posting-date reporting separate from
-- conversion-date revenue reporting.
-- ============================================================

CREATE TABLE IF NOT EXISTS mart.adjustment_daily (
    date_key BIGINT NOT NULL
        REFERENCES gold.dim_date(date_key),

    campaign_group_code TEXT NOT NULL,

    campaign_key BIGINT
        REFERENCES gold.dim_campaign(campaign_key),

    adjustment_count BIGINT NOT NULL DEFAULT 0,

    matched_adjustment_count BIGINT NOT NULL DEFAULT 0,

    orphan_adjustment_count BIGINT NOT NULL DEFAULT 0,

    eligible_adjustment_usd NUMERIC(24, 4)
        NOT NULL DEFAULT 0,

    adjustments_7d_after_conversion BIGINT
        NOT NULL DEFAULT 0,

    eligible_adjustments_7d_after_conversion_usd NUMERIC(24, 4)
        NOT NULL DEFAULT 0,

    refreshed_at TIMESTAMPTZ NOT NULL
        DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (date_key, campaign_group_code),

    CONSTRAINT chk_campaign_group
        CHECK (BTRIM(campaign_group_code) <> '')
);


-- ============================================================
-- 7. REPORTING INDEXES
-- ============================================================

CREATE INDEX IF NOT EXISTS idx_mart_campaign
    ON mart.campaign_daily(campaign_key, date_key);

CREATE INDEX IF NOT EXISTS idx_mart_advertiser
    ON mart.advertiser_daily(advertiser_key, date_key);

CREATE INDEX IF NOT EXISTS idx_mart_creative
    ON mart.creative_daily(creative_key, date_key);

CREATE INDEX IF NOT EXISTS idx_mart_partner
    ON mart.partner_daily(partner_key, date_key);

CREATE INDEX IF NOT EXISTS idx_mart_manager
    ON mart.account_manager_daily(
        account_manager_key, date_key
    );

CREATE INDEX IF NOT EXISTS idx_mart_adjustment_campaign
    ON mart.adjustment_daily(campaign_key, date_key);

COMMIT;


-- ============================================================
-- 8. VERIFY DATA MART TABLES
-- ============================================================

SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'mart'
  AND table_type = 'BASE TABLE'
ORDER BY table_name;
