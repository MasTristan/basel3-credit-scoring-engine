"""compute_metrics.py.

Reference Python implementation of the Basel III credit scoring pipeline.

Mirrors the PL/SQL packages (PKG_SEGMENTATION, PKG_RISK_PARAMS,
PKG_RWA_ENGINE, PKG_CONTROLS). The Oracle PL/SQL engine remains the
production reference; this module exists so the synthetic portfolio can
be scored without an Oracle install, feeding the Streamlit dashboard.

Outputs (in repository data/ folder):
    - contracts_enriched.csv   per-contract metrics
    - portfolio_risk.csv       mirrors V_PORTFOLIO_RISK
    - capital_summary.csv      mirrors V_CAPITAL_SUMMARY
    - control_log.csv          quality-control findings

Run::

    python python/compute_metrics.py

Author : Tristan Mas | github.com/tristan-mas
Version: 1.0 | 2025
"""

from __future__ import annotations

import logging
import os
from datetime import date

import numpy as np
import pandas as pd

from generate_portfolio import build_dataframes

# --------------------------------------------------------------------------- #
# Regulatory constants (kept in sync with PL/SQL packages)                     #
# --------------------------------------------------------------------------- #

RETAIL_BALANCE_LIMIT = 1_000_000.0
SME_TURNOVER_LIMIT   = 50_000_000.0

PD_FROM_RATING = {
    "AAA": 0.0003, "AA": 0.0005, "A": 0.0010, "BBB": 0.0025,
    "BB":  0.0100, "B":  0.0500, "CCC": 0.1500, "D": 1.0000,
}

PD_FLOOR_DEFAULT       = 0.0003
LGD_SECURED_FLOOR      = 0.10
LGD_SECURED_DEFAULT    = 0.35
LGD_UNSECURED_DEFAULT  = 0.45
CCF_DEFAULT            = 1.00

RW_BY_SEGMENT = {
    "RETAIL":     0.75,
    "SME_RETAIL": 0.75,
    "SME_CORP":   0.85,
    "CORPORATE":  1.00,
    "DEFAULTED":  1.50,
}
RW_SECURED_VEHICLE   = 0.50
LTV_VEHICLE_THRESH   = 0.50

CAPITAL_RATIO = 0.08

OUTPUT_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "data",
)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)-7s | %(message)s",
)
logger = logging.getLogger("metrics")


# --------------------------------------------------------------------------- #
# Pipeline steps                                                               #
# --------------------------------------------------------------------------- #

def assign_segment(df: pd.DataFrame) -> pd.Series:
    """Return the regulatory segment for each enriched contract row."""
    cond_default = df["STATUS"].eq("DEFAULT")
    cond_retail = (
        df["COUNTERPARTY_TYPE"].eq("RETAIL")
        & df["OUTSTANDING_BALANCE"].le(RETAIL_BALANCE_LIMIT)
    )
    cond_sme_retail = (
        df["COUNTERPARTY_TYPE"].eq("SME")
        & df["ANNUAL_TURNOVER"].fillna(0).le(SME_TURNOVER_LIMIT)
        & df["OUTSTANDING_BALANCE"].le(RETAIL_BALANCE_LIMIT)
    )
    cond_sme_corp = df["COUNTERPARTY_TYPE"].eq("SME")
    cond_corp     = df["COUNTERPARTY_TYPE"].eq("CORPORATE")

    return np.select(
        [cond_default, cond_retail, cond_sme_retail, cond_sme_corp, cond_corp],
        ["DEFAULTED", "RETAIL", "SME_RETAIL", "SME_CORP", "CORPORATE"],
        default="CORPORATE",
    )


def compute_pd(df: pd.DataFrame) -> pd.Series:
    """PD = max(PD_FLOOR, PD_from_rating); 100% if defaulted."""
    base = df["INTERNAL_RATING"].map(PD_FROM_RATING).fillna(0.05)
    pd_val = np.maximum(base, PD_FLOOR_DEFAULT)
    return np.where(df["STATUS"].eq("DEFAULT"), 1.0, pd_val)


def compute_ead(df: pd.DataFrame) -> pd.Series:
    """EAD = max(0, OUTSTANDING - PROVISION + RESIDUAL * CCF)."""
    ead = (
        df["OUTSTANDING_BALANCE"].fillna(0)
        - df["PROVISION_AMOUNT"].fillna(0)
        + df["RESIDUAL_VALUE"].fillna(0) * CCF_DEFAULT
    )
    return ead.clip(lower=0)


def compute_lgd(df: pd.DataFrame) -> pd.Series:
    """Collateral-adjusted LGD with regulatory floor."""
    eligible = df["ELIGIBLE_FLAG"].fillna(0).astype(int).eq(1)
    secured_value = df["COLLATERAL_VALUE"].fillna(0) * (1 - df["HAIRCUT_PCT"].fillna(0))
    ratio = np.where(df["EAD_VALUE"] > 0, secured_value / df["EAD_VALUE"], 0)
    ratio = np.clip(ratio, 0, 1)
    lgd_secured = LGD_SECURED_DEFAULT * (1 - ratio)
    lgd_secured = np.maximum(lgd_secured, LGD_SECURED_FLOOR)
    lgd = np.where(eligible & (df["EAD_VALUE"] > 0), lgd_secured, LGD_UNSECURED_DEFAULT)
    return np.clip(lgd, 0, 1)


def compute_risk_weight(df: pd.DataFrame) -> pd.Series:
    """Segment-driven RW with 50% override for well-collateralized vehicles."""
    base_rw = df["SEGMENT_CODE"].map(RW_BY_SEGMENT).fillna(1.0)
    eligible = df["ELIGIBLE_FLAG"].fillna(0).astype(int).eq(1)
    eligible_asset = df["ASSET_CLASS"].isin(["PASSENGER_CAR", "LCV"])
    ltv = np.where(
        df["COLLATERAL_VALUE"].fillna(0) > 0,
        df["OUTSTANDING_BALANCE"] / df["COLLATERAL_VALUE"].replace(0, np.nan),
        np.inf,
    )
    secured = (
        df["SEGMENT_CODE"].ne("DEFAULTED")
        & eligible
        & eligible_asset
        & (ltv <= LTV_VEHICLE_THRESH)
    )
    return np.where(secured, RW_SECURED_VEHICLE, base_rw)


# --------------------------------------------------------------------------- #
# Quality controls                                                             #
# --------------------------------------------------------------------------- #

def run_controls(df: pd.DataFrame, run_date: date) -> pd.DataFrame:
    """Return one row per finding (matches CONTROL_LOG)."""
    today = pd.Timestamp(run_date)
    findings = []

    def add(rule, severity, mask, msg_fn):
        for cid, msg in zip(df.loc[mask, "CONTRACT_ID"], df.loc[mask].apply(msg_fn, axis=1)):
            findings.append({
                "RUN_DATE":     today.date(),
                "CONTRACT_ID":  int(cid),
                "CONTROL_CODE": rule,
                "SEVERITY":     severity,
                "MESSAGE":      msg,
            })

    add("CTR-001", "ERROR",
        df["OUTSTANDING_BALANCE"].le(0),
        lambda r: f"Outstanding balance is not positive ({r['OUTSTANDING_BALANCE']:.2f})")

    expired = pd.to_datetime(df["MATURITY_DATE"]).lt(today) & df["STATUS"].ne("CLOSED")
    add("CTR-002", "WARNING", expired,
        lambda r: f"Contract expired on {pd.to_datetime(r['MATURITY_DATE']).date()}")

    add("CTR-003", "ERROR",
        df["PD_VALUE"].isna(),
        lambda r: "PD is NULL after calculation")

    add("CTR-004", "ERROR",
        (df["LGD_VALUE"] < 0) | (df["LGD_VALUE"] > 1),
        lambda r: f"LGD out of bounds: {r['LGD_VALUE']:.4f}")

    add("CTR-005", "WARNING",
        df["EAD_VALUE"] > df["ORIGINAL_AMOUNT"] * 1.2,
        lambda r: (f"EAD ({r['EAD_VALUE']:.2f}) exceeds 120% of "
                   f"original ({r['ORIGINAL_AMOUNT']:.2f})"))

    add("CTR-006", "WARNING",
        df["STATUS"].eq("ACTIVE") & df["RWA_VALUE"].fillna(0).eq(0),
        lambda r: "RWA = 0 on ACTIVE contract")

    add("CTR-007", "WARNING",
        (df["COLLATERAL_VALUE"].fillna(0) > df["OUTSTANDING_BALANCE"] * 3)
        & (df["OUTSTANDING_BALANCE"] > 0),
        lambda r: (f"Collateral ({r['COLLATERAL_VALUE']:.2f}) > 3x outstanding "
                   f"({r['OUTSTANDING_BALANCE']:.2f})"))

    add("CTR-008", "ERROR",
        df["DEFAULT_FLAG"].eq(1) & ~df["STATUS"].isin(["DEFAULT", "CLOSED"]),
        lambda r: f"Counterparty defaulted but contract STATUS = {r['STATUS']}")

    return pd.DataFrame(findings,
                        columns=["RUN_DATE", "CONTRACT_ID", "CONTROL_CODE",
                                 "SEVERITY", "MESSAGE"])


# --------------------------------------------------------------------------- #
# Aggregations                                                                 #
# --------------------------------------------------------------------------- #

def aggregate_by_segment(df: pd.DataFrame) -> pd.DataFrame:
    """Mirror of V_PORTFOLIO_RISK."""
    grp = df.groupby("SEGMENT_CODE").agg(
        NB_CONTRACTS=("CONTRACT_ID", "count"),
        TOTAL_EAD=("EAD_VALUE", "sum"),
        TOTAL_RWA=("RWA_VALUE", "sum"),
        TOTAL_CAPITAL_REQUIREMENT=("CAPITAL_REQUIREMENT", "sum"),
        AVG_PD=("PD_VALUE", "mean"),
        AVG_LGD=("LGD_VALUE", "mean"),
    ).reset_index()
    grp["RWA_DENSITY"] = np.where(
        grp["TOTAL_EAD"] > 0, grp["TOTAL_RWA"] / grp["TOTAL_EAD"], np.nan,
    )
    return grp.round({"AVG_PD": 6, "AVG_LGD": 4, "RWA_DENSITY": 4})


def portfolio_summary(df: pd.DataFrame, run_date: date,
                      nb_errors: int) -> pd.DataFrame:
    """Mirror of V_CAPITAL_SUMMARY (single-row)."""
    total_ead = df["EAD_VALUE"].sum()
    total_rwa = df["RWA_VALUE"].sum()
    total_cap = df["CAPITAL_REQUIREMENT"].sum()
    nb_default = df["STATUS"].eq("DEFAULT").sum()
    return pd.DataFrame([{
        "CALCULATION_DATE":         pd.Timestamp(run_date).date(),
        "TOTAL_PORTFOLIO_EAD":      round(total_ead, 2),
        "TOTAL_RWA":                round(total_rwa, 2),
        "TOTAL_CAPITAL_REQUIREMENT": round(total_cap, 2),
        "CAPITAL_RATIO":            round(total_cap / total_ead, 4) if total_ead else None,
        "NB_DEFAULTED_CONTRACTS":   int(nb_default),
        "NB_TOTAL_CONTRACTS":       int(len(df)),
        "DEFAULT_RATE":             round(nb_default / len(df), 4) if len(df) else None,
        "NB_ERRORS":                int(nb_errors),
    }])


# --------------------------------------------------------------------------- #
# Main                                                                         #
# --------------------------------------------------------------------------- #

def main(run_date: date | None = None) -> None:
    """Run the Basel III pipeline in pandas and write CSVs."""
    run_date = run_date or date.today()
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    frames = build_dataframes()
    cp     = frames["counterparties"]
    ct     = frames["contracts"]
    co     = frames["collaterals"]

    co_best = (
        co.sort_values(["ELIGIBLE_FLAG", "COLLATERAL_VALUE"], ascending=False)
          .drop_duplicates(subset=["CONTRACT_ID"], keep="first")
    )

    df = (
        ct.merge(cp, on="COUNTERPARTY_ID", how="left", suffixes=("", "_CP"))
          .merge(co_best, on="CONTRACT_ID", how="left", suffixes=("", "_CO"))
    )

    eligible_active = df["STATUS"].isin(["ACTIVE", "WATCHLIST", "DEFAULT"])
    df = df.loc[eligible_active].copy()

    df["SEGMENT_CODE"] = assign_segment(df)
    df["PD_VALUE"]     = compute_pd(df)
    df["EAD_VALUE"]    = compute_ead(df)
    df["LGD_VALUE"]    = compute_lgd(df)
    df["RISK_WEIGHT"]  = compute_risk_weight(df)
    df["RWA_VALUE"]    = (df["EAD_VALUE"] * df["RISK_WEIGHT"]).round(2)
    df["CAPITAL_REQUIREMENT"] = (df["RWA_VALUE"] * CAPITAL_RATIO).round(2)
    df["CALCULATION_DATE"] = pd.Timestamp(run_date).date()
    df["CALC_STATUS"] = np.where(df[["PD_VALUE", "LGD_VALUE", "EAD_VALUE",
                                     "RWA_VALUE"]].isna().any(axis=1),
                                 "ERROR", "VALID")
    nb_errors = int((df["CALC_STATUS"] == "ERROR").sum())

    enriched_cols = [
        "CONTRACT_ID", "COUNTERPARTY_ID", "COUNTERPARTY_TYPE", "COUNTRY_CODE",
        "INTERNAL_RATING", "SECTOR_CODE", "PRODUCT_TYPE", "ASSET_CLASS",
        "ORIGINAL_AMOUNT", "OUTSTANDING_BALANCE", "RESIDUAL_VALUE",
        "PROVISION_AMOUNT", "MATURITY_DATE", "STATUS",
        "COLLATERAL_TYPE", "COLLATERAL_VALUE", "HAIRCUT_PCT", "ELIGIBLE_FLAG",
        "SEGMENT_CODE", "PD_VALUE", "LGD_VALUE", "EAD_VALUE",
        "RISK_WEIGHT", "RWA_VALUE", "CAPITAL_REQUIREMENT",
        "CALCULATION_DATE", "CALC_STATUS",
    ]
    enriched = df[enriched_cols].copy()
    enriched.to_csv(os.path.join(OUTPUT_DIR, "contracts_enriched.csv"), index=False)
    logger.info("Wrote contracts_enriched.csv (%d rows)", len(enriched))

    aggregate_by_segment(df).to_csv(
        os.path.join(OUTPUT_DIR, "portfolio_risk.csv"), index=False
    )
    logger.info("Wrote portfolio_risk.csv")

    portfolio_summary(df, run_date, nb_errors).to_csv(
        os.path.join(OUTPUT_DIR, "capital_summary.csv"), index=False
    )
    logger.info("Wrote capital_summary.csv")

    controls = run_controls(df, run_date)
    controls.to_csv(os.path.join(OUTPUT_DIR, "control_log.csv"), index=False)
    logger.info("Wrote control_log.csv (%d findings)", len(controls))


if __name__ == "__main__":
    main()
