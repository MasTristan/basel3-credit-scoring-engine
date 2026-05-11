# Architecture — Basel III Credit Scoring Engine

## Data model

Six tables, one schema (BASEL_RISK on Oracle XE 21c).

```
COUNTERPARTIES ──< CONTRACTS ──< COLLATERALS
                       │
                       ▼
              RISK_CALCULATIONS (SCD2)  ◄── REGULATORY_PARAMETERS
                       │
                       ▼
                  CONTROL_LOG
```

RISK_CALCULATIONS uses Slowly Changing Dimension type 2:
each pipeline run closes the previous row (VALID_TO = run_date,
IS_CURRENT = 0) and inserts a new current row. Full calculation
history is preserved.

## PL/SQL packages

| Package              | Responsibility                              |
|----------------------|---------------------------------------------|
| PKG_SEGMENTATION     | Assigns CRR2 regulatory segment per contract|
| PKG_RISK_PARAMS      | Computes PD, LGD, EAD                       |
| PKG_RWA_ENGINE       | Derives RWA and capital requirement (K)     |
| PKG_CONTROLS         | Runs 8 data-quality rules → CONTROL_LOG     |
| PROC_MAIN_PIPELINE   | Orchestrator — single entry point           |

## Python reference implementation

`python/compute_metrics.py` replicates the PL/SQL logic in pandas.
It feeds the pre-computed CSVs in `data/` consumed by the Streamlit
dashboard. Same inputs produce identical aggregates within floating-
point rounding.

It is not a replacement for the Oracle engine — it exists so the
public demo runs without a database.

## Design decisions

- **SCD2 on RISK_CALCULATIONS**: preserves full run history for
  audit trail and trend analysis without separate archive tables.
- **Named constants for regulatory thresholds**: no magic numbers
  in the business logic; all CRR2 parameters are centralised in
  REGULATORY_PARAMETERS and as PL/SQL package constants.
- **BULK COLLECT / FORALL**: batch operations avoid row-by-row
  context switches between SQL and PL/SQL engines.
- **Zero paid licences**: Oracle XE 21c (free tier), Streamlit
  Community Cloud (free hosting), Python open-source stack.
