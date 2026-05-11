-- ============================================================
-- Package : PKG_RWA_ENGINE
-- Purpose : Compute RWA and capital requirement (Basel III standard)
-- Author  : Tristan Mas | github.com/tristan-mas
-- Version : 1.0 | 2025
-- ============================================================
-- References:
--   * Standard approach RW : CRR2 Article 122 (corporates), 123 (retail),
--                            127 (defaulted), 124-126 (real-estate)
--   * Capital requirement  : CRR2 Article 92 (8% of RWA)
-- ============================================================

CREATE OR REPLACE PACKAGE PKG_RWA_ENGINE AS

    -- Capital requirement multiplier (8%)
    C_CAPITAL_RATIO       CONSTANT NUMBER := 0.08;

    -- Standard-approach risk weights (decimal) per segment.
    C_RW_RETAIL           CONSTANT NUMBER := 0.75;
    C_RW_SME_RETAIL       CONSTANT NUMBER := 0.75;
    C_RW_SME_CORP         CONSTANT NUMBER := 0.85;
    C_RW_CORPORATE        CONSTANT NUMBER := 1.00;
    C_RW_DEFAULTED        CONSTANT NUMBER := 1.50;
    C_RW_SECURED_VEHICLE  CONSTANT NUMBER := 0.50;

    -- LTV threshold below which the secured-vehicle preferential RW applies.
    C_LTV_VEHICLE_THRESH  CONSTANT NUMBER := 0.50;

    FUNCTION GET_RISK_WEIGHT (p_contract_id IN CONTRACTS.CONTRACT_ID%TYPE,
                              p_segment     IN VARCHAR2) RETURN NUMBER;

    FUNCTION CALC_RWA      (p_contract_id IN CONTRACTS.CONTRACT_ID%TYPE) RETURN NUMBER;
    FUNCTION CALC_CAPITAL  (p_contract_id IN CONTRACTS.CONTRACT_ID%TYPE) RETURN NUMBER;

    -- Full portfolio run: computes everything and writes SCD2 records.
    PROCEDURE RUN_FULL_PORTFOLIO (p_run_date IN DATE DEFAULT SYSDATE);

END PKG_RWA_ENGINE;
/

CREATE OR REPLACE PACKAGE BODY PKG_RWA_ENGINE AS

    -- ------------------------------------------------------------
    -- Function : GET_RISK_WEIGHT
    --   Applies the segment-level RW, with a 50% override when a
    --   passenger-car / LCV contract is well-collateralized (LTV <= 50%).
    -- ------------------------------------------------------------
    FUNCTION GET_RISK_WEIGHT (p_contract_id IN CONTRACTS.CONTRACT_ID%TYPE,
                              p_segment     IN VARCHAR2) RETURN NUMBER
    IS
        v_asset      CONTRACTS.ASSET_CLASS%TYPE;
        v_outstand   CONTRACTS.OUTSTANDING_BALANCE%TYPE;
        v_coll_value COLLATERALS.COLLATERAL_VALUE%TYPE;
        v_eligible   COLLATERALS.ELIGIBLE_FLAG%TYPE;
        v_ltv        NUMBER;
        v_rw         NUMBER;
    BEGIN
        v_rw := CASE p_segment
                    WHEN PKG_SEGMENTATION.C_SEG_RETAIL     THEN C_RW_RETAIL
                    WHEN PKG_SEGMENTATION.C_SEG_SME_RETAIL THEN C_RW_SME_RETAIL
                    WHEN PKG_SEGMENTATION.C_SEG_SME_CORP   THEN C_RW_SME_CORP
                    WHEN PKG_SEGMENTATION.C_SEG_CORPORATE  THEN C_RW_CORPORATE
                    WHEN PKG_SEGMENTATION.C_SEG_DEFAULTED  THEN C_RW_DEFAULTED
                    ELSE C_RW_CORPORATE
                END;

        IF p_segment = PKG_SEGMENTATION.C_SEG_DEFAULTED THEN
            RETURN v_rw;
        END IF;

        SELECT ct.ASSET_CLASS, ct.OUTSTANDING_BALANCE
          INTO v_asset, v_outstand
          FROM CONTRACTS ct
         WHERE ct.CONTRACT_ID = p_contract_id;

        BEGIN
            SELECT NVL(SUM(CASE WHEN ELIGIBLE_FLAG = 1
                                THEN COLLATERAL_VALUE * (1 - HAIRCUT_PCT)
                                ELSE 0 END), 0),
                   MAX(ELIGIBLE_FLAG)
              INTO v_coll_value, v_eligible
              FROM COLLATERALS
             WHERE CONTRACT_ID = p_contract_id;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                v_coll_value := 0;
                v_eligible   := 0;
        END;

        IF v_outstand > 0 AND v_eligible = 1
           AND v_asset IN ('PASSENGER_CAR','LCV') THEN
            v_ltv := v_outstand / NULLIF(v_coll_value, 0);
            IF v_ltv IS NOT NULL AND v_ltv <= C_LTV_VEHICLE_THRESH THEN
                v_rw := C_RW_SECURED_VEHICLE;
            END IF;
        END IF;

        RETURN v_rw;

    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN C_RW_CORPORATE;
        WHEN OTHERS THEN
            INSERT INTO CONTROL_LOG
                (LOG_ID, RUN_DATE, CONTRACT_ID, CONTROL_CODE, SEVERITY, MESSAGE)
            VALUES
                (SEQ_LOG.NEXTVAL, SYSDATE, p_contract_id,
                 'RW-EX', 'ERROR',
                 'GET_RISK_WEIGHT failed: ' || SUBSTR(SQLERRM, 1, 800));
            RETURN C_RW_CORPORATE;
    END GET_RISK_WEIGHT;

    -- ------------------------------------------------------------
    -- Function : CALC_RWA
    -- ------------------------------------------------------------
    FUNCTION CALC_RWA (p_contract_id IN CONTRACTS.CONTRACT_ID%TYPE) RETURN NUMBER
    IS
        v_ead     NUMBER;
        v_segment VARCHAR2(20);
        v_rw      NUMBER;
    BEGIN
        v_segment := PKG_SEGMENTATION.GET_SEGMENT(p_contract_id);
        v_ead     := PKG_RISK_PARAMS.GET_EAD(p_contract_id);
        v_rw      := GET_RISK_WEIGHT(p_contract_id, v_segment);

        RETURN NVL(v_ead, 0) * NVL(v_rw, 1);
    EXCEPTION
        WHEN OTHERS THEN
            INSERT INTO CONTROL_LOG
                (LOG_ID, RUN_DATE, CONTRACT_ID, CONTROL_CODE, SEVERITY, MESSAGE)
            VALUES
                (SEQ_LOG.NEXTVAL, SYSDATE, p_contract_id,
                 'RWA-EX', 'ERROR',
                 'CALC_RWA failed: ' || SUBSTR(SQLERRM, 1, 800));
            RETURN NULL;
    END CALC_RWA;

    -- ------------------------------------------------------------
    -- Function : CALC_CAPITAL
    -- ------------------------------------------------------------
    FUNCTION CALC_CAPITAL (p_contract_id IN CONTRACTS.CONTRACT_ID%TYPE) RETURN NUMBER
    IS
        v_rwa NUMBER;
    BEGIN
        v_rwa := CALC_RWA(p_contract_id);
        RETURN NVL(v_rwa, 0) * C_CAPITAL_RATIO;
    EXCEPTION
        WHEN OTHERS THEN
            RETURN NULL;
    END CALC_CAPITAL;

    -- ------------------------------------------------------------
    -- Procedure : RUN_FULL_PORTFOLIO
    --   * Iterates over eligible contracts using an explicit cursor.
    --   * Closes the current SCD2 row, opens a new one.
    --   * Uses BULK COLLECT / FORALL for performance.
    -- ------------------------------------------------------------
    PROCEDURE RUN_FULL_PORTFOLIO (p_run_date IN DATE DEFAULT SYSDATE) IS

        CURSOR c_contracts IS
            SELECT ct.CONTRACT_ID
              FROM CONTRACTS ct
             WHERE ct.STATUS IN ('ACTIVE','WATCHLIST','DEFAULT');

        TYPE t_ids IS TABLE OF CONTRACTS.CONTRACT_ID%TYPE;
        TYPE t_num IS TABLE OF NUMBER;
        TYPE t_str IS TABLE OF VARCHAR2(20);
        TYPE t_err IS TABLE OF VARCHAR2(500);

        l_ids     t_ids := t_ids();
        l_pd      t_num := t_num();
        l_lgd     t_num := t_num();
        l_ead     t_num := t_num();
        l_rwa     t_num := t_num();
        l_cap     t_num := t_num();
        l_seg     t_str := t_str();
        l_status  t_str := t_str();
        l_msg     t_err := t_err();

        l_ok      PLS_INTEGER := 0;
        l_err     PLS_INTEGER := 0;
    BEGIN
        FOR rec IN c_contracts LOOP
            l_ids.EXTEND;   l_ids(l_ids.LAST)   := rec.CONTRACT_ID;
            l_seg.EXTEND;   l_seg(l_seg.LAST)   := PKG_SEGMENTATION.GET_SEGMENT(rec.CONTRACT_ID);
            l_pd.EXTEND;    l_pd(l_pd.LAST)     := PKG_RISK_PARAMS.GET_PD(rec.CONTRACT_ID);
            l_lgd.EXTEND;   l_lgd(l_lgd.LAST)   := PKG_RISK_PARAMS.GET_LGD(rec.CONTRACT_ID);
            l_ead.EXTEND;   l_ead(l_ead.LAST)   := PKG_RISK_PARAMS.GET_EAD(rec.CONTRACT_ID);
            l_rwa.EXTEND;   l_rwa(l_rwa.LAST)   := CALC_RWA(rec.CONTRACT_ID);
            l_cap.EXTEND;   l_cap(l_cap.LAST)   := CALC_CAPITAL(rec.CONTRACT_ID);

            l_status.EXTEND;
            l_msg.EXTEND;
            IF l_pd(l_pd.LAST)  IS NULL
               OR l_lgd(l_lgd.LAST) IS NULL
               OR l_ead(l_ead.LAST) IS NULL
               OR l_rwa(l_rwa.LAST) IS NULL THEN
                l_status(l_status.LAST) := 'ERROR';
                l_msg(l_msg.LAST)       := 'One or more metrics could not be computed';
                l_err := l_err + 1;
            ELSE
                l_status(l_status.LAST) := 'VALID';
                l_msg(l_msg.LAST)       := NULL;
                l_ok := l_ok + 1;
            END IF;
        END LOOP;

        -- Close the previous SCD2 rows for these contracts (vectorized).
        FORALL i IN 1 .. l_ids.COUNT
            UPDATE RISK_CALCULATIONS
               SET IS_CURRENT = 0,
                   VALID_TO   = p_run_date
             WHERE CONTRACT_ID = l_ids(i)
               AND IS_CURRENT  = 1;

        -- Insert the new SCD2 rows.
        FORALL i IN 1 .. l_ids.COUNT
            INSERT INTO RISK_CALCULATIONS
                (CALC_ID, CONTRACT_ID, CALCULATION_DATE,
                 PD_VALUE, LGD_VALUE, EAD_VALUE, RWA_VALUE, CAPITAL_REQUIREMENT,
                 SEGMENT_CODE, CALC_STATUS, ERROR_MESSAGE,
                 VALID_FROM, VALID_TO, IS_CURRENT)
            VALUES
                (SEQ_CALC.NEXTVAL, l_ids(i), p_run_date,
                 l_pd(i), l_lgd(i), l_ead(i), l_rwa(i), l_cap(i),
                 l_seg(i), l_status(i), l_msg(i),
                 p_run_date, NULL, 1);

        INSERT INTO CONTROL_LOG
            (LOG_ID, RUN_DATE, CONTROL_CODE, SEVERITY, MESSAGE)
        VALUES
            (SEQ_LOG.NEXTVAL, p_run_date, 'RWA-RUN', 'INFO',
             'RUN_FULL_PORTFOLIO done : ok=' || l_ok
             || ', errors=' || l_err
             || ', total=' || l_ids.COUNT);

        COMMIT;

    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            INSERT INTO CONTROL_LOG
                (LOG_ID, RUN_DATE, CONTROL_CODE, SEVERITY, MESSAGE)
            VALUES
                (SEQ_LOG.NEXTVAL, SYSDATE, 'RWA-EX', 'ERROR',
                 'RUN_FULL_PORTFOLIO failed: ' || SUBSTR(SQLERRM, 1, 800));
            COMMIT;
            RAISE;
    END RUN_FULL_PORTFOLIO;

END PKG_RWA_ENGINE;
/
