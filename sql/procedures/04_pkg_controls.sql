-- ============================================================
-- Package : PKG_CONTROLS
-- Purpose : Quality controls + alerting (Basel III credit scoring)
-- Author  : Tristan Mas | github.com/tristan-mas
-- Version : 1.0 | 2025
-- ============================================================
-- Implemented controls:
--   CTR-001 : OUTSTANDING_BALANCE <= 0                          ERROR
--   CTR-002 : MATURITY_DATE < SYSDATE  (expired contract)        WARNING
--   CTR-003 : PD = NULL after calculation                        ERROR
--   CTR-004 : LGD > 1 or LGD < 0                                 ERROR
--   CTR-005 : EAD > ORIGINAL_AMOUNT * 1.2                        WARNING
--   CTR-006 : RWA = 0 on ACTIVE contract                         WARNING
--   CTR-007 : COLLATERAL_VALUE > OUTSTANDING_BALANCE * 3         WARNING
--   CTR-008 : DEFAULT_FLAG=1 but contract.STATUS != 'DEFAULT'    ERROR
-- ============================================================

CREATE OR REPLACE PACKAGE PKG_CONTROLS AS

    PROCEDURE RUN_ALL_CONTROLS (p_calc_date IN DATE DEFAULT SYSDATE);

    -- Per-severity summary for a given run date.
    PROCEDURE GET_CONTROL_SUMMARY (p_calc_date IN DATE DEFAULT SYSDATE,
                                   p_result    OUT SYS_REFCURSOR);

END PKG_CONTROLS;
/

CREATE OR REPLACE PACKAGE BODY PKG_CONTROLS AS

    -- Bulk insert helper (CONTROL_LOG) using a single FORALL.
    PROCEDURE log_findings (p_codes    IN SYS.ODCIVARCHAR2LIST,
                            p_severity IN SYS.ODCIVARCHAR2LIST,
                            p_ids      IN SYS.ODCINUMBERLIST,
                            p_messages IN SYS.ODCIVARCHAR2LIST,
                            p_run_date IN DATE)
    IS
    BEGIN
        IF p_ids.COUNT = 0 THEN
            RETURN;
        END IF;

        FORALL i IN 1 .. p_ids.COUNT
            INSERT INTO CONTROL_LOG
                (LOG_ID, RUN_DATE, CONTRACT_ID, CONTROL_CODE, SEVERITY, MESSAGE)
            VALUES
                (SEQ_LOG.NEXTVAL, p_run_date, p_ids(i),
                 p_codes(i), p_severity(i), p_messages(i));
    END log_findings;

    -- ------------------------------------------------------------
    -- Procedure : RUN_ALL_CONTROLS
    -- ------------------------------------------------------------
    PROCEDURE RUN_ALL_CONTROLS (p_calc_date IN DATE DEFAULT SYSDATE) IS
        l_codes    SYS.ODCIVARCHAR2LIST := SYS.ODCIVARCHAR2LIST();
        l_severity SYS.ODCIVARCHAR2LIST := SYS.ODCIVARCHAR2LIST();
        l_ids      SYS.ODCINUMBERLIST   := SYS.ODCINUMBERLIST();
        l_msg      SYS.ODCIVARCHAR2LIST := SYS.ODCIVARCHAR2LIST();

        PROCEDURE add_finding (p_id IN NUMBER, p_code IN VARCHAR2,
                               p_sev IN VARCHAR2, p_text IN VARCHAR2) IS
        BEGIN
            l_codes.EXTEND;    l_codes(l_codes.LAST)       := p_code;
            l_severity.EXTEND; l_severity(l_severity.LAST) := p_sev;
            l_ids.EXTEND;      l_ids(l_ids.LAST)           := p_id;
            l_msg.EXTEND;      l_msg(l_msg.LAST)           := SUBSTR(p_text, 1, 1000);
        END add_finding;

    BEGIN
        -- CTR-001 : OUTSTANDING_BALANCE <= 0
        FOR rec IN (SELECT CONTRACT_ID, OUTSTANDING_BALANCE
                      FROM CONTRACTS
                     WHERE OUTSTANDING_BALANCE <= 0) LOOP
            add_finding(rec.CONTRACT_ID, 'CTR-001', 'ERROR',
                        'Outstanding balance is not positive (' || rec.OUTSTANDING_BALANCE || ')');
        END LOOP;

        -- CTR-002 : expired contracts
        FOR rec IN (SELECT CONTRACT_ID, MATURITY_DATE
                      FROM CONTRACTS
                     WHERE MATURITY_DATE < p_calc_date
                       AND STATUS NOT IN ('CLOSED')) LOOP
            add_finding(rec.CONTRACT_ID, 'CTR-002', 'WARNING',
                        'Contract expired on ' || TO_CHAR(rec.MATURITY_DATE, 'YYYY-MM-DD'));
        END LOOP;

        -- CTR-003 : PD NULL after calculation
        FOR rec IN (SELECT CONTRACT_ID
                      FROM RISK_CALCULATIONS
                     WHERE IS_CURRENT = 1
                       AND PD_VALUE IS NULL) LOOP
            add_finding(rec.CONTRACT_ID, 'CTR-003', 'ERROR',
                        'PD is NULL after calculation');
        END LOOP;

        -- CTR-004 : LGD out of [0,1]
        FOR rec IN (SELECT CONTRACT_ID, LGD_VALUE
                      FROM RISK_CALCULATIONS
                     WHERE IS_CURRENT = 1
                       AND (LGD_VALUE < 0 OR LGD_VALUE > 1)) LOOP
            add_finding(rec.CONTRACT_ID, 'CTR-004', 'ERROR',
                        'LGD out of bounds : ' || rec.LGD_VALUE);
        END LOOP;

        -- CTR-005 : EAD > ORIGINAL * 1.2
        FOR rec IN (SELECT rc.CONTRACT_ID, rc.EAD_VALUE, ct.ORIGINAL_AMOUNT
                      FROM RISK_CALCULATIONS rc
                      JOIN CONTRACTS ct ON ct.CONTRACT_ID = rc.CONTRACT_ID
                     WHERE rc.IS_CURRENT = 1
                       AND rc.EAD_VALUE > ct.ORIGINAL_AMOUNT * 1.2) LOOP
            add_finding(rec.CONTRACT_ID, 'CTR-005', 'WARNING',
                        'EAD (' || rec.EAD_VALUE
                        || ') exceeds 120% of original amount (' || rec.ORIGINAL_AMOUNT || ')');
        END LOOP;

        -- CTR-006 : RWA = 0 on ACTIVE contract
        FOR rec IN (SELECT rc.CONTRACT_ID
                      FROM RISK_CALCULATIONS rc
                      JOIN CONTRACTS ct ON ct.CONTRACT_ID = rc.CONTRACT_ID
                     WHERE rc.IS_CURRENT = 1
                       AND ct.STATUS = 'ACTIVE'
                       AND NVL(rc.RWA_VALUE, 0) = 0) LOOP
            add_finding(rec.CONTRACT_ID, 'CTR-006', 'WARNING',
                        'RWA = 0 on ACTIVE contract');
        END LOOP;

        -- CTR-007 : over-collateralization
        FOR rec IN (SELECT ct.CONTRACT_ID, ct.OUTSTANDING_BALANCE,
                           SUM(co.COLLATERAL_VALUE) AS COLL_TOTAL
                      FROM CONTRACTS ct
                      JOIN COLLATERALS co ON co.CONTRACT_ID = ct.CONTRACT_ID
                  GROUP BY ct.CONTRACT_ID, ct.OUTSTANDING_BALANCE
                    HAVING SUM(co.COLLATERAL_VALUE) > ct.OUTSTANDING_BALANCE * 3
                       AND ct.OUTSTANDING_BALANCE > 0) LOOP
            add_finding(rec.CONTRACT_ID, 'CTR-007', 'WARNING',
                        'Collateral (' || rec.COLL_TOTAL
                        || ') > 3x outstanding (' || rec.OUTSTANDING_BALANCE || ')');
        END LOOP;

        -- CTR-008 : default flag inconsistent with contract status
        FOR rec IN (SELECT ct.CONTRACT_ID, cp.DEFAULT_FLAG, ct.STATUS
                      FROM CONTRACTS ct
                      JOIN COUNTERPARTIES cp ON cp.COUNTERPARTY_ID = ct.COUNTERPARTY_ID
                     WHERE cp.DEFAULT_FLAG = 1
                       AND ct.STATUS != 'DEFAULT'
                       AND ct.STATUS != 'CLOSED') LOOP
            add_finding(rec.CONTRACT_ID, 'CTR-008', 'ERROR',
                        'Counterparty defaulted but contract STATUS = ' || rec.STATUS);
        END LOOP;

        -- Persist all findings in one batch
        log_findings(l_codes, l_severity, l_ids, l_msg, p_calc_date);

        INSERT INTO CONTROL_LOG
            (LOG_ID, RUN_DATE, CONTROL_CODE, SEVERITY, MESSAGE)
        VALUES
            (SEQ_LOG.NEXTVAL, p_calc_date, 'CTL-INFO', 'INFO',
             'RUN_ALL_CONTROLS done : ' || l_ids.COUNT || ' findings');

        COMMIT;

    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            INSERT INTO CONTROL_LOG
                (LOG_ID, RUN_DATE, CONTROL_CODE, SEVERITY, MESSAGE)
            VALUES
                (SEQ_LOG.NEXTVAL, SYSDATE, 'CTL-EX', 'ERROR',
                 'RUN_ALL_CONTROLS failed: ' || SUBSTR(SQLERRM, 1, 800));
            COMMIT;
            RAISE;
    END RUN_ALL_CONTROLS;

    -- ------------------------------------------------------------
    -- Procedure : GET_CONTROL_SUMMARY
    -- ------------------------------------------------------------
    PROCEDURE GET_CONTROL_SUMMARY (p_calc_date IN DATE DEFAULT SYSDATE,
                                   p_result    OUT SYS_REFCURSOR)
    IS
    BEGIN
        OPEN p_result FOR
            SELECT SEVERITY,
                   COUNT(*)          AS NB_FINDINGS,
                   COUNT(DISTINCT CONTRACT_ID) AS NB_CONTRACTS
              FROM CONTROL_LOG
             WHERE TRUNC(RUN_DATE) = TRUNC(p_calc_date)
             GROUP BY SEVERITY
             ORDER BY DECODE(SEVERITY, 'ERROR', 1, 'WARNING', 2, 'INFO', 3);
    END GET_CONTROL_SUMMARY;

END PKG_CONTROLS;
/
