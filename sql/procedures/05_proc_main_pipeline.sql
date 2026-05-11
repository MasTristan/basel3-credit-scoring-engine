-- ============================================================
-- Procedure : PROC_MAIN_PIPELINE
-- Purpose   : Orchestrate the full Basel III scoring pipeline.
-- Author    : Tristan Mas | github.com/tristan-mas
-- Version   : 1.0 | 2025
-- ============================================================
-- Sequence:
--   1. Log run start (active-contract count).
--   2. PKG_RWA_ENGINE.RUN_FULL_PORTFOLIO       (SCD2 + metrics)
--   3. PKG_SEGMENTATION.REFRESH_ALL_SEGMENTS   (back-fill segment on the new
--                                              current SCD2 rows)
--   4. PKG_CONTROLS.RUN_ALL_CONTROLS
--   5. Log run end (success / error counts, elapsed seconds).
-- ============================================================

CREATE OR REPLACE PROCEDURE PROC_MAIN_PIPELINE (p_run_date IN DATE DEFAULT SYSDATE) IS
    l_start_ts   TIMESTAMP;
    l_elapsed    NUMBER;
    l_active     PLS_INTEGER;
    l_ok         PLS_INTEGER;
    l_err        PLS_INTEGER;
BEGIN
    l_start_ts := SYSTIMESTAMP;

    SELECT COUNT(*)
      INTO l_active
      FROM CONTRACTS
     WHERE STATUS IN ('ACTIVE','WATCHLIST','DEFAULT');

    INSERT INTO CONTROL_LOG
        (LOG_ID, RUN_DATE, CONTROL_CODE, SEVERITY, MESSAGE)
    VALUES
        (SEQ_LOG.NEXTVAL, p_run_date, 'PIPE-START', 'INFO',
         'Pipeline started, eligible contracts = ' || l_active);
    COMMIT;

    -- Step 1 : compute metrics and write SCD2 rows
    PKG_RWA_ENGINE.RUN_FULL_PORTFOLIO(p_run_date);

    -- Step 2 : update segment codes on the new current rows
    PKG_SEGMENTATION.REFRESH_ALL_SEGMENTS;

    -- Step 3 : run quality controls
    PKG_CONTROLS.RUN_ALL_CONTROLS(p_run_date);

    -- Step 4 : run summary
    SELECT
        SUM(CASE WHEN CALC_STATUS = 'VALID' THEN 1 ELSE 0 END),
        SUM(CASE WHEN CALC_STATUS = 'ERROR' THEN 1 ELSE 0 END)
      INTO l_ok, l_err
      FROM RISK_CALCULATIONS
     WHERE CALCULATION_DATE = p_run_date
       AND IS_CURRENT = 1;

    l_elapsed := EXTRACT(SECOND FROM (SYSTIMESTAMP - l_start_ts))
                 + EXTRACT(MINUTE FROM (SYSTIMESTAMP - l_start_ts)) * 60
                 + EXTRACT(HOUR   FROM (SYSTIMESTAMP - l_start_ts)) * 3600;

    INSERT INTO CONTROL_LOG
        (LOG_ID, RUN_DATE, CONTROL_CODE, SEVERITY, MESSAGE)
    VALUES
        (SEQ_LOG.NEXTVAL, p_run_date, 'PIPE-END', 'INFO',
         'Pipeline done: ok=' || NVL(l_ok,0)
         || ', err=' || NVL(l_err,0)
         || ', elapsed=' || ROUND(l_elapsed, 2) || 's');
    COMMIT;

EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        INSERT INTO CONTROL_LOG
            (LOG_ID, RUN_DATE, CONTROL_CODE, SEVERITY, MESSAGE)
        VALUES
            (SEQ_LOG.NEXTVAL, SYSDATE, 'PIPE-EX', 'ERROR',
             'Pipeline failed: ' || SUBSTR(SQLERRM, 1, 800));
        COMMIT;
        RAISE;
END PROC_MAIN_PIPELINE;
/
