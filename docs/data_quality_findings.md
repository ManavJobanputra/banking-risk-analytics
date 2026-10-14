# Data Quality Findings

Findings from validating `Banking.csv` against the contract the SQL layer
assumes. Reproduce with:

```bash
python3 python/data_quality.py
```

The validator exits non-zero when it raises a CRITICAL finding, so this file's
central claim is re-checkable by anyone in one command.

---

## Finding 1 — `Client ID` is not unique (CRITICAL)

**Claim.** `Client ID` is documented and treated as a unique client identifier.
It is not.

**Evidence.** The file holds **3,000 rows but only 2,940 distinct `Client ID`
values**. 59 values collide — 58 appear twice and one appears three times —
accounting for 60 additional rows.

```
3000 rows but only 2940 distinct Client ID values
59 value(s) collide, accounting for 60 extra row(s)
multiplicity: 2x -> 58 id(s), 3x -> 1 id(s)
```

**The collisions are not duplicate records.** Every one of the 59 colliding
groups contains rows that differ in *every other field* — name, age, location,
join date, income and balances. These are distinct clients who were issued a
colliding ID, not the same client recorded twice. That distinction matters,
because it means deduplicating would silently delete 59 real clients.

Worked example — `IND35589`, which appears twice:

| Client ID | Name | Age | Joined Bank | Estimated Income | Bank Loans |
|---|---|---:|---|---:|---:|
| IND35589 | Jimmy Simpson | 52 | 08-01-2018 | 87,019.73 | 273,944.56 |
| IND35589 | Judy Lawrence | 85 | 22-01-1995 | 199,850.36 | 449,774.65 |

Two different people, one ID.

### Impact

1. **The documented import fails.** The table declares
   `client_id VARCHAR(20) NOT NULL PRIMARY KEY`
   (`sql/Banking_Complete_SQL_analysis.sql:38`). Loading the CSV into a column
   with a primary key constraint aborts on the first collision with
   `ER_DUP_ENTRY (1062)`. The pipeline as published cannot complete.
2. **Two KPIs disagreed about the client base.** `COUNT(DISTINCT client_id)`
   (sections 3.1 and 10.1) returns 2,940, while `COUNT(*)` (section 6.1)
   returns 3,000 — a 60-client discrepancy between two figures in the same
   script, with nothing to tell a reader which to trust.
3. **A stated expectation was wrong.** Section 1.2's check was annotated
   *"Expected: 0 rows — no duplicates"*. It returns 59 rows. Because the
   annotation asserted the opposite of the actual result, the check could not
   surface the problem it was written to catch.

### Resolution

The 3,000 rows are preserved, because every published figure in the README
depends on them and the rows are genuinely distinct clients. What changes is
the *identity model*:

- A surrogate `row_id INT AUTO_INCREMENT PRIMARY KEY` carries row identity, and
  `client_id` becomes an indexed, non-unique lookup column.
- The two client-count KPIs are reconciled into `total_records` and
  `distinct_client_ids`, reported side by side so the difference is visible
  rather than silently resolved in one direction.
- Section 1.2b adds a reconciliation query that returns `3000 / 2940 / 60`, so
  the divergence is asserted rather than assumed.

The underlying ID collision is **not fixed** — it is a property of the source
data, and inventing new IDs would make this repository's figures
non-comparable with the original analysis. It is documented instead. Anyone
wanting a true client-level key should obtain a corrected extract from the data
owner.

---

## Finding 2 — UTF-8 BOM (INFO)

`Banking.csv` begins with a UTF-8 BOM. The first header therefore reads
`﻿Client ID`, not `Client ID`.

The SQL import is unaffected, because `LOAD DATA ... IGNORE 1 ROWS` discards
the header line entirely. Other loaders are not so forgiving — reading the file
with a parser that consumes the header by name yields a column literally called
`﻿Client ID`, which then fails to match. `python/data_quality.py` reads
with `utf-8-sig` to neutralise this and reports the BOM rather than hiding it.

---

## Checks performed

| Check | Result |
|---|---|
| Schema — 25 columns, present and in the expected order | PASS |
| Nulls / blanks across all columns | PASS — 0 blanks |
| `Client ID` uniqueness (join cardinality) | **FAIL — 2,940 distinct of 3,000 rows** |
| Integer columns parse as integers | PASS |
| Decimal columns parse as decimals | PASS |
| `Joined Bank` parses as `%d-%m-%Y` | PASS — 3,000/3,000, years 1995–2021 |
| Coded categorical domains | PASS — no values outside the documented sets |
| Non-negative balance columns | PASS |
| `Age` within 16–100 | PASS — min 17, max 85 |
| UTF-8 BOM | INFO — present |

Column **order** is validated, not just column presence. The SQL import loads
positionally rather than by name, so a reordered source would shift every value
into the wrong column without raising an error. The schema check was
negative-tested by swapping two adjacent headers and confirming it reports
`SCHEMA_ORDER` with the offending positions.

---

## What this does not cover

- **The MySQL script was not executed against a live server.** No MySQL client
  or server was available in the analysis environment. The figures in this
  document and in `tests/` were produced by independent recomputation from the
  CSV using the Python standard library — they verify the *numbers*, not the
  *SQL engine's* behaviour. The `ER_DUP_ENTRY` failure in Impact 1 is inferred
  from the primary-key constraint in the DDL, not observed from a live run.
- **Business-logic validity.** Columns such as `Risk Weighting` and
  `Loyalty Classification` are validated for domain and type only. Whether the
  assigned values are correct is a question for the data owner.
- **The `Banking01.xlsx` referenced by the notebook** is absent from the
  repository; see the reproducibility notes in the README.
