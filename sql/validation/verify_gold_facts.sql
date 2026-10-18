-- ============================================================
-- PulseTrack: Gold Fact and Bridge Validation
-- ============================================================

-- ============================================================
-- 1. Source-to-Gold count and grain reconciliation
-- ============================================================

WITH checks AS (
    SELECT
        'fact_impression' AS table_name,
        (SELECT COUNT(*) FROM silver.impressions) AS expected_rows,
        (SELECT COUNT(*) FROM gold.fact_impression) AS actual_rows,
        (SELECT COUNT(DISTINCT impression_id)
         FROM gold.fact_impression) AS unique_ids

    UNION ALL
    SELECT
        'fact_click',
        (SELECT COUNT(*) FROM silver.clicks),
        (SELECT COUNT(*) FROM gold.fact_click),
        (SELECT COUNT(DISTINCT click_id)
         FROM gold.fact_click)

    UNION ALL
    SELECT
        'fact_conversion',
        (SELECT COUNT(DISTINCT conversion_id)
         FROM silver.conversion_history),
        (SELECT COUNT(*) FROM gold.fact_conversion),
        (SELECT COUNT(DISTINCT conversion_id)
         FROM gold.fact_conversion)

    UNION ALL
    SELECT
        'fact_revenue_adjustment',
        (SELECT COUNT(*) FROM silver.revenue_adjustments),
        (SELECT COUNT(*) FROM gold.fact_revenue_adjustment),
        (SELECT COUNT(DISTINCT adjustment_id)
         FROM gold.fact_revenue_adjustment)

    UNION ALL
    SELECT
        'bridge_conversion_touchpoint',
        (SELECT COUNT(*) FROM silver.conversion_touchpoints),
        (SELECT COUNT(*) FROM gold.bridge_conversion_touchpoint),
        (SELECT COUNT(DISTINCT touchpoint_id)
         FROM gold.bridge_conversion_touchpoint)
)
SELECT
    table_name,
    expected_rows,
    actual_rows,
    unique_ids,
    CASE
        WHEN expected_rows = actual_rows
         AND actual_rows = unique_ids
        THEN 'PASS'
        ELSE 'CHECK'
    END AS validation_result
FROM checks
ORDER BY table_name;


-- ============================================================
-- 2. Identify unresolved dimensional relationships
-- ============================================================

WITH checks AS (
    SELECT 'Impression: missing date' AS check_name,
        COUNT(*) FILTER (WHERE date_key IS NULL) AS issue_count
    FROM gold.fact_impression

    UNION ALL
    SELECT 'Impression: missing advertiser',
        COUNT(*) FILTER (WHERE advertiser_key IS NULL)
    FROM gold.fact_impression

    UNION ALL
    SELECT 'Impression: missing campaign',
        COUNT(*) FILTER (WHERE campaign_key IS NULL)
    FROM gold.fact_impression

    UNION ALL
    SELECT 'Impression: missing creative',
        COUNT(*) FILTER (WHERE creative_key IS NULL)
    FROM gold.fact_impression

    UNION ALL
    SELECT 'Click: missing date',
        COUNT(*) FILTER (WHERE date_key IS NULL)
    FROM gold.fact_click

    UNION ALL
    SELECT 'Click: missing advertiser',
        COUNT(*) FILTER (WHERE advertiser_key IS NULL)
    FROM gold.fact_click

    UNION ALL
    SELECT 'Click: missing campaign',
        COUNT(*) FILTER (WHERE campaign_key IS NULL)
    FROM gold.fact_click

    UNION ALL
    SELECT 'Click: missing partner',
        COUNT(*) FILTER (WHERE partner_key IS NULL)
    FROM gold.fact_click

    UNION ALL
    SELECT 'Conversion: missing date',
        COUNT(*) FILTER (WHERE date_key IS NULL)
    FROM gold.fact_conversion

    UNION ALL
    SELECT 'Conversion: missing advertiser',
        COUNT(*) FILTER (WHERE advertiser_key IS NULL)
    FROM gold.fact_conversion

    UNION ALL
    SELECT 'Conversion: missing campaign',
        COUNT(*) FILTER (WHERE campaign_key IS NULL)
    FROM gold.fact_conversion

    UNION ALL
    SELECT 'Conversion: missing status',
        COUNT(*) FILTER (WHERE conversion_status_key IS NULL)
    FROM gold.fact_conversion

    UNION ALL
    SELECT 'Conversion: missing account manager',
        COUNT(*) FILTER (WHERE account_manager_key IS NULL)
    FROM gold.fact_conversion

    UNION ALL
    SELECT 'Conversion: manager history mismatch',
        COUNT(*)
    FROM gold.fact_conversion f
    JOIN gold.dim_advertiser a
        ON a.advertiser_key = f.advertiser_key
    WHERE f.account_manager_key
          IS DISTINCT FROM a.account_manager_key

    UNION ALL
    SELECT 'Adjustment: missing conversion',
        COUNT(*) FILTER (WHERE conversion_key IS NULL)
    FROM gold.fact_revenue_adjustment

    UNION ALL
    SELECT 'Adjustment: missing date',
        COUNT(*) FILTER (WHERE date_key IS NULL)
    FROM gold.fact_revenue_adjustment

    UNION ALL
    SELECT 'Bridge: missing conversion',
        COUNT(*) FILTER (WHERE conversion_key IS NULL)
    FROM gold.bridge_conversion_touchpoint

    UNION ALL
    SELECT 'Bridge: missing click',
        COUNT(*) FILTER (WHERE click_key IS NULL)
    FROM gold.bridge_conversion_touchpoint
)
SELECT
    check_name,
    issue_count
FROM checks
ORDER BY check_name;


-- ============================================================
-- 3. Validate total attribution weights per conversion
-- ============================================================

WITH conversion_weights AS (
    SELECT
        conversion_id,
        COUNT(*) AS touchpoint_count,
        SUM(attribution_weight) AS total_weight
    FROM gold.bridge_conversion_touchpoint
    GROUP BY conversion_id
)
SELECT
    COUNT(*) AS conversions_with_touchpoints,

    COUNT(*) FILTER (
        WHERE total_weight IS NULL
    ) AS conversions_without_weights,

    COUNT(*) FILTER (
        WHERE total_weight IS NOT NULL
          AND ABS(total_weight - 1) > 0.000001
    ) AS conversions_with_nonunit_weights,

    MIN(total_weight) AS minimum_weight_sum,
    MAX(total_weight) AS maximum_weight_sum
FROM conversion_weights;
