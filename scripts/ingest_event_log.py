from pathlib import Path
from db_connection import get_connection
from pipeline_audit import start_pipeline_audit, finish_pipeline_audit

DATA_DIR = Path(__file__).resolve().parent.parent / "data"
LOG_FILE = DATA_DIR / "pulsetrack_conversions.log"
BATCH_SIZE = 2000


def ingest_event_log() -> int:
    """Load original event-log lines into Bronze in batches."""
    if not LOG_FILE.is_file():
        raise FileNotFoundError(f"Source file not found: {LOG_FILE}")

    query = """
        INSERT INTO bronze.event_log_records (
            source_file, line_number, raw_line
        )
        VALUES (%s, %s, %s)
        ON CONFLICT (source_file, line_number) DO NOTHING;
    """

    total_inserted = 0
    batch = []

    with get_connection() as connection:
        with connection.cursor() as cursor:
            with LOG_FILE.open("r", encoding="utf-8") as file:
                for line_number, line in enumerate(file, start=1):
                    batch.append((
                        LOG_FILE.name,
                        line_number,
                        line.rstrip("\r\n")
                    ))

                    if len(batch) >= BATCH_SIZE:
                        cursor.executemany(query, batch)
                        total_inserted += cursor.rowcount
                        batch.clear()

                if batch:
                    cursor.executemany(query, batch)
                    total_inserted += cursor.rowcount

    return total_inserted



if __name__ == "__main__":

    run_id = start_pipeline_audit(
        "bronze_ingestion",
        "ingest_event_log"
    )

    source_count = None

    try:
        if not LOG_FILE.is_file():
            raise FileNotFoundError(
                f"Source file not found: {LOG_FILE}"
            )

        # Count original physical event-log lines.
        with LOG_FILE.open("r", encoding="utf-8") as file:
            source_count = sum(1 for _ in file)

        # Ingest the original log lines into Bronze.
        inserted = ingest_event_log()

        # Save successful processing statistics.
        finish_pipeline_audit(
            run_id,
            "SUCCESS",
            source_count=source_count,
            processed_count=source_count,
            inserted_count=inserted,
            updated_count=0,
            rejected_count=0,
        )

        print(f"Total source log lines: {source_count}")
        print(f"Total lines processed: {source_count}")
        print(f"New event-log lines loaded: {inserted}")

    except Exception as error:
        finish_pipeline_audit(
            run_id,
            "FAILED",
            source_count=source_count,
            error_message=str(error),
        )

        print("Event-log Bronze ingestion failed.")
        raise

