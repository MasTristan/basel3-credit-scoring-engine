-- ============================================================
-- Script  : 01_create_schema.sql
-- Purpose : DDL for Basel III credit scoring engine (CRR2 standard approach)
-- Schema  : BASEL_RISK
-- Target  : Oracle XE 21c
-- Author  : Tristan Mas | github.com/tristan-mas
-- Version : 1.0 | 2025
-- ============================================================
-- Notes:
--   * All monetary amounts are in EUR with NUMBER(15,2) precision.
--   * Percentages are stored as decimals (0.75 = 75%).
--   * Constraints are explicitly named for traceability.
--   * No partitioning / no advanced compression (Oracle XE constraints).
-- ============================================================

-- Drop in reverse dependency order (safe re-run for development).
BEGIN
   FOR rec IN (SELECT table_name
                 FROM user_tables
                WHERE table_name IN ('CONTROL_LOG',
                                     'RISK_CALCULATIONS',
                                     'REGULATORY_PARAMETERS',
                                     'COLLATERALS',
                                     'CONTRACTS',
                                     'COUNTERPARTIES'))
   LOOP
      EXECUTE IMMEDIATE 'DROP TABLE ' || rec.table_name || ' CASCADE CONSTRAINTS PURGE';
   END LOOP;
END;
/

-- Drop sequences in case of re-run.
BEGIN
   FOR rec IN (SELECT sequence_name
                 FROM user_sequences
                WHERE sequence_name IN ('SEQ_COUNTERPARTY',
                                        'SEQ_CONTRACT',
                                        'SEQ_COLLATERAL',
                                        'SEQ_PARAM',
                                        'SEQ_CALC',
                                        'SEQ_LOG'))
   LOOP
      EXECUTE IMMEDIATE 'DROP SEQUENCE ' || rec.sequence_name;
   END LOOP;
END;
/

-- ============================================================
-- Table : COUNTERPARTIES
-- ============================================================
CREATE TABLE COUNTERPARTIES (
    COUNTERPARTY_ID     NUMBER(10)      NOT NULL,
    COUNTERPARTY_TYPE   VARCHAR2(20)    NOT NULL,
    COUNTRY_CODE        VARCHAR2(3)     NOT NULL,
    SECTOR_CODE         VARCHAR2(10),
    INTERNAL_RATING     VARCHAR2(5),
    ANNUAL_TURNOVER     NUMBER(15,2),
    DEFAULT_FLAG        NUMBER(1)       DEFAULT 0 NOT NULL,
    DEFAULT_DATE        DATE,
    CREATION_DATE       DATE            DEFAULT SYSDATE NOT NULL,
    CONSTRAINT PK_COUNTERPARTIES PRIMARY KEY (COUNTERPARTY_ID),
    CONSTRAINT CK_CP_TYPE        CHECK (COUNTERPARTY_TYPE IN ('CORPORATE','RETAIL','SME')),
    CONSTRAINT CK_CP_RATING      CHECK (INTERNAL_RATING IN ('AAA','AA','A','BBB','BB','B','CCC','D')),
    CONSTRAINT CK_CP_DEFAULT     CHECK (DEFAULT_FLAG IN (0,1))
);

COMMENT ON TABLE  COUNTERPARTIES                    IS 'Bank counterparties (obligors)';
COMMENT ON COLUMN COUNTERPARTIES.COUNTERPARTY_ID    IS 'Primary key';
COMMENT ON COLUMN COUNTERPARTIES.COUNTERPARTY_TYPE  IS 'Regulatory type : CORPORATE / RETAIL / SME';
COMMENT ON COLUMN COUNTERPARTIES.COUNTRY_CODE       IS 'ISO 3166 alpha-3 country code';
COMMENT ON COLUMN COUNTERPARTIES.SECTOR_CODE        IS 'Simplified NACE rev2 sector code';
COMMENT ON COLUMN COUNTERPARTIES.INTERNAL_RATING    IS 'Internal rating (AAA -> D)';
COMMENT ON COLUMN COUNTERPARTIES.ANNUAL_TURNOVER    IS 'Annual turnover in EUR (used for SME vs Corporate)';
COMMENT ON COLUMN COUNTERPARTIES.DEFAULT_FLAG       IS '1 if obligor is in default';
COMMENT ON COLUMN COUNTERPARTIES.DEFAULT_DATE       IS 'Default date if applicable';

-- ============================================================
-- Table : CONTRACTS
-- ============================================================
CREATE TABLE CONTRACTS (
    CONTRACT_ID         NUMBER(10)      NOT NULL,
    COUNTERPARTY_ID     NUMBER(10)      NOT NULL,
    PRODUCT_TYPE        VARCHAR2(30)    NOT NULL,
    ASSET_CLASS         VARCHAR2(30)    NOT NULL,
    ORIGINAL_AMOUNT     NUMBER(15,2)    NOT NULL,
    OUTSTANDING_BALANCE NUMBER(15,2)    NOT NULL,
    RESIDUAL_VALUE      NUMBER(15,2)    DEFAULT 0 NOT NULL,
    START_DATE          DATE            NOT NULL,
    MATURITY_DATE       DATE            NOT NULL,
    REMAINING_MONTHS    NUMBER(4),
    CURRENCY            VARCHAR2(3)     DEFAULT 'EUR' NOT NULL,
    STATUS              VARCHAR2(20)    DEFAULT 'ACTIVE' NOT NULL,
    PROVISION_AMOUNT    NUMBER(15,2)    DEFAULT 0 NOT NULL,
    CONSTRAINT PK_CONTRACTS               PRIMARY KEY (CONTRACT_ID),
    CONSTRAINT FK_CONTRACT_COUNTERPARTY   FOREIGN KEY (COUNTERPARTY_ID)
        REFERENCES COUNTERPARTIES (COUNTERPARTY_ID),
    CONSTRAINT CK_CONTRACT_PRODUCT  CHECK (PRODUCT_TYPE IN ('OPERATING_LEASE','FINANCE_LEASE')),
    CONSTRAINT CK_CONTRACT_ASSET    CHECK (ASSET_CLASS  IN ('PASSENGER_CAR','LCV','TRUCK','EQUIPMENT')),
    CONSTRAINT CK_CONTRACT_STATUS   CHECK (STATUS IN ('ACTIVE','DEFAULT','CLOSED','WATCHLIST')),
    CONSTRAINT CK_CONTRACT_DATES    CHECK (MATURITY_DATE >= START_DATE),
    CONSTRAINT CK_CONTRACT_AMOUNT   CHECK (ORIGINAL_AMOUNT > 0)
);

COMMENT ON TABLE  CONTRACTS                       IS 'Leasing contracts (operating / finance lease)';
COMMENT ON COLUMN CONTRACTS.CONTRACT_ID           IS 'Primary key';
COMMENT ON COLUMN CONTRACTS.COUNTERPARTY_ID       IS 'FK to COUNTERPARTIES';
COMMENT ON COLUMN CONTRACTS.PRODUCT_TYPE          IS 'OPERATING_LEASE or FINANCE_LEASE';
COMMENT ON COLUMN CONTRACTS.ASSET_CLASS           IS 'Asset financed (vehicle / equipment)';
COMMENT ON COLUMN CONTRACTS.ORIGINAL_AMOUNT       IS 'Initial financed amount EUR';
COMMENT ON COLUMN CONTRACTS.OUTSTANDING_BALANCE   IS 'Current outstanding EUR';
COMMENT ON COLUMN CONTRACTS.RESIDUAL_VALUE        IS 'Guaranteed residual value EUR (off-balance)';
COMMENT ON COLUMN CONTRACTS.PROVISION_AMOUNT      IS 'Accounting provisions EUR';
COMMENT ON COLUMN CONTRACTS.STATUS                IS 'ACTIVE / DEFAULT / CLOSED / WATCHLIST';

-- ============================================================
-- Table : COLLATERALS
-- ============================================================
CREATE TABLE COLLATERALS (
    COLLATERAL_ID       NUMBER(10)      NOT NULL,
    CONTRACT_ID         NUMBER(10)      NOT NULL,
    COLLATERAL_TYPE     VARCHAR2(30)    NOT NULL,
    COLLATERAL_VALUE    NUMBER(15,2)    DEFAULT 0 NOT NULL,
    COLLATERAL_DATE     DATE            DEFAULT SYSDATE NOT NULL,
    HAIRCUT_PCT         NUMBER(5,4)     DEFAULT 0 NOT NULL,
    ELIGIBLE_FLAG       NUMBER(1)       DEFAULT 0 NOT NULL,
    CONSTRAINT PK_COLLATERALS         PRIMARY KEY (COLLATERAL_ID),
    CONSTRAINT FK_COLLATERAL_CONTRACT FOREIGN KEY (CONTRACT_ID)
        REFERENCES CONTRACTS (CONTRACT_ID),
    CONSTRAINT CK_COLL_TYPE     CHECK (COLLATERAL_TYPE IN ('VEHICLE','REAL_ESTATE','GUARANTEE','NONE')),
    CONSTRAINT CK_COLL_ELIG     CHECK (ELIGIBLE_FLAG IN (0,1)),
    CONSTRAINT CK_COLL_HAIRCUT  CHECK (HAIRCUT_PCT BETWEEN 0 AND 1)
);

COMMENT ON TABLE  COLLATERALS                  IS 'Eligible collaterals attached to contracts (CRR2)';
COMMENT ON COLUMN COLLATERALS.HAIRCUT_PCT      IS 'Regulatory haircut applied to collateral value (decimal)';
COMMENT ON COLUMN COLLATERALS.ELIGIBLE_FLAG    IS '1 if collateral is CRR2-eligible';

-- ============================================================
-- Table : REGULATORY_PARAMETERS
-- ============================================================
CREATE TABLE REGULATORY_PARAMETERS (
    PARAM_ID            NUMBER(10)      NOT NULL,
    ASSET_CLASS         VARCHAR2(30),
    COUNTERPARTY_TYPE   VARCHAR2(20),
    INTERNAL_RATING     VARCHAR2(5),
    PD_FLOOR            NUMBER(6,4)     DEFAULT 0.0003 NOT NULL,
    LGD_SECURED         NUMBER(6,4)     DEFAULT 0.35   NOT NULL,
    LGD_UNSECURED       NUMBER(6,4)     DEFAULT 0.45   NOT NULL,
    RISK_WEIGHT         NUMBER(6,4)     DEFAULT 1.00   NOT NULL,
    CCF                 NUMBER(6,4)     DEFAULT 1.00   NOT NULL,
    EFFECTIVE_DATE      DATE            DEFAULT SYSDATE NOT NULL,
    CONSTRAINT PK_REGULATORY_PARAMETERS PRIMARY KEY (PARAM_ID),
    CONSTRAINT CK_PARAM_PD_FLOOR  CHECK (PD_FLOOR BETWEEN 0 AND 1),
    CONSTRAINT CK_PARAM_LGD_SEC   CHECK (LGD_SECURED   BETWEEN 0 AND 1),
    CONSTRAINT CK_PARAM_LGD_UNS   CHECK (LGD_UNSECURED BETWEEN 0 AND 1),
    CONSTRAINT CK_PARAM_RW        CHECK (RISK_WEIGHT BETWEEN 0 AND 2),
    CONSTRAINT CK_PARAM_CCF       CHECK (CCF BETWEEN 0 AND 1)
);

COMMENT ON TABLE  REGULATORY_PARAMETERS               IS 'CRR2 regulatory parameters by segment / asset class';
COMMENT ON COLUMN REGULATORY_PARAMETERS.PD_FLOOR      IS 'Minimum PD (Article 160 CRR2)';
COMMENT ON COLUMN REGULATORY_PARAMETERS.RISK_WEIGHT   IS 'Standard approach risk weight (decimal)';
COMMENT ON COLUMN REGULATORY_PARAMETERS.CCF           IS 'Credit Conversion Factor for off-balance items';

-- ============================================================
-- Table : RISK_CALCULATIONS (historized SCD2)
-- ============================================================
CREATE TABLE RISK_CALCULATIONS (
    CALC_ID             NUMBER(10)      NOT NULL,
    CONTRACT_ID         NUMBER(10)      NOT NULL,
    CALCULATION_DATE    DATE            NOT NULL,
    PD_VALUE            NUMBER(8,6),
    LGD_VALUE           NUMBER(6,4),
    EAD_VALUE           NUMBER(15,2),
    RWA_VALUE           NUMBER(15,2),
    CAPITAL_REQUIREMENT NUMBER(15,2),
    SEGMENT_CODE        VARCHAR2(20),
    CALC_STATUS         VARCHAR2(20)    DEFAULT 'VALID' NOT NULL,
    ERROR_MESSAGE       VARCHAR2(500),
    VALID_FROM          DATE            DEFAULT SYSDATE NOT NULL,
    VALID_TO            DATE,
    IS_CURRENT          NUMBER(1)       DEFAULT 1 NOT NULL,
    CONSTRAINT PK_RISK_CALCULATIONS     PRIMARY KEY (CALC_ID),
    CONSTRAINT FK_CALC_CONTRACT         FOREIGN KEY (CONTRACT_ID)
        REFERENCES CONTRACTS (CONTRACT_ID),
    CONSTRAINT CK_CALC_STATUS  CHECK (CALC_STATUS IN ('VALID','ERROR','OVERRIDE')),
    CONSTRAINT CK_CALC_CURRENT CHECK (IS_CURRENT IN (0,1))
);

COMMENT ON TABLE  RISK_CALCULATIONS                   IS 'Historized risk metrics per contract (SCD2)';
COMMENT ON COLUMN RISK_CALCULATIONS.PD_VALUE          IS 'Computed PD (decimal)';
COMMENT ON COLUMN RISK_CALCULATIONS.LGD_VALUE         IS 'Computed LGD (decimal)';
COMMENT ON COLUMN RISK_CALCULATIONS.EAD_VALUE         IS 'Exposure at default EUR';
COMMENT ON COLUMN RISK_CALCULATIONS.RWA_VALUE         IS 'Risk-Weighted Assets EUR';
COMMENT ON COLUMN RISK_CALCULATIONS.CAPITAL_REQUIREMENT IS 'Capital requirement EUR (RWA * 8%)';
COMMENT ON COLUMN RISK_CALCULATIONS.IS_CURRENT        IS '1 if this is the current SCD2 record';

-- ============================================================
-- Table : CONTROL_LOG
-- ============================================================
CREATE TABLE CONTROL_LOG (
    LOG_ID              NUMBER(10)      NOT NULL,
    RUN_DATE            DATE            DEFAULT SYSDATE NOT NULL,
    CONTRACT_ID         NUMBER(10),
    CONTROL_CODE        VARCHAR2(50)    NOT NULL,
    SEVERITY            VARCHAR2(10)    NOT NULL,
    MESSAGE             VARCHAR2(1000),
    RESOLVED_FLAG       NUMBER(1)       DEFAULT 0 NOT NULL,
    CONSTRAINT PK_CONTROL_LOG  PRIMARY KEY (LOG_ID),
    CONSTRAINT CK_CTL_SEV      CHECK (SEVERITY IN ('ERROR','WARNING','INFO')),
    CONSTRAINT CK_CTL_RES      CHECK (RESOLVED_FLAG IN (0,1))
);

COMMENT ON TABLE  CONTROL_LOG                IS 'Quality control log (errors, warnings, info)';
COMMENT ON COLUMN CONTROL_LOG.CONTROL_CODE   IS 'Control rule code (CTR-001, CTR-002, ...)';
COMMENT ON COLUMN CONTROL_LOG.SEVERITY       IS 'ERROR / WARNING / INFO';

-- ============================================================
-- Sequences
-- ============================================================
CREATE SEQUENCE SEQ_COUNTERPARTY START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE SEQ_CONTRACT     START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE SEQ_COLLATERAL   START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE SEQ_PARAM        START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE SEQ_CALC         START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;
CREATE SEQUENCE SEQ_LOG          START WITH 1 INCREMENT BY 1 NOCACHE NOCYCLE;

-- ============================================================
-- End of script 01_create_schema.sql
-- ============================================================
