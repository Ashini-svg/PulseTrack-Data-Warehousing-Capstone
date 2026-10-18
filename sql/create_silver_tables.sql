-- Silver Event Processing Tables
-- Purpose: Store parsed conversion events and validation errors.
CREATE SCHEMA IF NOT EXISTS silver;

-- Valid conversion events, deduplicated by event_id.
CREATE TABLE IF NOT EXISTS silver.conversion_events (
    event_id TEXT PRIMARY KEY,
    event_type TEXT NOT NULL,
    conversion_id TEXT,
    occurred_at TIMESTAMPTZ,

    log_topic TEXT,
    log_partition INTEGER,
    log_offset BIGINT,
    log_timestamp_ms BIGINT,
    log_key TEXT,

    payload JSONB NOT NULL,
    source_file TEXT NOT NULL,
    line_number INTEGER NOT NULL,
    processed_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Records that fail parsing or validation.
-- Original content remains available in Bronze.
CREATE TABLE IF NOT EXISTS silver.event_log_errors (
    source_file TEXT NOT NULL,
    line_number INTEGER NOT NULL,
    error_reason TEXT NOT NULL,
    processed_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (source_file, line_number)
);



-- ============================================================
-- Silver: Account Managers
-- Standardized account manager data with typed date fields.
-- ============================================================

CREATE TABLE IF NOT EXISTS silver.account_managers (
    am_id TEXT PRIMARY KEY,
    am_name TEXT,
    team TEXT,
    region TEXT,

    hire_date DATE,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ,

    source_ingested_at TIMESTAMPTZ NOT NULL,
    processed_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);




-- ============================================================
-- Silver: Advertisers
-- Standardized advertiser records with validated relationships.
-- ============================================================

CREATE TABLE IF NOT EXISTS silver.advertisers (
    advertiser_id TEXT PRIMARY KEY,
    advertiser_name TEXT NOT NULL,
    vertical TEXT,
    account_manager_id TEXT NOT NULL
        REFERENCES silver.account_managers(am_id),

    status TEXT NOT NULL
        CHECK (status IN ('active', 'paused', 'churned')),

    signup_date DATE,
    billing_country TEXT,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ,

    source_ingested_at TIMESTAMPTZ NOT NULL,
    processed_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);


-- ============================================================
-- Silver: Partners
-- ============================================================

CREATE TABLE IF NOT EXISTS silver.partners (
    partner_id TEXT PRIMARY KEY,
    partner_name TEXT,
    channel TEXT,
    media_buyer TEXT,
    join_date DATE,
    payment_terms TEXT,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ,
    source_ingested_at TIMESTAMPTZ NOT NULL,
    processed_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);


-- ============================================================
-- Silver: Offers
-- ============================================================

CREATE TABLE IF NOT EXISTS silver.offers (
    offer_id TEXT PRIMARY KEY,
    offer_name TEXT,
    advertiser_id TEXT REFERENCES silver.advertisers(advertiser_id),
    vertical TEXT,
    default_payout NUMERIC,
    payout_type TEXT CHECK (payout_type IN ('CPA', 'CPC', 'CPL')),
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ,
    source_ingested_at TIMESTAMPTZ NOT NULL,
    processed_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);


-- ============================================================
-- Silver: Campaigns
-- ============================================================

CREATE TABLE IF NOT EXISTS silver.campaigns (
    campaign_id TEXT PRIMARY KEY,
    campaign_name TEXT,
    offer_id TEXT REFERENCES silver.offers(offer_id),
    advertiser_id TEXT REFERENCES silver.advertisers(advertiser_id),
    price_type TEXT CHECK (
        price_type IN ('CPA', 'CPC', 'CPM', 'FIXED')
    ),
    start_date DATE,
    end_date DATE,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ,
    source_ingested_at TIMESTAMPTZ NOT NULL,
    processed_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);


-- ============================================================
-- Silver: Creatives
-- ============================================================

CREATE TABLE IF NOT EXISTS silver.creatives (
    creative_id TEXT PRIMARY KEY,
    campaign_id TEXT REFERENCES silver.campaigns(campaign_id),
    creative_name TEXT,
    format TEXT,
    size TEXT,
    landing_url TEXT,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ,
    source_ingested_at TIMESTAMPTZ NOT NULL,
    processed_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);



-- ============================================================
-- Silver: Impressions
-- ============================================================

CREATE TABLE IF NOT EXISTS silver.impressions (
    impression_id TEXT PRIMARY KEY,
    campaign_id TEXT,
    creative_id TEXT,
    partner_id_raw TEXT,
    partner_id TEXT,
    partner_match_status TEXT,
    impression_time TIMESTAMPTZ,
    placement_raw TEXT,
    country TEXT,
    device TEXT,
    bot_score NUMERIC,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ,
    source_ingested_at TIMESTAMPTZ NOT NULL,
    processed_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- ============================================================
-- Silver: Clicks
-- ============================================================

CREATE TABLE IF NOT EXISTS silver.clicks (
    click_id TEXT PRIMARY KEY,
    impression_id TEXT,
    campaign_id TEXT,
    creative_id TEXT,
    partner_id_raw TEXT,
    partner_id TEXT,
    partner_match_status TEXT,
    click_time TIMESTAMPTZ,
    ip TEXT,
    user_agent TEXT,
    country TEXT,
    device TEXT,
    is_unique BOOLEAN,
    referrer_raw TEXT,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ,
    source_ingested_at TIMESTAMPTZ NOT NULL,
    processed_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- ============================================================
-- Silver: Conversion History
-- Preserve distinct versions AND repeated source rows.
-- ============================================================

CREATE TABLE IF NOT EXISTS silver.conversion_history (
    history_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    row_fingerprint TEXT NOT NULL,
    duplicate_ordinal INTEGER NOT NULL,

    conversion_id TEXT NOT NULL,
    click_id TEXT,
    campaign_id TEXT,
    advertiser_name TEXT,
    account_manager TEXT,
    campaign_name TEXT,
    partner_id_raw TEXT,
    partner_id TEXT,
    partner_match_status TEXT,
    partner_name TEXT,
    offer_name TEXT,
    price_type TEXT,
    conversion_time TIMESTAMPTZ,
    revenue NUMERIC,
    payout NUMERIC,
    currency TEXT,
    status_raw TEXT,
    status_normalized TEXT,
    country TEXT,
    device TEXT,
    sub_id TEXT,
    is_test BOOLEAN,
    legacy_flag BOOLEAN,
    pixel_fired BOOLEAN,
    internal_note TEXT,
    reserved_1 TEXT,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ,
    source_ingested_at TIMESTAMPTZ NOT NULL,
    processed_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    UNIQUE (row_fingerprint, duplicate_ordinal)
);

-- ============================================================
-- Silver: Conversion Touchpoints
-- ============================================================

CREATE TABLE IF NOT EXISTS silver.conversion_touchpoints (
    touchpoint_id TEXT PRIMARY KEY,
    conversion_id TEXT,
    click_id TEXT,
    touch_position TEXT,
    weight NUMERIC,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ,
    source_ingested_at TIMESTAMPTZ NOT NULL,
    processed_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- ============================================================
-- Silver: Revenue Adjustments
-- ============================================================

CREATE TABLE IF NOT EXISTS silver.revenue_adjustments (
    adjustment_id TEXT PRIMARY KEY,
    conversion_id TEXT,
    delta_amount NUMERIC,
    reason TEXT,
    adjusted_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ,
    source_ingested_at TIMESTAMPTZ NOT NULL,
    processed_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);



-- ============================================================
-- Silver: Transaction Error Quarantine
-- Track source records that fail cleaning or validation.
-- ============================================================


-- ============================================================
-- Silver: Transaction Error Quarantine
-- Preserve invalid records and track resolution history.
-- ============================================================

CREATE TABLE IF NOT EXISTS silver.transaction_errors (
    source_table TEXT NOT NULL,
    source_row_hash TEXT NOT NULL,
    source_record_id TEXT,
    error_reason TEXT NOT NULL,
    raw_record JSONB NOT NULL,

    first_seen_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    last_seen_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    resolution_status TEXT NOT NULL DEFAULT 'open'
        CHECK (resolution_status IN ('open', 'resolved')),
    resolved_at TIMESTAMPTZ,
    resolution_note TEXT,

    PRIMARY KEY (source_table, source_row_hash)
);



-- ============================================================
-- Silver: Transaction Error Resolution
-- Mark a quarantined record as resolved after verification.
-- ============================================================

CREATE OR REPLACE FUNCTION silver.resolve_transaction_error(
    p_source_table TEXT,
    p_source_row_hash TEXT,
    p_resolution_note TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
BEGIN
    -- Require an explanation for audit purposes.
    IF p_resolution_note IS NULL
       OR TRIM(p_resolution_note) = '' THEN
        RAISE EXCEPTION 'Resolution note is required';
    END IF;

    UPDATE silver.transaction_errors
    SET
        resolution_status = 'resolved',
        resolved_at = CURRENT_TIMESTAMP,
        resolution_note = TRIM(p_resolution_note)
    WHERE source_table = p_source_table
      AND source_row_hash = p_source_row_hash
      AND resolution_status = 'open';

    RETURN FOUND;
END;
$$;



-- ============================================================
-- Silver: Advertiser Account Profiles
-- Preserve nested MongoDB-style profile information.
-- ============================================================

CREATE TABLE IF NOT EXISTS silver.advertiser_profiles (
    advertiser_id TEXT PRIMARY KEY
        REFERENCES silver.advertisers(advertiser_id),

    legal_name TEXT,
    display_name TEXT,
    billing_country TEXT,
    billing_currency TEXT,

    contacts JSONB,
    account_manager_history JSONB,
    contract JSONB,

    profile_data JSONB NOT NULL,

    source_file TEXT NOT NULL,
    line_number INTEGER NOT NULL,
    source_ingested_at TIMESTAMPTZ NOT NULL,
    processed_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);


-- ============================================================
-- Silver: Partner Profiles
-- Allow profiles with unresolved partner relationships.
-- ============================================================

CREATE TABLE IF NOT EXISTS silver.partner_profiles (
    profile_partner_id TEXT PRIMARY KEY,

    matched_partner_id TEXT
        REFERENCES silver.partners(partner_id),

    profile_name TEXT,
    contact JSONB,
    channels JSONB,
    payment JSONB,
    tags JSONB,
    joined_at TIMESTAMPTZ,

    profile_data JSONB NOT NULL,

    source_file TEXT NOT NULL,
    line_number INTEGER NOT NULL,
    source_ingested_at TIMESTAMPTZ NOT NULL,
    processed_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);


-- ============================================================
-- Silver: JSONL Profile Error Quarantine
-- Preserve invalid profile lines for investigation.
-- ============================================================

CREATE TABLE IF NOT EXISTS silver.jsonl_profile_errors (
    source_file TEXT NOT NULL,
    line_number INTEGER NOT NULL CHECK (line_number > 0),
    raw_line TEXT NOT NULL,
    error_reason TEXT NOT NULL,

    first_seen_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    last_seen_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    resolution_status TEXT NOT NULL DEFAULT 'open'
        CHECK (resolution_status IN ('open', 'resolved')),
    resolved_at TIMESTAMPTZ,

    PRIMARY KEY (source_file, line_number)
);
