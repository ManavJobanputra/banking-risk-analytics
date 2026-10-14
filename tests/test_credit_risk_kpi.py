"""Tests for the Credit Risk Concentration Score.

These check that the index is *internally* correct — bounded, monotonic and
reproducible — and that its documented assumptions match the data. They cannot
check that it is *predictive*, because the dataset carries no default outcome to
validate against. See the module docstring.
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

_HERE = Path(__file__).resolve().parent
for _p in (str(_HERE), str(_HERE.parent / "analysis")):
    if _p not in sys.path:
        sys.path.insert(0, _p)

import _data  # noqa: E402
import credit_risk_kpi as crc  # noqa: E402


class TestPercentileRanks(unittest.TestCase):
    def test_bounds(self):
        ranks = crc.percentile_ranks([5.0, 1.0, 9.0, 3.0])
        self.assertTrue(all(0.0 <= r <= 1.0 for r in ranks))

    def test_monotonic_with_values(self):
        values = [5.0, 1.0, 9.0, 3.0]
        ranks = crc.percentile_ranks(values)
        ordered = sorted(range(len(values)), key=lambda i: values[i])
        for a, b in zip(ordered, ordered[1:]):
            self.assertLessEqual(ranks[a], ranks[b])

    def test_extremes(self):
        ranks = crc.percentile_ranks([1.0, 2.0, 3.0])
        self.assertEqual(ranks[0], 0.0)
        self.assertEqual(ranks[1], 0.5)
        self.assertEqual(ranks[2], 1.0)

    def test_ties_share_a_rank(self):
        ranks = crc.percentile_ranks([4.0, 4.0, 4.0])
        self.assertEqual(len(set(ranks)), 1)

    def test_single_element_is_safe(self):
        self.assertEqual(crc.percentile_ranks([7.0]), [0.0])

    def test_empty_is_safe(self):
        self.assertEqual(crc.percentile_ranks([]), [])


class TestScoring(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.clients = crc.score(crc.load_clients())

    def test_every_row_is_scored(self):
        self.assertEqual(len(self.clients), 3000)

    def test_crcs_is_bounded(self):
        scores = [c["crcs"] for c in self.clients]
        self.assertGreaterEqual(min(scores), 0.0)
        self.assertLessEqual(max(scores), 100.0)

    def test_components_are_bounded(self):
        for c in self.clients:
            for key in ("rank_leverage", "rank_coverage", "rank_risk_tier"):
                with self.subTest(client=c["client_id"], key=key):
                    self.assertGreaterEqual(c[key], 0.0)
                    self.assertLessEqual(c[key], 1.0)

    def test_portfolio_mean_is_fifty_by_construction(self):
        """A property of percentile ranking, not a finding about the portfolio.

        Documented in the module docstring so the figure is not misread as an
        absolute risk level.
        """
        mean = sum(c["crcs"] for c in self.clients) / len(self.clients)
        self.assertAlmostEqual(mean, 50.0, places=6)

    def test_weights_sum_to_one(self):
        self.assertAlmostEqual(sum(crc.WEIGHTS.values()), 1.0, places=6)

    def test_scoring_is_deterministic(self):
        again = crc.score(crc.load_clients())
        self.assertEqual(
            [c["crcs"] for c in self.clients],
            [c["crcs"] for c in again],
        )

    def test_top_client_ranks_above_bottom_client(self):
        ranked = sorted(self.clients, key=lambda c: c["crcs"], reverse=True)
        self.assertGreater(ranked[0]["crcs"], ranked[-1]["crcs"])


class TestDocumentedAssumptions(unittest.TestCase):
    """The docstring makes claims about the data; hold it to them."""

    @classmethod
    def setUpClass(cls):
        cls.clients = crc.load_clients()

    def test_zero_deposit_guard_does_not_fire(self):
        """Docstring states the min total deposit balance is 954.04."""
        offenders = [c for c in self.clients if c["zero_deposits"]]
        self.assertEqual(offenders, [], "documented as 0 zero-deposit clients")
        self.assertGreater(min(c["deposits"] for c in self.clients), 0.0)

    def test_zero_income_guard_does_not_fire(self):
        self.assertGreater(min(c["income"] for c in self.clients), 0.0)


class TestIncomeBand(unittest.TestCase):
    def test_boundaries_match_the_inherited_definition(self):
        self.assertEqual(crc.income_band(0), "Low")
        self.assertEqual(crc.income_band(99_999.99), "Low")
        self.assertEqual(crc.income_band(100_000), "Mid")
        self.assertEqual(crc.income_band(299_999.99), "Mid")
        self.assertEqual(crc.income_band(300_000), "High")


class TestReportShape(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.report = crc.build_report(crc.score(crc.load_clients()))

    def test_deciles_cover_the_portfolio(self):
        self.assertEqual(len(self.report["deciles"]), 10)
        total = sum(d["share_of_exposure_pct"] for d in self.report["deciles"])
        self.assertAlmostEqual(total, 100.0, places=6)

    def test_cohorts_are_cumulative(self):
        cohorts = self.report["cohorts"]
        self.assertEqual(cohorts[0]["new_clients"], cohorts[0]["cumulative_clients"])
        self.assertEqual(cohorts[-1]["cumulative_clients"], 3000)
        for a, b in zip(cohorts, cohorts[1:]):
            self.assertLess(a["cumulative_clients"], b["cumulative_clients"])

    def test_top_clients_is_capped_at_ten(self):
        self.assertEqual(len(self.report["top_clients"]), 10)

    def test_render_produces_text(self):
        text = crc.render(self.report)
        self.assertIn("CREDIT RISK CONCENTRATION SCORE", text)
        self.assertIn("NOT a probability of default", text)


if __name__ == "__main__":
    unittest.main(verbosity=2)
