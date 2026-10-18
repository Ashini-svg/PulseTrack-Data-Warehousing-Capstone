from psycopg import sql
import hashlib
import json
from psycopg.types.json import Jsonb
from pipeline_audit import start_pipeline_audit, finish_pipeline_audit

from db_connection import get_connection
from cleaning_utils import (
    parse_mixed_datetime,
    parse_mixed_decimal,
    parse_mixed_boolean,
)


BATCH_SIZE = 2000


CONVERSION_SOURCE_COLUMNS = (
    "conversion_id", "click_id", "campaign_id",
    "advertiser_name", "account_manager", "campaign_name",
    "partner_id", "partner_name", "offer_name",
    "price_type", "conversion_time", "revenue", "payout",
    "currency", "status", "country", "device", "sub_id",
    "is_test", "legacy_flag", "pixel_fired",
    "internal_note", "reserved_1", "created_at",
    "updated_at", "ingested_at",
)

CONVERSION_HISTORY_COLUMNS = (
    "row_fingerprint", "duplicate_ordinal",
    "conversion_id", "click_id", "campaign_id",
    "advertiser_name", "account_manager", "campaign_name",
    "partner_id_raw", "partner_id", "partner_match_status",
    "partner_name", "offer_name", "price_type",
    "conversion_time", "revenue", "payout", "currency",
    "status_raw", "status_normalized", "country",
    "device", "sub_id", "is_test", "legacy_flag",
    "pixel_fired", "internal_note", "reserved_1",
    "created_at", "updated_at", "source_ingested_at",
)


def clean_text(value: str | None) -> str | None:
    """Trim text and convert empty values to None."""
    if value is None:
        return None

    return value.strip() or None


def resolve_partner_reference(
    value: str | None,
    valid_partner_ids: set[str]
) -> tuple[str | None, str | None, str]:
    """Classify a partner reference without losing its original value."""

    raw_partner_id = value
    partner_id = clean_text(value)

    if partner_id is None:
        return raw_partner_id, None, "missing"

    # The identifier matches a known partner directly.
    if partner_id in valid_partner_ids:
        return raw_partner_id, partner_id, "direct"

    # Compound IDs may contain a partner ID before the underscore.
    prefix, separator, suffix = partner_id.partition("_")

    if (
        separator
        and prefix.isdigit()
        and suffix.isdigit()
        and prefix in valid_partner_ids
    ):
        return raw_partner_id, None, "prefix_candidate"

    # Keep unresolved identifiers for investigation.
    return raw_partner_id, None, "unmatched"


def required_id(value, field_name):
    """Clean and validate a required record identifier."""
    cleaned = clean_text(value)

    if not cleaned:
        raise ValueError(f"Missing required ID: {field_name}")

    return cleaned


def clean_impression(row, valid_partner_ids):
    """Standardize an impression while preserving partner lineage."""

    (
        impression_id, campaign_id, creative_id, partner_id,
        impression_time, placement_raw, country, device,
        bot_score, created_at, updated_at, ingested_at
    ) = row

    raw_partner, resolved_partner, match_status = (
        resolve_partner_reference(partner_id, valid_partner_ids)
    )

    return (
        required_id(impression_id, "impression_id"),
        clean_text(campaign_id),
        clean_text(creative_id),
        raw_partner,
        resolved_partner,
        match_status,
        parse_mixed_datetime(impression_time),
        clean_text(placement_raw),
        clean_text(country),
        clean_text(device),
        parse_mixed_decimal(bot_score),
        parse_mixed_datetime(created_at),
        parse_mixed_datetime(updated_at),
        ingested_at,
    )


def clean_click(row, valid_partner_ids):
    """Standardize a click and its related source fields."""

    (
        click_id, impression_id, campaign_id, creative_id,
        partner_id, click_time, ip, user_agent, country,
        device, is_unique, referrer_raw, created_at,
        updated_at, ingested_at
    ) = row

    raw_partner, resolved_partner, match_status = (
        resolve_partner_reference(partner_id, valid_partner_ids)
    )

    return (
        required_id(click_id, "click_id"),
        clean_text(impression_id),
        clean_text(campaign_id),
        clean_text(creative_id),
        raw_partner,
        resolved_partner,
        match_status,
        parse_mixed_datetime(click_time),
        clean_text(ip),
        clean_text(user_agent),
        clean_text(country),
        clean_text(device),
        parse_mixed_boolean(is_unique),
        clean_text(referrer_raw),
        parse_mixed_datetime(created_at),
        parse_mixed_datetime(updated_at),
        ingested_at,
    )


def clean_conversion(row, valid_partner_ids):
    """Clean a conversion while preserving its original status."""

    (
        conversion_id, click_id, campaign_id,
        advertiser_name, account_manager, campaign_name,
        source_partner_id, partner_name, offer_name,
        price_type, conversion_time, revenue, payout,
        currency, status, country, device, sub_id,
        is_test, legacy_flag, pixel_fired,
        internal_note, reserved_1, created_at,
        updated_at, ingested_at,
    ) = row

    raw_partner, resolved_partner, match_status = (
        resolve_partner_reference(source_partner_id, valid_partner_ids)
    )

    # Preserve ambiguous statuses instead of guessing their meaning.
    status_raw = clean_text(status)
    normalized_status = status_raw.lower() if status_raw else None

    if normalized_status not in {
        "pending", "approved", "reversed", "returned"
    }:
        normalized_status = None

    price_type = clean_text(price_type)
    currency = clean_text(currency)

    return (
        required_id(conversion_id, "conversion_id"),
        clean_text(click_id),
        clean_text(campaign_id),
        clean_text(advertiser_name),
        clean_text(account_manager),
        clean_text(campaign_name),
        raw_partner,
        resolved_partner,
        match_status,
        clean_text(partner_name),
        clean_text(offer_name),
        price_type.upper() if price_type else None,
        parse_mixed_datetime(conversion_time),
        parse_mixed_decimal(revenue),
        parse_mixed_decimal(payout),
        currency.upper() if currency else None,
        status_raw,
        normalized_status,
        clean_text(country),
        clean_text(device),
        clean_text(sub_id),
        parse_mixed_boolean(is_test),
        parse_mixed_boolean(legacy_flag),
        parse_mixed_boolean(pixel_fired),
        clean_text(internal_note),
        clean_text(reserved_1),
        parse_mixed_datetime(created_at),
        parse_mixed_datetime(updated_at),
        ingested_at,
    )


def clean_touchpoint(row):
    """Clean conversion attribution touchpoints."""

    (
        touchpoint_id, conversion_id, click_id,
        touch_position, weight, created_at,
        updated_at, ingested_at,
    ) = row

    return (
        required_id(touchpoint_id, "touchpoint_id"),
        clean_text(conversion_id),
        clean_text(click_id),
        clean_text(touch_position),
        parse_mixed_decimal(weight),
        parse_mixed_datetime(created_at),
        parse_mixed_datetime(updated_at),
        ingested_at,
    )


def clean_revenue_adjustment(row):
    """Clean financial adjustments linked to conversions."""

    (
        adjustment_id, conversion_id, delta_amount,
        reason, adjusted_at, created_at,
        updated_at, ingested_at,
    ) = row

    return (
        required_id(adjustment_id, "adjustment_id"),
        clean_text(conversion_id),
        parse_mixed_decimal(delta_amount),
        clean_text(reason),
        parse_mixed_datetime(adjusted_at),
        parse_mixed_datetime(created_at),
        parse_mixed_datetime(updated_at),
        ingested_at,
    )


def quarantine_batch(cursor, source_table, source_columns, invalid_rows):
    """Save rejected source records and their validation errors."""

    if not invalid_rows:
        return 0

    records = []

    for row, error in invalid_rows:
        # Preserve the source values with their column names.
        raw_record = dict(zip(source_columns, row))

        # Convert database timestamps into JSON-compatible strings.
        raw_record = json.loads(
            json.dumps(raw_record, default=str, ensure_ascii=False)
        )

        # Ignore ingestion metadata when identifying source content.
        fingerprint_data = {
            column: value
            for column, value in raw_record.items()
            if column != "ingested_at"
        }

        fingerprint = hashlib.sha256(
            json.dumps(
                fingerprint_data,
                sort_keys=True,
                ensure_ascii=False,
            ).encode("utf-8")
        ).hexdigest()

        records.append((
            source_table,
            fingerprint,
            clean_text(row[0]),
            str(error),
            Jsonb(raw_record),
        ))

    query = """
        INSERT INTO silver.transaction_errors (
            source_table, source_row_hash, source_record_id,
            error_reason, raw_record
        )
        VALUES (%s, %s, %s, %s, %s)
        ON CONFLICT (source_table, source_row_hash)
        DO UPDATE SET
            error_reason = EXCLUDED.error_reason,
            last_seen_at = CURRENT_TIMESTAMP;
    """

    cursor.executemany(query, records)

    return len(invalid_rows)


def upsert_transaction_table(
    source_table,
    target_table,
    source_columns,
    target_columns,
    cleaner,
):
    """Load valid transactions in batches and return
    the affected-row and quarantined-row counts.
    """
    update_columns = target_columns[1:]

    assignments = sql.SQL(", ").join(
        sql.SQL("{} = EXCLUDED.{}").format(
            sql.Identifier(column),
            sql.Identifier(column),
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

    upsert_query = sql.SQL("""
        INSERT INTO silver.{} AS target ({})
        VALUES ({})
        ON CONFLICT ({}) DO UPDATE SET
            {},
            processed_at = CURRENT_TIMESTAMP
        WHERE ({}) IS DISTINCT FROM ({});
    """).format(
        sql.Identifier(target_table),
        sql.SQL(", ").join(map(sql.Identifier, target_columns)),
        sql.SQL(", ").join(
            sql.Placeholder() for _ in target_columns
        ),
        sql.Identifier(target_columns[0]),
        assignments,
        current_values,
        incoming_values,
    )

    total_affected = 0
    total_quarantined = 0

    # Keep the Bronze reader open while committing Silver batches.
    with get_connection() as source_connection:
        with get_connection() as target_connection:
            with source_connection.cursor(
                name=f"{source_table}_reader"
            ) as source_cursor:
                with target_connection.cursor() as target_cursor:

                    for batch in read_bronze_batches(
                        source_cursor, source_table, source_columns
                    ):
                        
                        cleaned_rows = []
                        invalid_rows = []

                        # Validate each record independently.
                        for row in batch:
                            try:
                                cleaned_rows.append(cleaner(row))
                            except ValueError as error:
                                invalid_rows.append((row, error))

                        # Load valid records.
                        if cleaned_rows:
                            target_cursor.executemany(
                                upsert_query, cleaned_rows
                            )
                            total_affected += target_cursor.rowcount

                        # Quarantine records that failed validation.
                        if invalid_rows:
                            total_quarantined += quarantine_batch(
                            target_cursor,
                            source_table,
                            source_columns,
                            invalid_rows,
                        )

                        # Save valid records and errors together.
                        target_connection.commit()


    return total_affected, total_quarantined


def load_conversion_history(
    valid_partner_ids: set[str]
) -> tuple[int, int]:
    """Preserve conversion versions and repeated rows across reruns."""

    columns = CONVERSION_HISTORY_COLUMNS
    update_columns = columns[2:]

    assignments = sql.SQL(", ").join(
        sql.SQL("{} = EXCLUDED.{}").format(
            sql.Identifier(column),
            sql.Identifier(column),
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

    upsert_query = sql.SQL("""
        INSERT INTO silver.conversion_history AS target ({})
        VALUES ({})
        ON CONFLICT (row_fingerprint, duplicate_ordinal)
        DO UPDATE SET
            {},
            processed_at = CURRENT_TIMESTAMP
        WHERE ({}) IS DISTINCT FROM ({});
    """).format(
        sql.SQL(", ").join(map(sql.Identifier, columns)),
        sql.SQL(", ").join(
            sql.Placeholder() for _ in columns
        ),
        assignments,
        current_values,
        incoming_values,
    )

    total_affected = 0
    total_quarantined = 0
    fingerprint_counts = {}

    with get_connection() as source_connection:
        with get_connection() as target_connection:
            with source_connection.cursor(
                name="conversion_history_reader"
            ) as source_cursor:
                with target_connection.cursor() as target_cursor:

                    for batch in read_bronze_batches(
                        source_cursor,
                        "conversions_raw",
                        CONVERSION_SOURCE_COLUMNS,
                    ):
                        cleaned_rows = []
                        invalid_rows = []

                        for row in batch:
                            # Identify the original source record,
                            # excluding Bronze ingestion metadata.
                            raw_values = row[:-1]

                            fingerprint = hashlib.sha256(
                                json.dumps(
                                    raw_values,
                                    ensure_ascii=False,
                                ).encode("utf-8")
                            ).hexdigest()

                            # Preserve repeated identical source rows.
                            ordinal = fingerprint_counts.get(
                                fingerprint, 0
                            ) + 1

                            fingerprint_counts[fingerprint] = ordinal

                            try:
                                cleaned = clean_conversion(
                                    row, valid_partner_ids
                                )
                            except ValueError as error:
                                invalid_rows.append((row, error))
                                continue

                            cleaned_rows.append((
                                fingerprint,
                                ordinal,
                                *cleaned,
                            ))

                        # Save valid conversion records.
                        if cleaned_rows:
                            target_cursor.executemany(
                                upsert_query, cleaned_rows
                            )
                            total_affected += target_cursor.rowcount

                        # Preserve rejected records for investigation.
                        if invalid_rows:
                            total_quarantined += quarantine_batch(
                                target_cursor,
                                "conversions_raw",
                                CONVERSION_SOURCE_COLUMNS,
                                invalid_rows,
                            )

                        # Commit valid records and errors together.
                        target_connection.commit()

    return total_affected, total_quarantined


def read_bronze_batches(cursor, table_name, columns):
    """Read a Bronze table in manageable batches."""

    query = sql.SQL("""
        SELECT {}
        FROM bronze.{}
        ORDER BY {};
    """).format(
        sql.SQL(", ").join(
            sql.Identifier(column) for column in columns
        ),
        sql.Identifier(table_name),
        sql.Identifier(columns[0]),
    )

    cursor.execute(query)

    while True:
        rows = cursor.fetchmany(BATCH_SIZE)

        if not rows:
            break

        yield rows


def load_all_transactions():
    """Process all five transactional tables in dependency order."""

    # Load registered partner IDs for reference validation.
    with get_connection() as connection:
        with connection.cursor() as cursor:
            cursor.execute("SELECT partner_id FROM silver.partners")
            valid_partner_ids = {
                row[0] for row in cursor.fetchall()
            }

    # 1. Impressions
    impressions, impressions_quarantined = upsert_transaction_table(
        "impressions_raw",
        "impressions",
        (
            "impression_id", "campaign_id", "creative_id",
            "partner_id", "impression_time", "placement_raw",
            "country", "device", "bot_score",
            "created_at", "updated_at", "ingested_at",
        ),
        (
            "impression_id", "campaign_id", "creative_id",
            "partner_id_raw", "partner_id", "partner_match_status",
            "impression_time", "placement_raw", "country",
            "device", "bot_score", "created_at", "updated_at",
            "source_ingested_at",
        ),
        lambda row: clean_impression(row, valid_partner_ids),
    )
    print(f"Impressions inserted or updated: {impressions}", flush=True)
    print(f"Impression records quarantined: {impressions_quarantined}", flush=True)

    # 2. Clicks
    clicks, clicks_quarantined = upsert_transaction_table(
        "clicks_raw",
        "clicks",
        (
            "click_id", "impression_id", "campaign_id",
            "creative_id", "partner_id", "click_time",
            "ip", "user_agent", "country", "device",
            "is_unique", "referrer_raw",
            "created_at", "updated_at", "ingested_at",
        ),
        (
            "click_id", "impression_id", "campaign_id",
            "creative_id", "partner_id_raw", "partner_id",
            "partner_match_status", "click_time",
            "ip", "user_agent", "country", "device",
            "is_unique", "referrer_raw",
            "created_at", "updated_at", "source_ingested_at",
        ),
        lambda row: clean_click(row, valid_partner_ids),
    )
    print(f"Clicks inserted or updated: {clicks}", flush=True)
    print(f"Click records quarantined: {clicks_quarantined}", flush=True)

    # 3. Conversion History
    conversions, rejected = load_conversion_history(valid_partner_ids)
    print(f"Conversion history inserted or updated: {conversions}", flush=True)
    print(f"Conversion records quarantined: {rejected}", flush=True)

    # 4. Conversion Touchpoints
    touchpoints, touchpoints_quarantined = upsert_transaction_table(
        "conversion_touchpoints_raw",
        "conversion_touchpoints",
        (
            "touchpoint_id", "conversion_id", "click_id",
            "touch_position", "weight",
            "created_at", "updated_at", "ingested_at",
        ),
        (
            "touchpoint_id", "conversion_id", "click_id",
            "touch_position", "weight",
            "created_at", "updated_at", "source_ingested_at",
        ),
        clean_touchpoint,
    )
    print(f"Touchpoints inserted or updated: {touchpoints}", flush=True)
    print(f"Touchpoint records quarantined: {touchpoints_quarantined}", flush=True)

    # 5. Revenue Adjustments
    adjustments, adjustments_quarantined = upsert_transaction_table(
        "revenue_adjustments_raw",
        "revenue_adjustments",
        (
            "adjustment_id", "conversion_id",
            "delta_amount", "reason", "adjusted_at",
            "created_at", "updated_at", "ingested_at",
        ),
        (
            "adjustment_id", "conversion_id",
            "delta_amount", "reason", "adjusted_at",
            "created_at", "updated_at", "source_ingested_at",
        ),
        clean_revenue_adjustment,
    )
    print(f"Revenue adjustments inserted or updated: {adjustments}", flush=True)
    print(f"Revenue adjustment records quarantined: {adjustments_quarantined}", flush=True)
    
    # Total records rejected during this processing run.
    total_quarantined = (
        impressions_quarantined
        + clicks_quarantined
        + rejected
        + touchpoints_quarantined
        + adjustments_quarantined
    )

    return total_quarantined



if __name__ == "__main__":

    run_id = start_pipeline_audit(
        "silver_processing",
        "process_transactions"
    )

    source_count = None

    try:
        source_tables = [
            "impressions_raw",
            "clicks_raw",
            "conversions_raw",
            "conversion_touchpoints_raw",
            "revenue_adjustments_raw",
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

        # Execute the existing Silver transformations.
        total_quarantined = load_all_transactions()

        # Record statistics only after successful completion.
        finish_pipeline_audit(
            run_id,
            "SUCCESS",
            source_count=source_count,
            processed_count=source_count,
            rejected_count=total_quarantined,
        )

        print(f"Total source records: {source_count}")
        print(f"Total records processed: {source_count}")
        print(f"Total records quarantined: {total_quarantined}")
        print("Silver transactional processing completed.")

    except Exception as error:
        finish_pipeline_audit(
            run_id,
            "FAILED",
            source_count=source_count,
            error_message=str(error),
        )

        print("Silver transactional processing failed.")
        raise
