-- ============================================================
-- PulseTrack: Question 9 - Business Analytics
-- Source: Final OLAP / Semantic Analytical Model only
--
-- Revenue: Confirmed eligible USD
-- Adjusted revenue: Base revenue + eligible adjustments
-- Attribution: Normalized weighted, base revenue only
-- ============================================================


-- ============================================================
-- Q9.1 WHICH ADVERTISERS GENERATED THE HIGHEST
-- REVENUE EACH QUARTER?
-- ============================================================

WITH quarterly AS (
    SELECT
        year_number,
        quarter_number,
        advertiser_id,
        MAX(advertiser_name) AS advertiser_name,
        SUM(eligible_conversions) AS eligible_conversions,
        SUM(adjusted_revenue_usd) AS adjusted_revenue_usd
    FROM semantic.advertiser_performance_daily
    GROUP BY
        year_number,
        quarter_number,
        advertiser_id
),
ranked AS (
    SELECT
        *,
        DENSE_RANK() OVER (
            PARTITION BY year_number, quarter_number
            ORDER BY adjusted_revenue_usd DESC
        ) AS revenue_rank
    FROM quarterly
)
SELECT
    year_number,
    quarter_number,
    advertiser_id,
    advertiser_name,
    eligible_conversions,
    ROUND(adjusted_revenue_usd, 2) AS adjusted_revenue_usd,
    revenue_rank
FROM ranked
WHERE revenue_rank <= 5
ORDER BY year_number, quarter_number, revenue_rank;


-- ============================================================
-- Q9.2 WHICH CAMPAIGNS HAVE HIGH CTR BUT LOW
-- CONVERSION RATE?
--
-- Definition: Top 25% CTR and bottom 25% conversion
-- rate among campaigns with at least 100 clicks
-- and 100 impressions.
-- ============================================================

WITH performance AS (
    SELECT
        campaign_key,
        MAX(campaign_id) AS campaign_id,
        MAX(campaign_name) AS campaign_name,
        SUM(impressions) AS impressions,
        SUM(clicks) AS clicks,
        SUM(eligible_conversions) AS conversions
    FROM semantic.campaign_performance_monthly
    GROUP BY campaign_key
),
rates AS (
    SELECT
        *,
        100.0 * clicks
            / NULLIF(impressions, 0) AS ctr_pct,
        100.0 * conversions
            / NULLIF(clicks, 0) AS conversion_rate_pct
    FROM performance
    WHERE impressions >= 100
      AND clicks >= 100
),
ranked AS (
    SELECT
        *,
        PERCENT_RANK() OVER (
            ORDER BY ctr_pct
        ) AS ctr_percentile,
        PERCENT_RANK() OVER (
            ORDER BY conversion_rate_pct
        ) AS conversion_percentile
    FROM rates
)
SELECT
    campaign_id,
    campaign_name,
    impressions,
    clicks,
    conversions,
    ROUND(ctr_pct, 2) AS ctr_pct,
    ROUND(conversion_rate_pct, 2) AS conversion_rate_pct
FROM ranked
WHERE ctr_percentile >= 0.75
  AND conversion_percentile <= 0.25
ORDER BY ctr_pct DESC, conversion_rate_pct
LIMIT 20;


-- ============================================================
-- Q9.3 WHICH VERIFIED PARTNERS GENERATED THE
-- HIGHEST ATTRIBUTED REVENUE?
--
-- Unresolved partner revenue is shown separately in Q9.8.
-- ============================================================

SELECT
    partner_key,
    MAX(partner_id) AS partner_id,
    MAX(partner_name) AS partner_name,
    SUM(clicks) AS clicks,
    ROUND(
        SUM(weighted_conversion_credit), 4
    ) AS weighted_conversion_credit,
    ROUND(
        SUM(attributed_revenue_usd), 2
    ) AS attributed_revenue_usd
FROM semantic.partner_performance_daily
WHERE partner_key IS NOT NULL
GROUP BY partner_key
ORDER BY attributed_revenue_usd DESC
LIMIT 10;


-- ============================================================
-- Q9.4 HOW DID REVENUE CHANGE COMPARED WITH
-- THE PREVIOUS MONTH?
--
-- Recalculate platform-level MoM after aggregation.
-- Do not average campaign-level percentages.
-- ============================================================

WITH monthly AS (
    SELECT
        month_start,
        SUM(adjusted_revenue_usd) AS adjusted_revenue_usd
    FROM semantic.campaign_performance_monthly
    GROUP BY month_start
),
comparison AS (
    SELECT
        *,
        LAG(month_start) OVER (
            ORDER BY month_start
        ) AS previous_month,
        LAG(adjusted_revenue_usd) OVER (
            ORDER BY month_start
        ) AS previous_revenue
    FROM monthly
)
SELECT
    month_start,
    ROUND(previous_revenue, 2) AS previous_month_revenue,
    ROUND(adjusted_revenue_usd, 2) AS current_month_revenue,
    CASE
        WHEN previous_month =
             (month_start - INTERVAL '1 month')::DATE
        THEN ROUND(
            100.0 * (adjusted_revenue_usd - previous_revenue)
            / NULLIF(previous_revenue, 0),
            2
        )
        ELSE NULL
    END AS mom_change_pct
FROM comparison
ORDER BY month_start;


-- ============================================================
-- Q9.5 WHICH CAMPAIGNS CONTRIBUTED MORE THAN
-- 10% OF TOTAL REVENUE?
--
-- An empty result is valid if no campaign exceeds 10%.
-- ============================================================

WITH campaign_totals AS (
    SELECT
        campaign_key,
        MAX(campaign_id) AS campaign_id,
        MAX(campaign_name) AS campaign_name,
        SUM(adjusted_revenue_usd) AS revenue
    FROM semantic.campaign_performance_monthly
    GROUP BY campaign_key
),
contributions AS (
    SELECT
        *,
        100.0 * revenue
            / NULLIF(SUM(revenue) OVER (), 0)
            AS contribution_pct
    FROM campaign_totals
)
SELECT
    campaign_id,
    campaign_name,
    ROUND(revenue, 2) AS adjusted_revenue_usd,
    ROUND(contribution_pct, 4) AS contribution_pct
FROM contributions
WHERE contribution_pct > 10
ORDER BY contribution_pct DESC;


-- ============================================================
-- Q9.6 WHICH CREATIVES UNDERPERFORMED RELATIVE
-- TO THEIR CAMPAIGN?
--
-- Underperformance: Creative CTR below campaign CTR.
-- Minimum creative impressions: 100.
-- ============================================================

WITH creative_totals AS (
    SELECT
        creative_key,
        campaign_key,
        MAX(creative_id) AS creative_id,
        MAX(creative_name) AS creative_name,
        MAX(campaign_name) AS campaign_name,
        SUM(impressions) AS impressions,
        SUM(clicks) AS clicks
    FROM semantic.creative_performance_daily
    WHERE campaign_key IS NOT NULL
    GROUP BY creative_key, campaign_key
),
campaign_totals AS (
    SELECT
        campaign_key,
        SUM(impressions) AS impressions,
        SUM(clicks) AS clicks
    FROM semantic.campaign_performance_daily
    GROUP BY campaign_key
),
comparison AS (
    SELECT
        cr.creative_id,
        cr.creative_name,
        cr.campaign_name,
        cr.impressions AS creative_impressions,

        100.0 * cr.clicks
            / NULLIF(cr.impressions, 0) AS creative_ctr,

        100.0 * ca.clicks
            / NULLIF(ca.impressions, 0) AS campaign_ctr

    FROM creative_totals cr
    JOIN campaign_totals ca
        ON ca.campaign_key = cr.campaign_key

    WHERE cr.impressions >= 100
      AND ca.impressions > 0
)
SELECT
    creative_id,
    creative_name,
    campaign_name,
    creative_impressions,
    ROUND(creative_ctr, 2) AS creative_ctr_pct,
    ROUND(campaign_ctr, 2) AS campaign_ctr_pct,
    ROUND(
        creative_ctr - campaign_ctr, 2
    ) AS ctr_gap_percentage_points
FROM comparison
WHERE creative_ctr < campaign_ctr
ORDER BY ctr_gap_percentage_points
LIMIT 20;


-- ============================================================
-- Q9.7 PERFORMANCE BEFORE AND AFTER A HISTORICAL
-- ACCOUNT-MANAGER CHANGE
--
-- Select a documented manager change with data on both
-- sides, using a 60-day comparison window.
-- This is descriptive, not proof of causation.
-- ============================================================

WITH versions AS (
    SELECT DISTINCT
        advertiser_id,
        advertiser_key,
        account_manager_id,
        effective_from
    FROM semantic.advertiser_performance_daily
    WHERE is_inferred IS FALSE
      AND account_manager_id IS NOT NULL
),
history AS (
    SELECT
        advertiser_id,
        advertiser_key,
        account_manager_id AS new_manager_id,

        (effective_from AT TIME ZONE 'UTC')::DATE
            AS change_date,

        LAG(account_manager_id) OVER (
            PARTITION BY advertiser_id
            ORDER BY effective_from, advertiser_key
        ) AS previous_manager_id

    FROM versions
),
changes AS (
    SELECT *
    FROM history
    WHERE previous_manager_id IS NOT NULL
      AND previous_manager_id <> new_manager_id
),
coverage AS (
    SELECT
        ch.*,

        COUNT(p.date_key) FILTER (
            WHERE p.full_date < ch.change_date
              AND p.account_manager_id =
                  ch.previous_manager_id
        ) AS before_rows,

        COUNT(p.date_key) FILTER (
            WHERE p.full_date >= ch.change_date
              AND p.account_manager_id =
                  ch.new_manager_id
        ) AS after_rows

    FROM changes ch

    LEFT JOIN semantic.account_manager_performance_daily p
        ON p.advertiser_id = ch.advertiser_id
       AND p.full_date >= ch.change_date - 60
       AND p.full_date < ch.change_date + 60

    GROUP BY
        ch.advertiser_id,
        ch.advertiser_key,
        ch.new_manager_id,
        ch.change_date,
        ch.previous_manager_id
),
selected_change AS (
    SELECT *
    FROM coverage
    WHERE before_rows > 0
      AND after_rows > 0
    ORDER BY
        before_rows + after_rows DESC,
        advertiser_id
    LIMIT 1
)
SELECT
    p.advertiser_id,
    MAX(p.advertiser_name) AS advertiser_name,
    ch.change_date,

    CASE
        WHEN p.full_date < ch.change_date
            THEN 'BEFORE'
        ELSE 'AFTER'
    END AS comparison_period,

    p.account_manager_id,
    MAX(p.manager_name) AS manager_name,

    SUM(p.clicks) AS clicks,
    SUM(p.eligible_conversions) AS eligible_conversions,

    ROUND(SUM(p.adjusted_revenue_usd), 2)
        AS adjusted_revenue_usd

FROM selected_change ch

JOIN semantic.account_manager_performance_daily p
    ON p.advertiser_id = ch.advertiser_id
   AND p.full_date >= ch.change_date - 60
   AND p.full_date < ch.change_date + 60
   AND (
        (
            p.full_date < ch.change_date
            AND p.account_manager_id =
                ch.previous_manager_id
        )
        OR
        (
            p.full_date >= ch.change_date
            AND p.account_manager_id =
                ch.new_manager_id
        )
   )

GROUP BY
    p.advertiser_id,
    ch.change_date,
    comparison_period,
    p.account_manager_id

ORDER BY comparison_period DESC;


-- ============================================================
-- Q9.8 WHAT PERCENTAGE OF ATTRIBUTED REVENUE
-- IS ASSIGNED TO EACH PARTNER?
--
-- The denominator includes the unresolved partner group.
-- Partner names alone are not unique identifiers.
-- ============================================================

WITH partner_totals AS (
    SELECT
        partner_group_code,
        MAX(partner_key) AS partner_key,
        MAX(partner_id) AS partner_id,
        MAX(partner_name) AS partner_name,

        SUM(weighted_conversion_credit) AS credit,
        SUM(attributed_revenue_usd) AS revenue

    FROM semantic.partner_performance_daily
    GROUP BY partner_group_code
),
shares AS (
    SELECT
        *,
        100.0 * credit
            / NULLIF(SUM(credit) OVER (), 0)
            AS attribution_pct,

        100.0 * revenue
            / NULLIF(SUM(revenue) OVER (), 0)
            AS revenue_share_pct,

        ROW_NUMBER() OVER (
            ORDER BY revenue DESC, partner_group_code
        ) AS revenue_rank

    FROM partner_totals
)
SELECT
    partner_id,
    partner_name,
    ROUND(credit, 4) AS weighted_conversion_credit,
    ROUND(revenue, 2) AS attributed_revenue_usd,
    ROUND(attribution_pct, 4) AS attribution_percentage,
    ROUND(revenue_share_pct, 4) AS revenue_share_percentage
FROM shares
WHERE revenue_rank <= 15
   OR partner_key IS NULL
ORDER BY revenue DESC;


-- ============================================================
-- Q9.9 WHICH CAMPAIGNS HAVE INCREASING IMPRESSIONS
-- BUT DECLINING CONVERSIONS?
--
-- Compare consecutive calendar months.
-- ============================================================

WITH monthly AS (
    SELECT
        month_start,
        campaign_key,
        campaign_id,
        campaign_name,
        impressions,
        eligible_conversions,

        LAG(month_start) OVER (
            PARTITION BY campaign_key
            ORDER BY month_start
        ) AS previous_month,

        LAG(impressions) OVER (
            PARTITION BY campaign_key
            ORDER BY month_start
        ) AS previous_impressions,

        LAG(eligible_conversions) OVER (
            PARTITION BY campaign_key
            ORDER BY month_start
        ) AS previous_conversions

    FROM semantic.campaign_performance_monthly
)
SELECT
    month_start,
    campaign_id,
    campaign_name,
    previous_impressions,
    impressions AS current_impressions,
    previous_conversions,
    eligible_conversions AS current_conversions,

    impressions - previous_impressions
        AS impression_increase,

    eligible_conversions - previous_conversions
        AS conversion_change

FROM monthly
WHERE previous_month =
      (month_start - INTERVAL '1 month')::DATE
  AND impressions > previous_impressions
  AND eligible_conversions < previous_conversions
ORDER BY
    month_start DESC,
    impression_increase DESC
LIMIT 20;


-- ============================================================
-- Q9.10 WHAT IS THE REVENUE IMPACT OF ADJUSTMENTS
-- DATED AT LEAST SEVEN DAYS AFTER CONVERSION?
--
-- Business timestamp lag, NOT ingestion arrival lag.
-- Measures are grouped by adjustment posting month.
-- ============================================================

WITH monthly AS (
    SELECT
        MAKE_DATE(year_number, month_number, 1)
            AS adjustment_month,

        SUM(adjustment_count) AS adjustments,

        SUM(adjustments_7d_after_conversion)
            AS adjustments_7d_late,

        SUM(eligible_adjustment_usd)
            AS eligible_adjustments_usd,

        SUM(eligible_adjustments_7d_after_conversion_usd)
            AS eligible_7d_late_amount_usd

    FROM semantic.adjustment_posting_daily

    GROUP BY
        MAKE_DATE(year_number, month_number, 1)
),
totals AS (
    SELECT
        adjustment_month,
        adjustments,
        adjustments_7d_late,
        eligible_adjustments_usd,
        eligible_7d_late_amount_usd
    FROM monthly

    UNION ALL

    SELECT
        NULL::DATE,
        SUM(adjustments),
        SUM(adjustments_7d_late),
        SUM(eligible_adjustments_usd),
        SUM(eligible_7d_late_amount_usd)
    FROM monthly
)
SELECT
    COALESCE(
        adjustment_month::TEXT,
        'ALL PERIODS'
    ) AS reporting_period,

    adjustments,
    adjustments_7d_late,

    ROUND(eligible_adjustments_usd, 2)
        AS eligible_adjustments_usd,

    ROUND(eligible_7d_late_amount_usd, 2)
        AS eligible_7d_late_amount_usd

FROM totals

ORDER BY
    adjustment_month NULLS LAST;
