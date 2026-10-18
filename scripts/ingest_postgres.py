from psycopg import sql
from db_connection import get_connection
from pipeline_audit import start_pipeline_audit, finish_pipeline_audit

SOURCE_TABLES = (
    "account_managers_raw",
    "advertisers_raw",
    "partners_raw",
    "offers_raw",
    "campaigns_raw",
    "creatives_raw",
    "impressions_raw",
    "clicks_raw",
    "conversions_raw",
    "conversion_touchpoints_raw",
    "revenue_adjustments_raw",
)


def load_missing_rows(table_name: str) -> int:
    """Copy missing source rows into Bronze while preserving duplicate counts."""
    if table_name not in SOURCE_TABLES:
        raise ValueError(f"Unknown source table: {table_name}")

    with get_connection() as connection:
        with connection.cursor() as cursor:
            # Read the source table's column names.
            cursor.execute(
                """
                SELECT column_name
                FROM information_schema.columns
                WHERE table_schema = 'pulsetrack_raw'
                  AND table_name = %s
                ORDER BY ordinal_position;
                """,
                (table_name,),
            )

            columns = [row[0] for row in cursor.fetchall()]

            if not columns:
                raise ValueError(f"No columns found for {table_name}")

            column_list = sql.SQL(", ").join(
                sql.Identifier(column) for column in columns
            )

            # Preserve source duplicates while avoiding repeated ingestion.
            query = sql.SQL("""
                INSERT INTO bronze.{table} ({columns})
                SELECT *
                FROM (
                    SELECT {columns}
                    FROM pulsetrack_raw.{table}

                    EXCEPT ALL

                    SELECT {columns}
                    FROM bronze.{table}
                ) AS missing_rows;
            """).format(
                table=sql.Identifier(table_name),
                columns=column_list,
            )

            cursor.execute(query)
            return cursor.rowcount


if __name__ == "__main__":

    run_id = start_pipeline_audit(
        "bronze_ingestion",
        "ingest_postgres"
    )

    source_count = None
    processed_count = 0
    total_inserted = 0

    try:
        # Count source records before processing.
        source_counts = {}

        with get_connection() as connection:
            with connection.cursor() as cursor:
                for table_name in SOURCE_TABLES:
                    query = sql.SQL(
                        "SELECT COUNT(*) FROM pulsetrack_raw.{}"
                    ).format(sql.Identifier(table_name))

                    cursor.execute(query)
                    source_counts[table_name] = cursor.fetchone()[0]

        source_count = sum(source_counts.values())

        # Ingest each source table into Bronze.
        for table_name in SOURCE_TABLES:
            inserted = load_missing_rows(table_name)

            processed_count += source_counts[table_name]
            total_inserted += inserted

            print(f"{table_name}: {inserted} new rows")

        # Record the successful processing results.
        finish_pipeline_audit(
            run_id,
            "SUCCESS",
            source_count=source_count,
            processed_count=processed_count,
            inserted_count=total_inserted,
            updated_count=0,
            rejected_count=0,
        )

        print(f"Total source rows: {source_count}")
        print(f"Total rows processed: {processed_count}")
        print(f"Total new rows loaded: {total_inserted}")

    except Exception as error:
        # Preserve counts from completed tables if a stage fails.
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

        print("PostgreSQL Bronze ingestion failed.")
        raise
