from pathlib import Path
from uuid import uuid4

from psycopg import sql
from db_connection import get_connection


PROJECT_ROOT = Path(__file__).resolve().parent.parent
SQL_FILE = PROJECT_ROOT / "sql" / "load_mart.sql"

MART_TABLES = [
    "campaign_daily",
    "advertiser_daily",
    "creative_daily",
    "partner_daily",
    "account_manager_daily",
    "adjustment_daily",
]


def record_start():
    """Create an audit record for the Data Mart refresh."""
    with get_connection() as connection:
        with connection.cursor() as cursor:
            cursor.execute("""
                INSERT INTO audit.pipeline_runs (
                    batch_id, pipeline_name, stage_name, status
                )
                VALUES (%s, 'load_mart', 'refresh_marts', 'RUNNING')
                RETURNING run_id;
            """, (uuid4(),))

            return cursor.fetchone()[0]


def record_finish(
    run_id,
    status,
    error_message=None,
    processed_count=None
):
    """Record Data Mart refresh results and output row count."""

    error_count = 0 if status == "SUCCESS" else 1

    with get_connection() as connection:
        with connection.cursor() as cursor:
            cursor.execute("""
                UPDATE audit.pipeline_runs
                SET
                    finished_at = clock_timestamp(),
                    status = %s,
                    processed_count = %s,
                    error_count = %s,
                    error_message = %s
                WHERE run_id = %s;
            """, (
                status,
                processed_count,
                error_count,
                error_message,
                run_id,
            ))


def load_mart():
    """Refresh all six business marts in one transaction."""
    run_id = record_start()

    try:
        if not SQL_FILE.is_file():
            raise FileNotFoundError(
                f"Data Mart SQL file not found: {SQL_FILE}"
            )

        script = SQL_FILE.read_text(encoding="utf-8-sig")

        print("Executing: load_mart.sql")

        # All six marts commit or roll back together.
        
        
        # Refresh the Data Mart and OLAP cache
        # within the same database transaction.
        with get_connection() as connection:
            with connection.cursor() as cursor:

                # Load all six Data Mart tables.
                cursor.execute(script)

                # Refresh the monthly OLAP cache.
                cursor.execute("""
                    REFRESH MATERIALIZED VIEW
                    semantic.campaign_performance_monthly_cache;
                """)

             
                # Count the materialized output of all six marts.
                processed_count = 0

                for table_name in MART_TABLES:
                    query = sql.SQL(
                        "SELECT COUNT(*) FROM mart.{}"
                    ).format(sql.Identifier(table_name))

                    cursor.execute(query)
                    processed_count += cursor.fetchone()[0]


        
        record_finish(
            run_id,
            "SUCCESS",
            processed_count=processed_count
        )

        print(f"Mart output rows processed: {processed_count}")

        print("Completed: load_mart.sql")


    except Exception as error:
        record_finish(run_id, "FAILED", str(error))
        print("Data Mart refresh failed.")
        raise

    print("\nData Mart row counts:")

    with get_connection() as connection:
        with connection.cursor() as cursor:
            for table_name in MART_TABLES:
                query = sql.SQL(
                    "SELECT COUNT(*) FROM mart.{}"
                ).format(sql.Identifier(table_name))

                cursor.execute(query)
                count = cursor.fetchone()[0]
                print(f"{table_name}: {count}")

    print("\nData Mart refresh completed successfully.")


if __name__ == "__main__":
    load_mart()
