import os

import psycopg


def get_connection() -> psycopg.Connection:
    """Create a connection to the PulseTrack PostgreSQL database."""
    return psycopg.connect(
        host=os.getenv("PGHOST", "localhost"),
        port=os.getenv("PGPORT", "5432"),
        dbname=os.getenv("PGDATABASE", "pulsetrack_capstone"),
        user=os.getenv("PGUSER", "postgres"),
        password=os.getenv("PGPASSWORD"),
    )
