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
    return pd.read_csv(DATA_DIR / "contracts_enriched.csv")


@st.cache_data
def load_summary() -> pd.DataFrame:
    return pd.read_csv(DATA_DIR / "capital_summary.csv")


@st.cache_data
def load_controls() -> pd.DataFrame:
    return pd.read_csv(DATA_DIR / "control_log.csv")


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
    "[GitHub repo](https://github.com/MasTristan/Moteur-de-Scoring-Cr-dit-B-le-III)"
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
    st.warning("No contracts match the current filters.")
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

k1, k2, k3, k4, k5, k6 = st.columns(6)
k1.metric("Contracts",       f"{len(df):,}")
k2.metric("Total EAD",       fmt_eur(total_ead))
k3.metric("Total RWA",       fmt_eur(total_rwa))
k4.metric("Capital req.",    fmt_eur(total_cap))
k5.metric("Capital ratio",   fmt_pct(capital_ratio))
k6.metric("Default rate",    fmt_pct(default_rate))


# --------------------------------------------------------------------------- #
# Tabs                                                                         #
# --------------------------------------------------------------------------- #

tab_overview, tab_segments, tab_quality, tab_data = st.tabs(
    ["Overview", "Segment breakdown", "Quality controls", "Raw data"]
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
    col_a.plotly_chart(fig1, width="stretch")

    fig2 = px.pie(
        seg_df, names="SEGMENT_CODE", values="CAPITAL",
        title="Capital requirement allocation",
        hole=0.45,
    )
    col_b.plotly_chart(fig2, width="stretch")

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
    st.plotly_chart(fig3, width="stretch")

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
    st.dataframe(display_df, hide_index=True, width="stretch")

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
    st.plotly_chart(fig_country, width="stretch")

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
        st.dataframe(summary, hide_index=True, width="stretch")

        sev = st.selectbox("Filter by severity", ["ALL", "ERROR", "WARNING", "INFO"])
        view = controls if sev == "ALL" else controls[controls["SEVERITY"].eq(sev)]
        st.dataframe(view.head(500), hide_index=True, width="stretch")
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
        hide_index=True, width="stretch",
    )
    st.caption(
        f"Showing top 500 of {len(df):,} filtered contracts, "
        "sorted by RWA descending."
    )

st.markdown("---")
st.caption(
    "Numbers produced by `python/compute_metrics.py` (reference). "
    "The Oracle PL/SQL engine returns identical aggregates within rounding."
)
