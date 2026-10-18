from pathlib import Path
from uuid import uuid4

from psycopg import sql
from db_connection import get_connection


# ============================================================
# Project configuration
# ============================================================

PROJECT_ROOT = Path(__file__).resolve().parent.parent
SQL_FOLDER = PROJECT_ROOT / "sql"

GOLD_SQL_FILES = [
    "load_gold_dimensions.sql",
    "load_gold_facts.sql",
]

GOLD_DIMENSIONS = [
    "dim_date",
    "dim_account_manager",
    "dim_advertiser",
    "dim_partner",
    "dim_offer",
    "dim_campaign",
    "dim_creative",
    "dim_country",
    "dim_device",
    "dim_conversion_status",
]

GOLD_FACTS = [
    "fact_impression",
    "fact_click",
    "fact_conversion",
    "fact_revenue_adjustment",
    "bridge_conversion_touchpoint",
]

GOLD_PRIMARY_KEYS = {
    "dim_date": "date_key",
    "dim_account_manager": "account_manager_key",
    "dim_advertiser": "advertiser_key",
    "dim_partner": "partner_key",
    "dim_offer": "offer_key",
    "dim_campaign": "campaign_key",
    "dim_creative": "creative_key",
    "dim_country": "country_key",
    "dim_device": "device_key",
    "dim_conversion_status": "conversion_status_key",
    "fact_impression": "impression_key",
    "fact_click": "click_key",
    "fact_conversion": "conversion_key",
    "fact_revenue_adjustment": "adjustment_key",
    "bridge_conversion_touchpoint": "bridge_key",
}


# ============================================================
# Audit functions
# ============================================================

def start_audit_run(batch_id, stage_name):
    """Create an audit record before starting a Gold stage."""

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
                "load_gold",
                stage_name,
            ))

            return cursor.fetchone()[0]



def finish_audit_run(
    run_id,
    status,
    inserted_count=None,
    updated_count=None,
    error_message=None
):
    """Record the result and row changes of a Gold stage."""

    error_count = 1 if status == "FAILED" else 0

    with get_connection() as connection:
        with connection.cursor() as cursor:
            cursor.execute("""
                UPDATE audit.pipeline_runs
                SET
                    finished_at = clock_timestamp(),
                    status = %s,
                    inserted_count = %s,
                    updated_count = %s,
                    error_count = %s,
                    error_message = %s
                WHERE run_id = %s;
            """, (
                status,
                inserted_count,
                updated_count,
                error_count,
                error_message,
                run_id,
            ))



def count_stage_rows(table_names):
    """Count existing Gold records across a stage's tables."""

    total = 0

    with get_connection() as connection:
        with connection.cursor() as cursor:
            for table_name in table_names:
                query = sql.SQL(
                    "SELECT COUNT(*) FROM gold.{}"
                ).format(sql.Identifier(table_name))

                cursor.execute(query)
                total += cursor.fetchone()[0]

    return total

def snapshot_gold_rows(cursor, table_names):
    """Capture row identities and content hashes before loading."""

    cursor.execute("""
        CREATE TEMP TABLE gold_audit_snapshot (
            table_name TEXT NOT NULL,
            row_key TEXT NOT NULL,
            row_hash TEXT NOT NULL,
            PRIMARY KEY (table_name, row_key)
        ) ON COMMIT DROP;
    """)

    for table_name in table_names:
        primary_key = GOLD_PRIMARY_KEYS[table_name]

        query = sql.SQL("""
            INSERT INTO gold_audit_snapshot (
                table_name, row_key, row_hash
            )
            SELECT
                {table_name},
                t.{primary_key}::text,
                MD5(TO_JSONB(t)::text)
            FROM gold.{table} AS t;
        """).format(
            table_name=sql.Literal(table_name),
            primary_key=sql.Identifier(primary_key),
            table=sql.Identifier(table_name),
        )

        cursor.execute(query)


def count_gold_changes(cursor, table_names):
    """Count inserted rows and existing rows whose values changed."""

    total_inserted = 0
    total_updated = 0

    for table_name in table_names:
        primary_key = GOLD_PRIMARY_KEYS[table_name]

        query = sql.SQL("""
            SELECT
                COUNT(*) FILTER (
                    WHERE previous.row_key IS NULL
                ) AS inserted_count,

                COUNT(*) FILTER (
                    WHERE previous.row_key IS NOT NULL
                      AND previous.row_hash IS DISTINCT FROM
                          MD5(TO_JSONB(t)::text)
                ) AS updated_count

            FROM gold.{table} AS t

            LEFT JOIN gold_audit_snapshot AS previous
                ON previous.table_name = {table_name}
               AND previous.row_key = t.{primary_key}::text;
        """).format(
            table=sql.Identifier(table_name),
            table_name=sql.Literal(table_name),
            primary_key=sql.Identifier(primary_key),
        )

        cursor.execute(query)
        inserted_count, updated_count = cursor.fetchone()

        total_inserted += inserted_count
        total_updated += updated_count

    return total_inserted, total_updated


# ============================================================
# Gold pipeline
# ============================================================

def load_gold():
    """Execute Gold transformations with audit tracking."""

    batch_id = uuid4()

    for filename in GOLD_SQL_FILES:
        stage_name = Path(filename).stem

        stage_tables = (
            GOLD_DIMENSIONS
            if filename == "load_gold_dimensions.sql"
            else GOLD_FACTS
        )

        run_id = start_audit_run(batch_id, stage_name)

        try:
            sql_path = SQL_FOLDER / filename

            if not sql_path.is_file():
                raise FileNotFoundError(
                    f"Gold SQL file not found: {sql_path}"
                )

            
            sql_script = sql_path.read_text(encoding="utf-8-sig")

            print(f"Executing: {filename}")

            with get_connection() as connection:
                with connection.cursor() as cursor:

                    # Capture the original Gold row state.
                    snapshot_gold_rows(cursor, stage_tables)

                    # Execute the existing Gold transformations.
                    cursor.execute(sql_script)

                    # Compare before and after within the transaction.
                    inserted_count, updated_count = count_gold_changes(
                        cursor, stage_tables
                    )

            finish_audit_run(
                run_id,
                status="SUCCESS",
                inserted_count=inserted_count,
                updated_count=updated_count,
            )

            print(f"Completed: {filename}")
            print(f"Inserted Gold rows: {inserted_count}")
            print(f"Changed Gold rows: {updated_count}")

        except Exception as error:
            finish_audit_run(
                run_id,
                status="FAILED",
                error_message=str(error),
            )

            print(f"Failed: {filename}")
            raise

    # Show final Gold row counts.
    print("\nGold table row counts:")

    with get_connection() as connection:
        with connection.cursor() as cursor:
            for table_name in GOLD_DIMENSIONS + GOLD_FACTS:
                query = sql.SQL(
                    "SELECT COUNT(*) FROM gold.{}"
                ).format(sql.Identifier(table_name))

                cursor.execute(query)
                count = cursor.fetchone()[0]

                print(f"{table_name}: {count}")

    print("\nGold pipeline completed successfully.")


if __name__ == "__main__":
    load_gold()
