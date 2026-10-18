"""Load PulseTrack CSV sources safely into PostgreSQL."""

import os
import argparse
import csv
from pathlib import Path

import psycopg
from psycopg import sql


DATA_DIR = Path(__file__).resolve().parent.parent / "data"

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



def connect_to_target(database_name):
    """Connect using the project's existing PostgreSQL settings."""

    return psycopg.connect(
        host=os.getenv("PGHOST", "localhost"),
        port=os.getenv("PGPORT", "5432"),
        dbname=database_name,
        user=os.getenv("PGUSER", "postgres"),
        password=os.getenv("PGPASSWORD"),
    )


def import_sources(database_name):
    """Import CSV files and verify existing records safely."""

    
    # Allow only the project and isolated test databases.
    ALLOWED_DATABASES = {
        "pulsetrack_csv_test",
        "pulsetrack_capstone",
    }

    if database_name not in ALLOWED_DATABASES:
        raise ValueError(
            f"Database is not allowed: {database_name}"
        )


    with connect_to_target(database_name) as connection:
        with connection.cursor() as cursor:

            cursor.execute("SELECT current_database()")
            actual_database = cursor.fetchone()[0]

            if actual_database != database_name:
                raise RuntimeError(
                    "Connected to an unexpected database."
                )

            print(f"Connected to: {actual_database}\n")

            total_rows = 0

            for table_name in SOURCE_TABLES:
                csv_path = DATA_DIR / f"{table_name}.csv"

                if not csv_path.is_file():
                    raise FileNotFoundError(
                        f"Missing CSV file: {csv_path}"
                    )

                # Check CSV headers.
                with csv_path.open(
                    "r", encoding="utf-8-sig", newline=""
                ) as file:
                    csv_columns = next(csv.reader(file), None)

                cursor.execute(
                    """
                    SELECT column_name
                    FROM information_schema.columns
                    WHERE table_schema = 'pulsetrack_raw'
                      AND table_name = %s
                    ORDER BY ordinal_position
                    """,
                    (table_name,),
                )

                db_columns = [
                    row[0] for row in cursor.fetchall()
                ]

                if not db_columns or csv_columns != db_columns:
                    raise ValueError(
                        f"Missing table or CSV header mismatch: {table_name}"
                    )

                source_table = sql.Identifier(
                    "pulsetrack_raw", table_name
                )

                temp_table = sql.Identifier(
                    f"csv_stage_{table_name}"
                )

                # Stage the CSV before modifying the source table.
                cursor.execute(
                    sql.SQL(
                        "CREATE TEMP TABLE {} ON COMMIT DROP AS "
                        "SELECT * FROM {} WITH NO DATA"
                    ).format(temp_table, source_table)
                )

                # Efficient bulk loading.
                with cursor.copy(
                    sql.SQL(
                        "COPY {} FROM STDIN "
                        "WITH (FORMAT CSV, HEADER TRUE)"
                    ).format(temp_table)
                ) as copy:
                    with csv_path.open("rb") as file:
                        while block := file.read(1024 * 1024):
                            copy.write(block)

                cursor.execute(
                    sql.SQL("SELECT COUNT(*) FROM {}").format(
                        temp_table
                    )
                )
                csv_rows = cursor.fetchone()[0]

                cursor.execute(
                    sql.SQL("SELECT COUNT(*) FROM {}").format(
                        source_table
                    )
                )
                existing_rows = cursor.fetchone()[0]

                
                # Detect existing records missing from the CSV.
                # This prevents accidental deletion or replacement.
                cursor.execute(
                    sql.SQL(
                        "SELECT EXISTS ("
                        "SELECT * FROM {} "
                        "EXCEPT ALL "
                        "SELECT * FROM {})"
                    ).format(source_table, temp_table)
                )

                existing_data_missing = cursor.fetchone()[0]

                if existing_data_missing:
                    raise ValueError(
                        f"Existing records differ from CSV: {table_name}. "
                        "Possible deletion or modification detected. "
                        "Import cancelled."
                    )

                # Identify new records, preserving duplicate occurrences.
                new_rows_query = sql.SQL(
                    "SELECT * FROM {} "
                    "EXCEPT ALL "
                    "SELECT * FROM {}"
                ).format(temp_table, source_table)

                cursor.execute(
                    sql.SQL(
                        "SELECT COUNT(*) FROM ({}) AS new_rows"
                    ).format(new_rows_query)
                )

                new_rows = cursor.fetchone()[0]

                if new_rows > 0:
                    cursor.execute(
                        sql.SQL(
                            "INSERT INTO {} "
                            "SELECT * FROM ({}) AS new_rows"
                        ).format(source_table, new_rows_query)
                    )

                    if cursor.rowcount != new_rows:
                        raise RuntimeError(
                            f"Inserted row count mismatch: {table_name}"
                        )

                    action = f"IMPORTED {new_rows:,} NEW"

                else:
                    action = "ALREADY MATCHES"

                total_rows += csv_rows

                print(
                    f"{table_name}: "
                    f"{csv_rows:,} rows - {action}"
                )

            print(
                f"\nAll 11 CSV sources verified: "
                f"{total_rows:,} rows."
            )

    # PostgreSQL commits only after every table succeeds.
    print("Transaction committed successfully.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Load PulseTrack source CSV files."
    )

    parser.add_argument(
        "--database",
        required=True,
        help="Target PostgreSQL database.",
    )

    args = parser.parse_args()

    import_sources(args.database)
