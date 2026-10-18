
-- ============================================================
-- PulseTrack: Gold Enterprise Data Warehouse
-- 10 Dimensions, 4 Facts, 1 Attribution Bridge
-- ============================================================

BEGIN;

CREATE SCHEMA IF NOT EXISTS gold;

-- ============================================================
-- 1. DIMENSIONS
-- ============================================================

-- 1.1 Date Dimension
CREATE TABLE IF NOT EXISTS gold.dim_date (
    date_key BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_date DATE NOT NULL UNIQUE,
    year_number INTEGER NOT NULL,
    quarter_number SMALLINT NOT NULL
        CHECK (quarter_number BETWEEN 1 AND 4),
    month_number SMALLINT NOT NULL
        CHECK (month_number BETWEEN 1 AND 12),
    month_name TEXT NOT NULL,
    day_of_month SMALLINT NOT NULL
        CHECK (day_of_month BETWEEN 1 AND 31),
    day_of_week SMALLINT NOT NULL
        CHECK (day_of_week BETWEEN 1 AND 7)
);

-- 1.2 Account Manager Dimension
CREATE TABLE IF NOT EXISTS gold.dim_account_manager (
    account_manager_key BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_manager_id TEXT NOT NULL UNIQUE,
    manager_name TEXT,
    team TEXT,
    region TEXT,
    loaded_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- 1.3 Advertiser Dimension (SCD Type 2)
CREATE TABLE IF NOT EXISTS gold.dim_advertiser (
    advertiser_key BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    advertiser_id TEXT NOT NULL,
    advertiser_name TEXT,
    vertical TEXT,
    account_manager_key BIGINT
        REFERENCES gold.dim_account_manager(account_manager_key),
    billing_country TEXT,
    billing_currency TEXT,
    effective_from TIMESTAMPTZ NOT NULL,
    effective_to TIMESTAMPTZ,
    is_current BOOLEAN NOT NULL DEFAULT TRUE,
    loaded_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT uq_advertiser_version
        UNIQUE (advertiser_id, effective_from),

    CONSTRAINT chk_advertiser_date_range
        CHECK (
            effective_to IS NULL
            OR effective_to > effective_from
        ),

    CONSTRAINT chk_advertiser_current
        CHECK (
            (is_current = TRUE AND effective_to IS NULL)
            OR
            (is_current = FALSE AND effective_to IS NOT NULL)
        )
);

-- Mark technical historical coverage separately
-- from documented account-manager assignments.
ALTER TABLE gold.dim_advertiser
ADD COLUMN IF NOT EXISTS is_inferred BOOLEAN NOT NULL DEFAULT FALSE;

-- Allow only one current version per advertiser.
CREATE UNIQUE INDEX IF NOT EXISTS idx_dim_advertiser_current
    ON gold.dim_advertiser(advertiser_id)
    WHERE is_current = TRUE;

CREATE INDEX IF NOT EXISTS idx_dim_advertiser_history
    ON gold.dim_advertiser(advertiser_id, effective_from, effective_to);

-- 1.4 Partner Dimension
CREATE TABLE IF NOT EXISTS gold.dim_partner (
    partner_key BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    partner_id TEXT NOT NULL UNIQUE,
    partner_name TEXT,
    partner_status TEXT,
    profile_data JSONB,
    loaded_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- 1.5 Offer Dimension
CREATE TABLE IF NOT EXISTS gold.dim_offer (
    offer_key BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    offer_id TEXT NOT NULL UNIQUE,
    offer_name TEXT,
    advertiser_id TEXT,
    offer_status TEXT,
    loaded_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- 1.6 Campaign Dimension
CREATE TABLE IF NOT EXISTS gold.dim_campaign (
    campaign_key BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    campaign_id TEXT NOT NULL UNIQUE,
    campaign_name TEXT,
    advertiser_id TEXT,
    offer_key BIGINT
        REFERENCES gold.dim_offer(offer_key),
    campaign_status TEXT,
    loaded_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- 1.7 Creative Dimension
CREATE TABLE IF NOT EXISTS gold.dim_creative (
    creative_key BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    creative_id TEXT NOT NULL UNIQUE,
    creative_name TEXT,
    creative_format TEXT,
    creative_size TEXT,
    campaign_key BIGINT
        REFERENCES gold.dim_campaign(campaign_key),
    loaded_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- 1.8 Country Dimension
CREATE TABLE IF NOT EXISTS gold.dim_country (
    country_key BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    country_code TEXT NOT NULL UNIQUE,
    country_name TEXT
);

-- 1.9 Device Dimension
CREATE TABLE IF NOT EXISTS gold.dim_device (
    device_key BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    device_code TEXT NOT NULL UNIQUE,
    device_name TEXT
);

-- 1.10 Conversion Status Dimension
CREATE TABLE IF NOT EXISTS gold.dim_conversion_status (
    conversion_status_key BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    status_code TEXT NOT NULL UNIQUE,
    status_name TEXT,
    is_approved BOOLEAN
);


-- ============================================================
-- 2. FACT TABLES
-- ============================================================

-- 2.1 Impression Fact
-- Grain: One row per unique valid impression.
CREATE TABLE IF NOT EXISTS gold.fact_impression (
    impression_key BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    impression_id TEXT NOT NULL UNIQUE,
    impression_timestamp TIMESTAMPTZ,

    date_key BIGINT REFERENCES gold.dim_date(date_key),
    advertiser_key BIGINT REFERENCES gold.dim_advertiser(advertiser_key),
    campaign_key BIGINT REFERENCES gold.dim_campaign(campaign_key),
    creative_key BIGINT REFERENCES gold.dim_creative(creative_key),
    country_key BIGINT REFERENCES gold.dim_country(country_key),
    device_key BIGINT REFERENCES gold.dim_device(device_key),

    impression_count SMALLINT NOT NULL DEFAULT 1
        CHECK (impression_count = 1),

    loaded_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- 2.2 Click Fact
-- Grain: One row per unique valid click.
CREATE TABLE IF NOT EXISTS gold.fact_click (
    click_key BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    click_id TEXT NOT NULL UNIQUE,
    impression_id TEXT,
    click_timestamp TIMESTAMPTZ,

    date_key BIGINT REFERENCES gold.dim_date(date_key),
    advertiser_key BIGINT REFERENCES gold.dim_advertiser(advertiser_key),
    campaign_key BIGINT REFERENCES gold.dim_campaign(campaign_key),
    creative_key BIGINT REFERENCES gold.dim_creative(creative_key),
    partner_key BIGINT REFERENCES gold.dim_partner(partner_key),
    country_key BIGINT REFERENCES gold.dim_country(country_key),
    device_key BIGINT REFERENCES gold.dim_device(device_key),

    click_count SMALLINT NOT NULL DEFAULT 1
        CHECK (click_count = 1),

    loaded_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- 2.3 Conversion Fact
-- Grain: One row per distinct business conversion.
CREATE TABLE IF NOT EXISTS gold.fact_conversion (
    conversion_key BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    conversion_id TEXT NOT NULL UNIQUE,
    conversion_timestamp TIMESTAMPTZ,
    source_updated_at TIMESTAMPTZ,

    date_key BIGINT REFERENCES gold.dim_date(date_key),
    advertiser_key BIGINT REFERENCES gold.dim_advertiser(advertiser_key),
    account_manager_key BIGINT
        REFERENCES gold.dim_account_manager(account_manager_key),
    campaign_key BIGINT REFERENCES gold.dim_campaign(campaign_key),
    conversion_status_key BIGINT
        REFERENCES gold.dim_conversion_status(conversion_status_key),

    original_status TEXT,
    test_status TEXT NOT NULL DEFAULT 'unknown'
        CHECK (test_status IN ('test', 'not_test', 'unknown')),

    base_revenue NUMERIC(20, 4),
    base_payout NUMERIC(20, 4),
    currency_code TEXT,
    original_currency TEXT,

    revenue_eligible BOOLEAN NOT NULL DEFAULT FALSE,

    conversion_count SMALLINT NOT NULL DEFAULT 1
        CHECK (conversion_count = 1),

    loaded_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- 2.4 Revenue Adjustment Fact
-- Grain: One row per unique revenue adjustment event.
CREATE TABLE IF NOT EXISTS gold.fact_revenue_adjustment (
    adjustment_key BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    adjustment_id TEXT NOT NULL UNIQUE,
    conversion_id TEXT,
    conversion_key BIGINT
        REFERENCES gold.fact_conversion(conversion_key),

    adjustment_timestamp TIMESTAMPTZ,
    date_key BIGINT REFERENCES gold.dim_date(date_key),

    adjustment_amount NUMERIC(20, 4),
    adjustment_type TEXT,
    currency_code TEXT,
    original_currency TEXT,

    loaded_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);


-- ============================================================
-- 3. ATTRIBUTION BRIDGE
-- ============================================================

-- Grain: One unique conversion-to-click touchpoint.
CREATE TABLE IF NOT EXISTS gold.bridge_conversion_touchpoint (
    bridge_key BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    touchpoint_id TEXT NOT NULL UNIQUE,

    conversion_id TEXT NOT NULL,
    conversion_key BIGINT
        REFERENCES gold.fact_conversion(conversion_key),

    click_id TEXT,
    click_key BIGINT
        REFERENCES gold.fact_click(click_key),

    touchpoint_position INTEGER
        CHECK (touchpoint_position > 0),

    attribution_weight NUMERIC(18, 10)
        CHECK (
            attribution_weight IS NULL
            OR attribution_weight BETWEEN 0 AND 1
        ),

    attribution_method TEXT,
    loaded_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);


-- ============================================================
-- 4. PERFORMANCE INDEXES
-- ============================================================

CREATE INDEX IF NOT EXISTS idx_fact_impression_date_campaign
    ON gold.fact_impression(date_key, campaign_key);

CREATE INDEX IF NOT EXISTS idx_fact_click_date_campaign
    ON gold.fact_click(date_key, campaign_key);

CREATE INDEX IF NOT EXISTS idx_fact_click_partner
    ON gold.fact_click(partner_key);

CREATE INDEX IF NOT EXISTS idx_fact_conversion_date_campaign
    ON gold.fact_conversion(date_key, campaign_key);

CREATE INDEX IF NOT EXISTS idx_fact_conversion_advertiser
    ON gold.fact_conversion(advertiser_key);

CREATE INDEX IF NOT EXISTS idx_fact_adjustment_conversion
    ON gold.fact_revenue_adjustment(conversion_key);

CREATE INDEX IF NOT EXISTS idx_bridge_conversion
    ON gold.bridge_conversion_touchpoint(conversion_key);

CREATE INDEX IF NOT EXISTS idx_bridge_click
    ON gold.bridge_conversion_touchpoint(click_key);

COMMIT;


-- ============================================================
-- 5. VERIFY GOLD TABLE CREATION
-- ============================================================

SELECT
    table_name
FROM information_schema.tables
WHERE table_schema = 'gold'
  AND table_type = 'BASE TABLE'
ORDER BY table_name;
