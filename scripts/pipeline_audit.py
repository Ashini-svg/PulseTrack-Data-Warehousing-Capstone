from uuid import uuid4
from db_connection import get_connection


def start_pipeline_audit(pipeline_name, stage_name, batch_id=None):
    """Create an audit record for a processing stage."""

    if batch_id is None:
        batch_id = uuid4()

    with get_connection() as connection:
        with connection.cursor() as cursor:
            cursor.execute("""
                INSERT INTO audit.pipeline_runs (
                    batch_id,
                    pipeline_name,
                    stage_name,
                    status
                )
                VALUES (%s, %s, %s, 'RUNNING')
                RETURNING run_id;
            """, (
                batch_id,
                pipeline_name,
                stage_name,
            ))

            return cursor.fetchone()[0]


def finish_pipeline_audit(
    run_id,
    status,
    source_count=None,
    processed_count=None,
    inserted_count=None,
    updated_count=None,
    rejected_count=None,
    error_message=None,
):
    """Record processing counts and the final stage outcome."""

    if status not in {"SUCCESS", "FAILED"}:
        raise ValueError(f"Invalid audit status: {status}")

    error_count = 1 if status == "FAILED" else 0

    with get_connection() as connection:
        with connection.cursor() as cursor:
            cursor.execute("""
                UPDATE audit.pipeline_runs
                SET
                    finished_at = clock_timestamp(),
                    status = %s,
                    source_count = %s,
                    processed_count = %s,
                    inserted_count = %s,
                    updated_count = %s,
                    rejected_count = %s,
                    error_count = %s,
                    error_message = %s
                WHERE run_id = %s;
            """, (
                status,
                source_count,
                processed_count,
                inserted_count,
                updated_count,
                rejected_count,
                error_count,
                error_message,
                run_id,
            ))
