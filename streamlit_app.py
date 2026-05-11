"""streamlit_app.py.

Public dashboard for the Basel III credit scoring engine.

Reads the pre-computed CSVs in ``data/`` (produced by
``python/compute_metrics.py``) and renders interactive charts mirroring
the V_PORTFOLIO_RISK and V_CAPITAL_SUMMARY views.

Author : Tristan Mas | github.com/tristan-mas
"""

from __future__ import annotations

import os
from pathlib import Path

import pandas as pd
import plotly.express as px
import streamlit as st

DATA_DIR = Path(__file__).resolve().parent / "data"

st.set_page_config(
    page_title="Basel III Credit Scoring Engine",
    page_icon=":bank:",
    layout="wide",
)


# --------------------------------------------------------------------------- #
# Data loaders                                                                 #
# --------------------------------------------------------------------------- #

@st.cache_data
def load_contracts() -> pd.DataFrame:
    path = DATA_DIR / "contracts_enriched.csv"
    if not path.exists():
        st.error(
            f"Data file not found: {path.name}. "
            "Run `python python/compute_metrics.py` to generate it."
        )
        st.stop()
    return pd.read_csv(path)


@st.cache_data
def load_summary() -> pd.DataFrame:
    path = DATA_DIR / "capital_summary.csv"
    if not path.exists():
        return pd.DataFrame()
    return pd.read_csv(path)


@st.cache_data
def load_controls() -> pd.DataFrame:
    path = DATA_DIR / "control_log.csv"
    if not path.exists():
        return pd.DataFrame()
    return pd.read_csv(path)


# --------------------------------------------------------------------------- #
# Helpers                                                                      #
# --------------------------------------------------------------------------- #

def fmt_eur(value: float) -> str:
    if value is None or pd.isna(value):
        return "n/a"
    if abs(value) >= 1e9:
        return f"€{value / 1e9:,.2f} bn"
    if abs(value) >= 1e6:
        return f"€{value / 1e6:,.2f} M"
    if abs(value) >= 1e3:
        return f"€{value / 1e3:,.1f} k"
    return f"€{value:,.0f}"


def fmt_pct(value: float, digits: int = 2) -> str:
    if value is None or pd.isna(value):
        return "n/a"
    return f"{value * 100:.{digits}f}%"


# --------------------------------------------------------------------------- #
# Sidebar (filters + info)                                                     #
# --------------------------------------------------------------------------- #

contracts = load_contracts()
controls  = load_controls()

st.sidebar.header("Filters")
all_segments = sorted(contracts["SEGMENT_CODE"].dropna().unique())
all_countries = sorted(contracts["COUNTRY_CODE"].dropna().unique())
all_ratings = ["AAA", "AA", "A", "BBB", "BB", "B", "CCC", "D"]
all_assets = sorted(contracts["ASSET_CLASS"].dropna().unique())

selected_segments  = st.sidebar.multiselect("Regulatory segment", all_segments, all_segments)
selected_countries = st.sidebar.multiselect("Country",            all_countries, all_countries)
selected_ratings   = st.sidebar.multiselect("Internal rating",
                                             all_ratings,
                                             [r for r in all_ratings
                                              if r in contracts["INTERNAL_RATING"].unique()])
selected_assets    = st.sidebar.multiselect("Asset class",        all_assets, all_assets)

st.sidebar.markdown("---")
st.sidebar.caption(
    "Reference Python implementation of the PL/SQL pipeline. "
    "Source of truth: Oracle packages under `sql/procedures/`."
)
st.sidebar.markdown(
    "[GitHub repo](https://github.com/MasTristan/basel3-credit-scoring-engine)"
)

mask = (
    contracts["SEGMENT_CODE"].isin(selected_segments)
    & contracts["COUNTRY_CODE"].isin(selected_countries)
    & contracts["INTERNAL_RATING"].isin(selected_ratings)
    & contracts["ASSET_CLASS"].isin(selected_assets)
)
df = contracts.loc[mask].copy()


# --------------------------------------------------------------------------- #
# Header                                                                       #
# --------------------------------------------------------------------------- #

st.title("Basel III Credit Scoring Engine")
st.markdown(
    "Synthetic automotive-leasing portfolio scored under the "
    "**CRR2 standard approach** (PD, LGD, EAD, RWA, capital requirement). "
    "The Oracle PL/SQL engine remains the production reference; this app "
    "renders the pre-computed pandas reference outputs."
)

if df.empty:
    st.warning(
        "No contracts match the current filters. "
        "Adjust the sidebar selections to display data."
    )
    st.info(
        f"Total portfolio: {len(contracts):,} contracts across "
        f"{contracts['COUNTRY_CODE'].nunique()} countries and "
        f"{contracts['SEGMENT_CODE'].nunique()} regulatory segments."
    )
    st.stop()


# --------------------------------------------------------------------------- #
# KPI row                                                                      #
# --------------------------------------------------------------------------- #

total_ead = df["EAD_VALUE"].sum()
total_rwa = df["RWA_VALUE"].sum()
total_cap = df["CAPITAL_REQUIREMENT"].sum()
nb_default = int(df["STATUS"].eq("DEFAULT").sum())
capital_ratio = total_cap / total_ead if total_ead else 0
default_rate = nb_default / len(df) if len(df) else 0

# Reference values computed on the full (unfiltered) portfolio.
ref_ead = contracts["EAD_VALUE"].sum()
ref_cap_ratio = (contracts["CAPITAL_REQUIREMENT"].sum() / ref_ead
                 if ref_ead else 0)
ref_default_rate = (contracts["STATUS"].eq("DEFAULT").sum() / len(contracts)
                    if len(contracts) else 0)
delta_cap = capital_ratio - ref_cap_ratio
delta_def = default_rate - ref_default_rate

k1, k2, k3, k4, k5, k6 = st.columns(6)
k1.metric("Contracts",       f"{len(df):,}")
k2.metric("Total EAD",       fmt_eur(total_ead))
k3.metric("Total RWA",       fmt_eur(total_rwa))
k4.metric("Capital req.",    fmt_eur(total_cap))
k5.metric("Capital ratio",   fmt_pct(capital_ratio),
          delta=f"{delta_cap * 100:+.2f}pp vs full portfolio")
k6.metric("Default rate",    fmt_pct(default_rate),
          delta=f"{delta_def * 100:+.2f}pp vs full portfolio",
          delta_color="inverse")


# --------------------------------------------------------------------------- #
# Tabs                                                                         #
# --------------------------------------------------------------------------- #

tab_about, tab_overview, tab_segments, tab_quality, tab_data, tab_simulator = st.tabs(
    ["About this engine", "Overview", "Segment breakdown",
     "Quality controls", "Raw data", "Single contract simulator"]
)

with tab_about:
    st.markdown(
        """
        ### What problem does this engine solve?

        Under **Basel III**, banks must hold a minimum amount of regulatory
        capital against their credit exposures — this is the **first pillar**
        of the framework, transposed into EU law via the
        **Capital Requirements Regulation 2 (CRR2)**.

        The **standard approach** (used here) computes risk-weighted assets
        (RWA) by applying regulator-defined risk weights to exposures,
        instead of estimating them with internal models (IRB approach).
        It is the default approach for banks that do not have, or do not
        want to defend, internal models — typically smaller banks or
        non-core portfolios of larger groups.

        The portfolio scored here is a **synthetic automotive-leasing book**
        (5 000 contracts across France, Germany, Spain, Italy, Belgium and
        the Netherlands) — representative of a captive-finance subsidiary
        of a European bank.
        """
    )

    st.markdown("---")
    st.subheader("The five regulatory metrics")
    st.markdown(
        "Each contract is scored along five metrics. The first three (PD, "
        "LGD, EAD) are inputs; the last two (RWA, K) are outputs."
    )

    with st.expander("PD — Probability of Default", expanded=False):
        st.markdown(
            "Probability that the obligor defaults within a 1-year horizon. "
            "In the standard approach, PD is derived from the **internal "
            "rating**, with a regulatory floor (CRR2 Article 160)."
        )
        st.latex(r"PD \;=\; \max\bigl(PD_{\text{floor}},\; PD_{\text{rating}}\bigr)")
        st.caption(
            "Rating mapping used: AAA 0.03 % · AA 0.05 % · A 0.10 % · "
            "BBB 0.25 % · BB 1.00 % · B 5.00 % · CCC 15.00 % · D 100 %."
        )

    with st.expander("LGD — Loss Given Default", expanded=False):
        st.markdown(
            "Share of the exposure that is **lost** when default occurs, "
            "after recoveries (collateral liquidation, guarantor calls, …). "
            "Eligible collateral reduces LGD via a **comprehensive method** "
            "with regulatory haircuts (CRR2 Articles 197-230)."
        )
        st.latex(
            r"LGD_{\text{secured}} \;=\; LGD_{\text{base}}"
            r"\times\left(1 - \min\!\left("
            r"\frac{C \times (1 - h)}{EAD},\; 1\right)\right)"
        )
        st.markdown(
            "with a **10 % floor** on the secured part. Unsecured exposures "
            "fall back to the regulatory LGD (45 % in the Foundation IRB "
            "default, used here as a proxy for the standard approach)."
        )

    with st.expander("EAD — Exposure At Default", expanded=False):
        st.markdown(
            "Amount the bank expects to be at risk at the moment of "
            "default. For leasing, EAD combines the **outstanding balance**, "
            "the **accounting provisions** already booked, and the "
            "**residual value** (off-balance commitment) converted via a "
            "**Credit Conversion Factor** — CRR2 Article 166."
        )
        st.latex(
            r"EAD \;=\; \max\!\bigl(0,\; "
            r"\text{Outstanding} - \text{Provisions} + "
            r"\text{Residual} \times CCF\bigr)"
        )

    with st.expander("RWA — Risk-Weighted Assets", expanded=False):
        st.markdown(
            "Exposure scaled by a regulator-set **risk weight**, which "
            "depends on the obligor's segment and on the asset class. "
            "RWA is the denominator of the bank's **solvency ratio**."
        )
        st.latex(r"RWA \;=\; EAD \times RW")

    with st.expander("K — Capital requirement", expanded=False):
        st.markdown(
            "Minimum regulatory capital the bank must hold against the "
            "exposure — **8 % of RWA** under Pillar 1 (CRR2 Article 92). "
            "Pillar 2 add-ons and capital buffers (conservation, "
            "counter-cyclical, systemic) sit on top of this figure and are "
            "out of scope here."
        )
        st.latex(r"K \;=\; RWA \times 8\%")

    st.markdown("---")
    st.subheader("Segmentation logic")
    st.markdown(
        "Each contract is routed to one of five regulatory segments. The "
        "segment drives the base risk weight, and a preferential 50 % "
        "weight applies to well-collateralized vehicle leases "
        "(LTV ≤ 50 %)."
    )
    seg_table = pd.DataFrame([
        {"Segment": "RETAIL",
         "Criteria": "Retail obligor, exposure ≤ 1 MEUR",
         "Risk weight": "75 %",
         "CRR2 ref.": "Art. 123"},
        {"Segment": "SME_RETAIL",
         "Criteria": "SME, turnover ≤ 50 MEUR, exposure ≤ 1 MEUR",
         "Risk weight": "75 %",
         "CRR2 ref.": "Art. 123 + SME supporting factor"},
        {"Segment": "SME_CORP",
         "Criteria": "SME outside the retail bucket",
         "Risk weight": "85 %",
         "CRR2 ref.": "Art. 122"},
        {"Segment": "CORPORATE",
         "Criteria": "Corporate obligor",
         "Risk weight": "100 %",
         "CRR2 ref.": "Art. 122"},
        {"Segment": "DEFAULTED",
         "Criteria": "Contract STATUS = DEFAULT (overrides the above)",
         "Risk weight": "150 %",
         "CRR2 ref.": "Art. 127"},
    ])
    st.dataframe(seg_table, hide_index=True, use_container_width=True)

    st.markdown("---")
    st.subheader("Pipeline architecture")
    st.markdown(
        """
        The **production engine is in Oracle PL/SQL** — five packages
        orchestrated by `PROC_MAIN_PIPELINE`:

        1. `PKG_SEGMENTATION` — assigns the regulatory segment.
        2. `PKG_RISK_PARAMS` — computes PD, LGD and EAD per contract.
        3. `PKG_RWA_ENGINE` — applies risk weights, derives RWA and K,
           writes **SCD2** rows in `RISK_CALCULATIONS` so every run is
           historized.
        4. `PKG_CONTROLS` — runs eight data-quality controls, logs
           findings into `CONTROL_LOG`.
        5. `PROC_MAIN_PIPELINE` — orchestrator with start/end logging and
           error handling.

        This Streamlit app does **not** call the database. It reads a
        snapshot produced by `python/compute_metrics.py`, which mirrors
        the PL/SQL logic in pandas. Same inputs → same numbers within
        rounding; the Oracle engine remains the source of truth, the
        Python module is a sandbox and a demo-feeder.
        """
    )

    st.markdown("---")
    st.subheader("Quality controls")
    st.markdown(
        "Production pipelines always include a control layer — eight rules "
        "run after each batch and findings land in `CONTROL_LOG` for "
        "follow-up. The full breakdown is in the **Quality controls** tab."
    )
    ctl_table = pd.DataFrame([
        {"Code": "CTR-001", "Severity": "ERROR",
         "Rule": "OUTSTANDING_BALANCE ≤ 0"},
        {"Code": "CTR-002", "Severity": "WARNING",
         "Rule": "Contract expired (MATURITY_DATE < today)"},
        {"Code": "CTR-003", "Severity": "ERROR",
         "Rule": "PD missing after calculation"},
        {"Code": "CTR-004", "Severity": "ERROR",
         "Rule": "LGD outside [0, 1]"},
        {"Code": "CTR-005", "Severity": "WARNING",
         "Rule": "EAD exceeds 120 % of original amount"},
        {"Code": "CTR-006", "Severity": "WARNING",
         "Rule": "RWA = 0 on an ACTIVE contract"},
        {"Code": "CTR-007", "Severity": "WARNING",
         "Rule": "Collateral value > 3× outstanding (over-collateralized)"},
        {"Code": "CTR-008", "Severity": "ERROR",
         "Rule": "Counterparty defaulted but contract STATUS ≠ DEFAULT"},
    ])
    st.dataframe(ctl_table, hide_index=True, use_container_width=True)

    st.markdown("---")
    st.subheader("How to read this dashboard")
    st.markdown(
        """
        - The **KPI row at the top** stays in sync with the sidebar
          filters — change a filter, every number updates.
        - **Overview**: EAD vs RWA per segment, capital allocation,
          average PD by rating (log scale, useful since rating-driven PDs
          span four orders of magnitude).
        - **Segment breakdown**: mirrors the `V_PORTFOLIO_RISK` view in
          Oracle plus a country drill-down.
        - **Quality controls**: full `CONTROL_LOG` with severity filter.
        - **Raw data**: top 500 contracts by RWA — the working set risk
          analysts would investigate first.
        """
    )

    st.markdown("---")
    st.subheader("Regulatory references")
    ref_table = pd.DataFrame([
        {"Topic": "Capital requirement (8 % of RWA)", "Reference": "CRR2 Art. 92"},
        {"Topic": "Exposures to corporates",          "Reference": "CRR2 Art. 122"},
        {"Topic": "Exposures to retail clients",      "Reference": "CRR2 Art. 123"},
        {"Topic": "Defaulted exposures (150 % RW)",   "Reference": "CRR2 Art. 127"},
        {"Topic": "PD floor (standard approach)",     "Reference": "CRR2 Art. 160"},
        {"Topic": "EAD definition",                    "Reference": "CRR2 Art. 166"},
        {"Topic": "Eligible collateral / haircuts",   "Reference": "CRR2 Art. 197-230"},
        {"Topic": "Definition of default",             "Reference": "EBA/GL/2016/07"},
    ])
    st.dataframe(ref_table, hide_index=True, use_container_width=True)

    st.markdown("---")
    st.markdown(
        "**Author** — Tristan Mas, Business Analyst Risk & Finance IT. "
        "Combines Oracle PL/SQL engineering with EBA / Basel III "
        "regulatory expertise. "
        "[GitHub](https://github.com/MasTristan/basel3-credit-scoring-engine)"
    )

with tab_overview:
    col_a, col_b = st.columns(2)

    seg_df = (
        df.groupby("SEGMENT_CODE")
          .agg(EAD=("EAD_VALUE", "sum"),
               RWA=("RWA_VALUE", "sum"),
               CAPITAL=("CAPITAL_REQUIREMENT", "sum"),
               NB=("CONTRACT_ID", "count"))
          .reset_index()
    )
    seg_df["RWA_DENSITY"] = seg_df["RWA"] / seg_df["EAD"]

    fig1 = px.bar(
        seg_df, x="SEGMENT_CODE", y=["EAD", "RWA"],
        title="EAD vs RWA per regulatory segment",
        barmode="group",
        labels={"value": "EUR", "variable": "Metric"},
    )
    fig1.update_layout(yaxis_title="EUR", legend_title="")
    col_a.plotly_chart(fig1, use_container_width=True)

    fig2 = px.pie(
        seg_df, names="SEGMENT_CODE", values="CAPITAL",
        title="Capital requirement allocation",
        hole=0.45,
    )
    col_b.plotly_chart(fig2, use_container_width=True)

    rating_order = ["AAA", "AA", "A", "BBB", "BB", "B", "CCC", "D"]
    rating_df = (
        df.assign(INTERNAL_RATING=pd.Categorical(df["INTERNAL_RATING"],
                                                 rating_order, ordered=True))
          .groupby("INTERNAL_RATING")["PD_VALUE"]
          .mean()
          .reset_index()
    )
    fig3 = px.bar(
        rating_df, x="INTERNAL_RATING", y="PD_VALUE",
        title="Average PD by internal rating (log scale)",
        labels={"PD_VALUE": "Average PD"},
        log_y=True,
    )
    st.plotly_chart(fig3, use_container_width=True)

with tab_segments:
    st.subheader("Regulatory segment view (mirror of V_PORTFOLIO_RISK)")
    display_df = seg_df.copy()
    display_df["EAD"]         = display_df["EAD"].map(fmt_eur)
    display_df["RWA"]         = display_df["RWA"].map(fmt_eur)
    display_df["CAPITAL"]     = display_df["CAPITAL"].map(fmt_eur)
    display_df["RWA_DENSITY"] = display_df["RWA_DENSITY"].map(lambda v: fmt_pct(v, 1))
    display_df = display_df.rename(columns={
        "SEGMENT_CODE": "Segment",
        "NB":           "Contracts",
        "EAD":          "Total EAD",
        "RWA":          "Total RWA",
        "CAPITAL":      "Capital req.",
        "RWA_DENSITY":  "RWA density",
    })[["Segment", "Contracts", "Total EAD", "Total RWA",
        "Capital req.", "RWA density"]]
    st.dataframe(display_df, hide_index=True, use_container_width=True)

    country_df = (
        df.groupby("COUNTRY_CODE")
          .agg(EAD=("EAD_VALUE", "sum"),
               RWA=("RWA_VALUE", "sum"),
               NB=("CONTRACT_ID", "count"))
          .reset_index()
          .sort_values("EAD", ascending=False)
    )
    fig_country = px.bar(
        country_df, x="COUNTRY_CODE", y="EAD",
        title="EAD distribution by country",
        labels={"EAD": "EAD (EUR)", "COUNTRY_CODE": "Country"},
    )
    st.plotly_chart(fig_country, use_container_width=True)

with tab_quality:
    st.subheader("Quality controls (CONTROL_LOG)")
    if controls.empty:
        st.success("No quality findings on this run.")
    else:
        summary = (
            controls.groupby(["CONTROL_CODE", "SEVERITY"])
            .size()
            .reset_index(name="Findings")
            .sort_values(["SEVERITY", "CONTROL_CODE"])
        )
        st.dataframe(summary, hide_index=True, use_container_width=True)

        sev = st.selectbox("Filter by severity", ["ALL", "ERROR", "WARNING", "INFO"])
        view = controls if sev == "ALL" else controls[controls["SEVERITY"].eq(sev)]
        st.dataframe(view.head(500), hide_index=True, use_container_width=True)
        st.caption(f"Showing {min(len(view), 500):,} of {len(view):,} findings.")

with tab_data:
    st.subheader("Per-contract metrics (sample)")
    cols = [
        "CONTRACT_ID", "COUNTERPARTY_TYPE", "COUNTRY_CODE", "INTERNAL_RATING",
        "ASSET_CLASS", "STATUS", "SEGMENT_CODE",
        "OUTSTANDING_BALANCE", "EAD_VALUE", "PD_VALUE", "LGD_VALUE",
        "RISK_WEIGHT", "RWA_VALUE", "CAPITAL_REQUIREMENT",
    ]
    st.dataframe(
        df[cols].sort_values("RWA_VALUE", ascending=False).head(500),
        hide_index=True, use_container_width=True,
    )
    st.caption(
        f"Showing top 500 of {len(df):,} filtered contracts, "
        "sorted by RWA descending."
    )

with tab_simulator:
    st.subheader("Single contract scorer")
    st.markdown(
        "Compute PD, LGD, EAD, RWA and capital requirement for a "
        "hypothetical contract — same formulas as the Oracle engine."
    )

    col1, col2, col3 = st.columns(3)

    with col1:
        st.markdown("**Counterparty**")
        cp_type = st.selectbox(
            "Counterparty type",
            ["RETAIL", "SME", "CORPORATE"],
            key="sim_cp_type",
        )
        rating = st.selectbox(
            "Internal rating",
            ["AAA", "AA", "A", "BBB", "BB", "B", "CCC", "D"],
            index=3,
            key="sim_rating",
        )
        turnover = st.number_input(
            "Annual turnover (EUR)",
            min_value=0,
            value=10_000_000,
            step=500_000,
            key="sim_turnover",
        )

    with col2:
        st.markdown("**Contract**")
        outstanding = st.number_input(
            "Outstanding balance (EUR)",
            min_value=1,
            value=150_000,
            step=5_000,
            key="sim_outstanding",
        )
        residual = st.number_input(
            "Residual value (EUR)",
            min_value=0,
            value=20_000,
            step=1_000,
            key="sim_residual",
        )
        provisions = st.number_input(
            "Accounting provisions (EUR)",
            min_value=0,
            value=0,
            step=1_000,
            key="sim_provisions",
        )
        status = st.selectbox(
            "Contract status",
            ["ACTIVE", "WATCHLIST", "DEFAULT"],
            key="sim_status",
        )

    with col3:
        st.markdown("**Collateral**")
        has_collateral = st.checkbox("Eligible collateral", value=True, key="sim_has_col")
        col_value = st.number_input(
            "Collateral value (EUR)",
            min_value=0,
            value=120_000,
            step=5_000,
            key="sim_col_value",
            disabled=not has_collateral,
        )
        haircut = st.slider(
            "Regulatory haircut",
            min_value=0.0,
            max_value=0.50,
            value=0.15,
            step=0.01,
            format="%.0f%%",
            key="sim_haircut",
            disabled=not has_collateral,
        )

    # ---- Segmentation ----
    if status == "DEFAULT":
        segment = "DEFAULTED"
    elif cp_type == "RETAIL":
        segment = "RETAIL" if outstanding <= 1_000_000 else "CORPORATE"
    elif cp_type == "SME":
        if turnover <= 50_000_000 and outstanding <= 1_000_000:
            segment = "SME_RETAIL"
        else:
            segment = "SME_CORP"
    else:
        segment = "CORPORATE"

    # ---- PD ----
    PD_MAP = {
        "AAA": 0.0003, "AA": 0.0005, "A": 0.0010, "BBB": 0.0025,
        "BB": 0.0100, "B": 0.0500, "CCC": 0.1500, "D": 1.0000,
    }
    PD_FLOOR = 0.0003
    pd_val = max(PD_FLOOR, PD_MAP[rating])

    # ---- EAD ----
    CCF = 0.40
    ead_val = max(0.0, outstanding - provisions + residual * CCF)

    # ---- LGD ----
    LGD_UNSECURED = {"RETAIL": 0.45, "SME_RETAIL": 0.45,
                     "SME_CORP": 0.45, "CORPORATE": 0.45, "DEFAULTED": 0.45}
    LGD_SECURED_BASE = 0.35
    LGD_SECURED_FLOOR = 0.10
    if has_collateral and ead_val > 0:
        adjusted_col = col_value * (1 - haircut)
        lgd_val = max(
            LGD_SECURED_FLOOR,
            LGD_SECURED_BASE * (1 - min(adjusted_col / ead_val, 1.0)),
        )
    else:
        lgd_val = LGD_UNSECURED.get(segment, 0.45)

    # ---- RWA ----
    RW_MAP = {
        "RETAIL": 0.75, "SME_RETAIL": 0.75, "SME_CORP": 0.85,
        "CORPORATE": 1.00, "DEFAULTED": 1.50,
    }
    rw = RW_MAP[segment]
    rwa_val = ead_val * rw
    capital_val = rwa_val * 0.08

    # ---- Display ----
    st.markdown("---")
    st.markdown(f"**Regulatory segment assigned : `{segment}`**")

    r1, r2, r3, r4, r5 = st.columns(5)
    r1.metric("PD", fmt_pct(pd_val, 3))
    r2.metric("LGD", fmt_pct(lgd_val, 1))
    r3.metric("EAD", fmt_eur(ead_val))
    r4.metric("RWA", fmt_eur(rwa_val))
    r5.metric("Capital req.", fmt_eur(capital_val))

    with st.expander("Calculation detail"):
        st.markdown(f"""
        | Step | Formula | Result |
        |------|---------|--------|
        | Segment | Based on type / turnover / status | `{segment}` |
        | PD | max(floor={fmt_pct(PD_FLOOR,3)}, rating PD) | `{fmt_pct(pd_val,4)}` |
        | EAD | max(0, {outstanding:,} - {provisions:,} + {residual:,} × {CCF}) | `{fmt_eur(ead_val)}` |
        | LGD | {'Secured method' if has_collateral else 'Unsecured fallback'} | `{fmt_pct(lgd_val,1)}` |
        | Risk weight | Segment `{segment}` → {fmt_pct(rw,0)} | `{fmt_pct(rw,0)}` |
        | RWA | {fmt_eur(ead_val)} × {fmt_pct(rw,0)} | `{fmt_eur(rwa_val)}` |
        | Capital | {fmt_eur(rwa_val)} × 8% | `{fmt_eur(capital_val)}` |
        """)

st.markdown("---")
st.caption(
    "Numbers produced by `python/compute_metrics.py` (reference). "
    "The Oracle PL/SQL engine returns identical aggregates within rounding."
)
st.markdown(
    "**Basel III Credit Scoring Engine** — Tristan Mas, Business Analyst "
    "Risk & Finance IT &nbsp;|&nbsp; "
    "[GitHub](https://github.com/MasTristan/basel3-credit-scoring-engine) "
    "&nbsp;|&nbsp; "
    "[LinkedIn](https://linkedin.com/in/tristan-mas)",
    unsafe_allow_html=True,
)
