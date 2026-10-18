from pathlib import Path
from db_connection import get_connection
from pipeline_audit import start_pipeline_audit, finish_pipeline_audit

DATA_DIR = Path(__file__).resolve().parent.parent / "data"

JSONL_FILES = (
    "advertiser_accounts.jsonl",
    "partner_profiles.jsonl",
)


def ingest_jsonl_file(filename: str) -> int:
    """Load a JSONL file into Bronze without repeating existing lines."""
    file_path = DATA_DIR / filename

    if not file_path.is_file():
        raise FileNotFoundError(f"Source file not found: {file_path}")

    with file_path.open("r", encoding="utf-8") as file:
        records = [
            (filename, line_number, line.rstrip("\r\n"))
            for line_number, line in enumerate(file, start=1)
        ]

    query = """
        INSERT INTO bronze.jsonl_records (
            source_file, line_number, raw_line
        )
        VALUES (%s, %s, %s)
        ON CONFLICT (source_file, line_number) DO NOTHING;
    """

    with get_connection() as connection:
        with connection.cursor() as cursor:
            cursor.executemany(query, records)
            return cursor.rowcount



if __name__ == "__main__":

    run_id = start_pipeline_audit(
        "bronze_ingestion",
        "ingest_jsonl"
    )

    source_count = None
    processed_count = 0
    total_inserted = 0

    try:
        # Count the original lines in both JSONL files.
        file_counts = {}

        for filename in JSONL_FILES:
            file_path = DATA_DIR / filename

            if not file_path.is_file():
                raise FileNotFoundError(
                    f"Source file not found: {file_path}"
                )

            with file_path.open("r", encoding="utf-8") as file:
                file_counts[filename] = sum(1 for _ in file)

        source_count = sum(file_counts.values())

        # Ingest each file into Bronze.
        for filename in JSONL_FILES:
            inserted = ingest_jsonl_file(filename)

            processed_count += file_counts[filename]
            total_inserted += inserted

            print(f"{filename}: {inserted} new records")

        # Record successful ingestion.
        finish_pipeline_audit(
            run_id,
            "SUCCESS",
            source_count=source_count,
            processed_count=processed_count,
            inserted_count=total_inserted,
            updated_count=0,
            rejected_count=0,
        )

        print(f"Total source lines: {source_count}")
        print(f"Total lines processed: {processed_count}")
        print(f"Total new JSONL records loaded: {total_inserted}")

    except Exception as error:
        finish_pipeline_audit(
            run_id,
            "FAILED",
            source_count=source_count,
            processed_count=processed_count,
            inserted_count=total_inserted,
            updated_count=0,
            rejected_count=0,
            error_message=str(error),
        )

        print("JSONL Bronze ingestion failed.")
        raise
