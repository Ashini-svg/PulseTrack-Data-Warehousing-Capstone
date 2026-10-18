-- PulseTrack: Bronze Ingestion Validation
-- Purpose: Verify that source records are loaded into Bronze
--          with correct row counts and ingestion metadata.
-- Database: pulsetrack_capstone



-- ============================================================
-- 1. PostgreSQL Source-to-Bronze Reconciliation
-- Compare source and Bronze row counts for all 11 tables.
-- Expected result: Difference = 0 for every table.


WITH counts AS (
    SELECT 'account_managers_raw' AS table_name,
        (SELECT COUNT(*) FROM pulsetrack_raw.account_managers_raw) AS source_rows,
        (SELECT COUNT(*) FROM bronze.account_managers_raw) AS bronze_rows
    UNION ALL
    SELECT 'advertisers_raw',
        (SELECT COUNT(*) FROM pulsetrack_raw.advertisers_raw),
        (SELECT COUNT(*) FROM bronze.advertisers_raw)
    UNION ALL
    SELECT 'partners_raw',
        (SELECT COUNT(*) FROM pulsetrack_raw.partners_raw),
        (SELECT COUNT(*) FROM bronze.partners_raw)
    UNION ALL
    SELECT 'offers_raw',
        (SELECT COUNT(*) FROM pulsetrack_raw.offers_raw),
        (SELECT COUNT(*) FROM bronze.offers_raw)
    UNION ALL
    SELECT 'campaigns_raw',
        (SELECT COUNT(*) FROM pulsetrack_raw.campaigns_raw),
        (SELECT COUNT(*) FROM bronze.campaigns_raw)
    UNION ALL
    SELECT 'creatives_raw',
        (SELECT COUNT(*) FROM pulsetrack_raw.creatives_raw),
        (SELECT COUNT(*) FROM bronze.creatives_raw)
    UNION ALL
    SELECT 'impressions_raw',
        (SELECT COUNT(*) FROM pulsetrack_raw.impressions_raw),
        (SELECT COUNT(*) FROM bronze.impressions_raw)
    UNION ALL
    SELECT 'clicks_raw',
        (SELECT COUNT(*) FROM pulsetrack_raw.clicks_raw),
        (SELECT COUNT(*) FROM bronze.clicks_raw)
    UNION ALL
    SELECT 'conversions_raw',
        (SELECT COUNT(*) FROM pulsetrack_raw.conversions_raw),
        (SELECT COUNT(*) FROM bronze.conversions_raw)
    UNION ALL
    SELECT 'conversion_touchpoints_raw',
        (SELECT COUNT(*) FROM pulsetrack_raw.conversion_touchpoints_raw),
        (SELECT COUNT(*) FROM bronze.conversion_touchpoints_raw)
    UNION ALL
    SELECT 'revenue_adjustments_raw',
        (SELECT COUNT(*) FROM pulsetrack_raw.revenue_adjustments_raw),
        (SELECT COUNT(*) FROM bronze.revenue_adjustments_raw)
)
SELECT
    table_name,
    source_rows,
    bronze_rows,
    bronze_rows - source_rows AS difference
FROM counts
ORDER BY table_name;


-- =============================================================
-- 2. JSONL Bronze Ingestion Verification
-- Verify record counts and ingestion timestamps for both files.
-- Expected: 60 advertiser accounts and 600 partner profiles.

SELECT
    source_file,
    COUNT(*) AS total_records,
    COUNT(ingested_at) AS records_with_metadata
FROM bronze.jsonl_records
GROUP BY source_file
ORDER BY source_file;



-- ============================================================
-- 3. Event Log Bronze Ingestion Verification
-- Verify that all original event-log lines were preserved.
-- Expected: 183,162 records with ingestion timestamps.


SELECT
    source_file,
    COUNT(*) AS total_records,
    COUNT(ingested_at) AS records_with_metadata,
    COUNT(DISTINCT line_number) AS unique_line_numbers
FROM bronze.event_log_records
GROUP BY source_file
ORDER BY source_file;
