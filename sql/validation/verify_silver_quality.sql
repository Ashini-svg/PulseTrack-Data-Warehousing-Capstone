
-- ============================================================
-- PulseTrack: Silver Data Quality Verification
-- Purpose: Reconcile Bronze and Silver relational tables.
-- ============================================================

WITH counts AS (
    SELECT 'account_managers' AS table_name,
        (SELECT COUNT(*) FROM bronze.account_managers_raw) AS bronze_rows,
        (SELECT COUNT(*) FROM silver.account_managers) AS silver_rows

    UNION ALL
    SELECT 'advertisers',
        (SELECT COUNT(*) FROM bronze.advertisers_raw),
        (SELECT COUNT(*) FROM silver.advertisers)

    UNION ALL
    SELECT 'partners',
        (SELECT COUNT(*) FROM bronze.partners_raw),
        (SELECT COUNT(*) FROM silver.partners)

    UNION ALL
    SELECT 'offers',
        (SELECT COUNT(*) FROM bronze.offers_raw),
        (SELECT COUNT(*) FROM silver.offers)

    UNION ALL
    SELECT 'campaigns',
        (SELECT COUNT(*) FROM bronze.campaigns_raw),
        (SELECT COUNT(*) FROM silver.campaigns)

    UNION ALL
    SELECT 'creatives',
        (SELECT COUNT(*) FROM bronze.creatives_raw),
        (SELECT COUNT(*) FROM silver.creatives)

    UNION ALL
    SELECT 'impressions',
        (SELECT COUNT(*) FROM bronze.impressions_raw),
        (SELECT COUNT(*) FROM silver.impressions)

    UNION ALL
    SELECT 'clicks',
        (SELECT COUNT(*) FROM bronze.clicks_raw),
        (SELECT COUNT(*) FROM silver.clicks)

    UNION ALL
    SELECT 'conversions',
        (SELECT COUNT(*) FROM bronze.conversions_raw),
        (SELECT COUNT(*) FROM silver.conversion_history)

    UNION ALL
    SELECT 'conversion_touchpoints',
        (SELECT COUNT(*) FROM bronze.conversion_touchpoints_raw),
        (SELECT COUNT(*) FROM silver.conversion_touchpoints)

    UNION ALL
    SELECT 'revenue_adjustments',
        (SELECT COUNT(*) FROM bronze.revenue_adjustments_raw),
        (SELECT COUNT(*) FROM silver.revenue_adjustments)
)
SELECT
    table_name,
    bronze_rows,
    silver_rows,
    CASE
        WHEN bronze_rows = silver_rows THEN 'PASS'
        ELSE 'CHECK'
    END AS validation_result
FROM counts
ORDER BY table_name;


-- ============================================================
-- Silver: JSONL Profile Reconciliation
-- Verify profile completeness and unresolved relationships.
-- ============================================================

SELECT
    (SELECT COUNT(*)
     FROM bronze.jsonl_records
     WHERE source_file = 'advertiser_accounts.jsonl')
        AS bronze_advertisers,

    (SELECT COUNT(*)
     FROM silver.advertiser_profiles)
        AS silver_advertisers,

    (SELECT COUNT(*)
     FROM bronze.jsonl_records
     WHERE source_file = 'partner_profiles.jsonl')
        AS bronze_partners,

    (SELECT COUNT(*)
     FROM silver.partner_profiles)
        AS silver_partners,

    (SELECT COUNT(*)
     FROM silver.partner_profiles
     WHERE matched_partner_id IS NULL)
        AS unresolved_partner_references,

    (SELECT COUNT(*)
     FROM silver.jsonl_profile_errors
     WHERE resolution_status = 'open')
        AS open_profile_errors;


-- ============================================================
-- Silver: Conversion Event-Log Reconciliation
-- Verify event deduplication and malformed-record tracking.
-- ============================================================

WITH event_counts AS (
    SELECT
        (SELECT COUNT(*)
         FROM bronze.event_log_records) AS bronze_lines,

        (SELECT COUNT(*)
         FROM silver.conversion_events) AS valid_events,

        (SELECT COUNT(DISTINCT event_id)
         FROM silver.conversion_events) AS unique_event_ids,

        (SELECT COUNT(*)
         FROM silver.event_log_errors) AS rejected_records
)
SELECT
    bronze_lines,
    valid_events,
    unique_event_ids,
    rejected_records,

    bronze_lines - valid_events - rejected_records
        AS duplicate_deliveries,

    CASE
        WHEN valid_events = unique_event_ids
         AND bronze_lines >= valid_events + rejected_records
        THEN 'PASS'
        ELSE 'CHECK'
    END AS validation_result
FROM event_counts;
