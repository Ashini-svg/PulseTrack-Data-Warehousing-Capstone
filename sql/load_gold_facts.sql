
-- ============================================================
-- PulseTrack: Gold Fact and Bridge Loading
-- Sources: Cleaned Silver tables
-- Grain: One row per unique business event
-- Transaction is managed by scripts/load_gold.py
-- ============================================================

-- ============================================================
-- 1. IMPRESSION FACT
-- ============================================================

INSERT INTO gold.fact_impression AS target (
    impression_id,
    impression_timestamp,
    date_key,
    advertiser_key,
    campaign_key,
    creative_key,
    country_key,
    device_key
)
SELECT
    i.impression_id,
    i.impression_time,
    d.date_key,
    a.advertiser_key,
    c.campaign_key,
    cr.creative_key,
    co.country_key,
    dv.device_key
FROM silver.impressions i
LEFT JOIN gold.dim_date d
    ON d.full_date =
       (i.impression_time AT TIME ZONE 'UTC')::date
LEFT JOIN gold.dim_campaign c
    ON c.campaign_id = i.campaign_id
LEFT JOIN gold.dim_advertiser a
    ON a.advertiser_id = c.advertiser_id
   AND i.impression_time >= a.effective_from
   AND (
       a.effective_to IS NULL
       OR i.impression_time < a.effective_to
   )
LEFT JOIN gold.dim_creative cr
    ON cr.creative_id = i.creative_id
   AND (
       c.campaign_key IS NULL
       OR cr.campaign_key = c.campaign_key
   )
LEFT JOIN gold.dim_country co
    ON co.country_code = UPPER(BTRIM(i.country))
LEFT JOIN gold.dim_device dv
    ON dv.device_code = LOWER(BTRIM(i.device))
ON CONFLICT (impression_id)
DO UPDATE SET
    impression_timestamp = EXCLUDED.impression_timestamp,
    date_key = EXCLUDED.date_key,
    advertiser_key = EXCLUDED.advertiser_key,
    campaign_key = EXCLUDED.campaign_key,
    creative_key = EXCLUDED.creative_key,
    country_key = EXCLUDED.country_key,
    device_key = EXCLUDED.device_key
WHERE (
    target.impression_timestamp,
    target.date_key,
    target.advertiser_key,
    target.campaign_key,
    target.creative_key,
    target.country_key,
    target.device_key
) IS DISTINCT FROM (
    EXCLUDED.impression_timestamp,
    EXCLUDED.date_key,
    EXCLUDED.advertiser_key,
    EXCLUDED.campaign_key,
    EXCLUDED.creative_key,
    EXCLUDED.country_key,
    EXCLUDED.device_key
);


-- ============================================================
-- 2. CLICK FACT
-- ============================================================

INSERT INTO gold.fact_click AS target (
    click_id,
    impression_id,
    click_timestamp,
    date_key,
    advertiser_key,
    campaign_key,
    creative_key,
    partner_key,
    country_key,
    device_key
)
SELECT
    cl.click_id,
    cl.impression_id,
    cl.click_time,
    d.date_key,
    a.advertiser_key,
    c.campaign_key,
    cr.creative_key,
    p.partner_key,
    co.country_key,
    dv.device_key
FROM silver.clicks cl
LEFT JOIN gold.dim_date d
    ON d.full_date =
       (cl.click_time AT TIME ZONE 'UTC')::date
LEFT JOIN gold.dim_campaign c
    ON c.campaign_id = cl.campaign_id
LEFT JOIN gold.dim_advertiser a
    ON a.advertiser_id = c.advertiser_id
   AND cl.click_time >= a.effective_from
   AND (
       a.effective_to IS NULL
       OR cl.click_time < a.effective_to
   )
LEFT JOIN gold.dim_creative cr
    ON cr.creative_id = cl.creative_id
   AND (
       c.campaign_key IS NULL
       OR cr.campaign_key = c.campaign_key
   )
LEFT JOIN gold.dim_partner p
    ON p.partner_id = cl.partner_id
LEFT JOIN gold.dim_country co
    ON co.country_code = UPPER(BTRIM(cl.country))
LEFT JOIN gold.dim_device dv
    ON dv.device_code = LOWER(BTRIM(cl.device))
ON CONFLICT (click_id)
DO UPDATE SET
    impression_id = EXCLUDED.impression_id,
    click_timestamp = EXCLUDED.click_timestamp,
    date_key = EXCLUDED.date_key,
    advertiser_key = EXCLUDED.advertiser_key,
    campaign_key = EXCLUDED.campaign_key,
    creative_key = EXCLUDED.creative_key,
    partner_key = EXCLUDED.partner_key,
    country_key = EXCLUDED.country_key,
    device_key = EXCLUDED.device_key
WHERE (
    target.impression_id,
    target.click_timestamp,
    target.date_key,
    target.advertiser_key,
    target.campaign_key,
    target.creative_key,
    target.partner_key,
    target.country_key,
    target.device_key
) IS DISTINCT FROM (
    EXCLUDED.impression_id,
    EXCLUDED.click_timestamp,
    EXCLUDED.date_key,
    EXCLUDED.advertiser_key,
    EXCLUDED.campaign_key,
    EXCLUDED.creative_key,
    EXCLUDED.partner_key,
    EXCLUDED.country_key,
    EXCLUDED.device_key
);


-- ============================================================
-- 3. CONVERSION FACT
-- Latest source snapshot per conversion_id.
-- Ambiguous statuses and test flags remain explicit.
-- ============================================================

WITH latest_conversions AS (
    SELECT DISTINCT ON (conversion_id)
        *
    FROM silver.conversion_history
    WHERE conversion_id IS NOT NULL
    ORDER BY
        conversion_id,
        updated_at DESC NULLS LAST,
        created_at DESC NULLS LAST,
        history_id DESC
),
prepared AS (
    SELECT
        h.*,
        CASE
            WHEN UPPER(BTRIM(h.currency)) IN ('USD', 'US$')
                THEN 'USD'
            ELSE NULL
        END AS verified_currency_code,

        CASE
            WHEN h.is_test IS TRUE THEN 'test'
            WHEN h.is_test IS FALSE THEN 'not_test'
            ELSE 'unknown'
        END AS test_classification,

        CASE
            WHEN NULLIF(LOWER(BTRIM(h.status_normalized)), '')
                 IS NOT NULL
                THEN LOWER(BTRIM(h.status_normalized))
            ELSE
                'UNMAPPED:' ||
                COALESCE(
                    NULLIF(LOWER(BTRIM(h.status_raw)), ''),
                    'missing'
                )
        END AS status_code
    FROM latest_conversions h
)
INSERT INTO gold.fact_conversion AS target (
    conversion_id,
    conversion_timestamp,
    source_updated_at,
    date_key,
    advertiser_key,
    account_manager_key,
    campaign_key,
    conversion_status_key,
    original_status,
    test_status,
    base_revenue,
    base_payout,
    currency_code,
    original_currency,
    revenue_eligible
)
SELECT
    h.conversion_id,
    h.conversion_time,
    h.updated_at,
    d.date_key,
    a.advertiser_key,
    a.account_manager_key,
    c.campaign_key,
    s.conversion_status_key,
    h.status_raw,
    h.test_classification,
    h.revenue,
    h.payout,
    h.verified_currency_code,
    h.currency,
 
COALESCE(
    (
        LOWER(BTRIM(h.status_normalized)) = 'approved'
        AND h.is_test IS FALSE
        AND h.verified_currency_code = 'USD'
        AND h.revenue IS NOT NULL
        AND h.revenue >= 0
    ),
    FALSE
) AS revenue_eligible

FROM prepared h
LEFT JOIN gold.dim_date d
    ON d.full_date =
       (h.conversion_time AT TIME ZONE 'UTC')::date
LEFT JOIN gold.dim_campaign c
    ON c.campaign_id = h.campaign_id
LEFT JOIN gold.dim_advertiser a
    ON a.advertiser_id = c.advertiser_id
   AND h.conversion_time >= a.effective_from
   AND (
       a.effective_to IS NULL
       OR h.conversion_time < a.effective_to
   )
LEFT JOIN gold.dim_conversion_status s
    ON s.status_code = h.status_code

ON CONFLICT (conversion_id)
DO UPDATE SET
    conversion_timestamp = EXCLUDED.conversion_timestamp,
    source_updated_at = EXCLUDED.source_updated_at,
    date_key = EXCLUDED.date_key,
    advertiser_key = EXCLUDED.advertiser_key,
    account_manager_key = EXCLUDED.account_manager_key,
    campaign_key = EXCLUDED.campaign_key,
    conversion_status_key = EXCLUDED.conversion_status_key,
    original_status = EXCLUDED.original_status,
    test_status = EXCLUDED.test_status,
    base_revenue = EXCLUDED.base_revenue,
    base_payout = EXCLUDED.base_payout,
    currency_code = EXCLUDED.currency_code,
    original_currency = EXCLUDED.original_currency,
    revenue_eligible = EXCLUDED.revenue_eligible

WHERE (
    target.conversion_timestamp,
    target.source_updated_at,
    target.date_key,
    target.advertiser_key,
    target.account_manager_key,
    target.campaign_key,
    target.conversion_status_key,
    target.original_status,
    target.test_status,
    target.base_revenue,
    target.base_payout,
    target.currency_code,
    target.original_currency,
    target.revenue_eligible
) IS DISTINCT FROM (
    EXCLUDED.conversion_timestamp,
    EXCLUDED.source_updated_at,
    EXCLUDED.date_key,
    EXCLUDED.advertiser_key,
    EXCLUDED.account_manager_key,
    EXCLUDED.campaign_key,
    EXCLUDED.conversion_status_key,
    EXCLUDED.original_status,
    EXCLUDED.test_status,
    EXCLUDED.base_revenue,
    EXCLUDED.base_payout,
    EXCLUDED.currency_code,
    EXCLUDED.original_currency,
    EXCLUDED.revenue_eligible
);


-- ============================================================
-- 4. REVENUE ADJUSTMENT FACT
-- Currency is inherited from a matched conversion as
-- an explicit working assumption; source has no currency.
-- ============================================================

INSERT INTO gold.fact_revenue_adjustment AS target (
    adjustment_id,
    conversion_id,
    conversion_key,
    adjustment_timestamp,
    date_key,
    adjustment_amount,
    adjustment_type,
    currency_code,
    original_currency
)
SELECT
    r.adjustment_id,
    r.conversion_id,
    fc.conversion_key,
    r.adjusted_at,
    d.date_key,
    r.delta_amount,
    NULL,                  -- No distinct type in Silver source
    fc.currency_code,      -- Derived from linked conversion
    NULL                   -- Adjustment source has no currency
FROM silver.revenue_adjustments r
LEFT JOIN gold.fact_conversion fc
    ON fc.conversion_id = r.conversion_id
LEFT JOIN gold.dim_date d
    ON d.full_date =
       (r.adjusted_at AT TIME ZONE 'UTC')::date

ON CONFLICT (adjustment_id)
DO UPDATE SET
    conversion_id = EXCLUDED.conversion_id,
    conversion_key = EXCLUDED.conversion_key,
    adjustment_timestamp = EXCLUDED.adjustment_timestamp,
    date_key = EXCLUDED.date_key,
    adjustment_amount = EXCLUDED.adjustment_amount,
    adjustment_type = EXCLUDED.adjustment_type,
    currency_code = EXCLUDED.currency_code,
    original_currency = EXCLUDED.original_currency

WHERE (
    target.conversion_id,
    target.conversion_key,
    target.adjustment_timestamp,
    target.date_key,
    target.adjustment_amount,
    target.adjustment_type,
    target.currency_code,
    target.original_currency
) IS DISTINCT FROM (
    EXCLUDED.conversion_id,
    EXCLUDED.conversion_key,
    EXCLUDED.adjustment_timestamp,
    EXCLUDED.date_key,
    EXCLUDED.adjustment_amount,
    EXCLUDED.adjustment_type,
    EXCLUDED.currency_code,
    EXCLUDED.original_currency
);


-- ============================================================
-- 5. CONVERSION TOUCHPOINT BRIDGE
-- Preserve original source weights.
-- Do not invent an attribution method.
-- ============================================================

INSERT INTO gold.bridge_conversion_touchpoint AS target (
    touchpoint_id,
    conversion_id,
    conversion_key,
    click_id,
    click_key,
    touchpoint_position,
    attribution_weight,
    attribution_method
)
SELECT
    t.touchpoint_id,
    t.conversion_id,
    fc.conversion_key,
    t.click_id,
    fcl.click_key,

    CASE
        WHEN BTRIM(t.touch_position) ~ '^[0-9]{1,9}$'
            THEN NULLIF(BTRIM(t.touch_position)::integer, 0)
        ELSE NULL
    END AS touchpoint_position,

    t.weight,
    NULL AS attribution_method

FROM silver.conversion_touchpoints t
LEFT JOIN gold.fact_conversion fc
    ON fc.conversion_id = t.conversion_id
LEFT JOIN gold.fact_click fcl
    ON fcl.click_id = t.click_id

ON CONFLICT (touchpoint_id)
DO UPDATE SET
    conversion_id = EXCLUDED.conversion_id,
    conversion_key = EXCLUDED.conversion_key,
    click_id = EXCLUDED.click_id,
    click_key = EXCLUDED.click_key,
    touchpoint_position = EXCLUDED.touchpoint_position,
    attribution_weight = EXCLUDED.attribution_weight,
    attribution_method = EXCLUDED.attribution_method

WHERE (
    target.conversion_id,
    target.conversion_key,
    target.click_id,
    target.click_key,
    target.touchpoint_position,
    target.attribution_weight,
    target.attribution_method
) IS DISTINCT FROM (
    EXCLUDED.conversion_id,
    EXCLUDED.conversion_key,
    EXCLUDED.click_id,
    EXCLUDED.click_key,
    EXCLUDED.touchpoint_position,
    EXCLUDED.attribution_weight,
    EXCLUDED.attribution_method
);
