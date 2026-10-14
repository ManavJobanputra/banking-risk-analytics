"""Shared test fixtures. Standard library only, so the suite runs anywhere.

Every test resolves the repository root from this file's own location rather
than the current working directory, so `python3 -m unittest discover` behaves
the same from the repo root or from inside tests/.
"""
from __future__ import annotations

import csv
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CSV_PATH = REPO_ROOT / "Banking.csv"
SQL_PATH = REPO_ROOT / "sql" / "Banking_Complete_SQL_analysis.sql"
NOTEBOOK_PATH = REPO_ROOT / "python" / "banking_eda.ipynb"


def load_rows() -> list[dict]:
    """Load Banking.csv as a list of dicts, neutralising the UTF-8 BOM."""
    with CSV_PATH.open(newline="", encoding="utf-8-sig") as fh:
        return list(csv.DictReader(fh))


def col(rows: list[dict], name: str) -> list[float]:
    """One numeric column as floats."""
    return [float(r[name]) for r in rows]
