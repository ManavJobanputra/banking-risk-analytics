#!/usr/bin/env python3
"""Credit Risk Concentration Score (CRCS) and segment analysis.

**This module is an addition, not part of the inherited analysis.** The upstream
project (see README "Provenance") deliberately stopped at screening rules and
stated plainly that the dataset carries no default outcomes, so it makes no
claim to predict default. This module keeps that boundary: it does not predict
default either. It builds a transparent, documented ranking so that a reviewer
can see *why* a client ranks highly and disagree with any component of it.

Formula
-------
Every client is scored on three components, each converted to a percentile rank
across the portfolio (0 = lowest, 1 = highest):

    leverage   = total_exposure / max(total_deposits, 1)
    coverage   = total_exposure / max(estimated_income, 1)
    risk_tier  = risk_weighting, as supplied by the dataset (1-5)

        CRCS = 100 * (0.40*rank(leverage) + 0.40*rank(coverage) + 0.20*rank(risk_tier))

where

    total_exposure = bank_loans + business_lending + credit_card_balance
    total_deposits = bank_deposits + saving_accounts + checking_accounts
                     + foreign_currency_account

Percentile ranks are used rather than the raw ratios because the raw
distributions are heavy-tailed — a single client with near-zero deposits would
otherwise dominate every other score. Ranking makes the output robust to those
outliers and bounds each component to [0, 1].

Because every component is a percentile rank, the portfolio mean CRCS is ~50
**by construction**, and the segment means below are only interpretable
*relative to 50* — not as absolute risk levels. A segment mean of 53.8 does not
mean "high risk"; it means that segment ranks above the portfolio average.

Stated assumptions (these are choices, not findings)
---------------------------------------------------
* The 0.40 / 0.40 / 0.20 weights are project assumptions with no empirical
  calibration, exactly like the 5% / 3% / 1% fee rates in the inherited
  analysis. They are exposed as ``WEIGHTS`` so a reviewer can change them.
* The ``max(..., 1)`` guards prevent division by zero. On the shipped data they
  never fire: the smallest total deposit balance is 954.04 and the smallest
  estimated income is 15,919.48, so no client has a zero denominator. The guards
  are retained so the module still behaves predictably on a different extract.
* ``risk_weighting`` is taken at face value from the dataset. Its provenance is
  not documented upstream and this module does not validate it.

What CRCS is not
----------------
It is not a probability of default, not a credit score, and not calibrated
against any outcome. The dataset contains no repayment, delinquency or default
field, so nothing here can be validated against reality. Treat it as a
prioritisation aid for a human reviewer, nothing more.

Usage::

    python3 analysis/credit_risk_kpi.py            # full report
    python3 analysis/credit_risk_kpi.py --json     # machine-readable

Standard library only, so it runs with no install step.
"""
from __future__ import annotations

import argparse
import csv
import json
import sys
from collections import Counter, defaultdict
from datetime import datetime
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
CSV_PATH = REPO_ROOT / "Banking.csv"

# Component weights. Project assumptions — see the module docstring.
WEIGHTS = {"leverage": 0.40, "coverage": 0.40, "risk_tier": 0.20}

# Mirrors the fee model in the inherited SQL: ELSE 0.01 catches any tier that is
# neither High nor Mid.
FEE_RATE = {"High": 0.05, "Mid": 0.03}
DEFAULT_FEE_RATE = 0.01

BRID_LABEL = {"1": "Premium", "2": "Business", "3": "Personal", "4": "SME"}
GENDER_LABEL = {"1": "Male", "2": "Female"}


def income_band(income: float) -> str:
    """Band definition carried over from the inherited analysis."""
    if income < 100_000:
        return "Low"
    if income < 300_000:
        return "Mid"
    return "High"


def percentile_ranks(values: list[float]) -> list[float]:
    """Percentile rank of each value in [0, 1]; ties share the average rank."""
    n = len(values)
    if n < 2:
        return [0.0] * n
    order = sorted(range(n), key=lambda i: values[i])
    ranks = [0.0] * n
    i = 0
    while i < n:
        j = i
        while j + 1 < n and values[order[j + 1]] == values[order[i]]:
            j += 1
        avg_position = (i + j) / 2
        for k in range(i, j + 1):
            ranks[order[k]] = avg_position / (n - 1)
        i = j + 1
    return ranks


def load_clients() -> list[dict]:
    """Load the CSV and derive the per-client quantities CRCS needs."""
    with CSV_PATH.open(newline="", encoding="utf-8-sig") as fh:
        raw = list(csv.DictReader(fh))

    clients = []
    for r in raw:
        exposure = (
            float(r["Bank Loans"])
            + float(r["Business Lending"])
            + float(r["Credit Card Balance"])
        )
        deposits = (
            float(r["Bank Deposits"])
            + float(r["Saving Accounts"])
            + float(r["Checking Accounts"])
            + float(r["Foreign Currency Account"])
        )
        income = float(r["Estimated Income"])
        clients.append({
            "client_id": r["Client ID"],
            "name": r["Name"],
            "relationship": BRID_LABEL.get(r["BRId"], "Unknown"),
            "nationality": r["Nationality"],
            "band": income_band(income),
            "risk_weighting": int(r["Risk Weighting"]),
            "joined_year": datetime.strptime(r["Joined Bank"], "%d-%m-%Y").year,
            "exposure": exposure,
            "deposits": deposits,
            "income": income,
            "zero_deposits": deposits <= 0,
            # Guards documented in the module docstring.
            "leverage": exposure / max(deposits, 1.0),
            "coverage": exposure / max(income, 1.0),
            "fee": exposure * FEE_RATE.get(r["Fee Structure"], DEFAULT_FEE_RATE),
        })
    return clients


def score(clients: list[dict]) -> list[dict]:
    """Attach percentile components and the composite CRCS to each client."""
    lev = percentile_ranks([c["leverage"] for c in clients])
    cov = percentile_ranks([c["coverage"] for c in clients])
    rsk = percentile_ranks([float(c["risk_weighting"]) for c in clients])

    for i, c in enumerate(clients):
        c["rank_leverage"] = lev[i]
        c["rank_coverage"] = cov[i]
        c["rank_risk_tier"] = rsk[i]
        c["crcs"] = 100.0 * (
            WEIGHTS["leverage"] * lev[i]
            + WEIGHTS["coverage"] * cov[i]
            + WEIGHTS["risk_tier"] * rsk[i]
        )
    return clients


def _mean(values):
    return sum(values) / len(values) if values else 0.0


def _median(values):
    if not values:
        return 0.0
    s = sorted(values)
    mid = len(s) // 2
    return s[mid] if len(s) % 2 else (s[mid - 1] + s[mid]) / 2


def _segment_table(clients, key_fn, label):
    """Aggregate risk, exposure and fee metrics by an arbitrary grouping."""
    groups = defaultdict(list)
    for c in clients:
        groups[key_fn(c)].append(c)
    total_exposure = sum(c["exposure"] for c in clients)
    total_fee = sum(c["fee"] for c in clients)

    rows = []
    for name, members in groups.items():
        exposure = sum(m["exposure"] for m in members)
        fee = sum(m["fee"] for m in members)
        rows.append({
            "segment": name,
            "clients": len(members),
            "mean_crcs": _mean([m["crcs"] for m in members]),
            "share_of_exposure_pct": 100.0 * exposure / total_exposure if total_exposure else 0.0,
            "share_of_fees_pct": 100.0 * fee / total_fee if total_fee else 0.0,
        })
    rows.sort(key=lambda r: r["mean_crcs"], reverse=True)
    return label, rows


def build_report(clients: list[dict]) -> dict:
    total_exposure = sum(c["exposure"] for c in clients)
    ranked = sorted(clients, key=lambda c: c["crcs"], reverse=True)
    decile_size = max(1, len(ranked) // 10)
    top_decile = ranked[:decile_size]
    top_decile_exposure = sum(c["exposure"] for c in top_decile)

    scores = [c["crcs"] for c in clients]
    deciles = []
    for d in range(10):
        start = d * len(ranked) // 10
        end = (d + 1) * len(ranked) // 10
        chunk = ranked[start:end]
        if chunk:
            deciles.append({
                "decile": d + 1,
                "mean_crcs": _mean([c["crcs"] for c in chunk]),
                "mean_leverage": _mean([c["leverage"] for c in chunk]),
                "share_of_exposure_pct": 100.0 * sum(c["exposure"] for c in chunk) / total_exposure,
            })

    segments = dict([
        _segment_table(clients, lambda c: c["relationship"], "by_relationship"),
        _segment_table(clients, lambda c: c["band"], "by_income_band"),
        _segment_table(clients, lambda c: c["nationality"], "by_nationality"),
        _segment_table(clients, lambda c: f"Tier {c['risk_weighting']}", "by_risk_tier"),
    ])

    years = defaultdict(list)
    for c in clients:
        years[c["joined_year"]].append(c)
    cumulative = 0
    cohorts = []
    for year in sorted(years):
        members = years[year]
        cumulative += len(members)
        cohorts.append({
            "year": year,
            "new_clients": len(members),
            "cumulative_clients": cumulative,
            "mean_crcs": _mean([m["crcs"] for m in members]),
            "share_of_exposure_pct": 100.0 * sum(m["exposure"] for m in members) / total_exposure,
        })

    return {
        "weights": WEIGHTS,
        "portfolio": {
            "clients": len(clients),
            "mean_crcs": _mean(scores),
            "median_crcs": _median(scores),
            "min_crcs": min(scores),
            "max_crcs": max(scores),
            "zero_deposit_clients": sum(1 for c in clients if c["zero_deposits"]),
            "total_exposure": total_exposure,
        },
        "concentration": {
            "top_decile_clients": len(top_decile),
            "top_decile_share_of_exposure_pct": (
                100.0 * top_decile_exposure / total_exposure if total_exposure else 0.0
            ),
            "top_decile_share_of_clients_pct": 100.0 * len(top_decile) / len(clients),
            "top_crcs": top_decile[0]["crcs"] if top_decile else 0.0,
        },
        "top_clients": ranked[:10],
        "deciles": deciles,
        "segments": segments,
        "cohorts": cohorts,
    }


def render(report: dict) -> str:
    out = []
    w = out.append
    w("=" * 92)
    w("CREDIT RISK CONCENTRATION SCORE (CRCS) - screening index, not a default model")
    w("=" * 92)
    p = report["portfolio"]
    wt = report["weights"]
    w(f"  weights: leverage {wt['leverage']:.2f} + coverage {wt['coverage']:.2f} "
      f"+ risk tier {wt['risk_tier']:.2f}  (project assumptions)")
    w("")
    w("PORTFOLIO")
    w(f"  clients scored            : {p['clients']:,}")
    w(f"  CRCS mean / median        : {p['mean_crcs']:.1f} / {p['median_crcs']:.1f}  "
      f"(min {p['min_crcs']:.1f}, max {p['max_crcs']:.1f})")
    w(f"  total exposure            : ${p['total_exposure']/1e9:.2f}B")
    w(f"  clients with 0 deposits   : {p['zero_deposit_clients']:,} "
      f"({100*p['zero_deposit_clients']/p['clients']:.1f}% - leverage guard "
      f"{'NOT triggered on this data' if p['zero_deposit_clients'] == 0 else 'applies'})")

    c = report["concentration"]
    w("")
    w("CONCENTRATION")
    w(f"  top decile ({c['top_decile_clients']} clients, "
      f"{c['top_decile_share_of_clients_pct']:.1f}% of clients) holds "
      f"{c['top_decile_share_of_exposure_pct']:.1f}% of exposure")

    w("")
    w("DECILE PROFILE  (1 = highest CRCS)")
    w(f"  {'decile':>7} {'mean CRCS':>10} {'mean leverage':>14} {'exposure share':>15}")
    for d in report["deciles"]:
        w(f"  {d['decile']:>7} {d['mean_crcs']:>10.1f} {d['mean_leverage']:>14.2f} "
          f"{d['share_of_exposure_pct']:>14.1f}%")

    w("")
    w("TOP 10 BY CRCS")
    w(f"  {'client':>10} {'name':<20} {'rel':<9} {'band':<5} {'tier':>4} "
      f"{'CRCS':>6} {'leverage':>9} {'exposure':>14}")
    for cl in report["top_clients"]:
        w(f"  {cl['client_id']:>10} {cl['name'][:19]:<20} {cl['relationship']:<9} "
          f"{cl['band']:<5} {cl['risk_weighting']:>4} {cl['crcs']:>6.1f} "
          f"{cl['leverage']:>9.2f} {cl['exposure']:>14,.0f}")

    for key, rows in report["segments"].items():
        w("")
        w(f"SEGMENTS {key.replace('_', ' ').upper()}")
        w(f"  {'segment':<14} {'clients':>8} {'mean CRCS':>10} "
          f"{'exposure %':>11} {'fees %':>8}")
        for r in rows:
            w(f"  {r['segment']:<14} {r['clients']:>8,} {r['mean_crcs']:>10.1f} "
              f"{r['share_of_exposure_pct']:>10.1f}% {r['share_of_fees_pct']:>7.1f}%")

    w("")
    w("ACQUISITION COHORTS")
    w(f"  {'year':>5} {'new':>6} {'cumulative':>11} {'mean CRCS':>10} {'exposure %':>11}")
    for coh in report["cohorts"]:
        w(f"  {coh['year']:>5} {coh['new_clients']:>6,} {coh['cumulative_clients']:>11,} "
          f"{coh['mean_crcs']:>10.1f} {coh['share_of_exposure_pct']:>10.1f}%")

    w("")
    w("=" * 92)
    w("  CRCS is NOT a probability of default. The dataset carries no repayment or")
    w("  default field, so this ranking cannot be validated against outcomes. The")
    w("  weights are assumptions, not calibrated parameters.")
    w("=" * 92)
    return "\n".join(out)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--json", action="store_true",
                        help="emit the report as JSON instead of a formatted table")
    args = parser.parse_args(argv)

    clients = score(load_clients())
    report = build_report(clients)

    if args.json:
        slim = dict(report)
        slim["top_clients"] = [
            {k: v for k, v in c.items() if not k.startswith("rank_")}
            for c in report["top_clients"]
        ]
        print(json.dumps(slim, indent=2, default=str))
    else:
        print(render(report))
    return 0


if __name__ == "__main__":
    sys.exit(main())
