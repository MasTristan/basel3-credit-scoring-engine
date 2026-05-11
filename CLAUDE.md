# CLAUDE.md - Projet 1 : Moteur de Scoring Crédit Bâle III
## Brief de démarrage pour Claude Code

---

## Contexte du projet

Ce projet est un portfolio public destiné à démontrer une expertise combinée
Oracle PL/SQL avancé + réglementation bancaire Bâle III (approche standard CRR2).
Il simule un moteur de calcul de risque de crédit sur un portefeuille de contrats
leasing automobile, type portefeuille d'une filiale bancaire européenne.

**Contrainte absolue : zéro licence payante.**
Stack autorisée : Oracle XE 21c (gratuit), Python 3.x (open-source), Power BI
Desktop (gratuit, pas de publication en ligne).

**Audience cible du repo GitHub :**
- Recruteurs techniques et clients consulting banque/assurance
- Profil auteur : Business Analyst Risk & Finance IT, expert Oracle SQL/PL-SQL,
  spécialisé réglementation EBA/Bâle III

---

## Objectifs techniques

Produire un moteur PL-SQL complet calculant les métriques de risque de crédit
réglementaires Bâle III (approche standard) sur un portefeuille synthétique :

1. **PD** - Probability of Default (par segment réglementaire)
2. **LGD** - Loss Given Default (selon type de garantie et classe d'actif)
3. **EAD** - Exposure At Default (exposition nette des provisions)
4. **RWA** - Risk-Weighted Assets (EAD x pondération réglementaire)
5. **Capital requirement** - RWA x 8% (minimum Bâle III)

---

## Architecture complète à produire

### Structure du repo

```
projet1_bale3/
├── CLAUDE.md                        ← ce fichier
├── README.md                        ← documentation publique GitHub (EN)
├── sql/
│   ├── ddl/
│   │   ├── 01_create_schema.sql     ← création des tables
│   │   └── 02_create_indexes.sql    ← index de performance
│   ├── procedures/
│   │   ├── 01_pkg_segmentation.sql  ← package : segmentation réglementaire
│   │   ├── 02_pkg_risk_params.sql   ← package : paramètres PD/LGD/EAD
│   │   ├── 03_pkg_rwa_engine.sql    ← package : calcul RWA et capital
│   │   ├── 04_pkg_controls.sql      ← package : contrôles qualité et alerting
│   │   └── 05_proc_main_pipeline.sql← procédure principale orchestratrice
│   └── views/
│       ├── v_portfolio_risk.sql     ← vue agrégée par segment
│       └── v_capital_summary.sql   ← vue résumé capital réglementaire
└── python/
    └── generate_portfolio.py        ← génération données synthétiques
```

---

## Schéma de base de données détaillé

### Table : COUNTERPARTIES (contreparties)

```sql
COUNTERPARTY_ID        NUMBER(10)      PK
COUNTERPARTY_TYPE      VARCHAR2(20)    -- 'CORPORATE', 'RETAIL', 'SME'
COUNTRY_CODE           VARCHAR2(3)     -- ISO 3166 (FRA, DEU, ESP, ITA, BEL...)
SECTOR_CODE            VARCHAR2(10)    -- NACE rev2 simplifié
INTERNAL_RATING        VARCHAR2(5)     -- 'AAA','AA','A','BBB','BB','B','CCC','D'
ANNUAL_TURNOVER        NUMBER(15,2)    -- en EUR, détermine SME vs Corporate
DEFAULT_FLAG           NUMBER(1)       -- 0/1
DEFAULT_DATE           DATE
CREATION_DATE          DATE
```

### Table : CONTRACTS (contrats leasing)

```sql
CONTRACT_ID            NUMBER(10)      PK
COUNTERPARTY_ID        NUMBER(10)      FK -> COUNTERPARTIES
PRODUCT_TYPE           VARCHAR2(30)    -- 'OPERATING_LEASE','FINANCE_LEASE'
ASSET_CLASS            VARCHAR2(30)    -- 'PASSENGER_CAR','LCV','TRUCK','EQUIPMENT'
ORIGINAL_AMOUNT        NUMBER(15,2)    -- montant initial EUR
OUTSTANDING_BALANCE    NUMBER(15,2)    -- encours actuel EUR
RESIDUAL_VALUE         NUMBER(15,2)    -- valeur résiduelle garantie
START_DATE             DATE
MATURITY_DATE          DATE
REMAINING_MONTHS       NUMBER(4)
CURRENCY               VARCHAR2(3)     -- 'EUR' majoritairement
STATUS                 VARCHAR2(20)    -- 'ACTIVE','DEFAULT','CLOSED','WATCHLIST'
PROVISION_AMOUNT       NUMBER(15,2)    -- provisions comptables
```

### Table : COLLATERALS (garanties)

```sql
COLLATERAL_ID          NUMBER(10)      PK
CONTRACT_ID            NUMBER(10)      FK -> CONTRACTS
COLLATERAL_TYPE        VARCHAR2(30)    -- 'VEHICLE','REAL_ESTATE','GUARANTEE','NONE'
COLLATERAL_VALUE       NUMBER(15,2)    -- valeur de marché EUR
COLLATERAL_DATE        DATE            -- date d'évaluation
HAIRCUT_PCT            NUMBER(5,4)     -- décote réglementaire (ex: 0.15 = 15%)
ELIGIBLE_FLAG          NUMBER(1)       -- éligibilité CRR2
```

### Table : REGULATORY_PARAMETERS (paramètres réglementaires)

```sql
PARAM_ID               NUMBER(10)      PK
ASSET_CLASS            VARCHAR2(30)
COUNTERPARTY_TYPE      VARCHAR2(20)
INTERNAL_RATING        VARCHAR2(5)
PD_FLOOR               NUMBER(6,4)     -- floor réglementaire PD (ex: 0.0003)
LGD_SECURED            NUMBER(6,4)     -- LGD garanti standard (ex: 0.35)
LGD_UNSECURED          NUMBER(6,4)     -- LGD non garanti (ex: 0.45)
RISK_WEIGHT            NUMBER(6,4)     -- pondération CRR2 (ex: 0.75 retail)
CCF                    NUMBER(6,4)     -- Credit Conversion Factor
EFFECTIVE_DATE         DATE
```

### Table : RISK_CALCULATIONS (résultats de calcul - historisée SCD2)

```sql
CALC_ID                NUMBER(10)      PK
CONTRACT_ID            NUMBER(10)      FK -> CONTRACTS
CALCULATION_DATE       DATE            -- date de run
PD_VALUE               NUMBER(8,6)     -- PD calculée
LGD_VALUE              NUMBER(6,4)     -- LGD calculée
EAD_VALUE              NUMBER(15,2)    -- EAD en EUR
RWA_VALUE              NUMBER(15,2)    -- RWA en EUR
CAPITAL_REQUIREMENT    NUMBER(15,2)    -- exigence capital EUR
SEGMENT_CODE           VARCHAR2(20)    -- segment réglementaire appliqué
CALC_STATUS            VARCHAR2(20)    -- 'VALID','ERROR','OVERRIDE'
ERROR_MESSAGE          VARCHAR2(500)
VALID_FROM             DATE
VALID_TO               DATE            -- NULL = enregistrement courant (SCD2)
IS_CURRENT             NUMBER(1)       -- 1 = courant
```

### Table : CONTROL_LOG (log des contrôles qualité)

```sql
LOG_ID                 NUMBER(10)      PK
RUN_DATE               DATE
CONTRACT_ID            NUMBER(10)
CONTROL_CODE           VARCHAR2(50)    -- code du contrôle déclenché
SEVERITY               VARCHAR2(10)    -- 'ERROR','WARNING','INFO'
MESSAGE                VARCHAR2(1000)
RESOLVED_FLAG          NUMBER(1)       DEFAULT 0
```

---

## Spécifications des packages PL-SQL

### PKG_SEGMENTATION

Responsabilité : déterminer le segment réglementaire Bâle III de chaque contrat.

Règles de segmentation à implémenter :

```
RETAIL      : COUNTERPARTY_TYPE = 'RETAIL'
              ET OUTSTANDING_BALANCE <= 1,000,000 EUR
SME_RETAIL  : COUNTERPARTY_TYPE = 'SME'
              ET ANNUAL_TURNOVER <= 50,000,000 EUR
              ET OUTSTANDING_BALANCE <= 1,000,000 EUR
SME_CORP    : COUNTERPARTY_TYPE = 'SME'
              ET (ANNUAL_TURNOVER > 50,000,000 EUR
                  OU OUTSTANDING_BALANCE > 1,000,000 EUR)
CORPORATE   : COUNTERPARTY_TYPE = 'CORPORATE'
DEFAULTED   : STATUS = 'DEFAULT' (override tous les autres segments)
```

Fonctions à exposer :
- `GET_SEGMENT(p_contract_id) RETURN VARCHAR2`
- `REFRESH_ALL_SEGMENTS` (bulk update)

### PKG_RISK_PARAMS

Responsabilité : calculer PD, LGD, EAD pour un contrat donné.

Logique PD (approche standard CRR2) :
```
PD = MAX(PD_FLOOR, PD_from_internal_rating)
Table de correspondance rating -> PD :
  AAA  -> 0.0003
  AA   -> 0.0005
  A    -> 0.0010
  BBB  -> 0.0025
  BB   -> 0.0100
  B    -> 0.0500
  CCC  -> 0.1500
  D    -> 1.0000  (défaut)
```

Logique LGD :
```
Si COLLATERAL éligible (ELIGIBLE_FLAG=1) :
  LGD = LGD_SECURED * (1 - (COLLATERAL_VALUE * (1-HAIRCUT_PCT)) / EAD)
  LGD = MAX(LGD, LGD_SECURED_FLOOR = 0.10)
Sinon :
  LGD = LGD_UNSECURED (paramètre réglementaire par segment)
```

Logique EAD :
```
EAD = OUTSTANDING_BALANCE - PROVISION_AMOUNT
      + (RESIDUAL_VALUE * CCF)
EAD = MAX(EAD, 0)
```

Fonctions à exposer :
- `GET_PD(p_contract_id) RETURN NUMBER`
- `GET_LGD(p_contract_id) RETURN NUMBER`
- `GET_EAD(p_contract_id) RETURN NUMBER`

### PKG_RWA_ENGINE

Responsabilité : calculer RWA et exigence de capital.

Logique RWA (approche standard) :
```
RWA = EAD * RISK_WEIGHT
      (RISK_WEIGHT issu de REGULATORY_PARAMETERS selon segment)

Pondérations standard CRR2 à paramétrer :
  RETAIL          -> 75%
  SME_RETAIL      -> 75%
  SME_CORP        -> 85%
  CORPORATE       -> 100%
  DEFAULTED       -> 150%
  Secured vehicle -> 50% (si LTV <= 50%)

CAPITAL_REQUIREMENT = RWA * 0.08
```

Procédures à exposer :
- `CALC_RWA(p_contract_id) RETURN NUMBER`
- `CALC_CAPITAL(p_contract_id) RETURN NUMBER`
- `RUN_FULL_PORTFOLIO` (bulk, insère dans RISK_CALCULATIONS avec SCD2)

### PKG_CONTROLS

Responsabilité : contrôles de qualité sur les données et les résultats.

Contrôles à implémenter :
```
CTR-001 : OUTSTANDING_BALANCE <= 0                  -> ERROR
CTR-002 : MATURITY_DATE < SYSDATE (contrat expiré)  -> WARNING
CTR-003 : PD = NULL après calcul                    -> ERROR
CTR-004 : LGD > 1 ou LGD < 0                       -> ERROR
CTR-005 : EAD > ORIGINAL_AMOUNT * 1.2              -> WARNING (anomalie EAD)
CTR-006 : RWA = 0 sur contrat ACTIVE               -> WARNING
CTR-007 : COLLATERAL_VALUE > OUTSTANDING_BALANCE*3 -> WARNING (sur-collatéral)
CTR-008 : DEFAULT_FLAG=1 mais STATUS != 'DEFAULT'  -> ERROR (incohérence)
```

Procédures à exposer :
- `RUN_ALL_CONTROLS(p_calc_date DATE)` : exécute tous les contrôles, insère dans CONTROL_LOG
- `GET_CONTROL_SUMMARY` : retourne un résumé par sévérité

### PROC_MAIN_PIPELINE

Responsabilité : orchestrer le pipeline complet en un seul appel.

Séquence d'exécution :
```
1. Log début de run (date, nb contrats actifs)
2. PKG_SEGMENTATION.REFRESH_ALL_SEGMENTS
3. Pour chaque contrat ACTIVE ou WATCHLIST :
   a. PKG_RISK_PARAMS : calcul PD, LGD, EAD
   b. PKG_RWA_ENGINE : calcul RWA, Capital
   c. Insert dans RISK_CALCULATIONS (SCD2 : ferme l'ancien, insère le nouveau)
4. PKG_CONTROLS.RUN_ALL_CONTROLS
5. Log fin de run (nb succès, nb erreurs, temps d'exécution)
```

Signature : `PROC_MAIN_PIPELINE(p_run_date DATE DEFAULT SYSDATE)`

---

## Vues SQL à produire

### V_PORTFOLIO_RISK

Agrégation par segment réglementaire, date de calcul courante :
```
SEGMENT_CODE
NB_CONTRACTS
TOTAL_EAD
TOTAL_RWA
TOTAL_CAPITAL_REQUIREMENT
AVG_PD
AVG_LGD
RWA_DENSITY (= TOTAL_RWA / TOTAL_EAD)
```

### V_CAPITAL_SUMMARY

Vue résumé niveau portefeuille entier :
```
CALCULATION_DATE
TOTAL_PORTFOLIO_EAD
TOTAL_RWA
TOTAL_CAPITAL_REQUIREMENT
CAPITAL_RATIO (= TOTAL_CAPITAL / TOTAL_EAD)
NB_DEFAULTED_CONTRACTS
DEFAULT_RATE
NB_ERRORS
```

---

## Script Python - generate_portfolio.py

Générer un portefeuille synthétique réaliste de **5 000 contrats** avec les
contraintes suivantes :

### Distribution des contreparties (1 500 contreparties pour 5 000 contrats)

```
RETAIL    : 40% (600 contreparties)
SME       : 40% (600 contreparties)
CORPORATE : 20% (300 contreparties)
```

### Distribution des ratings (réaliste, pas trop de défauts)

```
AAA-AA : 10%
A      : 20%
BBB    : 30%
BB     : 20%
B      : 12%
CCC    : 5%
D      : 3%   (défauts)
```

### Distribution géographique

```
FRA : 35%, DEU : 20%, ESP : 15%, ITA : 15%, BEL : 8%, NLD : 7%
```

### Distribution des montants (OUTSTANDING_BALANCE)

```
RETAIL    : 5 000 - 50 000 EUR (log-normal)
SME       : 20 000 - 500 000 EUR (log-normal)
CORPORATE : 100 000 - 5 000 000 EUR (log-normal)
```

### Output

Le script doit générer des fichiers SQL INSERT ou des CSV prêts à charger :
- `counterparties_data.sql` (ou .csv)
- `contracts_data.sql` (ou .csv)
- `collaterals_data.sql` (ou .csv)
- `regulatory_parameters_data.sql` (seed des paramètres réglementaires)

Utiliser **numpy**, **pandas**, **faker** pour la génération.
Seed fixé à 42 pour la reproductibilité.

---

## README.md (à produire en anglais)

Structure attendue :
1. Project overview (2-3 lignes)
2. Business context (Bâle III standard approach, leasing portfolio)
3. Technical architecture (schema diagram en ASCII, stack)
4. Repository structure
5. Setup instructions (Oracle XE install link, SQL scripts order)
6. How to run the pipeline
7. Sample output (résultats agrégés sur le portefeuille synthétique)
8. Regulatory references (CRR2 articles pertinents)
9. Author

---

## Standards de code à respecter

### PL-SQL
- Tout le code dans des packages (pas de procédures standalone sauf PROC_MAIN)
- Header de commentaire sur chaque package et procédure :
  ```sql
  -- ============================================================
  -- Package : PKG_SEGMENTATION
  -- Purpose : Regulatory segmentation (Basel III CRR2 Article 147)
  -- Author  : Tristan Mas | github.com/tristan-mas
  -- Version : 1.0 | 2025
  -- ============================================================
  ```
- Gestion d'exceptions systématique avec WHEN OTHERS THEN + log dans CONTROL_LOG
- Utiliser des constantes nommées pour les seuils réglementaires (pas de magic numbers)
- Curseurs explicites pour les traitements bulk (pas de boucles implicites)
- BULK COLLECT + FORALL sur les traitements de masse (performance)

### Python
- PEP8 strict
- Docstrings sur toutes les fonctions
- Logging via le module `logging` (pas de print)
- Seed numpy fixé à 42
- Requirements.txt à jour

### SQL général
- Noms de tables et colonnes en UPPER_SNAKE_CASE
- Commentaires sur les colonnes dans les DDL
- Contraintes nommées explicitement (PK_CONTRACTS, FK_CONTRACT_COUNTERPARTY, etc.)

---

## Ordre de production recommandé pour Claude Code

1. `sql/ddl/01_create_schema.sql` + `02_create_indexes.sql`
2. `python/generate_portfolio.py` + données synthétiques
3. `sql/procedures/01_pkg_segmentation.sql`
4. `sql/procedures/02_pkg_risk_params.sql`
5. `sql/procedures/03_pkg_rwa_engine.sql`
6. `sql/procedures/04_pkg_controls.sql`
7. `sql/procedures/05_proc_main_pipeline.sql`
8. `sql/views/v_portfolio_risk.sql` + `v_capital_summary.sql`
9. `README.md`

---

## Validation attendue

Après exécution du pipeline sur le portefeuille synthétique, les résultats
agrégés doivent être cohérents avec ces ordres de grandeur :

```
RWA Density (RWA/EAD) :
  RETAIL      : ~75%
  SME_RETAIL  : ~75%
  CORPORATE   : ~85-100%
  DEFAULTED   : ~150%
  Global      : ~80-90%

Default Rate : ~3% (cohérent avec distribution des ratings)
Capital Ratio global : ~7-8% de l'EAD total
```

Si les résultats s'écartent significativement de ces benchmarks,
revoir la logique de calcul avant de valider.

---

## Notes importantes

- Oracle XE 21c est la cible. Utiliser la syntaxe compatible XE
  (pas de fonctionnalités Enterprise Edition).
- Pas de dblink, pas de partitioning (fonctionnalités payantes).
- Le schéma utilisateur cible s'appelle : BASEL_RISK
- Tous les montants en EUR, précision NUMBER(15,2).
- Les pourcentages stockés en décimal (0.75 = 75%, pas 75).
