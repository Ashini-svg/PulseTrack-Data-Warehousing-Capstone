-- ============================================================
-- PulseTrack: Pipeline Audit Tables
-- Tracks execution, processing metrics and failures.
-- ============================================================

CREATE SCHEMA IF NOT EXISTS audit;

CREATE TABLE IF NOT EXISTS audit.pipeline_runs (
    run_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,

    batch_id UUID NOT NULL,
    pipeline_name TEXT NOT NULL,
    stage_name TEXT NOT NULL,

    started_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    finished_at TIMESTAMPTZ,

    status TEXT NOT NULL DEFAULT 'RUNNING'
        CHECK (status IN ('RUNNING', 'SUCCESS', 'FAILED')),

    source_count BIGINT CHECK (source_count >= 0),
    processed_count BIGINT CHECK (processed_count >= 0),
    inserted_count BIGINT CHECK (inserted_count >= 0),
    updated_count BIGINT CHECK (updated_count >= 0),
    rejected_count BIGINT CHECK (rejected_count >= 0),
    error_count BIGINT CHECK (error_count >= 0),

    error_message TEXT,

    CONSTRAINT chk_audit_run_times
        CHECK (
            finished_at IS NULL
            OR finished_at >= started_at
        )
);

CREATE INDEX IF NOT EXISTS idx_audit_batch
    ON audit.pipeline_runs(batch_id);

CREATE INDEX IF NOT EXISTS idx_audit_pipeline_status
    ON audit.pipeline_runs(pipeline_name, status, started_at);

-- Verify table creation.
SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'audit'
  AND table_type = 'BASE TABLE';
