"""
PulseTrack - Automated Pipeline Validation

Validates Gold-to-Mart reconciliation, attribution totals,
and the OLAP monthly materialized cache.

Raises an error when validation fails, allowing Airflow
to mark the task as FAILED.
"""

from decimal import Decimal
from pathlib import Path

from db_connection import get_connection


PROJECT_DIR = Path(__file__).resolve().parent.parent

VALIDATION_SQL = (
    PROJECT_DIR
    / "sql"
    / "validation"
    / "verify_mart_quality.sql"
)


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def validate_pipeline():
    sql_text = VALIDATION_SQL.read_text(encoding="utf-8-sig")

    with get_connection() as conn:
        with conn.cursor() as cursor:

            # The SQL file contains two SELECT queries.
            cursor.execute(sql_text)

            # ----------------------------------------
            # 1. Gold-to-Mart reconciliation
            # ----------------------------------------
            checks = cursor.fetchall()

            require(
                len(checks) == 14,
                f"Expected 14 checks, received {len(checks)}",
            )

            failures = []

            for metric, expected, actual, difference, status in checks:
                print(
                    f"{status}: {metric} "
                    f"(expected={expected}, actual={actual})",
                    flush=True,
                )

                if status != "PASS" or difference != 0:
                    failures.append(metric)

            require(
                not failures,
                "Reconciliation failed: " + ", ".join(failures),
            )

            print("Gold-to-Mart reconciliation: PASS")

            # ----------------------------------------
            # 2. Attribution reconciliation
            # ----------------------------------------
            require(
                cursor.nextset(),
                "Attribution query result is missing",
            )

            attribution = cursor.fetchone()

            require(
                attribution is not None,
                "Attribution query returned no results",
            )

            (
                gold_conversions,
                partner_credit,
                gold_revenue,
                partner_revenue,
                creative_revenue,
            ) = attribution

            credit_difference = abs(
                Decimal(str(gold_conversions))
                - Decimal(str(partner_credit))
            )

            revenue_difference = abs(
                Decimal(str(gold_revenue))
                - Decimal(str(partner_revenue))
            )

            require(
                credit_difference <= Decimal("0.0001"),
                "Weighted conversion credit mismatch",
            )

            require(
                revenue_difference <= Decimal("0.01"),
                "Partner attributed revenue mismatch",
            )

            print("Attribution reconciliation: PASS")

            # Creative attribution may legitimately be lower
            # because some creative references are unresolved.
            print(
                f"Creative attributed revenue: {creative_revenue}"
            )

            # ----------------------------------------
            # 3. OLAP cache validation
            # ----------------------------------------
            cursor.execute("""
                SELECT COUNT(*)
                FROM (
                    (
                        SELECT *
                        FROM semantic.campaign_performance_monthly

                        EXCEPT ALL

                        SELECT *
                        FROM semantic.campaign_performance_monthly_cache
                    )

                    UNION ALL

                    (
                        SELECT *
                        FROM semantic.campaign_performance_monthly_cache

                        EXCEPT ALL

                        SELECT *
                        FROM semantic.campaign_performance_monthly
                    )
                ) differences
            """)

            mismatched_rows = cursor.fetchone()[0]

            require(
                mismatched_rows == 0,
                f"OLAP cache mismatch: {mismatched_rows} rows",
            )

            print("OLAP cache validation: PASS")

    print("\nAll pipeline validations passed.")


if __name__ == "__main__":
    validate_pipeline()
