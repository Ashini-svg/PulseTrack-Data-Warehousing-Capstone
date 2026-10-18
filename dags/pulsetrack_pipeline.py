"""
PulseTrack Capstone - Apache Airflow Pipeline

Orchestrates existing Bronze, Silver, Gold and Data Mart
Python scripts using Apache Airflow 3.

The ETL scripts execute using the project's Windows
Python virtual environment.

Initially configured for manual triggering only.
"""
import os
from datetime import timedelta
from pathlib import Path
import shlex

import pendulum

from airflow.sdk import DAG
from airflow.providers.standard.operators.bash import BashOperator


# Locate the project directory.
PROJECT_DIR = Path(
    os.environ.get("PULSETRACK_PROJECT_DIR")
    or Path(__file__).resolve().parent.parent
).expanduser().resolve()

# Support Windows and Linux virtual environments.
PYTHON_CANDIDATES = [
    PROJECT_DIR / ".venv" / "Scripts" / "python.exe",
    PROJECT_DIR / ".venv" / "bin" / "python",
]

# Allow an explicitly configured Python interpreter.
configured_python = os.environ.get("PULSETRACK_PYTHON")

if configured_python:
    PYTHON_EXE = Path(configured_python).expanduser()
else:
    PYTHON_EXE = next(
        (path for path in PYTHON_CANDIDATES if path.is_file()),
        None,
    )

if PYTHON_EXE is None or not PYTHON_EXE.is_file():
    raise FileNotFoundError(
        "PulseTrack Python environment not found. "
        "Create the project's .venv or configure "
        "PULSETRACK_PYTHON."
    )


# Pipeline execution order.
STAGES = [
    ("load_source_csv", "load_source_csv.py"),
    ("ingest_postgres", "ingest_postgres.py"),
    ("ingest_jsonl", "ingest_jsonl.py"),
    ("ingest_event_log", "ingest_event_log.py"),
    ("process_dimensions", "process_dimensions.py"),
    ("process_jsonl_profiles", "process_jsonl_profiles.py"),
    ("process_transactions", "process_transactions.py"),
    ("process_event_log", "process_event_log.py"),
    ("load_gold", "load_gold.py"),
    ("load_mart", "load_mart.py"),
    ("validate_pipeline", "validate_pipeline.py"),
]


with DAG(
    dag_id="pulsetrack_pipeline",
    description="PulseTrack Bronze-to-OLAP data pipeline",
    start_date=pendulum.datetime(
        2026, 10, 1, tz="Asia/Colombo"
    ),
    schedule=None,
    catchup=False,
    max_active_runs=1,
    default_args={
        "owner": "pulsetrack",
        "retries": 1,
        "retry_delay": timedelta(minutes=2),
    },
    tags=["pulsetrack", "capstone", "data-warehouse"],
) as dag:

    previous_task = None

    for task_id, script_name in STAGES:

        python_command = shlex.quote(str(PYTHON_EXE))

        # Relative script paths work with the configured cwd.
        script_command = shlex.quote(
            f"scripts/{script_name}"
        )
        
        command = (
            "set -euo pipefail\n"
            f"{python_command} {script_command}"
        )

        # CSV loading requires an explicit target database.
        if task_id == "load_source_csv":
            command += " --database pulsetrack_capstone"

        current_task = BashOperator(
            task_id=task_id,
            bash_command=command,
            cwd=str(PROJECT_DIR),
            do_xcom_push=False,
            skip_on_exit_code=None,
        )

        if previous_task is not None:
            previous_task >> current_task

        previous_task = current_task
