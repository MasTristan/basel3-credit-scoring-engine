-- ============================================================
-- View    : V_CAPITAL_SUMMARY
-- Purpose : Portfolio-wide regulatory capital summary
-- Author  : Tristan Mas | github.com/tristan-mas
-- Version : 1.0 | 2025
-- ============================================================

CREATE OR REPLACE VIEW V_CAPITAL_SUMMARY AS
WITH current_calc AS (
    SELECT rc.*, ct.STATUS
      FROM RISK_CALCULATIONS rc
      JOIN CONTRACTS ct ON ct.CONTRACT_ID = rc.CONTRACT_ID
     WHERE rc.IS_CURRENT = 1
), agg AS (
    SELECT
        MAX(CALCULATION_DATE)                              AS CALCULATION_DATE,
        SUM(EAD_VALUE)                                     AS TOTAL_PORTFOLIO_EAD,
        SUM(RWA_VALUE)                                     AS TOTAL_RWA,
        SUM(CAPITAL_REQUIREMENT)                           AS TOTAL_CAPITAL_REQUIREMENT,
        SUM(CASE WHEN STATUS = 'DEFAULT' THEN 1 ELSE 0 END)
                                                           AS NB_DEFAULTED_CONTRACTS,
        COUNT(*)                                           AS NB_TOTAL_CONTRACTS,
        SUM(CASE WHEN CALC_STATUS = 'ERROR' THEN 1 ELSE 0 END)
                                                           AS NB_ERRORS
    FROM current_calc
)
SELECT
    CALCULATION_DATE,
    TOTAL_PORTFOLIO_EAD,
    TOTAL_RWA,
    TOTAL_CAPITAL_REQUIREMENT,
    CASE WHEN TOTAL_PORTFOLIO_EAD > 0
         THEN ROUND(TOTAL_CAPITAL_REQUIREMENT / TOTAL_PORTFOLIO_EAD, 4)
         ELSE NULL
    END AS CAPITAL_RATIO,
    NB_DEFAULTED_CONTRACTS,
    CASE WHEN NB_TOTAL_CONTRACTS > 0
         THEN ROUND(NB_DEFAULTED_CONTRACTS / NB_TOTAL_CONTRACTS, 4)
         ELSE NULL
    END AS DEFAULT_RATE,
    NB_ERRORS
FROM agg;

COMMENT ON TABLE V_CAPITAL_SUMMARY
    IS 'Portfolio-wide capital summary (current SCD2 record)';
