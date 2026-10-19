"""Prepare a one-time synthetic impression batch for isolated Q5 tests only."""
import csv
import os
from pathlib import Path

folder = Path(os.environ["PULSETRACK_DATA_DIR"]).resolve()
if folder.name != "PulseTrack-Q5-TestData":
    raise RuntimeError("Refusing to modify a non-test folder")
csv_path = folder / "impressions_raw.csv"
if not csv_path.is_file():
    raise FileNotFoundError(csv_path)

sample = []
total = 0
with csv_path.open("r", encoding="utf-8-sig", newline="") as file:
    reader = csv.DictReader(file)
    columns = reader.fieldnames
    if not columns or "impression_id" not in columns:
        raise ValueError("Expected impression_id column")
    for row in reader:
        total += 1
        if row["impression_id"].startswith("Q5IMP"):
            raise RuntimeError("Q5 records already exist; refusing to append twice")
        if total <= 50000:
            sample.append(row.copy())
if total != 300000:
    raise RuntimeError(f"Expected 300000 original rows, found {total}")
with csv_path.open("a", encoding="utf-8", newline="") as file:
    writer = csv.DictWriter(file, fieldnames=columns)
    for number, row in enumerate(sample, start=1):
        row["impression_id"] = f"Q5IMP{number:06d}"
        writer.writerow(row)
print("Original impressions:", total)
print("New test impressions:", len(sample))
print("Expected total impressions:", total + len(sample))
print("Test CSV:", csv_path)
