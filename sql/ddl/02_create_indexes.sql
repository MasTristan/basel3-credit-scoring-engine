-- ============================================================
-- Script  : 02_create_indexes.sql
-- Purpose : Performance indexes for Basel III scoring engine
-- Schema  : BASEL_RISK
-- Target  : Oracle XE 21c
-- Author  : Tristan Mas | github.com/tristan-mas
-- Version : 1.0 | 2025
-- ============================================================
-- Notes:
--   * PK indexes are created automatically by the DDL.
--   * Here we add indexes used by the pipeline (joins + filters)
--     and by the reporting views.
--   * No bitmap indexes (DML-heavy load context).
-- ============================================================

-- Drop indexes if they exist (safe re-run).
BEGIN
   FOR rec IN (SELECT index_name
                 FROM user_indexes
                WHERE index_name IN ('IX_CONTRACTS_CP',
                                     'IX_CONTRACTS_STATUS',
                                     'IX_CONTRACTS_ASSET',
                                     'IX_COLLATERALS_CTR',
                                     'IX_COLLATERALS_ELIG',
                                     'IX_CALC_CONTRACT',
                                     'IX_CALC_CURRENT',
                                     'IX_CALC_DATE',
                                     'IX_CTL_RUN',
                                     'IX_CTL_SEV',
                                     'IX_PARAM_LOOKUP'))
   LOOP
      EXECUTE IMMEDIATE 'DROP INDEX ' || rec.index_name;
   END LOOP;
END;
/

-- CONTRACTS : joins on counterparty, filters on status / asset class
CREATE INDEX IX_CONTRACTS_CP        ON CONTRACTS (COUNTERPARTY_ID);
CREATE INDEX IX_CONTRACTS_STATUS    ON CONTRACTS (STATUS);
CREATE INDEX IX_CONTRACTS_ASSET     ON CONTRACTS (ASSET_CLASS);

-- COLLATERALS : join on contract, filter on eligibility
CREATE INDEX IX_COLLATERALS_CTR     ON COLLATERALS (CONTRACT_ID);
CREATE INDEX IX_COLLATERALS_ELIG    ON COLLATERALS (ELIGIBLE_FLAG);

-- RISK_CALCULATIONS : SCD2 lookups (current record per contract / date filters)
CREATE INDEX IX_CALC_CONTRACT       ON RISK_CALCULATIONS (CONTRACT_ID);
CREATE INDEX IX_CALC_CURRENT        ON RISK_CALCULATIONS (CONTRACT_ID, IS_CURRENT);
CREATE INDEX IX_CALC_DATE           ON RISK_CALCULATIONS (CALCULATION_DATE);

-- CONTROL_LOG : reporting by run date / severity
CREATE INDEX IX_CTL_RUN             ON CONTROL_LOG (RUN_DATE);
CREATE INDEX IX_CTL_SEV             ON CONTROL_LOG (SEVERITY);

-- REGULATORY_PARAMETERS : lookups by (asset_class, counterparty_type, rating)
CREATE INDEX IX_PARAM_LOOKUP        ON REGULATORY_PARAMETERS (ASSET_CLASS, COUNTERPARTY_TYPE, INTERNAL_RATING);

-- Refresh stats to help the cost-based optimizer.
BEGIN
   DBMS_STATS.GATHER_SCHEMA_STATS(USER, cascade => TRUE);
END;
/

-- ============================================================
-- End of script 02_create_indexes.sql
-- ============================================================
