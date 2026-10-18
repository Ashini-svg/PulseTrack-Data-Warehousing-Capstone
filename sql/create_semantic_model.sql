-- ============================================================
-- PulseTrack: OLAP / Semantic Analytical Model
-- Question 8
--
-- Source: Data Mart + Gold dimensions
-- No direct access to detailed Gold fact tables
-- ============================================================

BEGIN;

CREATE SCHEMA IF NOT EXISTS semantic;


-- ============================================================
-- 1. DATE HIERARCHY
-- Year -> Quarter -> Month -> Day
-- ============================================================

CREATE OR REPLACE VIEW semantic.date_hierarchy AS
SELECT
    date_key,
    full_date,
    year_number,
    quarter_number,
    month_number,
    month_name,
    day_of_month,
    day_of_week,
    MAKE_DATE(year_number, month_number, 1)
        AS month_start
FROM gold.dim_date;


-- ============================================================
-- 2. ADVERTISER -> CAMPAIGN -> OFFER HIERARCHY
-- Current advertiser name is used only as a label.
-- Historical manager attribution uses the SCD2 keys
-- in the separate performance views.
-- ============================================================

CREATE OR REPLACE VIEW
semantic.advertiser_campaign_offer_hierarchy AS
SELECT
    c.advertiser_id,
    a.advertiser_name,
    c.campaign_key,
    c.campaign_id,
    c.campaign_name,
    c.campaign_status,
    o.offer_key,
    o.offer_id,
    o.offer_name,
    o.offer_status
FROM gold.dim_campaign c
LEFT JOIN gold.dim_advertiser a
    ON a.advertiser_id = c.advertiser_id
   AND a.is_current = TRUE
LEFT JOIN gold.dim_offer o
    ON o.offer_key = c.offer_key;


-- ============================================================
-- 3. CAMPAIGN -> CREATIVE HIERARCHY
-- ============================================================

CREATE OR REPLACE VIEW
semantic.campaign_creative_hierarchy AS
SELECT
    c.campaign_key,
    c.campaign_id,
    c.campaign_name,
    cr.creative_key,
    cr.creative_id,
    cr.creative_name,
    cr.creative_format,
    cr.creative_size
FROM gold.dim_campaign c
LEFT JOIN gold.dim_creative cr
    ON cr.campaign_key = c.campaign_key;


-- ============================================================
-- 4. PARTNER GROUPING
-- Current partner status -> Partner
-- Status is an operational grouping, not a historical
-- organizational hierarchy.
-- ============================================================


CREATE OR REPLACE VIEW semantic.partner_hierarchy AS
SELECT
    p.partner_key,
    p.partner_id,

    COALESCE(
        NULLIF(BTRIM(p.partner_name), ''),
        NULLIF(BTRIM(p.profile_data->>'name'), ''),
        'Unnamed partner key ' || p.partner_key::TEXT
    ) AS partner_name,

    p.partner_status

FROM gold.dim_partner p;


-- ============================================================
-- 5. CAMPAIGN DAILY PERFORMANCE
-- ============================================================

CREATE OR REPLACE VIEW
semantic.campaign_performance_daily AS
SELECT
    d.full_date,
    d.year_number,
    d.quarter_number,
    d.month_number,
    d.month_name,

    m.date_key,
    m.campaign_key,

    c.campaign_id,
    c.campaign_name,
    c.advertiser_id,

    o.offer_key,
    o.offer_id,
    o.offer_name,

    m.impressions,
    m.clicks,
    m.all_conversions,
    m.eligible_conversions,

    m.eligible_base_revenue_usd
        AS revenue_usd,

    m.eligible_adjustment_usd
        AS adjustment_usd,

    (
        m.eligible_base_revenue_usd
        + m.eligible_adjustment_usd
    ) AS adjusted_revenue_usd,

    ROUND(
        100.0 * m.clicks
        / NULLIF(m.impressions, 0),
        4
    ) AS ctr_pct,

    ROUND(
        100.0 * m.eligible_conversions
        / NULLIF(m.clicks, 0),
        4
    ) AS conversion_rate_pct,

    ROUND(
        m.eligible_base_revenue_usd
        / NULLIF(m.clicks, 0),
        4
    ) AS revenue_per_click_usd,

    ROUND(
        m.eligible_base_revenue_usd
        / NULLIF(m.eligible_conversions, 0),
        4
    ) AS revenue_per_conversion_usd

FROM mart.campaign_daily m
JOIN gold.dim_date d
    ON d.date_key = m.date_key
JOIN gold.dim_campaign c
    ON c.campaign_key = m.campaign_key
LEFT JOIN gold.dim_offer o
    ON o.offer_key = c.offer_key;


-- ============================================================
-- 6. ADVERTISER DAILY PERFORMANCE
-- Historical SCD Type 2 version is preserved.
-- ============================================================

CREATE OR REPLACE VIEW
semantic.advertiser_performance_daily AS
SELECT
    d.full_date,
    d.year_number,
    d.quarter_number,
    d.month_number,

    m.date_key,
    m.advertiser_key,

    a.advertiser_id,
    a.advertiser_name,
    a.vertical,
    a.billing_country,
    a.effective_from,
    a.effective_to,
    a.is_current,
    a.is_inferred,

    am.account_manager_id,
    am.manager_name,

    m.impressions,
    m.clicks,
    m.all_conversions,
    m.eligible_conversions,

    m.eligible_base_revenue_usd
        AS revenue_usd,

    m.eligible_adjustment_usd
        AS adjustment_usd,

    (
        m.eligible_base_revenue_usd
        + m.eligible_adjustment_usd
    ) AS adjusted_revenue_usd,

    ROUND(
        100.0 * m.clicks
        / NULLIF(m.impressions, 0),
        4
    ) AS ctr_pct,

    ROUND(
        100.0 * m.eligible_conversions
        / NULLIF(m.clicks, 0),
        4
    ) AS conversion_rate_pct

FROM mart.advertiser_daily m
JOIN gold.dim_date d
    ON d.date_key = m.date_key
JOIN gold.dim_advertiser a
    ON a.advertiser_key = m.advertiser_key
LEFT JOIN gold.dim_account_manager am
    ON am.account_manager_key = a.account_manager_key;


-- ============================================================
-- 7. CREATIVE DAILY PERFORMANCE
-- Attribution values are base-revenue measures.
-- ============================================================

CREATE OR REPLACE VIEW
semantic.creative_performance_daily AS
SELECT
    d.full_date,
    d.year_number,
    d.quarter_number,
    d.month_number,

    m.date_key,
    m.creative_key,

    cr.creative_id,
    cr.creative_name,
    cr.creative_format,
    cr.creative_size,

    c.campaign_key,
    c.campaign_id,
    c.campaign_name,

    m.impressions,
    m.clicks,
    m.attributed_conversions,
    m.weighted_conversion_credit,
    m.attributed_revenue_usd,

    ROUND(
        100.0 * m.clicks
        / NULLIF(m.impressions, 0),
        4
    ) AS ctr_pct

FROM mart.creative_daily m
JOIN gold.dim_date d
    ON d.date_key = m.date_key
JOIN gold.dim_creative cr
    ON cr.creative_key = m.creative_key
LEFT JOIN gold.dim_campaign c
    ON c.campaign_key = cr.campaign_key;


-- ============================================================
-- 8. PARTNER DAILY PERFORMANCE
-- Attribution percentages use weighted credit.
-- The unresolved group is included in the denominator.
-- ============================================================

CREATE OR REPLACE VIEW
semantic.partner_performance_daily AS
SELECT
    d.full_date,
    d.year_number,
    d.quarter_number,
    d.month_number,

    m.date_key,
    m.partner_group_code,
    m.partner_key,

   
COALESCE(
    NULLIF(BTRIM(p.partner_id), ''),
    CASE
        WHEN m.partner_key IS NULL THEN 'UNRESOLVED'
        ELSE 'KEY:' || m.partner_key::TEXT
    END
) AS partner_id,

CASE
    WHEN m.partner_key IS NULL
        THEN 'Unresolved partner (no verified key)'

    ELSE COALESCE(
        NULLIF(BTRIM(p.partner_name), ''),
        NULLIF(BTRIM(p.profile_data->>'name'), ''),
        'Unnamed partner key ' || m.partner_key::TEXT
    )
END AS partner_name,


    p.partner_status,

    m.clicks,
    m.attributed_conversions,
    m.weighted_conversion_credit,
    m.attributed_revenue_usd,

    ROUND(
        100.0 * m.weighted_conversion_credit
        / NULLIF(
            SUM(m.weighted_conversion_credit)
            OVER (PARTITION BY m.date_key),
            0
        ),
        4
    ) AS attribution_percentage_pct,

    ROUND(
        100.0 * m.attributed_revenue_usd
        / NULLIF(
            SUM(m.attributed_revenue_usd)
            OVER (PARTITION BY m.date_key),
            0
        ),
        4
    ) AS revenue_contribution_pct

FROM mart.partner_daily m
JOIN gold.dim_date d
    ON d.date_key = m.date_key
LEFT JOIN gold.dim_partner p
    ON p.partner_key = m.partner_key;


-- ============================================================
-- 9. HISTORICAL ACCOUNT-MANAGER PERFORMANCE
-- ============================================================

CREATE OR REPLACE VIEW
semantic.account_manager_performance_daily AS
SELECT
    d.full_date,
    d.year_number,
    d.quarter_number,
    d.month_number,

    m.date_key,
    m.account_manager_key,
    m.advertiser_key,

    am.account_manager_id,
    am.manager_name,
    am.team,
    am.region,

    a.advertiser_id,
    a.advertiser_name,

    m.impressions,
    m.clicks,
    m.all_conversions,
    m.eligible_conversions,

    m.eligible_base_revenue_usd
        AS revenue_usd,

    m.eligible_adjustment_usd
        AS adjustment_usd,

    (
        m.eligible_base_revenue_usd
        + m.eligible_adjustment_usd
    ) AS adjusted_revenue_usd,

    ROUND(
        100.0 * m.clicks
        / NULLIF(m.impressions, 0),
        4
    ) AS ctr_pct

FROM mart.account_manager_daily m
JOIN gold.dim_date d
    ON d.date_key = m.date_key
JOIN gold.dim_account_manager am
    ON am.account_manager_key = m.account_manager_key
JOIN gold.dim_advertiser a
    ON a.advertiser_key = m.advertiser_key;


-- ============================================================
-- 10. REVENUE ADJUSTMENT POSTING-DATE PERFORMANCE
-- ============================================================

CREATE OR REPLACE VIEW
semantic.adjustment_posting_daily AS
SELECT
    d.full_date AS adjustment_date,
    d.year_number,
    d.quarter_number,
    d.month_number,

    m.date_key,
    m.campaign_group_code,
    m.campaign_key,

    c.campaign_id,
    c.campaign_name,

    m.adjustment_count,
    m.matched_adjustment_count,
    m.orphan_adjustment_count,
    m.eligible_adjustment_usd,
    m.adjustments_7d_after_conversion,
    m.eligible_adjustments_7d_after_conversion_usd


FROM mart.adjustment_daily m
JOIN gold.dim_date d
    ON d.date_key = m.date_key
LEFT JOIN gold.dim_campaign c
    ON c.campaign_key = m.campaign_key;


-- ============================================================
-- 11. CAMPAIGN MONTHLY PERFORMANCE
-- Aggregate counts and amounts FIRST.
-- Recalculate KPIs instead of averaging daily percentages.
-- MoM compares consecutive calendar months only.
-- ============================================================

CREATE OR REPLACE VIEW
semantic.campaign_performance_monthly AS

WITH monthly AS (
    SELECT
        MAKE_DATE(year_number, month_number, 1)
            AS month_start,

        campaign_key,
        campaign_id,
        campaign_name,
        advertiser_id,

        SUM(impressions) AS impressions,
        SUM(clicks) AS clicks,
        SUM(all_conversions) AS all_conversions,
        SUM(eligible_conversions) AS eligible_conversions,

        SUM(revenue_usd) AS revenue_usd,
        SUM(adjustment_usd) AS adjustment_usd,
        SUM(adjusted_revenue_usd) AS adjusted_revenue_usd

    FROM semantic.campaign_performance_daily

    GROUP BY
        MAKE_DATE(year_number, month_number, 1),
        campaign_key,
        campaign_id,
        campaign_name,
        advertiser_id
),
previous_period AS (
    SELECT
        m.*,

        LAG(month_start) OVER (
            PARTITION BY campaign_key
            ORDER BY month_start
        ) AS previous_month_start,

        LAG(adjusted_revenue_usd) OVER (
            PARTITION BY campaign_key
            ORDER BY month_start
        ) AS previous_month_revenue_usd

    FROM monthly m
)
SELECT
    month_start,
    EXTRACT(YEAR FROM month_start)::INTEGER
        AS year_number,
    EXTRACT(MONTH FROM month_start)::INTEGER
        AS month_number,

    campaign_key,
    campaign_id,
    campaign_name,
    advertiser_id,

    impressions,
    clicks,
    all_conversions,
    eligible_conversions,

    revenue_usd,
    adjustment_usd,
    adjusted_revenue_usd,

    ROUND(
        100.0 * clicks
        / NULLIF(impressions, 0),
        4
    ) AS ctr_pct,

    ROUND(
        100.0 * eligible_conversions
        / NULLIF(clicks, 0),
        4
    ) AS conversion_rate_pct,

    previous_month_revenue_usd,

    CASE
        WHEN previous_month_start =
             (month_start - INTERVAL '1 month')::DATE
        THEN ROUND(
            100.0 * (
                adjusted_revenue_usd
                - previous_month_revenue_usd
            ) / NULLIF(previous_month_revenue_usd, 0),
            4
        )
        ELSE NULL
    
    END AS mom_revenue_change_pct,

    EXTRACT(QUARTER FROM month_start)::SMALLINT
        AS quarter_number

FROM previous_period;


-- ============================================================
-- 12. DOCUMENT IMPORTANT MEASURE DEFINITIONS
-- ============================================================

COMMENT ON VIEW semantic.campaign_performance_daily IS
'Campaign-date measures. Conversion rate uses revenue-eligible conversions divided by same-date clicks; it is not a click-cohort conversion rate. Confirmed USD revenue only.';

COMMENT ON VIEW semantic.creative_performance_daily IS
'Creative-date performance. Attributed revenue excludes unresolved creative touchpoints and excludes revenue adjustments. Attributed conversion counts are not additive across creatives.';

COMMENT ON VIEW semantic.partner_performance_daily IS
'Partner-date performance. Attribution shares include unresolved partner group. Weighted conversion credit is additive; distinct attributed-conversion counts are not additive across partners.';

COMMENT ON VIEW semantic.account_manager_performance_daily IS
'Historical manager attribution based on advertiser SCD2 surrogate keys; inferred historical periods without verified managers are excluded from manager-specific reporting.';

COMMENT ON VIEW semantic.campaign_performance_monthly IS
'Monthly sums of daily additive measures with recalculated rates. Month-over-month comparison requires consecutive months.';


-- ============================================================
-- PARTNER CHANNEL HIERARCHY
-- Channel -> Partner
-- A partner may belong to several channels.
-- Equal channel weights prevent duplicate aggregation.
-- ============================================================

CREATE OR REPLACE VIEW
semantic.partner_channel_hierarchy AS

WITH memberships AS (
    SELECT
        p.partner_key,
        p.partner_id,

        COALESCE(
            NULLIF(BTRIM(p.partner_name), ''),
            NULLIF(BTRIM(p.profile_data->>'name'), ''),
            'Unnamed partner key ' || p.partner_key::TEXT
        ) AS partner_name,

        COALESCE(
            channel_data.channel_name,
            'Unspecified channel'
        ) AS channel_name

    FROM gold.dim_partner p

    LEFT JOIN LATERAL (
        SELECT DISTINCT
            NULLIF(BTRIM(ch.value), '') AS channel_name

        FROM JSONB_ARRAY_ELEMENTS_TEXT(
            CASE
                WHEN JSONB_TYPEOF(
                    p.profile_data->'channels'
                ) = 'array'
                THEN p.profile_data->'channels'
                ELSE '[]'::JSONB
            END
        ) AS ch(value)

        WHERE NULLIF(BTRIM(ch.value), '') IS NOT NULL
    ) channel_data ON TRUE
),
weighted AS (
    SELECT
        *,
        COUNT(*) OVER (
            PARTITION BY partner_key
        ) AS channel_count

    FROM memberships
)
SELECT
    partner_key,
    partner_id,
    partner_name,
    channel_name,
    channel_count,

    1.0 / channel_count AS channel_allocation_weight

FROM weighted;


COMMENT ON VIEW semantic.partner_channel_hierarchy IS
'Many-to-many Channel-to-Partner hierarchy from partner JSON profiles. Equal channel weights are an explicit analytical allocation assumption, not observed event-channel attribution.';


-- ============================================================
-- CHANNEL ALLOCATION PERFORMANCE
-- Source: Partner Data Mart and channel hierarchy
--
-- Grain: Date + channel
-- Multi-channel partner measures are allocated equally.
-- Unresolved partners remain a separate group.
-- ============================================================

CREATE OR REPLACE VIEW
semantic.partner_channel_allocation_daily AS

WITH allocated AS (
    SELECT
        m.date_key,
        d.full_date,

        CASE
            WHEN m.partner_key IS NULL
                THEN 'Unresolved partner'
            ELSE COALESCE(
                h.channel_name,
                'Unspecified channel'
            )
        END AS channel_name,

        m.clicks::NUMERIC
            * COALESCE(
                h.channel_allocation_weight, 1
            ) AS allocated_click_credit,

        m.weighted_conversion_credit
            * COALESCE(
                h.channel_allocation_weight, 1
            ) AS allocated_conversion_credit,

        m.attributed_revenue_usd
            * COALESCE(
                h.channel_allocation_weight, 1
            ) AS allocated_revenue_usd

    FROM mart.partner_daily m

    JOIN gold.dim_date d
        ON d.date_key = m.date_key

    LEFT JOIN semantic.partner_channel_hierarchy h
        ON h.partner_key = m.partner_key
)
SELECT
    date_key,
    full_date,
    channel_name,

    SUM(allocated_click_credit)
        AS allocated_click_credit,

    SUM(allocated_conversion_credit)
        AS allocated_conversion_credit,

    SUM(allocated_revenue_usd)
        AS allocated_revenue_usd

FROM allocated
GROUP BY
    date_key,
    full_date,
    channel_name;


COMMENT ON VIEW semantic.partner_channel_allocation_daily IS
'Estimated channel allocation based on equal splitting across each partner profile channel. Not observed channel-specific performance. Unresolved partner measures remain separate.';

COMMIT;


-- ============================================================
-- 13. VERIFY CREATED VIEWS
-- ============================================================

SELECT
    schemaname,
    viewname
FROM pg_views
WHERE schemaname = 'semantic'
ORDER BY viewname;



SELECT
    SUM(adjustments_7d_after_conversion)
        AS late_adjustment_count,

    SUM(eligible_adjustments_7d_after_conversion_usd)
        AS late_adjustment_amount_usd

FROM semantic.adjustment_posting_daily;
