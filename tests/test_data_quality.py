"""Regression tests for the dataset contract and the known Client ID defect.

The Client ID collision is a property of the source data, not something this
repository can fix by editing rows. It is therefore pinned here explicitly
rather than left as a note in a document: if the data is ever corrected
upstream, or if someone "helpfully" deduplicates the file, these tests fail
loudly and force the decision to be made deliberately.
"""
from __future__ import annotations

import sys
import unittest
from collections import Counter
from pathlib import Path

_HERE = Path(__file__).resolve().parent
for _p in (str(_HERE), str(_HERE.parent / "python")):
    if _p not in sys.path:
        sys.path.insert(0, _p)

import _data  # noqa: E402
from data_quality import CRITICAL, EXPECTED_COLUMNS, validate  # noqa: E402


class TestSchemaContract(unittest.TestCase):
    def setUp(self):
        self.rows = _data.load_rows()

    def test_row_count(self):
        self.assertEqual(len(self.rows), 3000)

    def test_all_expected_columns_present(self):
        self.assertEqual(list(self.rows[0].keys()), list(EXPECTED_COLUMNS))

    def test_column_order_matches_positional_load(self):
        """Order is contractual: the SQL import loads positionally, not by name.

        A reordered source would shift every value into the wrong column
        without raising any error.
        """
        header = list(self.rows[0].keys())
        self.assertEqual(header, list(EXPECTED_COLUMNS))
        for i, (expected, actual) in enumerate(zip(EXPECTED_COLUMNS, header), 1):
            with self.subTest(position=i):
                self.assertEqual(expected, actual)


class TestCompleteness(unittest.TestCase):
    def test_no_blank_cells(self):
        rows = _data.load_rows()
        blanks = [
            (i, k)
            for i, r in enumerate(rows)
            for k, v in r.items()
            if v is None or v.strip() == ""
        ]
        self.assertEqual(blanks, [], f"{len(blanks)} blank cell(s) found")


class TestClientIdCollision(unittest.TestCase):
    """Pins the defect documented in docs/data_quality_findings.md."""

    def setUp(self):
        self.rows = _data.load_rows()
        self.ids = [r["Client ID"] for r in self.rows]
        self.counts = Counter(self.ids)
        self.collisions = {k: v for k, v in self.counts.items() if v > 1}

    def test_distinct_client_ids_is_2940(self):
        self.assertEqual(len(self.counts), 2940)

    def test_collision_count_is_59(self):
        self.assertEqual(len(self.collisions), 59)

    def test_extra_rows_is_60(self):
        self.assertEqual(len(self.rows) - len(self.counts), 60)

    def test_multiplicity_breakdown(self):
        multiplicity = Counter(self.collisions.values())
        self.assertEqual(multiplicity[2], 58, "expected 58 IDs appearing twice")
        self.assertEqual(multiplicity[3], 1, "expected 1 ID appearing three times")

    def test_colliding_rows_are_distinct_people_not_duplicates(self):
        """The distinction that rules out naive deduplication."""
        groups: dict[str, list[dict]] = {}
        for r in self.rows:
            groups.setdefault(r["Client ID"], []).append(r)

        identical = differing = 0
        for rows in groups.values():
            if len(rows) < 2:
                continue
            if all(r == rows[0] for r in rows):
                identical += 1
            else:
                differing += 1

        self.assertEqual(identical, 0)
        self.assertEqual(differing, 59)

    def test_validator_reports_it_as_critical(self):
        report = validate(_data.CSV_PATH)
        codes = {f.code for f in report.critical}
        self.assertIn("KEY_NOT_UNIQUE", codes)
        self.assertFalse(report.ok)


class TestTypesRangesAndDomains(unittest.TestCase):
    def setUp(self):
        self.rows = _data.load_rows()

    def test_joined_bank_parses_as_dd_mm_yyyy(self):
        from datetime import datetime

        years = [
            datetime.strptime(r["Joined Bank"], "%d-%m-%Y").year for r in self.rows
        ]
        self.assertEqual(len(years), 3000)
        self.assertEqual((min(years), max(years)), (1995, 2021))

    def test_age_within_plausible_range(self):
        ages = [int(r["Age"]) for r in self.rows]
        self.assertGreaterEqual(min(ages), 16)
        self.assertLessEqual(max(ages), 100)

    def test_no_negative_balances(self):
        for column in (
            "Bank Loans", "Business Lending", "Credit Card Balance",
            "Bank Deposits", "Saving Accounts", "Checking Accounts",
            "Foreign Currency Account",
        ):
            with self.subTest(column=column):
                self.assertTrue(all(v >= 0 for v in _data.col(self.rows, column)))

    def test_categorical_domains(self):
        expected = {
            "Fee Structure": {"High", "Mid", "Low"},
            "Loyalty Classification": {"Jade", "Silver", "Gold", "Platinum"},
            "BRId": {"1", "2", "3", "4"},
            "GenderId": {"1", "2"},
            "Risk Weighting": {"1", "2", "3", "4", "5"},
        }
        for column, allowed in expected.items():
            with self.subTest(column=column):
                observed = {r[column].strip() for r in self.rows}
                self.assertTrue(
                    observed <= allowed, f"{column} has values outside {allowed}"
                )

    def test_source_carries_a_utf8_bom(self):
        """Documented in the findings; asserted so a re-export is noticed."""
        self.assertTrue(_data.CSV_PATH.read_bytes().startswith(b"\xef\xbb\xbf"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
