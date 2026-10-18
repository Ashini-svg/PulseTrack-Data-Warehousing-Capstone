import json
from psycopg.types.json import Jsonb
from psycopg import sql

from db_connection import get_connection
from cleaning_utils import parse_mixed_datetime
from pipeline_audit import start_pipeline_audit, finish_pipeline_audit

def parse_json_profile(source_file, line_number, raw_line):
    """Parse a Bronze JSONL record and validate its identifier."""
    try:
        profile = json.loads(raw_line)
    except json.JSONDecodeError as error:
        raise ValueError(
            f"Invalid JSON in {source_file}, line {line_number}"
        ) from error

    if not isinstance(profile, dict):
        raise ValueError("Profile must be a JSON object")

    id_fields = {
        "advertiser_accounts.jsonl": "advertiser_id",
        "partner_profiles.jsonl": "partner_id",
    }

    if source_file not in id_fields:
        raise ValueError(f"Unexpected profile source: {source_file}")

    id_field = id_fields[source_file]
    entity_id = profile.get(id_field)

    if not isinstance(entity_id, str) or not entity_id.strip():
        raise ValueError(
            f"Missing {id_field} in {source_file}, line {line_number}"
        )

    profile[id_field] = entity_id.strip()
    return profile


def parse_mongo_date(value):
    """Convert MongoDB-style dates into UTC timestamps."""
    if isinstance(value, dict):
        value = value.get("$date")

    if value is not None and not isinstance(value, str):
        raise ValueError("Invalid MongoDB date value")

    return parse_mixed_datetime(value)


def as_jsonb(value):
    """Prepare nested JSON values for PostgreSQL JSONB columns."""
    return Jsonb(value) if value is not None else None


def clean_advertiser_profile(profile, source_file, line_number, ingested_at):
    """Prepare an advertiser account profile for Silver."""

    billing = profile.get("billing") or {}

    if not isinstance(billing, dict):
        raise ValueError("Invalid advertiser billing structure")

    return (
        profile["advertiser_id"],
        profile.get("legal_name"),
        profile.get("display_name"),
        billing.get("country"),
        billing.get("currency"),
        as_jsonb(profile.get("contacts")),
        as_jsonb(profile.get("account_manager_history")),
        as_jsonb(profile.get("contract")),
        Jsonb(profile),
        source_file,
        line_number,
        ingested_at,
    )


def clean_partner_profile(
    profile, source_file, line_number, ingested_at, valid_partner_ids
):
    """Prepare a partner profile while preserving unmatched references."""

    partner_id = profile["partner_id"]

    # Keep unmatched profiles; do not invent a partner reference.
    matched_partner_id = (
        partner_id if partner_id in valid_partner_ids else None
    )

    return (
        partner_id,
        matched_partner_id,
        profile.get("name"),
        as_jsonb(profile.get("contact")),
        as_jsonb(profile.get("channels")),
        as_jsonb(profile.get("payment")),
        as_jsonb(profile.get("tags")),
        parse_mongo_date(profile.get("joinedAt")),
        Jsonb(profile),
        source_file,
        line_number,
        ingested_at,
    )


def save_profile_errors(cursor, invalid_records):
    """Save invalid JSONL profiles without duplicating error entries."""

    if not invalid_records:
        return 0

    query = """
        INSERT INTO silver.jsonl_profile_errors (
            source_file, line_number, raw_line, error_reason
        )
        VALUES (%s, %s, %s, %s)
        ON CONFLICT (source_file, line_number)
        DO UPDATE SET
            raw_line = EXCLUDED.raw_line,
            error_reason = EXCLUDED.error_reason,
            last_seen_at = CURRENT_TIMESTAMP,
            resolution_status = 'open',
            resolved_at = NULL;
    """

    cursor.executemany(query, invalid_records)

    return len(invalid_records)


def upsert_profiles(cursor, table_name, columns, rows):
    """Insert new profiles and update only changed records."""
    if not rows:
        return 0

    update_columns = columns[1:]

    assignments = sql.SQL(", ").join(
        sql.SQL("{} = EXCLUDED.{}").format(
            sql.Identifier(column),
            sql.Identifier(column)
        )
        for column in update_columns
    )

    query = sql.SQL("""
        INSERT INTO silver.{} AS target ({})
        VALUES ({})
        ON CONFLICT ({}) DO UPDATE SET
            {},
            processed_at = CURRENT_TIMESTAMP
        WHERE ({}) IS DISTINCT FROM ({});
    """).format(
        sql.Identifier(table_name),
        sql.SQL(", ").join(map(sql.Identifier, columns)),
        sql.SQL(", ").join(
            sql.Placeholder() for _ in columns
        ),
        sql.Identifier(columns[0]),
        assignments,
        sql.SQL(", ").join(
            sql.SQL("target.{}").format(sql.Identifier(c))
            for c in update_columns
        ),
        sql.SQL(", ").join(
            sql.SQL("EXCLUDED.{}").format(sql.Identifier(c))
            for c in update_columns
        ),
    )

    cursor.executemany(query, rows)
    return cursor.rowcount


def load_jsonl_profiles():
    """Transform Bronze JSONL records into Silver profile tables."""

    advertiser_rows = []
    partner_rows = []
    invalid_rows = []

    with get_connection() as connection:
        with connection.cursor() as cursor:

            # Load registered partner IDs for relationship matching.
            cursor.execute("SELECT partner_id FROM silver.partners")
            valid_partner_ids = {
                row[0] for row in cursor.fetchall()
            }

            # Read both JSONL sources from Bronze.
            cursor.execute("""
                SELECT source_file, line_number, raw_line, ingested_at
                FROM bronze.jsonl_records
                WHERE source_file IN (
                    'advertiser_accounts.jsonl',
                    'partner_profiles.jsonl'
                )
                ORDER BY source_file, line_number;
            """)

            for source_file, line_number, raw_line, ingested_at in cursor:
                try:
                    profile = parse_json_profile(
                        source_file, line_number, raw_line
                    )

                    if source_file == "advertiser_accounts.jsonl":
                        advertiser_rows.append(
                            clean_advertiser_profile(
                                profile, source_file,
                                line_number, ingested_at
                            )
                        )
                    else:
                        partner_rows.append(
                            clean_partner_profile(
                                profile, source_file,
                                line_number, ingested_at,
                                valid_partner_ids
                            )
                        )

                except (ValueError, TypeError) as error:
                    invalid_rows.append((
                        source_file, line_number,
                        raw_line, str(error)
                    ))

            # Load cleaned advertiser profiles.
            advertisers = upsert_profiles(
                cursor,
                "advertiser_profiles",
                (
                    "advertiser_id", "legal_name", "display_name",
                    "billing_country", "billing_currency",
                    "contacts", "account_manager_history",
                    "contract", "profile_data", "source_file",
                    "line_number", "source_ingested_at"
                ),
                advertiser_rows,
            )

            # Load cleaned partner profiles.
            partners = upsert_profiles(
                cursor,
                "partner_profiles",
                (
                    "profile_partner_id", "matched_partner_id",
                    "profile_name", "contact", "channels",
                    "payment", "tags", "joined_at",
                    "profile_data", "source_file",
                    "line_number", "source_ingested_at"
                ),
                partner_rows,
            )

            # Save validation errors without losing Bronze records.
            quarantined = save_profile_errors(cursor, invalid_rows)

    return advertisers, partners, quarantined



if __name__ == "__main__":

    run_id = start_pipeline_audit(
        "silver_processing",
        "process_jsonl_profiles"
    )

    source_count = None

    try:
        # Count the Bronze JSONL records available for processing.
        with get_connection() as connection:
            with connection.cursor() as cursor:
                cursor.execute("""
                    SELECT COUNT(*)
                    FROM bronze.jsonl_records
                    WHERE source_file IN (
                        'advertiser_accounts.jsonl',
                        'partner_profiles.jsonl'
                    );
                """)

                source_count = cursor.fetchone()[0]

        # Execute the existing Silver profile processing.
        advertisers, partners, quarantined = load_jsonl_profiles()

        # Record the successful processing results.
        finish_pipeline_audit(
            run_id,
            "SUCCESS",
            source_count=source_count,
            processed_count=source_count,
            rejected_count=quarantined,
        )

        print(f"Advertiser profiles inserted or updated: {advertisers}")
        print(f"Partner profiles inserted or updated: {partners}")
        print(f"JSONL profile records quarantined: {quarantined}")

        print(f"Total source records: {source_count}")
        print(f"Total records processed: {source_count}")
        print("Silver JSONL profile processing completed.")

    except Exception as error:
        finish_pipeline_audit(
            run_id,
            "FAILED",
            source_count=source_count,
            error_message=str(error),
        )

        print("Silver JSONL profile processing failed.")
        raise
