-- ============================================================
-- PulseTrack: Monthly OLAP Materialized Cache
-- Question 8 - Performance and Pre-Aggregation
--
-- Source: Existing monthly semantic model
-- ============================================================

CREATE MATERIALIZED VIEW IF NOT EXISTS
semantic.campaign_performance_monthly_cache
AS
SELECT *
FROM semantic.campaign_performance_monthly
WITH NO DATA;


-- Unique monthly campaign grain
CREATE UNIQUE INDEX IF NOT EXISTS
idx_semantic_campaign_monthly_cache
ON semantic.campaign_performance_monthly_cache (
    month_start,
    campaign_key
);


-- Populate / refresh the cached results
REFRESH MATERIALIZED VIEW
semantic.campaign_performance_monthly_cache;


-- Refresh planner statistics
ANALYZE semantic.campaign_performance_monthly_cache;


-- Verify the cache has been populated
SELECT COUNT(*) AS cached_monthly_rows
FROM semantic.campaign_performance_monthly_cache;
