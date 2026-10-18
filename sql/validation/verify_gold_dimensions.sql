-- ============================================================
-- PulseTrack: Gold Dimension Validation
-- ============================================================

WITH ordered_versions AS (
    SELECT
        advertiser_id,
        effective_from,
        effective_to,
        LAG(effective_from) OVER (
            PARTITION BY advertiser_id
            ORDER BY effective_from
        ) AS previous_start,
        LAG(effective_to) OVER (
            PARTITION BY advertiser_id
            ORDER BY effective_from
        ) AS previous_end
    FROM gold.dim_advertiser
)
SELECT
    (SELECT COUNT(DISTINCT advertiser_id)
     FROM gold.dim_advertiser)
        AS unique_advertisers,

    (SELECT COUNT(*)
     FROM gold.dim_advertiser
     WHERE is_current = TRUE)
        AS current_advertiser_versions,

    (SELECT COUNT(*)
     FROM gold.dim_advertiser
     WHERE is_current = FALSE)
        AS historical_advertiser_versions,

    (SELECT COUNT(*)
     FROM ordered_versions
     WHERE previous_start IS NOT NULL
       AND (
           previous_end IS NULL
           OR previous_end > effective_from
       ))
        AS overlapping_versions,

    (SELECT COUNT(*)
     FROM gold.dim_advertiser
     WHERE account_manager_key IS NULL)
        AS unresolved_manager_versions,

    (SELECT COUNT(*)
     FROM gold.dim_campaign
     WHERE offer_key IS NULL)
        AS unresolved_campaign_offers,

    (SELECT COUNT(*)
     FROM gold.dim_creative
     WHERE campaign_key IS NULL)
        AS unresolved_creative_campaigns,

    (SELECT COUNT(*)
     FROM silver.advertisers a
     JOIN gold.dim_advertiser d
       ON d.advertiser_id = a.advertiser_id
      AND d.is_current = TRUE
     LEFT JOIN gold.dim_account_manager am
       ON am.account_manager_key = d.account_manager_key
     WHERE a.account_manager_id
           IS DISTINCT FROM am.account_manager_id)
        AS current_manager_mismatches;
