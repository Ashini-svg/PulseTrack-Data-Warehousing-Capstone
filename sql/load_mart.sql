-- ============================================================
-- PulseTrack: Business Data Mart Loading
-- Source: Gold Enterprise Data Warehouse only
-- Strategy: Transactional full refresh
-- Transaction managed by scripts/load_mart.py
-- ============================================================

-- ============================================================
-- 1. PREPARE DAILY BUSINESS MEASURES
-- Each fact contributes separately to prevent join fanout.
-- Adjustments are reported here by original conversion date.
-- ============================================================

CREATE TEMP TABLE tmp_mart_activity
ON COMMIT DROP AS

-- Impressions
SELECT
    f.date_key,
    f.campaign_key,
    f.advertiser_key,
    f.creative_key,
    a.account_manager_key,
    NULL::BIGINT AS partner_key,
    f.impression_count::BIGINT AS impressions,
    0::BIGINT AS clicks,
    0::BIGINT AS all_conversions,
    0::BIGINT AS eligible_conversions,
    0::NUMERIC(24, 4) AS eligible_base_revenue_usd,
    0::NUMERIC(24, 4) AS eligible_adjustment_usd
FROM gold.fact_impression f
LEFT JOIN gold.dim_advertiser a
    ON a.advertiser_key = f.advertiser_key
WHERE f.date_key IS NOT NULL

UNION ALL

-- Clicks
SELECT
    f.date_key,
    f.campaign_key,
    f.advertiser_key,
    f.creative_key,
    a.account_manager_key,
    f.partner_key,
    0::BIGINT,
    f.click_count::BIGINT,
    0::BIGINT,
    0::BIGINT,
    0::NUMERIC(24, 4),
    0::NUMERIC(24, 4)
FROM gold.fact_click f
LEFT JOIN gold.dim_advertiser a
    ON a.advertiser_key = f.advertiser_key
WHERE f.date_key IS NOT NULL

UNION ALL

-- Conversions
SELECT
    f.date_key,
    f.campaign_key,
    f.advertiser_key,
    NULL::BIGINT,
    f.account_manager_key,
    NULL::BIGINT,
    0::BIGINT,
    0::BIGINT,
    f.conversion_count::BIGINT,
    CASE
        WHEN f.revenue_eligible
            THEN f.conversion_count::BIGINT
        ELSE 0::BIGINT
    END,
    CASE
        WHEN f.revenue_eligible
            THEN COALESCE(f.base_revenue, 0)
        ELSE 0
    END,
    0::NUMERIC(24, 4)
FROM gold.fact_conversion f
WHERE f.date_key IS NOT NULL

UNION ALL

-- Eligible adjustments, attached to conversion date.
-- Orphan adjustments cannot be assigned to an advertiser.
SELECT
    c.date_key,
    c.campaign_key,
    c.advertiser_key,
    NULL::BIGINT,
    c.account_manager_key,
    NULL::BIGINT,
    0::BIGINT,
    0::BIGINT,
    0::BIGINT,
    0::BIGINT,
    0::NUMERIC(24, 4),
    CASE
        WHEN c.revenue_eligible
         AND r.currency_code = 'USD'
            THEN COALESCE(r.adjustment_amount, 0)
        ELSE 0
    END
FROM gold.fact_revenue_adjustment r
JOIN gold.fact_conversion c
    ON c.conversion_key = r.conversion_key
WHERE c.date_key IS NOT NULL;


-- ============================================================
-- 2. PREPARE NORMALIZED ATTRIBUTION
-- Preserve original weights in Gold.
-- Correct rounded sums such as 0.999 for analytical credit.
-- ============================================================

CREATE TEMP TABLE tmp_mart_touchpoints
ON COMMIT DROP AS

WITH weighted AS (
    SELECT
        c.date_key,
        c.conversion_id,
        c.revenue_eligible,
        c.base_revenue,
        cl.creative_key,
        cl.partner_key,
        b.attribution_weight,

        SUM(b.attribution_weight) OVER (
            PARTITION BY b.conversion_key
        ) AS conversion_weight_total

    FROM gold.bridge_conversion_touchpoint b

    JOIN gold.fact_conversion c
        ON c.conversion_key = b.conversion_key

    JOIN gold.fact_click cl
        ON cl.click_key = b.click_key

    WHERE c.date_key IS NOT NULL
      AND b.attribution_weight BETWEEN 0 AND 1
),
normalized AS (
    SELECT
        *,
        attribution_weight / conversion_weight_total
            AS normalized_weight
    FROM weighted
    WHERE conversion_weight_total > 0
)
SELECT
    date_key,
    conversion_id,
    revenue_eligible,
    creative_key,
    partner_key,
    normalized_weight,

    CASE
        WHEN revenue_eligible
            THEN COALESCE(base_revenue, 0)
                 * normalized_weight
        ELSE 0
    END AS attributed_base_revenue_usd

FROM normalized
WHERE normalized_weight > 0;


-- ============================================================
-- 3. REFRESH ALL SIX DATA MART TABLES
-- This is atomic when executed in one database transaction.
-- ============================================================

TRUNCATE TABLE
    mart.campaign_daily,
    mart.advertiser_daily,
    mart.creative_daily,
    mart.partner_daily,
    mart.account_manager_daily,
    mart.adjustment_daily;


-- ============================================================
-- 4. CAMPAIGN DAILY
-- ============================================================

INSERT INTO mart.campaign_daily (
    date_key,
    campaign_key,
    impressions,
    clicks,
    all_conversions,
    eligible_conversions,
    eligible_base_revenue_usd,
    eligible_adjustment_usd
)
SELECT
    date_key,
    campaign_key,
    SUM(impressions),
    SUM(clicks),
    SUM(all_conversions),
    SUM(eligible_conversions),
    SUM(eligible_base_revenue_usd),
    SUM(eligible_adjustment_usd)
FROM tmp_mart_activity
WHERE campaign_key IS NOT NULL
GROUP BY date_key, campaign_key;


-- ============================================================
-- 5. ADVERTISER DAILY
-- ============================================================

INSERT INTO mart.advertiser_daily (
    date_key,
    advertiser_key,
    impressions,
    clicks,
    all_conversions,
    eligible_conversions,
    eligible_base_revenue_usd,
    eligible_adjustment_usd
)
SELECT
    date_key,
    advertiser_key,
    SUM(impressions),
    SUM(clicks),
    SUM(all_conversions),
    SUM(eligible_conversions),
    SUM(eligible_base_revenue_usd),
    SUM(eligible_adjustment_usd)
FROM tmp_mart_activity
WHERE advertiser_key IS NOT NULL
GROUP BY date_key, advertiser_key;


-- ============================================================
-- 6. CREATIVE DAILY
-- ============================================================

WITH activity AS (
    SELECT
        date_key,
        creative_key,
        SUM(impressions) AS impressions,
        SUM(clicks) AS clicks
    FROM tmp_mart_activity
    WHERE creative_key IS NOT NULL
    GROUP BY date_key, creative_key
),
credit AS (
    SELECT
        date_key,
        creative_key,

        COUNT(DISTINCT conversion_id) FILTER (
            WHERE revenue_eligible
        ) AS attributed_conversions,

        COALESCE(
            SUM(normalized_weight) FILTER (
                WHERE revenue_eligible
            ), 0
        ) AS weighted_conversion_credit,

        SUM(attributed_base_revenue_usd)
            AS attributed_revenue_usd

    FROM tmp_mart_touchpoints
    WHERE creative_key IS NOT NULL
    GROUP BY date_key, creative_key
)
INSERT INTO mart.creative_daily (
    date_key,
    creative_key,
    impressions,
    clicks,
    attributed_conversions,
    weighted_conversion_credit,
    attributed_revenue_usd
)
SELECT
    COALESCE(a.date_key, c.date_key),
    COALESCE(a.creative_key, c.creative_key),
    COALESCE(a.impressions, 0),
    COALESCE(a.clicks, 0),
    COALESCE(c.attributed_conversions, 0),
    COALESCE(c.weighted_conversion_credit, 0),
    COALESCE(c.attributed_revenue_usd, 0)
FROM activity a
FULL OUTER JOIN credit c
    ON c.date_key = a.date_key
   AND c.creative_key = a.creative_key;


-- ============================================================
-- 7. PARTNER DAILY
-- Unverified and missing partner IDs form an unresolved group.
-- ============================================================

WITH activity AS (
    SELECT
        date_key,
        CASE
            WHEN partner_key IS NULL THEN 'UNRESOLVED'
            ELSE 'PARTNER:' || partner_key::TEXT
        END AS partner_group_code,
        partner_key,
        SUM(clicks) AS clicks

    FROM tmp_mart_activity
    WHERE clicks > 0
    GROUP BY
        date_key,
        partner_key
),
credit AS (
    SELECT
        date_key,
        CASE
            WHEN partner_key IS NULL THEN 'UNRESOLVED'
            ELSE 'PARTNER:' || partner_key::TEXT
        END AS partner_group_code,
        partner_key,

        COUNT(DISTINCT conversion_id) FILTER (
            WHERE revenue_eligible
        ) AS attributed_conversions,

        COALESCE(
            SUM(normalized_weight) FILTER (
                WHERE revenue_eligible
            ), 0
        ) AS weighted_conversion_credit,

        SUM(attributed_base_revenue_usd)
            AS attributed_revenue_usd

    FROM tmp_mart_touchpoints
    GROUP BY date_key, partner_key
)
INSERT INTO mart.partner_daily (
    date_key,
    partner_group_code,
    partner_key,
    clicks,
    attributed_conversions,
    weighted_conversion_credit,
    attributed_revenue_usd
)
SELECT
    COALESCE(a.date_key, c.date_key),
    COALESCE(a.partner_group_code, c.partner_group_code),
    COALESCE(a.partner_key, c.partner_key),
    COALESCE(a.clicks, 0),
    COALESCE(c.attributed_conversions, 0),
    COALESCE(c.weighted_conversion_credit, 0),
    COALESCE(c.attributed_revenue_usd, 0)
FROM activity a
FULL OUTER JOIN credit c
    ON c.date_key = a.date_key
   AND c.partner_group_code = a.partner_group_code;


-- ============================================================
-- 8. ACCOUNT MANAGER DAILY
-- Do not assign unknown historical managers to current staff.
-- ============================================================

INSERT INTO mart.account_manager_daily (
    date_key,
    account_manager_key,
    advertiser_key,
    impressions,
    clicks,
    all_conversions,
    eligible_conversions,
    eligible_base_revenue_usd,
    eligible_adjustment_usd
)
SELECT
    date_key,
    account_manager_key,
    advertiser_key,
    SUM(impressions),
    SUM(clicks),
    SUM(all_conversions),
    SUM(eligible_conversions),
    SUM(eligible_base_revenue_usd),
    SUM(eligible_adjustment_usd)
FROM tmp_mart_activity
WHERE account_manager_key IS NOT NULL
  AND advertiser_key IS NOT NULL
GROUP BY
    date_key,
    account_manager_key,
    advertiser_key;


-- ============================================================
-- 9. ADJUSTMENT DAILY
-- Grain: Adjustment posting date + campaign group.
-- Unmatched conversions remain in the unresolved group.
-- ============================================================


-- ============================================================
-- 9. ADJUSTMENT DAILY
-- Grain: Adjustment posting date + campaign group
-- Includes seven-day-late business adjustment measures
-- ============================================================

INSERT INTO mart.adjustment_daily (
    date_key,
    campaign_group_code,
    campaign_key,
    adjustment_count,
    matched_adjustment_count,
    orphan_adjustment_count,
    eligible_adjustment_usd,
    adjustments_7d_after_conversion,
    eligible_adjustments_7d_after_conversion_usd
)
SELECT
    r.date_key,

    CASE
        WHEN c.campaign_key IS NULL THEN 'UNRESOLVED'
        ELSE 'CAMPAIGN:' || c.campaign_key::TEXT
    END AS campaign_group_code,

    c.campaign_key,

    -- All adjustments
    COUNT(*),

    -- Adjustments with a matching conversion
    COUNT(*) FILTER (
        WHERE r.conversion_key IS NOT NULL
    ),

    -- Adjustments without a matching conversion
    COUNT(*) FILTER (
        WHERE r.conversion_key IS NULL
    ),

    -- Confirmed eligible USD adjustments
    COALESCE(
        SUM(
            CASE
                WHEN c.revenue_eligible IS TRUE
                 AND r.currency_code = 'USD'
                    THEN COALESCE(r.adjustment_amount, 0)
                ELSE 0
            END
        ),
        0
    ),

    -- Adjustments dated at least seven days after conversion
    COUNT(*) FILTER (
        WHERE r.adjustment_timestamp >=
              c.conversion_timestamp + INTERVAL '7 days'
    ),

    -- Eligible USD value of those seven-day adjustments
    COALESCE(
        SUM(
            CASE
                WHEN r.adjustment_timestamp >=
                     c.conversion_timestamp + INTERVAL '7 days'
                 AND c.revenue_eligible IS TRUE
                 AND r.currency_code = 'USD'
                    THEN COALESCE(r.adjustment_amount, 0)
                ELSE 0
            END
        ),
        0
    )

FROM gold.fact_revenue_adjustment r

LEFT JOIN gold.fact_conversion c
    ON c.conversion_key = r.conversion_key

WHERE r.date_key IS NOT NULL

GROUP BY
    r.date_key,
    c.campaign_key;
