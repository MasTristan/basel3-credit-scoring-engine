-- ============================================================
-- Package : PKG_RISK_PARAMS
-- Purpose : Compute PD / LGD / EAD per contract (Basel III CRR2)
-- Author  : Tristan Mas | github.com/tristan-mas
-- Version : 1.0 | 2025
-- ============================================================
-- References:
--   * PD floor           : CRR2 Article 160
--   * LGD adjustment     : CRR2 Article 230 (eligible collaterals)
--   * EAD definition     : CRR2 Article 166 (net of provisions + CCF * off-BS)
-- ============================================================

CREATE OR REPLACE PACKAGE PKG_RISK_PARAMS AS

    -- Regulatory floors (decimal)
    C_PD_FLOOR_DEFAULT      CONSTANT NUMBER := 0.0003;
    C_LGD_SECURED_FLOOR     CONSTANT NUMBER := 0.10;
    C_LGD_UNSECURED_DEFAULT CONSTANT NUMBER := 0.45;
    C_LGD_SECURED_DEFAULT   CONSTANT NUMBER := 0.35;
    C_CCF_DEFAULT           CONSTANT NUMBER := 1.00;

    FUNCTION GET_PD  (p_contract_id IN CONTRACTS.CONTRACT_ID%TYPE) RETURN NUMBER;
    FUNCTION GET_LGD (p_contract_id IN CONTRACTS.CONTRACT_ID%TYPE) RETURN NUMBER;
    FUNCTION GET_EAD (p_contract_id IN CONTRACTS.CONTRACT_ID%TYPE) RETURN NUMBER;

END PKG_RISK_PARAMS;
/

CREATE OR REPLACE PACKAGE BODY PKG_RISK_PARAMS AS

    -- ------------------------------------------------------------
    -- Internal: rating-driven base PD (CRR2 standard mapping)
    -- ------------------------------------------------------------
    FUNCTION pd_from_rating (p_rating IN VARCHAR2) RETURN NUMBER IS
    BEGIN
        RETURN CASE p_rating
                   WHEN 'AAA' THEN 0.0003
                   WHEN 'AA'  THEN 0.0005
                   WHEN 'A'   THEN 0.0010
                   WHEN 'BBB' THEN 0.0025
                   WHEN 'BB'  THEN 0.0100
                   WHEN 'B'   THEN 0.0500
                   WHEN 'CCC' THEN 0.1500
                   WHEN 'D'   THEN 1.0000
                   ELSE 0.0500
               END;
    END pd_from_rating;

    -- ------------------------------------------------------------
    -- Internal: regulatory parameter row lookup with fallback to NULL columns
    -- ------------------------------------------------------------
    FUNCTION lookup_param (p_asset_class      IN VARCHAR2,
                           p_counterparty_t   IN VARCHAR2,
                           p_rating           IN VARCHAR2)
        RETURN REGULATORY_PARAMETERS%ROWTYPE
    IS
        v_row REGULATORY_PARAMETERS%ROWTYPE;
    BEGIN
        -- Most-specific first, then progressive fallback.
        BEGIN
            SELECT *
              INTO v_row
              FROM (SELECT *
                      FROM REGULATORY_PARAMETERS
                     WHERE NVL(ASSET_CLASS, p_asset_class)            = p_asset_class
                       AND NVL(COUNTERPARTY_TYPE, p_counterparty_t)   = p_counterparty_t
                       AND NVL(INTERNAL_RATING, p_rating)             = p_rating
                  ORDER BY (CASE WHEN ASSET_CLASS       IS NULL THEN 1 ELSE 0 END)
                         + (CASE WHEN COUNTERPARTY_TYPE IS NULL THEN 1 ELSE 0 END)
                         + (CASE WHEN INTERNAL_RATING   IS NULL THEN 1 ELSE 0 END))
             WHERE ROWNUM = 1;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                v_row.PD_FLOOR      := C_PD_FLOOR_DEFAULT;
                v_row.LGD_SECURED   := C_LGD_SECURED_DEFAULT;
                v_row.LGD_UNSECURED := C_LGD_UNSECURED_DEFAULT;
                v_row.RISK_WEIGHT   := 1.00;
                v_row.CCF           := C_CCF_DEFAULT;
        END;
        RETURN v_row;
    END lookup_param;

    -- ------------------------------------------------------------
    -- Function : GET_PD
    -- ------------------------------------------------------------
    FUNCTION GET_PD (p_contract_id IN CONTRACTS.CONTRACT_ID%TYPE) RETURN NUMBER
    IS
        v_rating       COUNTERPARTIES.INTERNAL_RATING%TYPE;
        v_asset        CONTRACTS.ASSET_CLASS%TYPE;
        v_cp_type      COUNTERPARTIES.COUNTERPARTY_TYPE%TYPE;
        v_status       CONTRACTS.STATUS%TYPE;
        v_pd_base      NUMBER;
        v_param        REGULATORY_PARAMETERS%ROWTYPE;
    BEGIN
        SELECT cp.INTERNAL_RATING, ct.ASSET_CLASS, cp.COUNTERPARTY_TYPE, ct.STATUS
          INTO v_rating, v_asset, v_cp_type, v_status
          FROM CONTRACTS ct
          JOIN COUNTERPARTIES cp ON cp.COUNTERPARTY_ID = ct.COUNTERPARTY_ID
         WHERE ct.CONTRACT_ID = p_contract_id;

        IF v_status = 'DEFAULT' THEN
            RETURN 1;
        END IF;

        v_pd_base := pd_from_rating(v_rating);
        v_param   := lookup_param(v_asset, v_cp_type, v_rating);

        RETURN GREATEST(NVL(v_param.PD_FLOOR, C_PD_FLOOR_DEFAULT), v_pd_base);

    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN NULL;
        WHEN OTHERS THEN
            INSERT INTO CONTROL_LOG
                (LOG_ID, RUN_DATE, CONTRACT_ID, CONTROL_CODE, SEVERITY, MESSAGE)
            VALUES
                (SEQ_LOG.NEXTVAL, SYSDATE, p_contract_id,
                 'PD-EX', 'ERROR',
                 'GET_PD failed: ' || SUBSTR(SQLERRM, 1, 800));
            RETURN NULL;
    END GET_PD;

    -- ------------------------------------------------------------
    -- Function : GET_EAD
    --   EAD = max(0, OUTSTANDING - PROVISIONS + RESIDUAL_VALUE * CCF)
    -- ------------------------------------------------------------
    FUNCTION GET_EAD (p_contract_id IN CONTRACTS.CONTRACT_ID%TYPE) RETURN NUMBER
    IS
        v_outstanding  CONTRACTS.OUTSTANDING_BALANCE%TYPE;
        v_provision    CONTRACTS.PROVISION_AMOUNT%TYPE;
        v_residual     CONTRACTS.RESIDUAL_VALUE%TYPE;
        v_asset        CONTRACTS.ASSET_CLASS%TYPE;
        v_cp_type      COUNTERPARTIES.COUNTERPARTY_TYPE%TYPE;
        v_rating       COUNTERPARTIES.INTERNAL_RATING%TYPE;
        v_param        REGULATORY_PARAMETERS%ROWTYPE;
        v_ead          NUMBER;
    BEGIN
        SELECT ct.OUTSTANDING_BALANCE, ct.PROVISION_AMOUNT, ct.RESIDUAL_VALUE,
               ct.ASSET_CLASS, cp.COUNTERPARTY_TYPE, cp.INTERNAL_RATING
          INTO v_outstanding, v_provision, v_residual,
               v_asset, v_cp_type, v_rating
          FROM CONTRACTS ct
          JOIN COUNTERPARTIES cp ON cp.COUNTERPARTY_ID = ct.COUNTERPARTY_ID
         WHERE ct.CONTRACT_ID = p_contract_id;

        v_param := lookup_param(v_asset, v_cp_type, v_rating);

        v_ead := NVL(v_outstanding, 0)
                 - NVL(v_provision, 0)
                 + NVL(v_residual, 0) * NVL(v_param.CCF, C_CCF_DEFAULT);

        RETURN GREATEST(v_ead, 0);

    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            RETURN NULL;
        WHEN OTHERS THEN
            INSERT INTO CONTROL_LOG
                (LOG_ID, RUN_DATE, CONTRACT_ID, CONTROL_CODE, SEVERITY, MESSAGE)
            VALUES
                (SEQ_LOG.NEXTVAL, SYSDATE, p_contract_id,
                 'EAD-EX', 'ERROR',
                 'GET_EAD failed: ' || SUBSTR(SQLERRM, 1, 800));
            RETURN NULL;
    END GET_EAD;

    -- ------------------------------------------------------------
    -- Function : GET_LGD
    --   With eligible collateral:
    --     LGD = LGD_SECURED * (1 - CollateralAfterHaircut / EAD)
    --     LGD = max(LGD, LGD_SECURED_FLOOR = 0.10)
    --   Without eligible collateral:
    --     LGD = LGD_UNSECURED (segment parameter)
    -- ------------------------------------------------------------
    FUNCTION GET_LGD (p_contract_id IN CONTRACTS.CONTRACT_ID%TYPE) RETURN NUMBER
    IS
        v_asset        CONTRACTS.ASSET_CLASS%TYPE;
        v_cp_type      COUNTERPARTIES.COUNTERPARTY_TYPE%TYPE;
        v_rating       COUNTERPARTIES.INTERNAL_RATING%TYPE;
        v_eligible     COLLATERALS.ELIGIBLE_FLAG%TYPE;
        v_coll_value   COLLATERALS.COLLATERAL_VALUE%TYPE;
        v_haircut      COLLATERALS.HAIRCUT_PCT%TYPE;
        v_param        REGULATORY_PARAMETERS%ROWTYPE;
        v_ead          NUMBER;
        v_lgd          NUMBER;
        v_secured_val  NUMBER;
    BEGIN
        SELECT ct.ASSET_CLASS, cp.COUNTERPARTY_TYPE, cp.INTERNAL_RATING
          INTO v_asset, v_cp_type, v_rating
          FROM CONTRACTS ct
          JOIN COUNTERPARTIES cp ON cp.COUNTERPARTY_ID = ct.COUNTERPARTY_ID
         WHERE ct.CONTRACT_ID = p_contract_id;

        v_param := lookup_param(v_asset, v_cp_type, v_rating);
        v_ead   := GET_EAD(p_contract_id);

        BEGIN
            SELECT NVL(ELIGIBLE_FLAG,0), NVL(COLLATERAL_VALUE,0), NVL(HAIRCUT_PCT,0)
              INTO v_eligible, v_coll_value, v_haircut
              FROM (SELECT ELIGIBLE_FLAG, COLLATERAL_VALUE, HAIRCUT_PCT
                      FROM COLLATERALS
                     WHERE CONTRACT_ID = p_contract_id
                  ORDER BY ELIGIBLE_FLAG DESC, COLLATERAL_VALUE DESC)
             WHERE ROWNUM = 1;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                v_eligible := 0; v_coll_value := 0; v_haircut := 0;
        END;

        IF v_eligible = 1 AND v_ead > 0 THEN
            v_secured_val := v_coll_value * (1 - v_haircut);
            v_lgd := NVL(v_param.LGD_SECURED, C_LGD_SECURED_DEFAULT)
                     * (1 - LEAST(v_secured_val / v_ead, 1));
            v_lgd := GREATEST(v_lgd, C_LGD_SECURED_FLOOR);
        ELSE
            v_lgd := NVL(v_param.LGD_UNSECURED, C_LGD_UNSECURED_DEFAULT);
        END IF;

        RETURN LEAST(GREATEST(v_lgd, 0), 1);

    EXCEPTION
        WHEN OTHERS THEN
            INSERT INTO CONTROL_LOG
                (LOG_ID, RUN_DATE, CONTRACT_ID, CONTROL_CODE, SEVERITY, MESSAGE)
            VALUES
                (SEQ_LOG.NEXTVAL, SYSDATE, p_contract_id,
                 'LGD-EX', 'ERROR',
                 'GET_LGD failed: ' || SUBSTR(SQLERRM, 1, 800));
            RETURN NULL;
    END GET_LGD;

END PKG_RISK_PARAMS;
/
