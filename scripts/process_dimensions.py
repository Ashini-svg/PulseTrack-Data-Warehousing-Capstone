from psycopg import sql

from db_connection import get_connection
from cleaning_utils import parse_mixed_datetime, parse_mixed_decimal
from pipeline_audit import start_pipeline_audit, finish_pipeline_audit

def clean_text(value: str | None) -> str | None:
    """Remove surrounding whitespace and standardize empty values."""
    if value is None:
        return None

    return value.strip() or None


def clean_account_manager(row: tuple) -> tuple:
    """Convert a Bronze account manager record into Silver-ready values."""

    (
        am_id,
        am_name,
        team,
        region,
        hire_date,
        created_at,
        updated_at,
        ingested_at,
    ) = row

    # Account manager ID is required.
    am_id = clean_text(am_id)

    if not am_id:
        raise ValueError("Account manager ID cannot be empty")

    # Standardize the mixed-format dates.
    parsed_hire_date = parse_mixed_datetime(hire_date)

    return (
        am_id,
        clean_text(am_name),
        clean_text(team),
        clean_text(region),
        parsed_hire_date.date() if parsed_hire_date else None,
        parse_mixed_datetime(created_at),
        parse_mixed_datetime(updated_at),
        ingested_at,
    )



def clean_advertiser(row: tuple) -> tuple:
    """Clean and validate a Bronze advertiser record."""

    (
        advertiser_id,
        advertiser_name,
        vertical,
        account_manager_id,
        status,
        signup_date,
        billing_country,
        created_at,
        updated_at,
        ingested_at,
    ) = row

    # Clean required fields.
    advertiser_id = clean_text(advertiser_id)
    advertiser_name = clean_text(advertiser_name)
    account_manager_id = clean_text(account_manager_id)
    status = clean_text(status)

    if not advertiser_id:
        raise ValueError("Advertiser ID cannot be empty")

    if not advertiser_name:
        raise ValueError(f"Missing name for {advertiser_id}")

    if not account_manager_id:
        raise ValueError(f"Missing account manager for {advertiser_id}")

    # Standardize and validate advertiser status.
    status = status.lower() if status else None

    if status not in {"active", "paused", "churned"}:
        raise ValueError(f"Invalid status for {advertiser_id}: {status}")

    # Convert mixed-format dates.
    parsed_signup_date = parse_mixed_datetime(signup_date)

    return (
        advertiser_id,
        advertiser_name,
        clean_text(vertical),
        account_manager_id,
        status,
        parsed_signup_date.date() if parsed_signup_date else None,
        clean_text(billing_country),
        parse_mixed_datetime(created_at),
        parse_mixed_datetime(updated_at),
        ingested_at,
    )



def required_text(value, field_name):
    """Clean a required identifier."""
    cleaned = clean_text(value)
    if not cleaned:
        raise ValueError(f"Missing required field: {field_name}")
    return cleaned


def clean_date(value):
    """Convert a source date to a date-only value."""
    parsed = parse_mixed_datetime(value)
    return parsed.date() if parsed else None


def clean_partner(row):
    """Standardize a partner record."""
    return (
        required_text(row[0], "partner_id"),
        clean_text(row[1]),
        clean_text(row[2]),
        clean_text(row[3]),
        clean_date(row[4]),
        clean_text(row[5]),
        parse_mixed_datetime(row[6]),
        parse_mixed_datetime(row[7]),
        row[8],
    )


def clean_offer(row):
    """Standardize an offer record."""
    payout_type = clean_text(row[5])

    return (
        required_text(row[0], "offer_id"),
        clean_text(row[1]),
        required_text(row[2], "offer.advertiser_id"),
        clean_text(row[3]),
        parse_mixed_decimal(row[4]),
        payout_type.upper() if payout_type else None,
        parse_mixed_datetime(row[6]),
        parse_mixed_datetime(row[7]),
        row[8],
    )


def clean_campaign(row, offer_owners, valid_advertisers):
    """Clean a campaign and repair invalid advertiser references."""
    campaign_id = required_text(row[0], "campaign_id")
    offer_id = required_text(row[2], "offer_id")
    original_advertiser = clean_text(row[3])

    if not original_advertiser:
        raise ValueError(
            f"Missing advertiser ID for campaign {campaign_id}"
    )

    if offer_id not in offer_owners:
        raise ValueError(f"Unknown offer for {campaign_id}: {offer_id}")

    offer_advertiser = offer_owners[offer_id]

    if not offer_advertiser:
        raise ValueError(f"Offer has no advertiser: {offer_id}")

    if original_advertiser in valid_advertisers:
        if original_advertiser != offer_advertiser:
            raise ValueError(
                f"Conflicting valid advertisers for {campaign_id}"
            )
        advertiser_id = original_advertiser
    else:
        # Repair an invalid reference using the linked offer.
        # The original value remains unchanged in Bronze.
        advertiser_id = offer_advertiser

    price_type = clean_text(row[4])

    return (
        campaign_id,
        clean_text(row[1]),
        offer_id,
        advertiser_id,
        price_type.upper() if price_type else None,
        clean_date(row[5]),
        clean_date(row[6]),
        parse_mixed_datetime(row[7]),
        parse_mixed_datetime(row[8]),
        row[9],
    )


def clean_creative(row):
    """Standardize a creative record."""
    return (
        required_text(row[0], "creative_id"),
        required_text(row[1], "creative.campaign_id"),
        clean_text(row[2]),
        clean_text(row[3]),
        clean_text(row[4]),
        clean_text(row[5]),
        parse_mixed_datetime(row[6]),
        parse_mixed_datetime(row[7]),
        row[8],
    )



def upsert_dimension(cursor, source_table, target_table, columns, cleaner):
    """Load a small Bronze dimension into Silver using an upsert."""

    source_columns = [
        "ingested_at" if column == "source_ingested_at" else column
        for column in columns
    ]

    cursor.execute(
        sql.SQL("SELECT {} FROM bronze.{} ORDER BY {}").format(
            sql.SQL(", ").join(map(sql.Identifier, source_columns)),
            sql.Identifier(source_table),
            sql.Identifier(source_columns[0]),
        )
    )

    cleaned_rows = [cleaner(row) for row in cursor.fetchall()]

    if not cleaned_rows:
        return 0

    # Update all source-derived columns, but only when values change.
    update_columns = columns[1:]

    assignments = sql.SQL(", ").join(
        sql.SQL("{} = EXCLUDED.{}").format(
            sql.Identifier(column), sql.Identifier(column)
        )
        for column in update_columns
    )

    current_values = sql.SQL(", ").join(
        sql.SQL("target.{}").format(sql.Identifier(column))
        for column in update_columns
    )

    incoming_values = sql.SQL(", ").join(
        sql.SQL("EXCLUDED.{}").format(sql.Identifier(column))
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
        sql.Identifier(target_table),
        sql.SQL(", ").join(map(sql.Identifier, columns)),
        sql.SQL(", ").join(
            sql.Placeholder() for _ in columns
        ),
        sql.Identifier(columns[0]),
        assignments,
        current_values,
        incoming_values,
    )

    cursor.executemany(query, cleaned_rows)
    return cursor.rowcount



def load_all_dimensions():
    """Clean and load all six Silver dimensions in dependency order."""
    results = {}

    with get_connection() as connection:
        with connection.cursor() as cursor:

            results["Account managers"] = upsert_dimension(
                cursor, "account_managers_raw", "account_managers",
                (
                    "am_id", "am_name", "team", "region",
                    "hire_date", "created_at", "updated_at",
                    "source_ingested_at"
                ),
                clean_account_manager,
            )

            results["Advertisers"] = upsert_dimension(
                cursor, "advertisers_raw", "advertisers",
                (
                    "advertiser_id", "advertiser_name", "vertical",
                    "account_manager_id", "status", "signup_date",
                    "billing_country", "created_at", "updated_at",
                    "source_ingested_at"
                ),
                clean_advertiser,
            )


            results["Partners"] = upsert_dimension(
                cursor, "partners_raw", "partners",
                (
                    "partner_id", "partner_name", "channel",
                    "media_buyer", "join_date", "payment_terms",
                    "created_at", "updated_at", "source_ingested_at"
                ),
                clean_partner,
            )

            results["Offers"] = upsert_dimension(
                cursor, "offers_raw", "offers",
                (
                    "offer_id", "offer_name", "advertiser_id",
                    "vertical", "default_payout", "payout_type",
                    "created_at", "updated_at", "source_ingested_at"
                ),
                clean_offer,
            )

            # Read the validated advertiser relationships.
            cursor.execute(
                "SELECT offer_id, advertiser_id FROM silver.offers"
            )
            offer_owners = dict(cursor.fetchall())

            cursor.execute(
                "SELECT advertiser_id FROM silver.advertisers"
            )
            valid_advertisers = {
                row[0] for row in cursor.fetchall()
            }

            results["Campaigns"] = upsert_dimension(
                cursor, "campaigns_raw", "campaigns",
                (
                    "campaign_id", "campaign_name", "offer_id",
                    "advertiser_id", "price_type", "start_date",
                    "end_date", "created_at", "updated_at",
                    "source_ingested_at"
                ),
                lambda row: clean_campaign(
                    row, offer_owners, valid_advertisers
                ),
            )

            results["Creatives"] = upsert_dimension(
                cursor, "creatives_raw", "creatives",
                (
                    "creative_id", "campaign_id", "creative_name",
                    "format", "size", "landing_url",
                    "created_at", "updated_at", "source_ingested_at"
                ),
                clean_creative,
            )

    return results




if __name__ == "__main__":

    run_id = start_pipeline_audit(
        "silver_processing",
        "process_dimensions"
    )

    source_count = None

    try:
        source_tables = [
            "account_managers_raw",
            "advertisers_raw",
            "partners_raw",
            "offers_raw",
            "campaigns_raw",
            "creatives_raw",
        ]

        # Count the Bronze records available for processing.
        source_count = 0

        with get_connection() as connection:
            with connection.cursor() as cursor:
                for table_name in source_tables:
                    query = sql.SQL(
                        "SELECT COUNT(*) FROM bronze.{}"
                    ).format(sql.Identifier(table_name))

                    cursor.execute(query)
                    source_count += cursor.fetchone()[0]

        # Execute the existing Silver dimension processing.
        results = load_all_dimensions()

        for table_name, affected_rows in results.items():
            print(
                f"{table_name} inserted or updated: "
                f"{affected_rows}"
            )

        finish_pipeline_audit(
            run_id,
            "SUCCESS",
            source_count=source_count,
            processed_count=source_count,
            rejected_count=0,
        )

        print(f"Total source records: {source_count}")
        print(f"Total records processed: {source_count}")
        print("Silver dimension processing completed.")

    except Exception as error:
        finish_pipeline_audit(
            run_id,
            "FAILED",
            source_count=source_count,
            error_message=str(error),
        )

        print("Silver dimension processing failed.")
        raise
