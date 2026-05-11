-- ============================================================
-- View    : V_PORTFOLIO_RISK
-- Purpose : Aggregated risk view by regulatory segment (current SCD2 rows).
-- Author  : Tristan Mas | github.com/tristan-mas
-- Version : 1.0 | 2025
-- ============================================================

CREATE OR REPLACE VIEW V_PORTFOLIO_RISK AS
SELECT
    rc.SEGMENT_CODE                                       AS SEGMENT_CODE,
    COUNT(*)                                              AS NB_CONTRACTS,
    SUM(rc.EAD_VALUE)                                     AS TOTAL_EAD,
    SUM(rc.RWA_VALUE)                                     AS TOTAL_RWA,
    SUM(rc.CAPITAL_REQUIREMENT)                           AS TOTAL_CAPITAL_REQUIREMENT,
    ROUND(AVG(rc.PD_VALUE), 6)                            AS AVG_PD,
    ROUND(AVG(rc.LGD_VALUE), 4)                           AS AVG_LGD,
    CASE WHEN SUM(rc.EAD_VALUE) > 0
         THEN ROUND(SUM(rc.RWA_VALUE) / SUM(rc.EAD_VALUE), 4)
         ELSE NULL
    END                                                   AS RWA_DENSITY
FROM RISK_CALCULATIONS rc
WHERE rc.IS_CURRENT  = 1
  AND rc.CALC_STATUS = 'VALID'
GROUP BY rc.SEGMENT_CODE
ORDER BY rc.SEGMENT_CODE;

COMMENT ON TABLE V_PORTFOLIO_RISK
    IS 'Risk aggregates by regulatory segment (current SCD2 record)';
