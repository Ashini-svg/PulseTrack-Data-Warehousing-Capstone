import re
from datetime import datetime, timezone, timedelta
from decimal import Decimal, InvalidOperation



DATE_FORMATS = (
    "%d-%m-%Y",
    "%m/%d/%Y",
    "%b %d, %Y",
    "%d-%m-%Y %H:%M",
    "%d-%m-%Y %H:%M:%S",
    "%m/%d/%Y %H:%M",
    "%m/%d/%Y %H:%M:%S",
    "%b %d, %Y %H:%M:%S",
)


# Explicit UTC offsets for supported timezone abbreviations.
# US interpretations are used for CST, MST, PST and related labels.
TIMEZONE_OFFSETS = {
    "UTC": 0,
    "GMT": 0,
    "EST": -5,
    "EDT": -4,
    "CST": -6,
    "CDT": -5,
    "MST": -7,
    "MDT": -6,
    "PST": -8,
    "PDT": -7,
}


def parse_mixed_datetime(value: str | None) -> datetime | None:
    """Parse supported source dates and normalize timestamps to UTC."""
    if value is None or not value.strip():
        return None

    text = value.strip()
    named_timezone = None

    # Identify a timezone abbreviation at the end of the value.
    match = re.fullmatch(r"(.+?)\s+([A-Za-z]{2,5})", text)

    if match:
        text, abbreviation = match.groups()
        abbreviation = abbreviation.upper()

        if abbreviation not in TIMEZONE_OFFSETS:
            raise ValueError(
                f"Unsupported timezone abbreviation: {abbreviation}"
            )

        named_timezone = timezone(
            timedelta(hours=TIMEZONE_OFFSETS[abbreviation])
        )

    # Unix timestamp in seconds.
    if re.fullmatch(r"\d{10}", text):
        if named_timezone is not None:
            raise ValueError("Unexpected timezone on Unix timestamp")
        return datetime.fromtimestamp(int(text), tz=timezone.utc)

    # ISO date or datetime.
    try:
        parsed = datetime.fromisoformat(
            text.replace("Z", "+00:00")
        )
    except ValueError:
        # Try the other supported date formats.
        for date_format in DATE_FORMATS:
            try:
                parsed = datetime.strptime(text, date_format)
                break
            except ValueError:
                continue
        else:
            raise ValueError(f"Unsupported or invalid date: {text}")

    if named_timezone is not None:
        if parsed.tzinfo is not None:
            raise ValueError("Conflicting timezone information")

        parsed = parsed.replace(tzinfo=named_timezone)

    elif parsed.tzinfo is None:
        # Documented assumption for timestamps without a timezone.
        parsed = parsed.replace(tzinfo=timezone.utc)

    return parsed.astimezone(timezone.utc)


def parse_mixed_boolean(value: str | None) -> bool | None:
    """Convert mixed source boolean representations."""
    if value is None or not value.strip():
        return None

    text = value.strip().lower()

    if text in {"1", "true", "t", "y", "yes", "test", "legacy"}:
        return True

    if text in {"0", "false", "f", "n", "no"}:
        return False

    raise ValueError(f"Invalid boolean value: {value}")


def parse_mixed_decimal(value: str | None) -> Decimal | None:
    """Convert supported financial values into exact decimals."""
    if value is None:
        return None

    text = value.strip()

    if text.upper() in {"", "N/A", "NA", "NULL", "NONE"}:
        return None

    # Remove supported currency markers and formatting.
    text = (
        text.upper()
        .replace("USD", "")
        .replace("$", "")
        .replace(",", "")
        .strip()
    )

    try:
        amount = Decimal(text)
    except InvalidOperation as error:
        raise ValueError(f"Invalid numeric value: {value}") from error

    if not amount.is_finite():
        raise ValueError(f"Invalid numeric value: {value}")

    return amount
