-- ============================================================================
-- PulseTrack — RAW source schema  (Capstone dataset · Zuu Crew DWDF)
-- ============================================================================
-- This is the RELATIONAL source of the PulseTrack capstone — 11 related tables,
-- exactly as they would arrive from the platform's export: UNNORMALIZED,
-- REDUNDANT and DIRTY. It is one of THREE sources generated from the same
-- ground truth (they reconcile exactly):
--   1. this relational export            (data/*.csv  +  this DDL)
--   2. MongoDB "PartnerHub/CRM"          (mongo/*.jsonl — nested reference data)
--   3. a Kafka-style conversion stream   (stream/pulsetrack_conversions.log)
-- Cross-source keys: partner prefix <-> partner_profiles.partner_id;
-- advertiser_id <-> advertiser_accounts.advertiser_id; conversion_id <-> stream key.
--
-- Design notes (deliberate, for teaching):
--   * EVERY column is TEXT. A raw dump is untyped — "$ 214.52", "USD 980.00", "N/A"
--     and epoch timestamps must all load without rejection. Typing/validation
--     is the student's job in the Silver layer.
--   * Timezone convention: all wall-clock timestamps are UTC; epoch values are
--     true UTC epochs of those wall clocks.
--   * There are NO primary keys, foreign keys or constraints. The relationships
--     below are the INTENDED (messy) links; students must discover, clean and
--     enforce them. Some keys are compound, null, or orphaned on purpose.
--   * conversions_raw embeds advertiser / campaign / partner / offer NAMES
--     redundantly and inconsistently — reconciling those against the reference
--     tables IS the normalization exercise.
--   * EVERY table carries created_at / updated_at audit columns (messy like
--     everything else). They enable watermark-based INCREMENTAL extraction,
--     and updated_at is the dedup key on conversions_raw (keep MAX(updated_at)).
--
-- Load (PostgreSQL):
--   createdb pulsetrack_raw
--   psql -d pulsetrack_raw -f pulsetrack_source_schema.sql
--   -- then, from psql, for each table:
--   -- \copy pulsetrack_raw.<table> FROM 'data/<table>.csv' WITH (FORMAT csv, HEADER true)
-- ============================================================================

DROP SCHEMA IF EXISTS pulsetrack_raw CASCADE;
CREATE SCHEMA pulsetrack_raw;
SET search_path TO pulsetrack_raw;

-- ---------------------------------------------------------------- reference / dimension-like
-- 1) account_managers_raw — internal AMs. Clean-ish. The SCD2 subject:
--    an advertiser's owning AM changes over time (see conversions.account_manager).
CREATE TABLE account_managers_raw (

    am_id       TEXT,   -- e.g. AM007
    am_name     TEXT,   -- exactly one null value (AM013 - deliberate)
    team        TEXT,
    region      TEXT,
    hire_date   TEXT,    -- mixed date formats,
    created_at      TEXT,   -- audit: record created (mixed date formats)
    updated_at      TEXT    -- audit: last updated (mixed formats; ~1-3% precede created_at; ~5-6% null)
);

-- 2) advertisers_raw — brands/clients. Shows the CURRENT account_manager_id.
--    advertiser_name has casing inconsistency. A few campaigns carry orphaned
--    advertiser_ids not present here; embedded names in conversions appear only
--    under variant spellings.
CREATE TABLE advertisers_raw (

    advertiser_id       TEXT,   -- ADV0001
    advertiser_name     TEXT,   -- casing variants
    vertical            TEXT,
    account_manager_id  TEXT,   -- -> account_managers_raw.am_id  (current owner)
    status              TEXT,
    signup_date         TEXT,   -- messy dates
    billing_country     TEXT,
    created_at      TEXT,   -- audit: record created (mixed date formats)
    updated_at      TEXT    -- audit: last updated (mixed formats; ~1-3% precede created_at; ~5-6% null)
);

-- 3) partners_raw — affiliates/publishers. CANONICAL partner id is the numeric
--    prefix; conversions/clicks reference compound "<prefix>_<subid>", bare
--    prefix, "plat<hex>", or null. partner_name has nulls/variants.
CREATE TABLE partners_raw (

    partner_id      TEXT,   -- canonical 5-digit numeric prefix
    partner_name    TEXT,   -- ~13% null
    channel         TEXT,   -- casing variants
    media_buyer     TEXT,
    join_date       TEXT,   -- messy dates
    payment_terms   TEXT,
    created_at      TEXT,   -- audit: record created (mixed date formats)
    updated_at      TEXT    -- audit: last updated (mixed formats; ~1-3% precede created_at; ~5-6% null)
);

-- 4) offers_raw — offers/products promoted. offer_name is embedded (redundantly)
--    in conversions and must be reconciled.
CREATE TABLE offers_raw (

    offer_id        TEXT,   -- OFF0001
    offer_name      TEXT,
    advertiser_id   TEXT,   -- -> advertisers_raw.advertiser_id
    vertical        TEXT,
    default_payout  TEXT,   -- money-as-text
    payout_type     TEXT,
    created_at      TEXT,   -- audit: record created (mixed date formats)
    updated_at      TEXT    -- audit: last updated (mixed formats; ~1-3% precede created_at; ~5-6% null)
);

-- 5) campaigns_raw — campaigns promoting an offer. advertiser_id occasionally
--    disagrees with the offer's advertiser (orphan). price_type casing mess.
CREATE TABLE campaigns_raw (

    campaign_id     TEXT,   -- CMP00001
    campaign_name   TEXT,   -- casing variants
    offer_id        TEXT,   -- -> offers_raw.offer_id
    advertiser_id   TEXT,   -- -> advertisers_raw.advertiser_id (some orphaned)
    price_type      TEXT,   -- CPA/CPC/CPM/Fixed + casing noise
    start_date      TEXT,   -- messy dates
    end_date        TEXT,    -- messy dates,
    created_at      TEXT,   -- audit: record created (mixed date formats)
    updated_at      TEXT    -- audit: last updated (mixed formats; ~1-3% precede created_at; ~5-6% null)
);

-- 6) creatives_raw — ads within a campaign.
CREATE TABLE creatives_raw (

    creative_id     TEXT,   -- CRE00001
    campaign_id     TEXT,   -- -> campaigns_raw.campaign_id
    creative_name   TEXT,
    format          TEXT,
    size            TEXT,
    landing_url     TEXT,
    created_at      TEXT,   -- audit: record created (mixed date formats)
    updated_at      TEXT    -- audit: last updated (mixed formats; ~1-3% precede created_at; ~5-6% null)
);

-- ---------------------------------------------------------------- funnel / events
-- 7) impressions_raw — FACTLESS fact, top of funnel (high volume).
--    placement_raw + bot_score are junk/noise columns to ignore.
CREATE TABLE impressions_raw (

    impression_id   TEXT,   -- IMP00000001
    campaign_id     TEXT,   -- -> campaigns_raw.campaign_id
    creative_id     TEXT,   -- -> creatives_raw.creative_id (blank ~5%: campaign without creatives)
    partner_id      TEXT,   -- compound/bare/plat/null
    impression_time TEXT,   -- mixed date formats + timezones
    placement_raw   TEXT,   -- JUNK
    country         TEXT,   -- inconsistent (US/USA/United States/...)
    device          TEXT,   -- inconsistent
    bot_score       TEXT,    -- JUNK,
    created_at      TEXT,   -- audit: record created (mixed date formats)
    updated_at      TEXT    -- audit: last updated (mixed formats; ~1-3% precede created_at; ~5-6% null)
);

-- 8) clicks_raw — click events (funnel middle). ip / user_agent are junk/PII;
--    is_unique is mixed (1/0/true/false/Y/N/blank). ~15% have no impression.
CREATE TABLE clicks_raw (

    click_id        TEXT,   -- CLK00000001
    impression_id   TEXT,   -- -> impressions_raw.impression_id (nullable: "direct")
    campaign_id     TEXT,
    creative_id     TEXT,
    partner_id      TEXT,
    click_time      TEXT,   -- mixed date formats + timezones
    ip              TEXT,   -- JUNK / PII
    user_agent      TEXT,   -- JUNK / PII
    country         TEXT,
    device          TEXT,
    is_unique       TEXT,   -- mixed booleans
    referrer_raw    TEXT,    -- JUNK (nullable),
    created_at      TEXT,   -- audit: record created (mixed date formats)
    updated_at      TEXT    -- audit: last updated (mixed formats; ~1-3% precede created_at; ~5-6% null)
);

-- 9) conversions_raw — TRANSACTIONAL fact and the UNNORMALIZED, DIRTY centrepiece.
--    Embeds advertiser/campaign/partner/offer names (redundant + inconsistent);
--    money as text; dates+tz chaos; ~80% null sub_id; exact + status-snapshot
--    DUPLICATE rows (same conversion_id, evolving status; snapshots carry
--    increasing updated_at — the correct row is MAX(updated_at) per id);
--    negative revenue and payout>revenue anomalies; is_test rows to filter;
--    legacy_flag/pixel_fired/internal_note/reserved_1 are junk columns.
--    account_manager is the AM valid AT conversion time (differs from the
--    advertiser's CURRENT AM for some advertisers -> Slowly Changing Dimension).
CREATE TABLE conversions_raw (

    conversion_id   TEXT,   -- CV0000001 (NOT unique in the raw file — has duplicates)
    click_id        TEXT,   -- -> clicks_raw.click_id (nullable / some orphaned)
    campaign_id     TEXT,   -- -> campaigns_raw.campaign_id
    advertiser_name TEXT,   -- EMBEDDED, redundant, inconsistent casing/variants
    account_manager TEXT,   -- EMBEDDED AM-at-event-time (SCD2 signal)
    campaign_name   TEXT,   -- EMBEDDED, redundant
    partner_id      TEXT,   -- compound/bare/plat/null
    partner_name    TEXT,   -- EMBEDDED, mostly null
    offer_name      TEXT,   -- EMBEDDED, redundant
    price_type      TEXT,
    conversion_time TEXT,   -- mixed date formats + timezones
    revenue         TEXT,   -- money-as-text ($/USD/plain/N/A/blank/negative)
    payout          TEXT,   -- money-as-text
    currency        TEXT,   -- USD/usd/$/US$/blank
    status          TEXT,   -- ~10 spellings/codes for approved/pending/reversed
    country         TEXT,
    device          TEXT,
    sub_id          TEXT,   -- ~80% null
    is_test         TEXT,   -- mixed flag values (test/1/true/0/blank) -> filter TRUTHY rows out
    legacy_flag     TEXT,   -- JUNK
    pixel_fired     TEXT,   -- JUNK
    internal_note   TEXT,   -- JUNK (entirely empty -- drop candidate)
    reserved_1      TEXT,    -- JUNK,
    created_at      TEXT,   -- audit: record created (mixed date formats)
    updated_at      TEXT    -- THE DEDUP KEY: never null, always time-bearing; keep MAX(updated_at) per id
);

-- 10) conversion_touchpoints_raw — BRIDGE (many-to-many): many clicks -> one
--     conversion (multi-touch attribution). weights sum to ~1 per conversion
--     (3-decimal rounding: a 3-touch conversion sums to 0.999).
CREATE TABLE conversion_touchpoints_raw (

    touchpoint_id   TEXT,   -- TP00000001
    conversion_id   TEXT,   -- -> conversions_raw.conversion_id
    click_id        TEXT,   -- -> clicks_raw.click_id
    touch_position  TEXT,   -- first / mid / last
    weight          TEXT,    -- fractional attribution weight,
    created_at      TEXT,   -- audit: record created (mixed date formats)
    updated_at      TEXT    -- audit: last updated (mixed formats; ~1-3% precede created_at; ~5-6% null)
);

-- 11) revenue_adjustments_raw — LATE-ARRIVING revenue edits applied after the
--     conversion (delta can be negative). adjusted_at is later than the
--     conversion; some conversion_id values are orphaned. Drives incremental /
--     idempotent processing and "true revenue = revenue + sum(delta)".
CREATE TABLE revenue_adjustments_raw (

    adjustment_id   TEXT,   -- ADJ0000001
    conversion_id   TEXT,   -- -> conversions_raw.conversion_id (some orphaned)
    delta_amount    TEXT,   -- money-as-text; may be NEGATIVE or blank/'N/A' (stream holds the value)
    reason          TEXT,
    adjusted_at     TEXT,   -- messy date, ~3% null; later than the conversion when present
    created_at      TEXT,   -- audit: record created (mixed date formats)
    updated_at      TEXT    -- audit: last updated (mixed formats; ~1-3% precede created_at; ~5-6% null)
);

-- ============================================================================
-- Intended (messy) relationships — students discover & enforce these in Silver/Gold:
--   creatives -> campaigns -> offers -> advertisers -> account_managers   (snowflake chain)
--   impressions -> clicks -> conversions                                  (funnel)
--   conversion_touchpoints  bridges  conversions <-> clicks               (M:N / multi-touch)
--   revenue_adjustments -> conversions                                    (late-arriving)
-- ============================================================================





