-- ============================================================
-- PulseTrack: Data Mart Quality Verification
-- Question 7 - Gold-to-Mart Reconciliation
-- ============================================================

WITH checks (metric, expected_value, actual_value) AS (
    VALUES
    (
        'Campaign impressions',
        (SELECT COALESCE(SUM(impression_count), 0)
         FROM gold.fact_impression
         WHERE date_key IS NOT NULL
           AND campaign_key IS NOT NULL),
        (SELECT COALESCE(SUM(impressions), 0)
         FROM mart.campaign_daily)
    ),
    (
        'Campaign clicks',
        (SELECT COALESCE(SUM(click_count), 0)
         FROM gold.fact_click
         WHERE date_key IS NOT NULL
           AND campaign_key IS NOT NULL),
        (SELECT COALESCE(SUM(clicks), 0)
         FROM mart.campaign_daily)
    ),
    (
        'Campaign all conversions',
        (SELECT COUNT(*)
         FROM gold.fact_conversion
         WHERE date_key IS NOT NULL
           AND campaign_key IS NOT NULL),
        (SELECT COALESCE(SUM(all_conversions), 0)
         FROM mart.campaign_daily)
    ),
    (
        'Campaign eligible conversions',
        (SELECT COUNT(*)
         FROM gold.fact_conversion
         WHERE date_key IS NOT NULL
           AND campaign_key IS NOT NULL
           AND revenue_eligible IS TRUE),
        (SELECT COALESCE(SUM(eligible_conversions), 0)
         FROM mart.campaign_daily)
    ),
    (
        'Campaign eligible base revenue USD',
        (SELECT COALESCE(SUM(base_revenue), 0)
         FROM gold.fact_conversion
         WHERE date_key IS NOT NULL
           AND campaign_key IS NOT NULL
           AND revenue_eligible IS TRUE),
        (SELECT COALESCE(SUM(eligible_base_revenue_usd), 0)
         FROM mart.campaign_daily)
    ),
    (
        'Campaign eligible adjustment USD',
        (SELECT COALESCE(SUM(r.adjustment_amount), 0)
         FROM gold.fact_revenue_adjustment r
         JOIN gold.fact_conversion c
           ON c.conversion_key = r.conversion_key
         WHERE c.date_key IS NOT NULL
           AND c.campaign_key IS NOT NULL
           AND c.revenue_eligible IS TRUE
           AND r.currency_code = 'USD'),
        (SELECT COALESCE(SUM(eligible_adjustment_usd), 0)
         FROM mart.campaign_daily)
    ),
    (
        'Advertiser impressions',
        (SELECT COALESCE(SUM(impression_count), 0)
         FROM gold.fact_impression
         WHERE date_key IS NOT NULL
           AND advertiser_key IS NOT NULL),
        (SELECT COALESCE(SUM(impressions), 0)
         FROM mart.advertiser_daily)
    ),
    (
        'Advertiser clicks',
        (SELECT COALESCE(SUM(click_count), 0)
         FROM gold.fact_click
         WHERE date_key IS NOT NULL
           AND advertiser_key IS NOT NULL),
        (SELECT COALESCE(SUM(clicks), 0)
         FROM mart.advertiser_daily)
    ),
    (
        'Creative impressions',
        (SELECT COALESCE(SUM(impression_count), 0)
         FROM gold.fact_impression
         WHERE date_key IS NOT NULL
           AND creative_key IS NOT NULL),
        (SELECT COALESCE(SUM(impressions), 0)
         FROM mart.creative_daily)
    ),
    (
        'Partner-group clicks',
        (SELECT COALESCE(SUM(click_count), 0)
         FROM gold.fact_click
         WHERE date_key IS NOT NULL),
        (SELECT COALESCE(SUM(clicks), 0)
         FROM mart.partner_daily)
    ),
    (
        'Historical manager conversions',
        (SELECT COUNT(*)
         FROM gold.fact_conversion
         WHERE date_key IS NOT NULL
           AND advertiser_key IS NOT NULL
           AND account_manager_key IS NOT NULL),
        (SELECT COALESCE(SUM(all_conversions), 0)
         FROM mart.account_manager_daily)
    ),
    (
        'Dated revenue adjustments',
        (SELECT COUNT(*)
         FROM gold.fact_revenue_adjustment
         WHERE date_key IS NOT NULL),
        (SELECT COALESCE(SUM(adjustment_count), 0)
         FROM mart.adjustment_daily)
    ),
    (
        'Dated orphan adjustments',
        (SELECT COUNT(*)
         FROM gold.fact_revenue_adjustment
         WHERE date_key IS NOT NULL
           AND conversion_key IS NULL),
        (SELECT COALESCE(SUM(orphan_adjustment_count), 0)
         FROM mart.adjustment_daily)
    ),
    (
        'Posted eligible adjustment USD',
        (SELECT COALESCE(SUM(r.adjustment_amount), 0)
         FROM gold.fact_revenue_adjustment r
         JOIN gold.fact_conversion c
           ON c.conversion_key = r.conversion_key
         WHERE r.date_key IS NOT NULL
           AND c.revenue_eligible IS TRUE
           AND r.currency_code = 'USD'),
        (SELECT COALESCE(SUM(eligible_adjustment_usd), 0)
         FROM mart.adjustment_daily)
    )
)
SELECT
    metric,
    expected_value,
    actual_value,
    actual_value - expected_value AS difference,
    CASE
        WHEN actual_value = expected_value THEN 'PASS'
        ELSE 'CHECK'
    END AS result
FROM checks
ORDER BY metric;


-- ============================================================
-- Attribution reconciliation
-- Compare Gold eligible conversions with Mart attribution.
-- Monetary differences may arise from decimal rounding.
-- ============================================================

WITH attributable_conversions AS (
    SELECT
        c.conversion_key,
        c.base_revenue
    FROM gold.fact_conversion c
    WHERE c.date_key IS NOT NULL
      AND c.revenue_eligible IS TRUE
      AND EXISTS (
          SELECT 1
          FROM gold.bridge_conversion_touchpoint b
          JOIN gold.fact_click cl
            ON cl.click_key = b.click_key
          WHERE b.conversion_key = c.conversion_key
            AND b.attribution_weight > 0
      )
)
SELECT
    (SELECT COUNT(*)
     FROM attributable_conversions)
        AS gold_attributable_conversions,

    (SELECT COALESCE(SUM(weighted_conversion_credit), 0)
     FROM mart.partner_daily)
        AS partner_weighted_credit,

    (SELECT COALESCE(SUM(base_revenue), 0)
     FROM attributable_conversions)
        AS gold_attributable_base_revenue_usd,

    (SELECT COALESCE(SUM(attributed_revenue_usd), 0)
     FROM mart.partner_daily)
        AS partner_attributed_revenue_usd,

    (SELECT COALESCE(SUM(attributed_revenue_usd), 0)
     FROM mart.creative_daily)
        AS creative_attributed_revenue_usd;
