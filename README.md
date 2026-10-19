# PulseTrack — Data Warehousing Capstone

**Programme:** Zero to Data Engineer — Data Warehouse Design Fundamentals  
**Course provider:** Zuu Crew Machine Learning Academy  
**Implemented stack:** Python 3.11, PostgreSQL 18, psycopg 3.3.6, Apache Airflow 3.3.0 (Ubuntu/WSL 2), SQL; DataGrip was used for development and verification.

## Overview

PulseTrack is a performance-marketing data warehousing project. It processes eleven relational CSV datasets, advertiser and partner JSONL profiles, and a Kafka-style conversion-event-log **export** (not a running Kafka broker). The platform follows:

**CSV/JSONL/event-log sources → PostgreSQL source / Bronze → Silver → Gold Enterprise Data Warehouse → six Data Marts → semantic/OLAP layer → business analytics.**

Python loads and cleans the data; PostgreSQL stores the layers and performs SQL transformations. An **11-task Apache Airflow DAG** orchestrates the stages and runs a final analytical validation. The report includes source profiling, dimensional modelling, SCD Type 2 advertiser history, attribution, reconciliations, controlled incremental and recovery tests, and ten business analyses. A separate test reproduced duplicate delivery of 50,000 new impressions and propagated the records through the reporting layers.

## Source-data availability (public repository)

**The `data/` folder and its CSV, JSONL and event-log files are intentionally NOT included in this public GitHub repository.** The original datasets were provided by **Zuu Crew Machine Learning Academy** for the capstone assessment, and permission to redistribute them publicly has not been established.

To reproduce the complete pipeline, an authorised user must obtain the original assessment datasets from the course provider and place them in a local `data/` folder with the exact filenames shown in **Step 2**. The GitHub repository supplies the Python, SQL, DAG, diagrams and report, but **it cannot complete an end-to-end rebuild without the original data**. The synthetic Q5 data-generation script is supplied for reproducibility, but it must not be run on the original dataset.

Do not publish the private lecturer submission ZIP, PostgreSQL credentials, raw source exports or a locally populated `data/` folder. The report contains assessed analysis and screenshots; check it for source-sensitive information before publishing future revisions.

## Folder structure

```text
PulseTrack/
├── dags/
│   └── pulsetrack_pipeline.py
├── data/                         # LOCAL ONLY; excluded from public GitHub repository
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
├── .gitignore                     # Excludes local data, secrets and generated files
├── README.md
└── PulseTrack_Report.pdf          # Detailed project report
```

`load_gold_dimensions.sql`, `load_gold_facts.sql` and `load_mart.sql` contain data-loading/refresh logic and are invoked by the corresponding Python loaders. They are **not** extra schema-initialisation scripts. `scripts/q5_prepare_impressions.py` is a **test-data generation utility**, not a stage in the 11-task production DAG.

## Prerequisites

- PostgreSQL server, a PostgreSQL account with permission to create the database and schemas, and a SQL client such as DataGrip or `psql`.
- Python **3.11** and ability to create a virtual environment (`.venv`).
- Apache Airflow **3.3.0** if running the orchestrated DAG; the implementation was tested in Ubuntu under WSL 2 using `LocalExecutor`. Airflow is installed **separately** from the project Python environment.
- The 11 original CSV files, two JSONL files and event-log export named below. A full rebuild requires these source files.

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

The CSV source loader takes an **explicit database argument** (`--database pulsetrack_capstone`) rather than relying on `PGDATABASE` for its target. Its allowed database names are `pulsetrack_capstone`, `pulsetrack_csv_test` and `pulsetrack_backfill_test`. Downstream scripts obtain the database from `PGDATABASE` (default: `pulsetrack_capstone`). **Set both consistently** and check the actual connection before starting. The Airflow DAG hardcodes `pulsetrack_capstone` for its CSV-loading task; do not use it for a differently named test database without changing and retesting that configuration.

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

**Destructive DDL warning:** the supplied-source `pulsetrack_source_schema.sql` includes `DROP SCHEMA IF EXISTS pulsetrack_raw CASCADE`. **Run it only in a new, empty database** where resetting the raw schema is intended. Do not execute it against an existing populated warehouse. Inspect other DDL files before executing them against populated databases.

The proposed ordering follows schema dependencies; unlike the populated end-to-end pipeline, a from-scratch installation of every SQL file has **not** been separately verified as one automated rebuild. `create_semantic_cache.sql` may initially have no cache rows before the Mart is populated; `load_mart.py` refreshes the cache after loading the Mart. Resolve any environment- or prerequisite-specific errors rather than skipping failed SQL statements.

## Step 2 — Provide the source files (not supplied on GitHub)

After obtaining them **from the course provider through authorised access**, place the eleven original CSVs, two JSONLs and event log in a **local, untracked** `data/` directory, retaining their original filenames:

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

The Python CSV loader (`scripts/load_source_csv.py`) checks file existence and column headers, stages the CSV data using PostgreSQL `COPY`, and compares rows with `EXCEPT ALL`. It inserts additional row occurrences without duplicating an unchanged snapshot; it refuses a source-file change that would silently remove existing database rows. All eleven imports operate in one transaction. It does **not** perform arbitrary existing-row corrections, identify all newly duplicated rows inside a changed source file, or recreate missing table schemas. By default it reads `data/`; the `PULSETRACK_DATA_DIR` environment variable can override that path for isolated testing.

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
| Impressions in original Gold fact | 300,000 |
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

For additional SQL checks, use the files in `sql/validation/`, including `verify_bronze_ingestion.sql`, `verify_silver_quality.sql`, `verify_gold_dimensions.sql`, `verify_gold_facts.sql`, `verify_mart_quality.sql`, `verify_semantic_model.sql` and `pulsetrack_business_analytics.sql`. The final script contains the ten analytical queries. `verify_semantic_model.sql` includes **Query 16**, the partner-channel allocation conservation test (546 dates, zero mismatches). The report contains the detailed evidence, including the new Q5 and Q8 screenshots.

## Scope and limitations

- The SQL schemas and supplied source datasets must be prepared before the pipeline runs; the Airflow DAG is not a one-click installation for an empty PostgreSQL server.
- Initial CSV loading, unchanged CSV reruns, restoration of a removed test row and the integrated 11-task DAG were verified. An **additional isolated test** delivered 50,000 synthetic historical-period impressions twice: the first delivery inserted 50,000, the second inserted **zero**, and all 350,000 impressions reconciled across Source, Bronze, Silver and Gold after downstream processing.
- This is **manual historical-period replay and duplicate-delivery evidence**, not a general automated date-scoped backfill system. Late source-row corrections, updates and deletions are not automatically handled by the append-only CSV loader; arbitrary changed-data scenarios remain unverified.
- All six Data Marts are transactionally **fully refreshed**. Date-specific incremental Mart updates were not implemented.
- The Airflow DAG was successfully tested using **manual triggering** (`schedule=None`). Its retry configuration exists, but automatic retry completion was not independently demonstrated by the controlled recovery test.
- The supplied dataset does not contain five complete years of history; unresolved references are preserved where appropriate.
- JSONL and event-log landing keys use source filename and line number. Identical content arriving under a new filename is not universally deduplicated by content checksum.
- A completely fresh installation and end-to-end rebuild of all schemas and data on a new PostgreSQL instance has **not** been independently executed as one reproducibility test.

The final report contains the exact business rules, Q5/Q8 screenshots, reconciliations, caveats and tested results. Never commit PostgreSQL credentials, local virtual environments, original raw datasets or generated test CSVs to GitHub.

## Supplementary Q5/Q8 validation (19 October 2026)

### Q5 — Controlled 50,000-record duplicate-delivery and historical-period replay

This experiment was performed **only in a separate database**, `pulsetrack_backfill_test`, created as a PostgreSQL `TEMPLATE` copy of the completed `pulsetrack_capstone` database (both approximately 938 MB when cloned). Original source files were not changed. The input experiment copied the 11 original CSVs to an external `PulseTrack-Q5-TestData` folder, then generated 50,000 additional synthetic impression IDs using the existing impression attributes and dates.

| Stage / check | Observed result |
|---|---:|
| Original impressions before test | 300,000 |
| New impressions in first CSV delivery | +50,000 |
| New impressions in second delivery of unchanged CSV | **0** |
| Source impressions after both deliveries | 350,000 |
| Bronze impressions after processing | 350,000 |
| Silver impressions after processing | 350,000 |
| Gold impressions after processing | 350,000 |
| New impression records quarantined | 0 |
| Gold-to-Mart checks | 14 PASS |
| Attribution reconciliation | PASS |
| OLAP cache validation | PASS |

**How the isolated test was performed** (for authorised users with the original source data):

1. Back up or protect the completed database. Create an isolated copy named `pulsetrack_backfill_test`; `CREATE DATABASE ... WITH TEMPLATE ...` must be run from another database, outside a transaction, while the source database has **no active connections**. Do not run schema-reset SQL on the populated clone.
2. Copy **all 11 unmodified CSV files** from `data/` into a separate folder named exactly `PulseTrack-Q5-TestData` outside the project. Use the cloned database and **never** edit the original CSV files.
3. In Windows PowerShell from the project root, activate `.venv`, configure PostgreSQL credentials privately and run the commands below. If your personal `pgpass.conf` entry is database-specific, add a private entry for **`pulsetrack_backfill_test`** as well (or securely set a temporary `PGPASSWORD` in the terminal). The preparation script intentionally rejects other folder names and refuses to append its synthetic rows a second time.

```powershell
$env:PGDATABASE = "pulsetrack_backfill_test"
$env:PULSETRACK_DATA_DIR = "$env:USERPROFILE\Downloads\PulseTrack-Q5-TestData"

# Verify the actual database connection before making changes.
python -c "import sys; sys.path.insert(0,'scripts'); from db_connection import get_connection; c=get_connection(); db=c.execute('SELECT current_database()').fetchone()[0]; c.close(); print(db); assert db == 'pulsetrack_backfill_test'"

# Run ONCE against the copied CSV directory.
python scripts/q5_prepare_impressions.py

# Deliver once, then deliver the SAME file again.
python scripts/load_source_csv.py --database pulsetrack_backfill_test
python scripts/load_source_csv.py --database pulsetrack_backfill_test

# Downstream manual processing, in this order.
python scripts/ingest_postgres.py
python scripts/process_transactions.py
python scripts/load_gold.py
python scripts/load_mart.py
python scripts/validate_pipeline.py
```

Stop if the database verification fails or any processing step reports an error. All downstream scripts must inherit `PGDATABASE=pulsetrack_backfill_test`. **Do not trigger the Airflow DAG for this experiment:** its first task hardcodes `pulsetrack_capstone`, whereas the other scripts use `PGDATABASE`. The test copied an already populated, valid database; it is **not** a test of creating every SQL schema from zero.

The end-to-end processing and validation passed. Because the test uses copies of existing impression attributes with new IDs, it demonstrates controlled historical-period replay and repeated delivery, **not** automatic discovery of every late-arriving correction or every type of source-data change.

### Q8 — Partner-channel allocation conservation

**Query 16** in `sql/validation/verify_semantic_model.sql` compared `mart.partner_daily` with `semantic.partner_channel_allocation_daily` by `date_key` using a full outer join and a tolerance of `0.000001`. It returned **546 dates checked, zero mismatched dates and zero maximum differences** in click credit, weighted conversion credit and attributed revenue.

The result shows the tested allocation conserves those totals. It does not by itself establish the correctness of all business weighting assumptions.


## Public repository hygiene

Publicly include the DAG, Python scripts (including `q5_prepare_impressions.py`), SQL schema/load/validation scripts (including Q8 Query 16), architecture figures, this README, the revised report PDF and `.gitignore`. Keep the instructor-provided `data/` files, local test folders, `.venv/`, `__pycache__/`, `.env` secrets, `pgpass.conf`, `.pgpass` and Airflow runtime files **out** of the repository. A `.gitignore` rule does **not** remove files that were previously committed, and browser uploads may bypass ignore rules; inspect uploads before committing.

For this public repository, datasets are deliberately unavailable rather than missing by accident. Dataset access is limited to appropriately authorised course recipients.
