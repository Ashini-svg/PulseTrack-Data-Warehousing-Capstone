import json
from datetime import datetime
from psycopg.types.json import Jsonb
from db_connection import get_connection
from pipeline_audit import start_pipeline_audit, finish_pipeline_audit

VALID_EVENT_TYPES = {
    "conversion.created",
    "conversion.status_changed",
    "adjustment.applied",
}


def parse_event_line(raw_line: str) -> dict:
    """Parse a Kafka-style conversion log line."""

    parts = raw_line.split("|", 5)

    if len(parts) != 6:
        raise ValueError("Invalid event-log structure")

    topic, partition, offset, timestamp, key, payload_text = parts

    # Validate the metadata fields.
    for field, prefix in (
        (partition, "partition="),
        (offset, "offset="),
        (timestamp, "ts="),
        (key, "key="),
    ):
        if not field.startswith(prefix):
            raise ValueError(f"Invalid metadata field: {field}")

    try:
        log_partition = int(partition.removeprefix("partition="))
        log_offset = int(offset.removeprefix("offset="))
        log_timestamp_ms = int(timestamp.removeprefix("ts="))
    except ValueError as error:
        raise ValueError("Invalid numeric log metadata") from error

    # Parse the JSON payload.
    try:
        payload = json.loads(payload_text)
    except json.JSONDecodeError as error:
        raise ValueError("Invalid JSON payload") from error

    if not isinstance(payload, dict):
        raise ValueError("JSON payload must be an object")

    # Validate the common event fields.
    for field in ("event_id", "event_type", "conversion_id"):
        value = payload.get(field)

        if not isinstance(value, str) or not value.strip():
            raise ValueError(f"Missing or invalid {field}")

    if payload["event_type"] not in VALID_EVENT_TYPES:
        raise ValueError("Unsupported event type")

    occurred_at = payload.get("occurred_at")

    if not isinstance(occurred_at, str):
        raise ValueError("Missing event timestamp")

    try:
        event_time = datetime.fromisoformat(
            occurred_at.replace("Z", "+00:00")
        )
    except ValueError as error:
        raise ValueError("Invalid event timestamp") from error

    return {
        "event_id": payload["event_id"],
        "event_type": payload["event_type"],
        "conversion_id": payload["conversion_id"],
        "occurred_at": event_time,
        "log_topic": topic,
        "log_partition": log_partition,
        "log_offset": log_offset,
        "log_timestamp_ms": log_timestamp_ms,
        "log_key": key.removeprefix("key="),
        "payload": payload,
    }



def save_event_batch(records, connection):
    """Validate a batch and save valid events or parsing errors."""
    valid_events = []
    errors = []

    for source_file, line_number, raw_line in records:
        try:
            event = parse_event_line(raw_line)
        except ValueError as error:
            errors.append((source_file, line_number, str(error)))
            continue

        valid_events.append((
            event["event_id"],
            event["event_type"],
            event["conversion_id"],
            event["occurred_at"],
            event["log_topic"],
            event["log_partition"],
            event["log_offset"],
            event["log_timestamp_ms"],
            event["log_key"],
            Jsonb(event["payload"]),
            source_file,
            line_number,
        ))

    with connection.cursor() as cursor:
        inserted = 0

        if valid_events:
            cursor.executemany(
                """
                INSERT INTO silver.conversion_events (
                    event_id, event_type, conversion_id, occurred_at,
                    log_topic, log_partition, log_offset,
                    log_timestamp_ms, log_key, payload,
                    source_file, line_number
                )
                VALUES (
                    %s, %s, %s, %s, %s, %s,
                    %s, %s, %s, %s, %s, %s
                )
                ON CONFLICT (event_id) DO NOTHING;
                """,
                valid_events,
            )
            inserted = cursor.rowcount

        if errors:
            cursor.executemany(
                """
                INSERT INTO silver.event_log_errors (
                    source_file, line_number, error_reason
                )
                VALUES (%s, %s, %s)
                ON CONFLICT (source_file, line_number)
                DO UPDATE SET
                    error_reason = EXCLUDED.error_reason,
                    processed_at = CURRENT_TIMESTAMP;
                """,
                errors,
            )

    duplicate_events = len(valid_events) - inserted

    return inserted, len(errors), duplicate_events



def process_event_log(batch_size: int = 2000):
    """Process Bronze event-log records into Silver in batches."""
    if batch_size <= 0:
        raise ValueError("Batch size must be greater than zero")

    total_inserted = 0
    total_errors = 0
    total_skipped = 0

    # Use separate connections for reading and writing.
    with get_connection() as source_connection:
        with get_connection() as target_connection:
            with source_connection.cursor(
                name="bronze_event_reader"
            ) as cursor:
                cursor.execute("""
                    SELECT source_file, line_number, raw_line
                    FROM bronze.event_log_records
                    ORDER BY source_file, line_number;
                """)

                while True:
                    records = cursor.fetchmany(batch_size)

                    if not records:
                        break

                    inserted, errors, skipped = save_event_batch(
                        records, target_connection
                    )

                    # Commit each successfully processed batch.
                    target_connection.commit()

                    total_inserted += inserted
                    total_errors += errors
                    total_skipped += skipped

    return total_inserted, total_errors, total_skipped





if __name__ == "__main__":

    run_id = start_pipeline_audit(
        "silver_processing",
        "process_event_log"
    )

    source_count = None

    try:
        # Count Bronze event-log records available for processing.
        with get_connection() as connection:
            with connection.cursor() as cursor:
                cursor.execute("""
                    SELECT COUNT(*)
                    FROM bronze.event_log_records;
                """)

                source_count = cursor.fetchone()[0]

        # Execute the existing Silver event-log processing.
        inserted, errors, skipped = process_event_log()

        # Ensure every source line is accounted for.
        if inserted + errors + skipped != source_count:
            raise ValueError(
                "Event-log processing counts do not reconcile."
            )

        # Record the successful processing results.
        finish_pipeline_audit(
            run_id,
            "SUCCESS",
            source_count=source_count,
            processed_count=source_count,
            inserted_count=inserted,
            rejected_count=errors,
        )

        print(f"New valid events loaded: {inserted}")
        print(f"Invalid records encountered: {errors}")
        print(f"Duplicate or existing events skipped: {skipped}")
        print(f"Total source records: {source_count}")
        print(f"Total records processed: {source_count}")
        print("Silver event-log processing completed.")

    except Exception as error:
        finish_pipeline_audit(
            run_id,
            "FAILED",
            source_count=source_count,
            error_message=str(error),
        )

        print("Silver event-log processing failed.")
        raise

