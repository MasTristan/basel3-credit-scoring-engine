-- ============================================================
-- Package : PKG_SEGMENTATION
-- Purpose : Regulatory segmentation (Basel III CRR2 Article 147)
-- Author  : Tristan Mas | github.com/tristan-mas
-- Version : 1.0 | 2025
-- ============================================================
-- Segmentation rules:
--   RETAIL      : RETAIL counterparty and outstanding <= 1 MEUR
--   SME_RETAIL  : SME counterparty, turnover <= 50 MEUR, outstanding <= 1 MEUR
--   SME_CORP    : SME counterparty, turnover > 50 MEUR OR outstanding > 1 MEUR
--   CORPORATE   : CORPORATE counterparty
--   DEFAULTED   : contract STATUS = 'DEFAULT' (overrides everything)
-- ============================================================

CREATE OR REPLACE PACKAGE PKG_SEGMENTATION AS

    -- Named regulatory thresholds (CRR2)
    C_RETAIL_BALANCE_LIMIT    CONSTANT NUMBER := 1000000;     -- 1 MEUR
    C_SME_TURNOVER_LIMIT      CONSTANT NUMBER := 50000000;    -- 50 MEUR

    -- Public segment codes
    C_SEG_RETAIL     CONSTANT VARCHAR2(20) := 'RETAIL';
    C_SEG_SME_RETAIL CONSTANT VARCHAR2(20) := 'SME_RETAIL';
    C_SEG_SME_CORP   CONSTANT VARCHAR2(20) := 'SME_CORP';
    C_SEG_CORPORATE  CONSTANT VARCHAR2(20) := 'CORPORATE';
    C_SEG_DEFAULTED  CONSTANT VARCHAR2(20) := 'DEFAULTED';

    -- Returns the regulatory segment of one contract.
    FUNCTION GET_SEGMENT (p_contract_id IN CONTRACTS.CONTRACT_ID%TYPE)
        RETURN VARCHAR2;

    -- Bulk refresh: re-evaluates and caches the segment on every contract
    -- through the current row in RISK_CALCULATIONS.
    PROCEDURE REFRESH_ALL_SEGMENTS;

END PKG_SEGMENTATION;
/

CREATE OR REPLACE PACKAGE BODY PKG_SEGMENTATION AS

    -- ------------------------------------------------------------
    -- Function : GET_SEGMENT
    -- ------------------------------------------------------------
    FUNCTION GET_SEGMENT (p_contract_id IN CONTRACTS.CONTRACT_ID%TYPE)
        RETURN VARCHAR2
    IS
        v_cp_type        COUNTERPARTIES.COUNTERPARTY_TYPE%TYPE;
        v_turnover       COUNTERPARTIES.ANNUAL_TURNOVER%TYPE;
        v_outstanding    CONTRACTS.OUTSTANDING_BALANCE%TYPE;
        v_status         CONTRACTS.STATUS%TYPE;
        v_segment        VARCHAR2(20);
    BEGIN
        SELECT cp.COUNTERPARTY_TYPE,
               cp.ANNUAL_TURNOVER,
               ct.OUTSTANDING_BALANCE,
               ct.STATUS
          INTO v_cp_type, v_turnover, v_outstanding, v_status
          FROM CONTRACTS ct
          JOIN COUNTERPARTIES cp ON cp.COUNTERPARTY_ID = ct.COUNTERPARTY_ID
         WHERE ct.CONTRACT_ID = p_contract_id;

        IF v_status = 'DEFAULT' THEN
            v_segment := C_SEG_DEFAULTED;

        ELSIF v_cp_type = 'RETAIL'
              AND v_outstanding <= C_RETAIL_BALANCE_LIMIT THEN
            v_segment := C_SEG_RETAIL;

        ELSIF v_cp_type = 'SME'
              AND NVL(v_turnover, 0) <= C_SME_TURNOVER_LIMIT
              AND v_outstanding <= C_RETAIL_BALANCE_LIMIT THEN
            v_segment := C_SEG_SME_RETAIL;

        ELSIF v_cp_type = 'SME' THEN
            v_segment := C_SEG_SME_CORP;

        ELSIF v_cp_type = 'CORPORATE' THEN
            v_segment := C_SEG_CORPORATE;

        ELSE
            v_segment := C_SEG_CORPORATE;
        END IF;

        RETURN v_segment;

    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN NULL;
        WHEN OTHERS THEN
            INSERT INTO CONTROL_LOG
                (LOG_ID, RUN_DATE, CONTRACT_ID, CONTROL_CODE, SEVERITY, MESSAGE)
            VALUES
                (SEQ_LOG.NEXTVAL, SYSDATE, p_contract_id,
                 'SEG-EX', 'ERROR',
                 'GET_SEGMENT failed: ' || SUBSTR(SQLERRM, 1, 800));
            RETURN NULL;
    END GET_SEGMENT;

    -- ------------------------------------------------------------
    -- Procedure : REFRESH_ALL_SEGMENTS
    -- Updates SEGMENT_CODE on the currently-active SCD2 row.
    -- ------------------------------------------------------------
    PROCEDURE REFRESH_ALL_SEGMENTS
    IS
        CURSOR c_contracts IS
            SELECT CONTRACT_ID
              FROM CONTRACTS
             WHERE STATUS IN ('ACTIVE','WATCHLIST','DEFAULT');

        TYPE t_id_tab    IS TABLE OF CONTRACTS.CONTRACT_ID%TYPE;
        TYPE t_seg_tab   IS TABLE OF VARCHAR2(20);

        l_ids  t_id_tab  := t_id_tab();
        l_segs t_seg_tab := t_seg_tab();
        l_total PLS_INTEGER := 0;
    BEGIN
        FOR rec IN c_contracts LOOP
            l_ids.EXTEND;
            l_segs.EXTEND;
            l_ids(l_ids.LAST)  := rec.CONTRACT_ID;
            l_segs(l_segs.LAST) := GET_SEGMENT(rec.CONTRACT_ID);
            l_total := l_total + 1;
        END LOOP;

        FORALL i IN 1 .. l_ids.COUNT
            UPDATE RISK_CALCULATIONS
               SET SEGMENT_CODE = l_segs(i)
             WHERE CONTRACT_ID  = l_ids(i)
               AND IS_CURRENT   = 1;

        INSERT INTO CONTROL_LOG
            (LOG_ID, RUN_DATE, CONTROL_CODE, SEVERITY, MESSAGE)
        VALUES
            (SEQ_LOG.NEXTVAL, SYSDATE, 'SEG-INFO', 'INFO',
             'REFRESH_ALL_SEGMENTS processed ' || l_total || ' contracts');
        COMMIT;

    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            INSERT INTO CONTROL_LOG
                (LOG_ID, RUN_DATE, CONTROL_CODE, SEVERITY, MESSAGE)
            VALUES
                (SEQ_LOG.NEXTVAL, SYSDATE, 'SEG-EX', 'ERROR',
                 'REFRESH_ALL_SEGMENTS failed: ' || SUBSTR(SQLERRM, 1, 800));
            COMMIT;
            RAISE;
    END REFRESH_ALL_SEGMENTS;

END PKG_SEGMENTATION;
/
