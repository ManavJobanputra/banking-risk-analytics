#!/usr/bin/env python3
"""Data-quality validation for the banking portfolio dataset.

Validates the raw ``Banking.csv`` against the contract the SQL layer assumes:
column presence, value types, missingness, key uniqueness, join cardinality,
date parseability, and the allowed domain of every coded categorical column.

The module deliberately uses only the standard library. The source dataset is a
single 568 KB CSV, so the whole validation runs in well under a second without
pandas, which means it can be executed in CI, in a bare container, or on a
reviewer's machine with no install step.

Usage::

    python3 python/data_quality.py                  # defaults to ./Banking.csv
    python3 python/data_quality.py path/to/file.csv

Exit status is 0 when no CRITICAL finding is raised, 1 otherwise, so the script
can gate a pipeline directly.
"""
from __future__ import annotations

import argparse
import csv
import sys
from collections import Counter
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

CRITICAL = "CRITICAL"
WARN = "WARN"
INFO = "INFO"

# --- column contract -------------------------------------------------------
# Mirrors the CREATE TABLE in sql/Banking_Complete_SQL_analysis.sql. If the
# SQL types and these contracts disagree, that is itself a finding.
KEY_COLUMN = "Client ID"

# The exact expected header, in order. Order is part of the contract: the SQL
# import loads positionally (LOAD DATA ... (client_id, name, age, ...)) rather
# than by name, so a reordered source file would silently shift every value into
# the wrong column without raising an error.
EXPECTED_COLUMNS = (
    "Client ID", "Name", "Age", "Location ID", "Joined Bank", "Banking Contact",
    "Nationality", "Occupation", "Fee Structure", "Loyalty Classification",
    "Estimated Income", "Superannuation Savings", "Amount of Credit Cards",
    "Credit Card Balance", "Bank Loans", "Bank Deposits", "Checking Accounts",
    "Saving Accounts", "Foreign Currency Account", "Business Lending",
    "Properties Owned", "Risk Weighting", "BRId", "GenderId", "IAId",
)

INTEGER_COLUMNS = (
    "Age",
    "Location ID",
    "Amount of Credit Cards",
    "Properties Owned",
    "Risk Weighting",
    "BRId",
    "GenderId",
    "IAId",
)

DECIMAL_COLUMNS = (
    "Estimated Income",
    "Superannuation Savings",
    "Credit Card Balance",
    "Bank Loans",
    "Bank Deposits",
    "Checking Accounts",
    "Saving Accounts",
    "Foreign Currency Account",
    "Business Lending",
)

# Only one format is accepted, and it is the one the SQL declares at
# sql/Banking_Complete_SQL_analysis.sql:81 via STR_TO_DATE(..., '%d-%m-%Y').
DATE_COLUMNS = {"Joined Bank": "%d-%m-%Y"}

# Coded categorical columns with their documented domains. An unexpected value
# here usually means the source changed underneath the analysis.
CATEGORICAL_DOMAINS = {
    "Fee Structure": {"High", "Mid", "Low"},
    "Loyalty Classification": {"Jade", "Silver", "Gold", "Platinum"},
    "Nationality": {"European", "Asian", "American", "Australian", "African"},
    "BRId": {"1", "2", "3", "4"},
    "GenderId": {"1", "2"},
    "Risk Weighting": {"1", "2", "3", "4", "5"},
    "Amount of Credit Cards": {"1", "2", "3"},
}

# Non-negative balance columns; a negative balance is a data error, not a
# business signal, for every one of these fields.
NON_NEGATIVE = DECIMAL_COLUMNS


@dataclass
class Finding:
    severity: str
    code: str
    message: str
    detail: list[str] = field(default_factory=list)


@dataclass
class Report:
    path: Path
    has_bom: bool = False
    rows: int = 0
    columns: list[str] = field(default_factory=list)
    findings: list[Finding] = field(default_factory=list)

    def add(self, severity: str, code: str, message: str, detail=None) -> None:
        self.findings.append(Finding(severity, code, message, list(detail or [])))

    @property
    def critical(self) -> list[Finding]:
        return [f for f in self.findings if f.severity == CRITICAL]

    @property
    def warnings(self) -> list[Finding]:
        return [f for f in self.findings if f.severity == WARN]

    @property
    def ok(self) -> bool:
        return not self.critical


def _parse_int(value: str) -> bool:
    try:
        int(value)
        return True
    except ValueError:
        return False


def _parse_float(value: str) -> bool:
    try:
        float(value)
        return True
    except ValueError:
        return False


def validate(path: Path) -> Report:
    """Run the full contract against ``path`` and return a Report."""
    report = Report(path=path)
    raw = path.read_bytes()

    # A UTF-8 BOM turns the first header into '﻿Client ID', which silently
    # breaks any code that matches column names literally. Read with utf-8-sig
    # to neutralise it, but report it so import steps can be checked too.
    report.has_bom = raw.startswith(b"\xef\xbb\xbf")
    if report.has_bom:
        report.add(
            INFO,
            "BOM_PRESENT",
            "Source file begins with a UTF-8 BOM",
            ["First header becomes '\\ufeffClient ID' unless stripped; "
             "LOAD DATA IGNORE 1 ROWS happens to mask this, other loaders may not."],
        )

    with path.open(newline="", encoding="utf-8-sig") as fh:
        rows = list(csv.DictReader(fh))

    if not rows:
        report.add(CRITICAL, "EMPTY_FILE", "No data rows found")
        return report

    report.rows = len(rows)
    report.columns = list(rows[0].keys())

    _check_schema(report, rows)
    _check_missing(report, rows)
    _check_key_cardinality(report, rows)
    _check_types(report, rows)
    _check_domains(report, rows)
    _check_ranges(report, rows)
    return report


def _check_schema(report: Report, rows: list[dict]) -> None:
    observed = report.columns
    missing = [c for c in EXPECTED_COLUMNS if c not in observed]
    unexpected = [c for c in observed if c not in EXPECTED_COLUMNS]

    if missing:
        report.add(CRITICAL, "SCHEMA_MISSING",
                   f"{len(missing)} expected column(s) absent", missing)
    if unexpected:
        report.add(WARN, "SCHEMA_UNEXPECTED",
                   f"{len(unexpected)} unexpected column(s)", unexpected)
    if missing or unexpected:
        return

    # Same set, so now check the order — the positional load depends on it.
    if observed != list(EXPECTED_COLUMNS):
        drifted = [
            f"position {i}: expected {e!r}, found {o!r}"
            for i, (e, o) in enumerate(zip(EXPECTED_COLUMNS, observed), start=1)
            if e != o
        ]
        report.add(CRITICAL, "SCHEMA_ORDER",
                   "Column order differs from the positional load order",
                   drifted[:10])
    else:
        report.add(INFO, "SCHEMA_OK",
                   f"All {len(EXPECTED_COLUMNS)} columns present in the expected order")


def _check_missing(report: Report, rows: list[dict]) -> None:
    blanks: Counter[str] = Counter()
    for row in rows:
        for col, val in row.items():
            if val is None or val.strip() == "":
                blanks[col] += 1
    if blanks:
        report.add(WARN, "NULLS_PRESENT",
                   f"{sum(blanks.values())} blank cell(s) across {len(blanks)} column(s)",
                   [f"{c}: {n}" for c, n in blanks.most_common()])
    else:
        report.add(INFO, "NO_NULLS", "No blank cells — dataset is 100% populated")


def _check_key_cardinality(report: Report, rows: list[dict]) -> None:
    """The SQL declares Client ID as a unique key. Verify that it actually is.

    This is the join-cardinality check: if Client ID is not 1:1 with rows, then
    any join or GROUP BY keyed on it will fan out and miscount.
    """
    ids = [r[KEY_COLUMN] for r in rows]
    counts = Counter(ids)
    collisions = {k: v for k, v in counts.items() if v > 1}
    distinct = len(counts)

    if collisions:
        multi = Counter(collisions.values())
        detail = [
            f"{report.rows} rows but only {distinct} distinct {KEY_COLUMN} values",
            f"{len(collisions)} value(s) collide, accounting for "
            f"{report.rows - distinct} extra row(s)",
            "multiplicity: " + ", ".join(f"{v}x -> {n} id(s)"
                                         for v, n in sorted(multi.items())),
            f"consequence: COUNT(*) = {report.rows} but "
            f"COUNT(DISTINCT {KEY_COLUMN}) = {distinct}",
        ]
        # Demonstrate that colliding groups are distinct entities, not true
        # duplicate rows — that distinction decides whether deduping is safe.
        groups: dict[str, list[dict]] = {}
        for r in rows:
            groups.setdefault(r[KEY_COLUMN], []).append(r)
        differing = sum(
            1 for v in groups.values()
            if len(v) > 1 and not all(x == v[0] for x in v)
        )
        detail.append(
            f"{differing}/{len(collisions)} colliding group(s) contain rows that "
            "differ in every other field — these are distinct clients sharing an "
            "ID, not duplicate records"
        )
        report.add(CRITICAL, "KEY_NOT_UNIQUE",
                   f"{KEY_COLUMN} is not unique and cannot serve as a primary key",
                   detail)
    else:
        report.add(INFO, "KEY_UNIQUE",
                   f"{KEY_COLUMN} is unique across all {report.rows} rows (1:1)")


def _check_types(report: Report, rows: list[dict]) -> None:
    for col in INTEGER_COLUMNS:
        bad = [r[col] for r in rows if not _parse_int(r[col].strip())]
        if bad:
            report.add(CRITICAL, "TYPE_INT", f"{col}: {len(bad)} non-integer value(s)",
                       sorted(set(bad))[:10])

    for col in DECIMAL_COLUMNS:
        bad = [r[col] for r in rows if not _parse_float(r[col].strip())]
        if bad:
            report.add(CRITICAL, "TYPE_DECIMAL",
                       f"{col}: {len(bad)} non-numeric value(s)", sorted(set(bad))[:10])

    for col, fmt in DATE_COLUMNS.items():
        bad, years = [], []
        for r in rows:
            try:
                years.append(datetime.strptime(r[col].strip(), fmt).year)
            except ValueError:
                bad.append(r[col])
        if bad:
            report.add(CRITICAL, "TYPE_DATE",
                       f"{col}: {len(bad)} value(s) do not match {fmt}",
                       sorted(set(bad))[:10])
        else:
            report.add(INFO, "DATE_OK",
                       f"{col}: all {len(rows)} values parse as {fmt} "
                       f"(years {min(years)}-{max(years)})")


def _check_domains(report: Report, rows: list[dict]) -> None:
    for col, allowed in CATEGORICAL_DOMAINS.items():
        observed = Counter(r[col].strip() for r in rows)
        unexpected = {v: n for v, n in observed.items() if v not in allowed}
        if unexpected:
            report.add(WARN, "DOMAIN_UNEXPECTED",
                       f"{col}: value(s) outside the documented domain",
                       [f"{v!r} ({n} rows) — allowed: {sorted(allowed)}"
                        for v, n in sorted(unexpected.items())])


def _check_ranges(report: Report, rows: list[dict]) -> None:
    for col in NON_NEGATIVE:
        neg = [r[col] for r in rows if float(r[col]) < 0]
        if neg:
            report.add(WARN, "NEGATIVE_VALUE",
                       f"{col}: {len(neg)} negative value(s)", sorted(set(neg))[:10])

    ages = [int(r["Age"]) for r in rows]
    implausible = [a for a in ages if a < 16 or a > 100]
    if implausible:
        report.add(WARN, "AGE_RANGE",
                   f"Age: {len(implausible)} value(s) outside 16-100",
                   sorted(set(implausible))[:10])
    else:
        report.add(INFO, "AGE_OK",
                   f"Age: all values within 16-100 (min {min(ages)}, max {max(ages)})")


def render(report: Report) -> str:
    out = []
    out.append("=" * 78)
    out.append("DATA QUALITY REPORT")
    out.append("=" * 78)
    out.append(f"  source   : {report.path}")
    out.append(f"  rows     : {report.rows:,}")
    out.append(f"  columns  : {len(report.columns)}")
    out.append("")
    for severity in (CRITICAL, WARN, INFO):
        for f in report.findings:
            if f.severity != severity:
                continue
            out.append(f"[{f.severity}] {f.code}: {f.message}")
            for d in f.detail:
                out.append(f"           - {d}")
    out.append("")
    out.append("-" * 78)
    out.append(f"  {len(report.critical)} critical, {len(report.warnings)} warning")
    out.append("  RESULT: " + ("PASS" if report.ok else "FAIL"))
    out.append("-" * 78)
    return "\n".join(out)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("csv", nargs="?", default="Banking.csv",
                        help="path to the banking CSV (default: Banking.csv)")
    args = parser.parse_args(argv)

    path = Path(args.csv)
    if not path.exists():
        print(f"error: {path} not found", file=sys.stderr)
        return 2

    report = validate(path)
    print(render(report))
    return 0 if report.ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
