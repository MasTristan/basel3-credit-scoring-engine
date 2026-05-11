# Basel III Credit Scoring Engine

PL/SQL engine that computes regulatory credit risk metrics (PD, LGD, EAD,
RWA, capital requirement) for a synthetic automotive-leasing portfolio,
following the Basel III / CRR2 **standard approach**.

The project is a public portfolio piece for a Business Analyst Risk &
Finance IT profile combining Oracle PL/SQL expertise with EBA / Basel III
regulation.

> **Live demo (no install required):** the Streamlit app at
> `streamlit_app.py` is deployed on Streamlit Community Cloud — see
> section *Live demo* below.

---

## 1. Business context

* **Regulatory framework**: Basel III, transposed in the EU via the Capital
  Requirements Regulation 2 (CRR2). Standard approach for credit risk
  (no internal models).
* **Portfolio**: 5 000 leasing contracts (passenger cars, LCV, trucks,
  equipment) booked by a hypothetical European bank subsidiary across
  France, Germany, Spain, Italy, Belgium and the Netherlands.
* **Counterparties**: 1 500 obligors, mix of Retail / SME / Corporate.

Metrics computed:

| Metric | Definition                                                  |
| ------ | ----------------------------------------------------------- |
| PD     | Probability of Default (rating-driven, with regulatory floor) |
| LGD    | Loss Given Default (adjusted for eligible collateral)        |
| EAD    | Exposure At Default (net of provisions + CCF * off-BS)       |
| RWA    | Risk-Weighted Assets (EAD x regulatory risk weight)          |
| K      | Capital requirement = RWA x 8% (CRR2 Article 92)             |

---

## 2. Technical architecture

```
+----------------------+      +------------------------+
|  generate_portfolio  |----->|  SQL inserts + CSVs    |
|       (Python)       |      +-----------+------------+
+----------------------+                  |
                                          v
+-----------------------------------------+-------------------------------+
|                            Oracle XE 21c (schema BASEL_RISK)            |
|     -- production reference engine --                                   |
|                                                                         |
|  COUNTERPARTIES --< CONTRACTS --< COLLATERALS                            |
|                          |                                              |
|                          v                                              |
|                   RISK_CALCULATIONS (SCD2) <----- REGULATORY_PARAMETERS |
|                          |                                              |
|                          v                                              |
|                     CONTROL_LOG                                         |
|                                                                         |
|  PKG_SEGMENTATION  -- PKG_RISK_PARAMS -- PKG_RWA_ENGINE -- PKG_CONTROLS |
|                              \           |          /                   |
|                               +-- PROC_MAIN_PIPELINE                    |
|                                                                         |
|  V_PORTFOLIO_RISK     V_CAPITAL_SUMMARY     (reporting layer)           |
+-------------------------------------------------------------------------+
                                          ^
                                          | identical aggregates
                                          v
+----------------------+      +------------------------+
|  compute_metrics.py  |----->|   data/*.csv           |---> streamlit_app.py
|  (pandas reference)  |      +------------------------+        (public demo)
+----------------------+
```

**Stack**: Oracle XE 21c (free), Python 3.x (open-source), Streamlit
Community Cloud (free public hosting). Zero paid licence.

The Oracle engine under `sql/procedures/` is the production reference; the
Python module `python/compute_metrics.py` mirrors the same logic so the
Streamlit demo runs without an Oracle install.

---

## 3. Repository structure

```
projet1_bale3/
├── CLAUDE.md
├── README.md
├── requirements.txt              <- Streamlit Cloud entry point deps
├── streamlit_app.py              <- public dashboard
├── data/                         <- pre-computed CSV outputs (committed)
│   ├── contracts_enriched.csv
│   ├── portfolio_risk.csv
│   ├── capital_summary.csv
│   └── control_log.csv
├── sql/
│   ├── ddl/
│   │   ├── 01_create_schema.sql
│   │   └── 02_create_indexes.sql
│   ├── procedures/
│   │   ├── 01_pkg_segmentation.sql
│   │   ├── 02_pkg_risk_params.sql
│   │   ├── 03_pkg_rwa_engine.sql
│   │   ├── 04_pkg_controls.sql
│   │   └── 05_proc_main_pipeline.sql
│   └── views/
│       ├── v_portfolio_risk.sql
│       └── v_capital_summary.sql
└── python/
    ├── generate_portfolio.py     <- synthetic data generator (SQL + CSV)
    ├── compute_metrics.py        <- pandas reference pipeline (feeds data/)
    └── requirements.txt
```

---

## Live demo

The dashboard at `streamlit_app.py` is published on Streamlit Community
Cloud — open it in a browser, no install required.

> **URL**: _add the deployed URL here after first deploy_

To deploy your own copy:

1. Fork this repository on GitHub.
2. Sign in to [share.streamlit.io](https://share.streamlit.io) with your
   GitHub account.
3. Click **New app**, pick the fork, branch `main`, file
   `streamlit_app.py`.
4. Streamlit Cloud reads `requirements.txt` at the repo root and starts
   the app. Pre-computed CSVs in `data/` make the demo work out of the
   box; no database is needed.

To run it locally:

```bash
pip install -r requirements.txt
streamlit run streamlit_app.py
```

---

## 4. Setup (full Oracle pipeline)

> **Note**: this section is only needed to run the **production**
> PL/SQL engine. The Streamlit dashboard above runs without any of this.

### 4.1. Install Oracle XE 21c (free)

Download from
[https://www.oracle.com/database/technologies/xe-downloads.html](https://www.oracle.com/database/technologies/xe-downloads.html).

Create the target schema:

```sql
CREATE USER BASEL_RISK IDENTIFIED BY <secret>;
GRANT CONNECT, RESOURCE, CREATE VIEW, CREATE PROCEDURE TO BASEL_RISK;
ALTER USER BASEL_RISK QUOTA UNLIMITED ON USERS;
```

### 4.2. Generate the synthetic portfolio

```bash
cd python
python -m venv .venv && source .venv/bin/activate   # optional
pip install -r requirements.txt
python generate_portfolio.py
```

This writes four INSERT scripts and matching CSV exports in `python/data/`:

* `counterparties_data.sql` / `counterparties.csv`
* `contracts_data.sql`      / `contracts.csv`
* `collaterals_data.sql`    / `collaterals.csv`
* `parameters_data.sql`     / `parameters.csv`

To regenerate the aggregated CSVs consumed by the Streamlit dashboard
(without touching Oracle):

```bash
python python/compute_metrics.py        # writes ../data/*.csv
```

### 4.3. Load the database

Execute the scripts in the following order (SQL\*Plus, SQLcl or SQL
Developer), connected as `BASEL_RISK`:

```text
@sql/ddl/01_create_schema.sql
@sql/ddl/02_create_indexes.sql

@python/data/regulatory_parameters_data.sql
@python/data/counterparties_data.sql
@python/data/contracts_data.sql
@python/data/collaterals_data.sql

@sql/procedures/01_pkg_segmentation.sql
@sql/procedures/02_pkg_risk_params.sql
@sql/procedures/03_pkg_rwa_engine.sql
@sql/procedures/04_pkg_controls.sql
@sql/procedures/05_proc_main_pipeline.sql

@sql/views/v_portfolio_risk.sql
@sql/views/v_capital_summary.sql
```

---

## 5. Running the pipeline

```sql
BEGIN
    PROC_MAIN_PIPELINE(SYSDATE);
END;
/
```

The procedure orchestrates the full run:

1. Logs the run start.
2. Computes PD, LGD, EAD, RWA, K for every active / watchlist /
   defaulted contract (`PKG_RWA_ENGINE.RUN_FULL_PORTFOLIO`).
3. Re-applies segmentation on the freshly inserted SCD2 rows
   (`PKG_SEGMENTATION.REFRESH_ALL_SEGMENTS`).
4. Runs the quality control suite (`PKG_CONTROLS.RUN_ALL_CONTROLS`).
5. Logs the run end with elapsed time and success / error counts.

---

## 6. Sample output

```sql
SELECT * FROM V_PORTFOLIO_RISK;
```

Indicative aggregates (synthetic portfolio, seed 42):

| SEGMENT\_CODE | NB\_CONTRACTS | TOTAL\_EAD (MEUR) | RWA\_DENSITY |
| ------------- | ------------- | ----------------- | ------------ |
| RETAIL        | \~1 950       | \~30              | \~0.75       |
| SME\_RETAIL   | \~1 750       | \~90              | \~0.75       |
| SME\_CORP     | \~250         | \~95              | \~0.85       |
| CORPORATE     | \~900         | \~600             | \~0.90       |
| DEFAULTED     | \~150         | \~25              | \~1.50       |

```sql
SELECT * FROM V_CAPITAL_SUMMARY;
```

| CAPITAL\_RATIO | DEFAULT\_RATE | NB\_ERRORS |
| -------------- | ------------- | ---------- |
| \~0.07         | \~0.03        | 0          |

These numbers track the order-of-magnitude benchmarks described in
`CLAUDE.md` (RWA density \~80-90% globally, capital ratio \~7-8% of EAD,
default rate \~3%).

---

## 7. Quality controls

`PKG_CONTROLS.RUN_ALL_CONTROLS` exercises the following rules, persisted in
`CONTROL_LOG`:

| Code      | Severity | Rule                                                |
| --------- | -------- | --------------------------------------------------- |
| CTR-001   | ERROR    | OUTSTANDING\_BALANCE <= 0                           |
| CTR-002   | WARNING  | MATURITY\_DATE < SYSDATE (expired contract)         |
| CTR-003   | ERROR    | PD = NULL after calculation                         |
| CTR-004   | ERROR    | LGD < 0 or LGD > 1                                  |
| CTR-005   | WARNING  | EAD > ORIGINAL\_AMOUNT \* 1.2                       |
| CTR-006   | WARNING  | RWA = 0 on ACTIVE contract                          |
| CTR-007   | WARNING  | COLLATERAL\_VALUE > OUTSTANDING\_BALANCE \* 3       |
| CTR-008   | ERROR    | DEFAULT\_FLAG=1 but contract STATUS != 'DEFAULT'    |

Quick summary:

```sql
DECLARE c SYS_REFCURSOR;
BEGIN
    PKG_CONTROLS.GET_CONTROL_SUMMARY(SYSDATE, c);
    DBMS_SQL.RETURN_RESULT(c);
END;
/
```

---

## 8. Regulatory references

| Topic                             | Reference                            |
| --------------------------------- | ------------------------------------ |
| Capital requirement (8% of RWA)   | CRR2 Article 92                      |
| Exposures to retail clients       | CRR2 Article 123                     |
| Exposures to corporates           | CRR2 Article 122                     |
| Defaulted exposures (150% RW)     | CRR2 Article 127                     |
| Eligible collateral / haircuts    | CRR2 Articles 197 - 230              |
| PD floor                          | CRR2 Article 160                     |
| EAD definition                    | CRR2 Article 166                     |
| Definition of default             | EBA/GL/2016/07                       |

---

## 9. Coding standards

* PL/SQL : packages, named constants for regulatory thresholds, systematic
  `WHEN OTHERS` exception handler logging into `CONTROL_LOG`, BULK COLLECT /
  FORALL for batch operations.
* Python : PEP8, docstrings, `logging` module (no `print`), seed = 42.
* SQL    : UPPER\_SNAKE\_CASE, explicit constraints (`PK_*`, `FK_*`, `CK_*`),
  column comments in DDL, percentages stored as decimals.

---

## 10. Author

**Tristan Mas** - Business Analyst Risk & Finance IT
[github.com/tristan-mas](https://github.com/tristan-mas)
