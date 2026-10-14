"""Recomputation tests for the published portfolio KPIs, plus SQL contract checks.

No MySQL client or server was available in the analysis environment, so the SQL
script could not be executed end to end. These tests instead recompute each
published KPI from ``Banking.csv`` using the same arithmetic the SQL expresses.
That verifies the **numbers**; it does not verify the MySQL engine's behaviour,
and it should not be read as having done so.

Each expected value is the figure published in the README and in the SQL
comments, so a change in either place without a matching change here fails.
"""
from __future__ import annotations

import re
import sys
import unittest
from collections import Counter
from pathlib import Path

_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))

import _data  # noqa: E402

# Mirrors the CASE expression in the SQL fee calculation. ELSE 0.01 is
# deliberate: the SQL treats any unrecognised tier as the lowest rate.
FEE_RATE = {"High": 0.05, "Mid": 0.03}
DEFAULT_FEE_RATE = 0.01


class TestClientCountReconciliation(unittest.TestCase):
    """Section 1.2b and the reconciled KPI aliases."""

    def test_record_and_client_counts_diverge_by_60(self):
        rows = _data.load_rows()
        total_records = len(rows)
        distinct_client_ids = len({r["Client ID"] for r in rows})
        self.assertEqual(total_records, 3000)
        self.assertEqual(distinct_client_ids, 2940)
        self.assertEqual(total_records - distinct_client_ids, 60)


class TestPortfolioKPIs(unittest.TestCase):
    def setUp(self):
        self.rows = _data.load_rows()

    def _total(self, *columns):
        return sum(sum(_data.col(self.rows, c)) for c in columns)

    def test_income_bands(self):
        income = _data.col(self.rows, "Estimated Income")
        low = sum(1 for v in income if v < 100_000)
        mid = sum(1 for v in income if 100_000 <= v < 300_000)
        high = sum(1 for v in income if v >= 300_000)
        self.assertEqual((low, mid, high), (1027, 1517, 456))
        self.assertEqual(low + mid + high, 3000)

    def test_banking_relationship_counts(self):
        counts = Counter(r["BRId"] for r in self.rows)
        self.assertEqual(counts["3"], 1352)  # Personal
        self.assertEqual(sum(counts.values()), 3000)

    def test_gender_split(self):
        counts = Counter(r["GenderId"] for r in self.rows)
        self.assertEqual((counts["1"], counts["2"]), (1488, 1512))

    def test_total_loan_exposure(self):
        total = self._total("Bank Loans", "Business Lending", "Credit Card Balance")
        self.assertEqual(round(total / 1e9, 2), 4.38)

    def test_total_deposits(self):
        total = self._total(
            "Bank Deposits", "Saving Accounts", "Checking Accounts",
            "Foreign Currency Account",
        )
        self.assertEqual(round(total / 1e9, 2), 3.77)

    def test_business_lending(self):
        self.assertEqual(round(self._total("Business Lending") / 1e9, 2), 2.60)

    def test_loan_to_deposit_ratio(self):
        loans = self._total("Bank Loans", "Business Lending", "Credit Card Balance")
        deposits = self._total(
            "Bank Deposits", "Saving Accounts", "Checking Accounts",
            "Foreign Currency Account",
        )
        self.assertEqual(round(loans / deposits, 4), 1.1640)

    def test_estimated_fees_and_average(self):
        loans = _data.col(self.rows, "Bank Loans")
        biz = _data.col(self.rows, "Business Lending")
        cc = _data.col(self.rows, "Credit Card Balance")
        exposure = [loans[i] + biz[i] + cc[i] for i in range(len(self.rows))]
        fees = [
            exposure[i]
            * FEE_RATE.get(self.rows[i]["Fee Structure"], DEFAULT_FEE_RATE)
            for i in range(len(self.rows))
        ]
        self.assertEqual(round(sum(fees) / 1e6, 2), 158.19)
        self.assertEqual(round(sum(fees) / len(fees)), 52_731)

    def test_above_average_bank_loan_clients(self):
        loans = _data.col(self.rows, "Bank Loans")
        mean = sum(loans) / len(loans)
        self.assertEqual(sum(1 for v in loans if v > mean), 1205)

    def test_clients_whose_loans_exceed_deposits(self):
        loans = _data.col(self.rows, "Bank Loans")
        deposits = _data.col(self.rows, "Bank Deposits")
        self.assertEqual(
            sum(1 for i in range(len(self.rows)) if loans[i] > deposits[i]), 1506
        )

    def test_high_loan_low_income_clients(self):
        loans = _data.col(self.rows, "Bank Loans")
        income = _data.col(self.rows, "Estimated Income")
        mean = sum(loans) / len(loans)
        count = sum(
            1 for i in range(len(self.rows))
            if income[i] < 100_000 and loans[i] > mean
        )
        self.assertEqual(count, 269)

    def test_peak_acquisition_year(self):
        from datetime import datetime

        years = Counter(
            datetime.strptime(r["Joined Bank"], "%d-%m-%Y").year for r in self.rows
        )
        year, count = years.most_common(1)[0]
        self.assertEqual((year, count), (2020, 248))


class TestSqlContract(unittest.TestCase):
    """Pins the SQL fixes so they cannot silently revert."""

    def setUp(self):
        self.sql = _data.SQL_PATH.read_text()

    def test_client_id_is_not_the_primary_key(self):
        match = re.search(r"^\s*client_id\s+VARCHAR.*$", self.sql, re.MULTILINE)
        self.assertIsNotNone(match, "client_id column definition not found")
        self.assertNotIn(
            "PRIMARY KEY", match.group(0),
            "client_id is declared PRIMARY KEY again, which breaks the import "
            "on the 59 colliding IDs",
        )

    def test_surrogate_row_id_is_the_primary_key(self):
        self.assertRegex(
            self.sql, r"row_id\s+INT\s+AUTO_INCREMENT\s+PRIMARY KEY",
            "the surrogate key carrying row identity is missing",
        )

    def test_no_ambiguous_total_clients_alias(self):
        self.assertNotIn(
            "AS total_clients", self.sql,
            "total_clients is ambiguous on this data; use total_records and "
            "distinct_client_ids",
        )

    def test_duplicate_check_annotation_is_corrected(self):
        # Matches the annotation only as an active claim of its own, not the
        # correction note that quotes the old wording.
        self.assertIsNone(
            re.search(r"^\s*--\s*Expected:\s*0 rows", self.sql, re.MULTILINE),
            "the duplicate-ID check must not claim 0 rows; it returns 59",
        )
        self.assertIn("Returns 59 rows on the shipped data", self.sql)

    def test_reconciliation_query_is_present(self):
        self.assertIn("duplicated_id_rows", self.sql)


if __name__ == "__main__":
    unittest.main(verbosity=2)
