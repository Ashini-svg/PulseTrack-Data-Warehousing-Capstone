-- ============================================================
-- PulseTrack: OLAP / Semantic Model Verification
-- Question 8
--
-- Demonstrates:
-- Roll-up, Drill-down, Slice, Dice, Pivot,
-- Top-N, Ranking, Percentage Contribution,
-- MoM, QoQ, YoY and Attribution.
--
-- Source: Semantic analytical model only.
-- ============================================================


-- ============================================================
-- 1. MONTHLY PRE-AGGREGATION RECONCILIATION
-- Expected: 7200 groups, 0 mismatches.
-- ============================================================

WITH daily AS (
    SELECT
        MAKE_DATE(year_number, month_number, 1)
            AS month_start,
        campaign_key,
        SUM(impressions) AS impressions,
        SUM(clicks) AS clicks,
        SUM(eligible_conversions) AS conversions,
        SUM(adjusted_revenue_usd) AS revenue
    FROM semantic.campaign_performance_daily
    GROUP BY
        MAKE_DATE(year_number, month_number, 1),
        campaign_key
),
monthly AS (
    SELECT
        month_start,
        campaign_key,
        impressions,
        clicks,
        eligible_conversions AS conversions,
        adjusted_revenue_usd AS revenue
    FROM semantic.campaign_performance_monthly
)
SELECT
    COUNT(*) AS total_monthly_groups,
    COUNT(*) FILTER (
        WHERE d.campaign_key IS NULL
           OR m.campaign_key IS NULL
           OR d.impressions IS DISTINCT FROM m.impressions
           OR d.clicks IS DISTINCT FROM m.clicks
           OR d.conversions IS DISTINCT FROM m.conversions
           OR d.revenue IS DISTINCT FROM m.revenue
    ) AS mismatched_groups
FROM daily d
FULL OUTER JOIN monthly m
    ON m.month_start = d.month_start
   AND m.campaign_key = d.campaign_key;


-- ============================================================
-- 2. ROLL-UP
-- Month -> Quarter -> Year -> Grand Total
-- ============================================================

SELECT
    CASE
        WHEN GROUPING(year_number) = 1
            THEN 'GRAND TOTAL'
        WHEN GROUPING(quarter_number) = 1
            THEN 'YEAR'
        WHEN GROUPING(month_number) = 1
            THEN 'QUARTER'
        ELSE 'MONTH'
    END AS aggregation_level,

    year_number,
    quarter_number,
    month_number,

    SUM(impressions) AS impressions,
    SUM(clicks) AS clicks,
    SUM(eligible_conversions) AS conversions,

    ROUND(SUM(adjusted_revenue_usd), 2)
        AS adjusted_revenue_usd

FROM semantic.campaign_performance_monthly

GROUP BY ROLLUP (
    year_number,
    quarter_number,
    month_number
)

ORDER BY
    year_number NULLS LAST,
    quarter_number NULLS LAST,
    month_number NULLS LAST;


-- ============================================================
-- 3. DRILL-DOWN
-- Latest quarter -> Month -> Individual day
-- ============================================================

WITH focus AS (
    SELECT
        year_number,
        quarter_number
    FROM semantic.campaign_performance_daily
    ORDER BY full_date DESC
    LIMIT 1
)
SELECT
    CASE
        WHEN GROUPING(p.month_number) = 1
            THEN 'QUARTER'
        WHEN GROUPING(p.full_date) = 1
            THEN 'MONTH'
        ELSE 'DAY'
    END AS detail_level,

    p.year_number,
    p.quarter_number,
    p.month_number,
    p.full_date,

    SUM(p.clicks) AS clicks,

    ROUND(SUM(p.adjusted_revenue_usd), 2)
        AS adjusted_revenue_usd

FROM semantic.campaign_performance_daily p
JOIN focus f
    ON f.year_number = p.year_number
   AND f.quarter_number = p.quarter_number

GROUP BY GROUPING SETS (
    (p.year_number, p.quarter_number),
    (p.year_number, p.quarter_number, p.month_number),
    (
        p.year_number,
        p.quarter_number,
        p.month_number,
        p.full_date
    )
)

ORDER BY
    p.month_number NULLS FIRST,
    p.full_date NULLS FIRST

LIMIT 30;


-- ============================================================
-- 4. SLICE
-- Campaign performance in the latest available month.
-- ============================================================

SELECT
    month_start,
    campaign_id,
    campaign_name,
    impressions,
    clicks,
    eligible_conversions,
    ROUND(adjusted_revenue_usd, 2) AS revenue_usd,
    ctr_pct,
    conversion_rate_pct

FROM semantic.campaign_performance_monthly

WHERE month_start = (
    SELECT MAX(month_start)
    FROM semantic.campaign_performance_monthly
)

ORDER BY adjusted_revenue_usd DESC
LIMIT 10;


-- ============================================================
-- 5. DICE
-- Filter by year, advertiser vertical and billing country.
-- Choose an actual populated combination.
-- ============================================================

WITH focus AS (
    SELECT
        year_number,
        vertical,
        billing_country
    FROM semantic.advertiser_performance_daily
    WHERE vertical IS NOT NULL
      AND billing_country IS NOT NULL
    GROUP BY
        year_number,
        vertical,
        billing_country
    ORDER BY COUNT(*) DESC
    LIMIT 1
)
SELECT
    p.year_number,
    p.vertical,
    p.billing_country,
    p.advertiser_id,
    p.advertiser_name,

    SUM(p.clicks) AS clicks,

    ROUND(SUM(p.adjusted_revenue_usd), 2)
        AS adjusted_revenue_usd

FROM semantic.advertiser_performance_daily p
JOIN focus f
    ON f.year_number = p.year_number
   AND f.vertical = p.vertical
   AND f.billing_country = p.billing_country

GROUP BY
    p.year_number,
    p.vertical,
    p.billing_country,
    p.advertiser_id,
    p.advertiser_name

ORDER BY adjusted_revenue_usd DESC
LIMIT 10;


-- ============================================================
-- 6. PIVOT
-- Compare advertisers across the four quarters of
-- the latest available year.
-- ============================================================

SELECT
    advertiser_id,

    ROUND(COALESCE(
        SUM(adjusted_revenue_usd)
        FILTER (WHERE quarter_number = 1), 0
    ), 2) AS q1_revenue,

    ROUND(COALESCE(
        SUM(adjusted_revenue_usd)
        FILTER (WHERE quarter_number = 2), 0
    ), 2) AS q2_revenue,

    ROUND(COALESCE(
        SUM(adjusted_revenue_usd)
        FILTER (WHERE quarter_number = 3), 0
    ), 2) AS q3_revenue,

    ROUND(COALESCE(
        SUM(adjusted_revenue_usd)
        FILTER (WHERE quarter_number = 4), 0
    ), 2) AS q4_revenue

FROM semantic.campaign_performance_daily

WHERE year_number = (
    SELECT MAX(year_number)
    FROM semantic.campaign_performance_daily
)

GROUP BY advertiser_id
ORDER BY advertiser_id
LIMIT 20;


-- ============================================================
-- 7. TOP-N
-- Top 10 campaigns by adjusted revenue.
-- ============================================================

SELECT
    campaign_id,
    campaign_name,

    SUM(impressions) AS impressions,
    SUM(clicks) AS clicks,
    SUM(eligible_conversions) AS conversions,

    ROUND(SUM(adjusted_revenue_usd), 2)
        AS adjusted_revenue_usd

FROM semantic.campaign_performance_monthly

GROUP BY
    campaign_id,
    campaign_name

ORDER BY adjusted_revenue_usd DESC
LIMIT 10;


-- ============================================================
-- 8. RANKING
-- Top 5 campaigns within each quarter.
-- ============================================================

WITH quarterly AS (
    SELECT
        year_number,
        quarter_number,
        campaign_key,
        campaign_name,

        SUM(adjusted_revenue_usd)
            AS adjusted_revenue_usd

    FROM semantic.campaign_performance_monthly

    GROUP BY
        year_number,
        quarter_number,
        campaign_key,
        campaign_name
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
    campaign_name,
    ROUND(adjusted_revenue_usd, 2)
        AS adjusted_revenue_usd,
    revenue_rank
FROM ranked
WHERE revenue_rank <= 5
ORDER BY
    year_number,
    quarter_number,
    revenue_rank,
    campaign_name
LIMIT 30;


-- ============================================================
-- 9. PERCENTAGE CONTRIBUTION
-- Campaign share of quarterly adjusted revenue.
-- ============================================================

WITH quarterly AS (
    SELECT
        year_number,
        quarter_number,
        campaign_key,
        campaign_name,

        SUM(adjusted_revenue_usd)
            AS campaign_revenue

    FROM semantic.campaign_performance_monthly

    GROUP BY
        year_number,
        quarter_number,
        campaign_key,
        campaign_name
),
contributions AS (
    SELECT
        *,

        ROUND(
            100.0 * campaign_revenue
            / NULLIF(
                SUM(campaign_revenue) OVER (
                    PARTITION BY year_number, quarter_number
                ),
                0
            ),
            4
        ) AS contribution_pct

    FROM quarterly
)
SELECT
    year_number,
    quarter_number,
    campaign_name,

    ROUND(campaign_revenue, 2)
        AS campaign_revenue,

    contribution_pct

FROM contributions
ORDER BY
    year_number DESC,
    quarter_number DESC,
    contribution_pct DESC NULLS LAST

LIMIT 20;


-- ============================================================
-- 10. MONTH-OVER-MONTH (MoM)
-- Use the existing monthly semantic view.
-- ============================================================

SELECT
    month_start,
    campaign_id,
    campaign_name,

    ROUND(previous_month_revenue_usd, 2)
        AS previous_month_revenue,

    ROUND(adjusted_revenue_usd, 2)
        AS current_month_revenue,

    mom_revenue_change_pct

FROM semantic.campaign_performance_monthly

WHERE mom_revenue_change_pct IS NOT NULL

ORDER BY
    month_start DESC,
    campaign_id

LIMIT 20;


-- ============================================================
-- 11. QUARTER-OVER-QUARTER (QoQ)
-- Compare consecutive calendar quarters.
-- ============================================================

WITH quarterly AS (
    SELECT
        DATE_TRUNC('quarter', month_start)::DATE
            AS quarter_start,

        SUM(adjusted_revenue_usd)
            AS adjusted_revenue_usd

    FROM semantic.campaign_performance_monthly

    GROUP BY
        DATE_TRUNC('quarter', month_start)::DATE
),
previous_quarter AS (
    SELECT
        *,

        LAG(quarter_start) OVER (
            ORDER BY quarter_start
        ) AS previous_quarter_start,

        LAG(adjusted_revenue_usd) OVER (
            ORDER BY quarter_start
        ) AS previous_quarter_revenue

    FROM quarterly
)
SELECT
    quarter_start,

    ROUND(adjusted_revenue_usd, 2)
        AS current_quarter_revenue,

    ROUND(previous_quarter_revenue, 2)
        AS previous_quarter_revenue,

    CASE
        WHEN previous_quarter_start =
             (quarter_start - INTERVAL '3 months')::DATE
        THEN ROUND(
            100.0 * (
                adjusted_revenue_usd
                - previous_quarter_revenue
            ) / NULLIF(previous_quarter_revenue, 0),
            4
        )
        ELSE NULL
    END AS qoq_revenue_change_pct

FROM previous_quarter

ORDER BY quarter_start;


-- ============================================================
-- 12. YEAR-OVER-YEAR (YoY)
-- Compare the same calendar month in the previous year.
-- ============================================================

WITH monthly AS (
    SELECT
        month_start,

        SUM(adjusted_revenue_usd)
            AS adjusted_revenue_usd

    FROM semantic.campaign_performance_monthly

    GROUP BY month_start
)
SELECT
    current_month.month_start,

    ROUND(current_month.adjusted_revenue_usd, 2)
        AS current_year_revenue,

    ROUND(previous_year.adjusted_revenue_usd, 2)
        AS previous_year_revenue,

    ROUND(
        100.0 * (
            current_month.adjusted_revenue_usd
            - previous_year.adjusted_revenue_usd
        ) / NULLIF(previous_year.adjusted_revenue_usd, 0),
        4
    ) AS yoy_revenue_change_pct

FROM monthly current_month

JOIN monthly previous_year
    ON previous_year.month_start =
       (current_month.month_start - INTERVAL '1 year')::DATE

ORDER BY current_month.month_start DESC;


-- ============================================================
-- 13. PARTNER ATTRIBUTION
-- Include unresolved partner credit in the denominator.
-- ============================================================

WITH partner_totals AS (
    SELECT
        partner_group_code,
        MAX(partner_name) AS partner_name,

        SUM(clicks) AS clicks,

        SUM(weighted_conversion_credit)
            AS weighted_credit,

        SUM(attributed_revenue_usd)
            AS attributed_revenue_usd

    FROM semantic.partner_performance_daily

    GROUP BY partner_group_code
)
SELECT
    partner_name,

    clicks,

    ROUND(weighted_credit, 4)
        AS weighted_conversion_credit,

    ROUND(attributed_revenue_usd, 2)
        AS attributed_revenue_usd,

    ROUND(
        100.0 * weighted_credit
        / NULLIF(
            SUM(weighted_credit) OVER (), 0
        ),
        4
    ) AS attribution_percentage,

    ROUND(
        100.0 * attributed_revenue_usd
        / NULLIF(
            SUM(attributed_revenue_usd) OVER (), 0
        ),
        4
    ) AS revenue_contribution_percentage

FROM partner_totals

ORDER BY attributed_revenue_usd DESC
LIMIT 15;


-- ============================================================
-- 14. BUSINESS HIERARCHY VERIFICATION
-- Advertiser -> Campaign -> Offer
-- Campaign -> Creative
-- ============================================================

SELECT
    h.advertiser_id,
    h.advertiser_name,
    h.campaign_id,
    h.campaign_name,
    h.offer_id,
    h.offer_name,

    COUNT(cc.creative_key)
        AS creatives_under_campaign

FROM semantic.advertiser_campaign_offer_hierarchy h

LEFT JOIN semantic.campaign_creative_hierarchy cc
    ON cc.campaign_key = h.campaign_key

GROUP BY
    h.advertiser_id,
    h.advertiser_name,
    h.campaign_id,
    h.campaign_name,
    h.offer_id,
    h.offer_name

ORDER BY h.advertiser_id, h.campaign_id

LIMIT 20;



-- ============================================================
-- 15. PARTNER CHANNEL HIERARCHY
-- Channel membership and allocation coverage
-- ============================================================

SELECT
    channel_name,

    COUNT(DISTINCT partner_key) AS partners,

    ROUND(
        SUM(channel_allocation_weight), 4
    ) AS allocated_partner_equivalents

FROM semantic.partner_channel_hierarchy

GROUP BY channel_name
ORDER BY partners DESC, channel_name;
