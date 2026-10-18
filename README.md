# PulseTrack — Data Warehousing Capstone

**Programme:** Zero to Data Engineer — Data Warehouse Design Fundamentals  
**Course provider:** Zuu Crew Machine Learning Academy  
**Implemented stack:** Python 3.11, PostgreSQL, psycopg 3.3.6, Apache Airflow 3.3.0 (Ubuntu/WSL 2), SQL; DataGrip used for development and verification.

## Overview

PulseTrack is a performance-marketing data warehousing project. It processes eleven relational CSV datasets, advertiser and partner JSONL profiles, and a Kafka-style conversion-event-log **export** (not a running Kafka broker). The platform follows:

**CSV/JSONL/event-log sources → PostgreSQL source / Bronze → Silver → Gold Enterprise Data Warehouse → six Data Marts → semantic/OLAP layer → business analytics.**

Python loads and cleans the data; PostgreSQL stores the layers and performs SQL transformations. An **11-task Apache Airflow DAG** orchestrates the stages and runs a final analytical validation. The report includes source profiling, dimensional modelling, SCD Type 2 advertiser history, attribution, reconciliations, controlled replay/recovery tests, and ten business analyses.

## Source-data availability (public repository)

**The `data/` directory is intentionally omitted from this public repository.** The source datasets were provided by **Zuu Crew Machine Learning Academy** for the capstone assessment. Public redistribution rights have not been established. Authorized users must obtain the original files from the course provider and place them in the `data/` directory shown below before attempting a rebuild. This public repository is **not runnable end to end without those files**.

The accompanying report presents the academic analysis and test evidence; review any screenshots or embedded source samples before public distribution to avoid revealing source-sensitive information.

## Folder structure

```text
PulseTrack/
├── dags/
│   └── pulsetrack_pipeline.py
├── data/                         # Required for running; NOT committed to public repository
├── figures/                      # Diagrams and supporting visual materials
├── scripts/                      # Python ingestion, processing, loading, audit and validation
├── sql/
│   ├── 00_create_database.sql
│   ├── pulsetrack_source_schema.sql
│   ├── create_audit_tables.sql
│   ├── create_bronze_tables.sql
│   ├── create_silver_tables.sql
│   ├── create_gold_tables.sql
│   ├── create_mart_tables.sql
│   ├── create_semantic_model.sql
│   ├── create_semantic_cache.sql
│   ├── load_gold_dimensions.sql
│   ├── load_gold_facts.sql
│   ├── load_mart.sql
│   └── validation/
│       └── *.sql                  # Bronze/Silver/Gold/Mart/semantic checks and business analytics
├── README.md
└── PulseTrack_Report.pdf          # Detailed submission report
```

`load_gold_dimensions.sql`, `load_gold_facts.sql` and `load_mart.sql` contain data-loading/refresh logic and are invoked by the corresponding Python loaders. They are **not** extra schema-initialisation scripts.

## Prerequisites

- PostgreSQL server, a PostgreSQL account with permission to create the database and schemas, and a SQL client such as DataGrip or `psql`.
- Python **3.11** and ability to create a virtual environment (`.venv`).
- Apache Airflow **3.3.0** if running the orchestrated DAG; the implementation was tested in Ubuntu under WSL 2 using `LocalExecutor`. Airflow is installed **separately** from the project Python environment.
- The original instructor-provided input datasets, in the filenames listed below. A rebuild will not work without the data.

### Python environment

From the project root in **Windows PowerShell**:

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install "psycopg[binary]==3.3.6"
```

For a native **Linux/WSL Python execution** (instead of Windows Python):

```bash
python3.11 -m venv .venv
source .venv/bin/activate
python -m pip install 'psycopg[binary]==3.3.6'
```

`psycopg` is the verified database driver version. Any additional local dependencies required by a particular environment should be installed according to the imports in the included scripts; this is not a frozen one-command deployment environment.

## PostgreSQL connection and password setup

The reusable `scripts/db_connection.py` reads these optional environment variables:

| Variable | Default | Meaning |
|---|---|---|
| `PGHOST` | `localhost` | PostgreSQL host |
| `PGPORT` | `5432` | PostgreSQL port |
| `PGDATABASE` | `pulsetrack_capstone` | Target for downstream processing scripts |
| `PGUSER` | `postgres` | PostgreSQL account |
| `PGPASSWORD` | unset | Optional password; do not put credentials into source code |

The CSV source loader takes an **explicit database argument** (`--database pulsetrack_capstone`) rather than relying on `PGDATABASE` for its target. The Airflow DAG is configured to use that target for its first task. Rebuilders should use an isolated database and review that setting before making changes.

**Recommended for the tested Windows-Python setup:** use the personal PostgreSQL password file, outside this project:

1. Create `%APPDATA%\postgresql\pgpass.conf` in your own Windows profile.
2. Add one line, replacing the placeholder with **your own** PostgreSQL password:

   ```text
   localhost:5432:pulsetrack_capstone:postgres:YOUR_PASSWORD
   ```

3. Keep the file private; never copy it into the project, ZIP, or Git repository.

If `PGPASSWORD` is unset, `psycopg`/libpq can use this personal password file. To verify connectivity after database creation, run from the project root:

```powershell
python -c "import sys; sys.path.insert(0, 'scripts'); from db_connection import get_connection; c=get_connection(); print(c.execute('SELECT current_database()').fetchone()); c.close()"
```

**Native Linux/WSL Python:** use `~/.pgpass` with the same entry and run `chmod 600 ~/.pgpass`. **Note:** in the demonstrated WSL Airflow configuration the DAG invokes **Windows** `.venv\Scripts\python.exe`; that Python process uses the **Windows** password-file location, not WSL's `~/.pgpass`. A hosted database or different user account requires corresponding changes to host, database, user and credentials. Prefer a dedicated least-privilege user for any non-local deployment.

## Step 1 — Create the database and tables

**Fresh-database setup only.** Using DataGrip, first connect to the default **`postgres`** database, enable **autocommit**, and execute `sql/00_create_database.sql`:

```sql
CREATE DATABASE pulsetrack_capstone;
```

If the target database already exists, **do not run the creation script**. Connect to `pulsetrack_capstone` for subsequent SQL files. Use these exact filenames in the following expected dependency order:

```text
1. sql/pulsetrack_source_schema.sql
2. sql/create_audit_tables.sql
3. sql/create_bronze_tables.sql
4. sql/create_silver_tables.sql
5. sql/create_gold_tables.sql
6. sql/create_mart_tables.sql
7. sql/create_semantic_model.sql
8. sql/create_semantic_cache.sql
```

**Destructive DDL warning:** `pulsetrack_source_schema.sql` is based on the supplied lecturer schema and includes `DROP SCHEMA IF EXISTS pulsetrack_raw CASCADE`. **Run it only in a new, empty database** where resetting the raw schema is intended. Do not execute it against the existing populated warehouse. Inspect other DDL files before executing them on any database that already holds data.

The proposed ordering follows schema dependencies; unlike the populated end-to-end pipeline, a from-scratch installation of every SQL file has **not** been separately verified as one automated rebuild. Fix any environment- or prerequisite-specific failures before proceeding; do not skip failed SQL statements.

## Step 2 — Provide the source files

Place the **eleven original CSVs**, two JSONLs and event log in the project-root `data/` directory, retaining their original filenames:

```text
data/
├── account_managers_raw.csv
├── advertisers_raw.csv
├── partners_raw.csv
├── offers_raw.csv
├── campaigns_raw.csv
├── creatives_raw.csv
├── impressions_raw.csv
├── clicks_raw.csv
├── conversions_raw.csv
├── conversion_touchpoints_raw.csv
├── revenue_adjustments_raw.csv
├── advertiser_accounts.jsonl
├── partner_profiles.jsonl
└── pulsetrack_conversions.log
```

The Python CSV loader (`scripts/load_source_csv.py`) checks file existence and column headers, stages the CSV data using PostgreSQL `COPY`, and compares rows with `EXCEPT ALL`. It inserts additional row occurrences without duplicating unchanged rows; it refuses a source-file change that would silently remove existing database rows. All eleven table imports operate in one database transaction. It does not perform arbitrary existing-row corrections or recreate missing table schemas.

## Step 3 — Execute the pipeline

### Option A: Run the eleven scripts manually

In **Windows PowerShell**, with the Python `.venv` active, from the project root:

```powershell
python scripts/load_source_csv.py --database pulsetrack_capstone
python scripts/ingest_postgres.py
python scripts/ingest_jsonl.py
python scripts/ingest_event_log.py
python scripts/process_dimensions.py
python scripts/process_jsonl_profiles.py
python scripts/process_transactions.py
python scripts/process_event_log.py
python scripts/load_gold.py
python scripts/load_mart.py
python scripts/validate_pipeline.py
```

Each command must succeed before running the next. Python loading scripts execute the matching SQL transformations where applicable; do not re-run Gold and Mart load SQL unnecessarily after successful loaders.

### Option B: Run the Airflow DAG

The file `dags/pulsetrack_pipeline.py` defines DAG ID **`pulsetrack_pipeline`** and eleven sequential `BashOperator` tasks. The DAG is **manually triggered** (`schedule=None`, `catchup=False`), with `max_active_runs=1` and one retry per failed task after two minutes. It is not a configured daily schedule and does not demonstrate automatic date-partition backfill.

1. Install and configure **Apache Airflow 3.3.0** separately; enable a working executor and DAG processor/scheduler as appropriate for the installation. A Python 3.11 Airflow installation should use the official constraints and installation guidance for the chosen OS.
2. Make the DAG accessible under Airflow's `dags/` directory, e.g. by a local file copy or symlink. The project remains in a separately accessible directory.
3. Configure `PULSETRACK_PROJECT_DIR` for the DAG's runtime process to the **absolute project-root path**. On WSL this may be a path under `/mnt/c/...`; preserve spaces safely with quoting. The DAG selects `.venv/Scripts/python.exe` on Windows or `.venv/bin/python` on Linux, unless overridden by `PULSETRACK_PYTHON`.
4. In the **tested WSL→Windows-Python configuration**, keep the Windows `.venv` in the project root so Airflow can invoke the Windows Python executable. Ensure PostgreSQL is reachable by that process and Windows credentials are configured as above. Environment variables must be visible to the Airflow processes parsing/executing the DAG—not only to an unrelated terminal.
5. Check discovery with `airflow dags list` and `airflow tasks list pulsetrack_pipeline`, then trigger `pulsetrack_pipeline` from the web interface. Confirm all **11 tasks** show Success and inspect `validate_pipeline` logs.

## Validation and expected results

These figures are **observed results for the supplied test dataset**, not generic hard-coded rules that will hold for changed files:

| Verification | Observed result |
|---|---:|
| PostgreSQL relational source records, 11 tables | 774,344 |
| Original JSONL records | 660 |
| Original event-log lines | 183,162 |
| Source records/lines retained across Bronze | 958,166 |
| Distinct business conversions in Gold | 90,000 |
| Conversion-history rows in Silver | 126,380 |
| Conversion touchpoints | 183,529 |
| Revenue adjustments | 12,000 |
| Six Data Mart tables, combined output rows | 687,318 |
| Monthly OLAP semantic view/cache | 7,200 rows each |
| Gold-to-Mart reconciliation checks | 14 PASS |
| Attribution reconciliation | PASS |
| OLAP cache validation | PASS |
| Airflow DAG, 18 Oct 2026 | **11/11 tasks SUCCESS**, version 3, ~4m 25s |

The six Data Mart row counts refer to **aggregate reporting rows**, not distinct source transactions. PostgreSQL `audit.pipeline_runs` logs **ten internal processing stages** (three Bronze, four Silver, two Gold, one Mart). The CSV-loading and final validation task outcomes are available in Airflow logs, not as separate audit stages.

For additional SQL checks, use the files in `sql/validation/`, including `verify_bronze_ingestion.sql`, `verify_silver_quality.sql`, `verify_gold_dimensions.sql`, `verify_gold_facts.sql`, `verify_mart_quality.sql`, `verify_semantic_model.sql` and `pulsetrack_business_analytics.sql`. The final script contains the ten analytical queries. The report provides the detailed evidence and business interpretations.

## Scope and limitations

- The SQL schemas and source datasets must be prepared before the pipeline is run; the DAG is not a one-click installation of an empty PostgreSQL server.
- Initial CSV loading, idempotent CSV reruns, restoration of a removed test row and the integrated 11-task DAG were verified. Complete processing of a newly appended *historical* source record through all layers was **not** separately demonstrated.
- CSV source updates/deletions are not applied automatically by the append-only loader.
- The six Data Marts are transactionally **fully refreshed**; date-specific incremental Mart loading and automated backfill have not been demonstrated.
- The DAG was tested with **manual triggering**. Its retry configuration exists, but automatic retry completion was not separately proven by the controlled recovery test.
- The supplied dataset does not provide five full years of history; unresolved references are preserved where appropriate.
- JSONL/event-log source keys are filename and line number, so identical data delivered under a different filename is not fully protected by a content-based file checksum.

The final report provides the precise business rules, reconciliation details, figures and tested limitations. Do not copy PostgreSQL password files, raw datasets or virtual environments into public repositories.

## GitHub repository hygiene

Commit the Python and SQL source files, DAG, README, diagrams, report PDF (after a source-sensitive-content review) and `.gitignore`. Do **not** commit instructor datasets, `.venv/`, `__pycache__/`, `*.pyc`, `pgpass.conf`, `.pgpass`, `.env` secrets, or Airflow runtime databases and logs. If files were committed previously, adding `.gitignore` alone does not untrack them.
