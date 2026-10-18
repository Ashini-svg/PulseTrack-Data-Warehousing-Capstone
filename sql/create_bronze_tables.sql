
-- Create Bronze tables for all PostgreSQL source tables.
-- Preserve source columns and add ingestion metadata.
CREATE SCHEMA IF NOT EXISTS bronze;
DO $$
DECLARE
    source_table RECORD;
BEGIN
    FOR source_table IN
        SELECT table_name
        FROM information_schema.tables
        WHERE table_schema = 'pulsetrack_raw'
          AND table_type = 'BASE TABLE'
        ORDER BY table_name
    LOOP
        EXECUTE format(
            'CREATE TABLE IF NOT EXISTS bronze.%I (
                LIKE pulsetrack_raw.%I,
                ingested_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
            )',
            source_table.table_name,
            source_table.table_name
        );
    END LOOP;
END $$;



-- Store original JSONL records from advertiser and partner sources.
-- Keep the raw content unchanged for later processing.

CREATE TABLE IF NOT EXISTS bronze.jsonl_records (
    source_file TEXT NOT NULL,
    line_number INTEGER NOT NULL CHECK (line_number > 0),
    raw_line TEXT NOT NULL,
    ingested_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (source_file, line_number)
);



-- Conversion Event Log: Bronze Landing Table
-- Preserve every original log line, including malformed events.


CREATE TABLE IF NOT EXISTS bronze.event_log_records (
    source_file TEXT NOT NULL,
    line_number INTEGER NOT NULL CHECK (line_number > 0),
    raw_line TEXT NOT NULL,
    ingested_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (source_file, line_number)
);

