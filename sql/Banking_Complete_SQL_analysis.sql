-- ============================================================
-- BANKING RISK ANALYTICS — FULL SQL SCRIPT
-- Project: Integrated Banking Analytics (SQL + Python + Power BI)
-- Database: MySQL
-- Standard: Big 4 Analyst Quality
-- ============================================================
-- CONTENTS:
--   SECTION 0 — Database Setup & Data Import
--   SECTION 1 — Data Quality & Profiling
--   SECTION 2 — Feature Engineering
--   SECTION 3 — Client Segmentation Analysis
--   SECTION 4 — Loan Portfolio Analysis
--   SECTION 5 — Deposit Portfolio Analysis
--   SECTION 6 — Risk Analysis
--   SECTION 7 — Growth & Trend Analysis
--   SECTION 8 — Revenue & Profitability Analysis
--   SECTION 9 — Views for Power BI
--   SECTION 10 — Executive Summary
-- ============================================================


-- ============================================================
-- SECTION 0 — DATABASE SETUP & DATA IMPORT
-- ============================================================

-- Create isolated project database
CREATE DATABASE IF NOT EXISTS banking_case;
USE banking_case;

-- Verify environment
SHOW VARIABLES WHERE Variable_name = 'hostname';
SELECT current_user();

-- -------------------------------------------------------
-- Create the main banking table with correct data types
-- -------------------------------------------------------
-- NOTE (adaptation): the source's Client ID is NOT unique. 59 values collide
-- (58 appear twice, one appears three times), covering 60 of the 3,000 rows,
-- and every colliding group is a genuinely different person rather than a
-- duplicate record. Declaring client_id as PRIMARY KEY, as this script
-- originally did, makes the import below abort with ER_DUP_ENTRY (1062) on the
-- first collision. Row identity is therefore carried by a surrogate key, and
-- client_id is indexed for lookup rather than enforced unique.
-- Verified by python/data_quality.py; see docs/data_quality_findings.md.
CREATE TABLE IF NOT EXISTS banking (
    row_id                  INT AUTO_INCREMENT PRIMARY KEY,
    client_id               VARCHAR(20)     NOT NULL,
    name                    VARCHAR(100),
    age                     INT,
    location_id             INT,
    joined_bank             DATE,
    banking_contact         VARCHAR(100),
    nationality             VARCHAR(50),
    occupation              VARCHAR(100),
    fee_structure           VARCHAR(10),
    loyalty_classification  VARCHAR(20),
    estimated_income        DECIMAL(15,2),
    superannuation_savings  DECIMAL(15,2),
    amount_of_credit_cards  INT,
    credit_card_balance     DECIMAL(15,2),
    bank_loans              DECIMAL(15,2),
    bank_deposits           DECIMAL(15,2),
    checking_accounts       DECIMAL(15,2),
    saving_accounts         DECIMAL(15,2),
    foreign_currency_account DECIMAL(15,2),
    business_lending        DECIMAL(15,2),
    properties_owned        INT,
    risk_weighting          INT,
    br_id                   INT,
    gender_id               INT,
    ia_id                   INT,

    -- Lookup index only; deliberately NOT UNIQUE (see note above).
    KEY idx_client_id (client_id)
);

-- -------------------------------------------------------
-- Import data from CSV
-- Run this after placing Banking.csv in MySQL secure path
-- -------------------------------------------------------
-- LOAD DATA INFILE '/var/lib/mysql-files/Banking.csv'
-- INTO TABLE banking
-- FIELDS TERMINATED BY ','
-- ENCLOSED BY '"'
-- LINES TERMINATED BY '\n'
-- IGNORE 1 ROWS
-- (client_id, name, age, location_id, @joined_bank, banking_contact,
--  nationality, occupation, fee_structure, loyalty_classification,
--  estimated_income, superannuation_savings, amount_of_credit_cards,
--  credit_card_balance, bank_loans, bank_deposits, checking_accounts,
--  saving_accounts, foreign_currency_account, business_lending,
--  properties_owned, risk_weighting, br_id, gender_id, ia_id)
-- SET joined_bank = STR_TO_DATE(@joined_bank, '%d-%m-%Y');

-- Verify row count — should be 3000
SELECT COUNT(*) AS total_rows FROM banking;

-- Preview first 5 rows
SELECT * FROM banking LIMIT 5;


-- ============================================================
-- SECTION 1 — DATA QUALITY & PROFILING
-- ============================================================

-- -------------------------------------------------------
-- 1.1 — Check for NULL values across all columns
-- -------------------------------------------------------
SELECT
    SUM(CASE WHEN client_id               IS NULL THEN 1 ELSE 0 END) AS null_client_id,
    SUM(CASE WHEN name                    IS NULL THEN 1 ELSE 0 END) AS null_name,
    SUM(CASE WHEN age                     IS NULL THEN 1 ELSE 0 END) AS null_age,
    SUM(CASE WHEN joined_bank             IS NULL THEN 1 ELSE 0 END) AS null_joined_bank,
    SUM(CASE WHEN nationality             IS NULL THEN 1 ELSE 0 END) AS null_nationality,
    SUM(CASE WHEN occupation              IS NULL THEN 1 ELSE 0 END) AS null_occupation,
    SUM(CASE WHEN fee_structure           IS NULL THEN 1 ELSE 0 END) AS null_fee_structure,
    SUM(CASE WHEN loyalty_classification  IS NULL THEN 1 ELSE 0 END) AS null_loyalty,
    SUM(CASE WHEN estimated_income        IS NULL THEN 1 ELSE 0 END) AS null_income,
    SUM(CASE WHEN bank_loans              IS NULL THEN 1 ELSE 0 END) AS null_bank_loans,
    SUM(CASE WHEN bank_deposits           IS NULL THEN 1 ELSE 0 END) AS null_bank_deposits,
    SUM(CASE WHEN business_lending        IS NULL THEN 1 ELSE 0 END) AS null_business_lending,
    SUM(CASE WHEN br_id                   IS NULL THEN 1 ELSE 0 END) AS null_br_id,
    SUM(CASE WHEN gender_id               IS NULL THEN 1 ELSE 0 END) AS null_gender_id
FROM banking;
-- Expected: all zeros — dataset is 100% complete

-- -------------------------------------------------------
-- 1.2 — Check for duplicate Client IDs
-- -------------------------------------------------------
-- NOTE (adaptation): this check RETURNS 59 ROWS on the shipped Banking.csv.
-- The original comment here read "Expected: 0 rows — no duplicates", and that
-- expectation was wrong. The collisions are real: 58 IDs appear twice and one
-- appears three times, and inspecting the groups shows a different name, age,
-- join date, income and balance set in each — these are distinct clients who
-- were issued a colliding ID, not repeated records. Because client_id
-- therefore identifies a *row* rather than a *client*, any COUNT(DISTINCT
-- client_id) under-reports the client base by 60. See
-- docs/data_quality_findings.md.
SELECT
    client_id,
    COUNT(*) AS occurrences
FROM banking
GROUP BY client_id
HAVING COUNT(*) > 1
ORDER BY occurrences DESC, client_id;
-- Returns 59 rows on the shipped data.

-- -------------------------------------------------------
-- 1.2b — Reconcile record count against distinct-client count
-- -------------------------------------------------------
-- These two figures legitimately differ, so report both rather than letting a
-- downstream KPI pick one silently.
SELECT
    COUNT(*)                             AS total_records,
    COUNT(DISTINCT client_id)            AS distinct_client_ids,
    COUNT(*) - COUNT(DISTINCT client_id) AS duplicated_id_rows
FROM banking;
-- Expected on the shipped data: 3000 / 2940 / 60

-- -------------------------------------------------------
-- 1.3 — Validate categorical column values
-- -------------------------------------------------------
-- Nationality
SELECT nationality, COUNT(*) AS client_count
FROM banking
GROUP BY nationality
ORDER BY client_count DESC;

-- Fee Structure
SELECT fee_structure, COUNT(*) AS client_count
FROM banking
GROUP BY fee_structure
ORDER BY client_count DESC;

-- Loyalty Classification
SELECT loyalty_classification, COUNT(*) AS client_count
FROM banking
GROUP BY loyalty_classification
ORDER BY client_count DESC;

-- Banking Relationship (BRId)
SELECT
    br_id,
    CASE br_id
        WHEN 1 THEN 'Premium'
        WHEN 2 THEN 'Business'
        WHEN 3 THEN 'Personal'
        WHEN 4 THEN 'SME'
    END AS banking_relationship,
    COUNT(*) AS client_count
FROM banking
GROUP BY br_id
ORDER BY br_id;

-- Gender
SELECT
    gender_id,
    CASE gender_id WHEN 1 THEN 'Male' WHEN 2 THEN 'Female' END AS gender,
    COUNT(*) AS client_count
FROM banking
GROUP BY gender_id
ORDER BY gender_id;

-- -------------------------------------------------------
-- 1.4 — Numeric column range validation
-- -------------------------------------------------------
SELECT
    MIN(age)                    AS min_age,
    MAX(age)                    AS max_age,
    ROUND(AVG(age), 1)          AS avg_age,
    MIN(estimated_income)       AS min_income,
    MAX(estimated_income)       AS max_income,
    ROUND(AVG(estimated_income), 2) AS avg_income,
    MIN(bank_loans)             AS min_loan,
    MAX(bank_loans)             AS max_loan,
    ROUND(AVG(bank_loans), 2)   AS avg_loan,
    MIN(bank_deposits)          AS min_deposit,
    MAX(bank_deposits)          AS max_deposit,
    ROUND(AVG(bank_deposits), 2) AS avg_deposit,
    MIN(risk_weighting)         AS min_risk,
    MAX(risk_weighting)         AS max_risk
FROM banking;

-- -------------------------------------------------------
-- 1.5 — Date range validation
-- -------------------------------------------------------
SELECT
    MIN(joined_bank)                        AS earliest_join,
    MAX(joined_bank)                        AS latest_join,
    YEAR(MIN(joined_bank))                  AS earliest_year,
    YEAR(MAX(joined_bank))                  AS latest_year,
    COUNT(DISTINCT YEAR(joined_bank))       AS distinct_years
FROM banking;


-- ============================================================
-- SECTION 2 — FEATURE ENGINEERING
-- ============================================================
-- Creating derived columns to mirror Power BI and Python EDA
-- These are computed inline using CASE and DATEDIFF

-- -------------------------------------------------------
-- 2.1 — Income Band (mirrors Python EDA and Power BI)
-- -------------------------------------------------------
-- Preview Income Band distribution
SELECT
    CASE
        WHEN estimated_income < 100000 THEN 'Low'
        WHEN estimated_income < 300000 THEN 'Mid'
        ELSE 'High'
    END AS income_band,
    COUNT(*) AS client_count,
    ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM banking), 1) AS pct_of_total
FROM banking
GROUP BY income_band
ORDER BY FIELD(income_band, 'Low', 'Mid', 'High');

-- -------------------------------------------------------
-- 2.2 — Age Band
-- -------------------------------------------------------
SELECT
    CASE
        WHEN age < 31 THEN '18-30'
        WHEN age < 46 THEN '31-45'
        WHEN age < 61 THEN '46-60'
        ELSE '61+'
    END AS age_band,
    COUNT(*) AS client_count,
    ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM banking), 1) AS pct_of_total
FROM banking
GROUP BY age_band
ORDER BY FIELD(age_band, '18-30', '31-45', '46-60', '61+');

-- -------------------------------------------------------
-- 2.3 — Engagement Days and Timeframe
-- -------------------------------------------------------
SELECT
    client_id,
    joined_bank,
    DATEDIFF(CURDATE(), joined_bank) AS engagement_days,
    CASE
        WHEN DATEDIFF(CURDATE(), joined_bank) < 365   THEN 'Less than 1 Year'
        WHEN DATEDIFF(CURDATE(), joined_bank) < 1825  THEN '1-5 Years'
        WHEN DATEDIFF(CURDATE(), joined_bank) < 3650  THEN '5-10 Years'
        ELSE '10+ Years'
    END AS engagement_timeframe
FROM banking
LIMIT 10;

-- Engagement Timeframe distribution
SELECT
    CASE
        WHEN DATEDIFF(CURDATE(), joined_bank) < 365   THEN 'Less than 1 Year'
        WHEN DATEDIFF(CURDATE(), joined_bank) < 1825  THEN '1-5 Years'
        WHEN DATEDIFF(CURDATE(), joined_bank) < 3650  THEN '5-10 Years'
        ELSE '10+ Years'
    END AS engagement_timeframe,
    COUNT(*) AS client_count
FROM banking
GROUP BY engagement_timeframe
ORDER BY FIELD(engagement_timeframe, 'Less than 1 Year', '1-5 Years', '5-10 Years', '10+ Years');

-- -------------------------------------------------------
-- 2.4 — Processing Fees
-- -------------------------------------------------------
SELECT
    fee_structure,
    CASE
        WHEN fee_structure = 'High' THEN 0.05
        WHEN fee_structure = 'Mid'  THEN 0.03
        ELSE 0.01
    END AS processing_fee_rate,
    COUNT(*) AS client_count
FROM banking
GROUP BY fee_structure
ORDER BY FIELD(fee_structure, 'High', 'Mid', 'Low');

-- -------------------------------------------------------
-- 2.5 — Total Loan and Total Deposit derived fields
-- -------------------------------------------------------
SELECT
    client_id,
    bank_loans,
    business_lending,
    credit_card_balance,
    (bank_loans + business_lending + credit_card_balance)           AS total_loan,
    bank_deposits,
    saving_accounts,
    checking_accounts,
    foreign_currency_account,
    (bank_deposits + saving_accounts + checking_accounts + foreign_currency_account) AS total_deposit
FROM banking
LIMIT 10;


-- ============================================================
-- SECTION 3 — CLIENT SEGMENTATION ANALYSIS
-- ============================================================

-- -------------------------------------------------------
-- 3.1 — Portfolio overview KPIs
-- -------------------------------------------------------
SELECT
    -- Both figures are reported deliberately: the dataset holds 3,000 records
    -- but only 2,940 distinct client_id values (see 1.2). A single
    -- "total_clients" here previously disagreed with the COUNT(*) used in
    -- section 6.1 by 60, depending on which the reader trusted.
    COUNT(*)                                            AS total_records,
    COUNT(DISTINCT client_id)                           AS distinct_client_ids,
    ROUND(SUM(bank_loans), 2)                           AS total_bank_loans,
    ROUND(SUM(business_lending), 2)                     AS total_business_lending,
    ROUND(SUM(credit_card_balance), 2)                  AS total_cc_balance,
    ROUND(SUM(bank_loans + business_lending + credit_card_balance), 2) AS total_loan,
    ROUND(SUM(bank_deposits), 2)                        AS total_bank_deposits,
    ROUND(SUM(saving_accounts), 2)                      AS total_savings,
    ROUND(SUM(checking_accounts), 2)                    AS total_checking,
    ROUND(SUM(foreign_currency_account), 2)             AS total_fx,
    ROUND(SUM(bank_deposits + saving_accounts + checking_accounts + foreign_currency_account), 2) AS total_deposit,
    ROUND(AVG(estimated_income), 2)                     AS avg_estimated_income
FROM banking;

-- -------------------------------------------------------
-- 3.2 — Clients by Banking Relationship
-- -------------------------------------------------------
SELECT
    CASE br_id
        WHEN 1 THEN 'Premium'
        WHEN 2 THEN 'Business'
        WHEN 3 THEN 'Personal'
        WHEN 4 THEN 'SME'
    END AS banking_relationship,
    COUNT(*)                                            AS client_count,
    ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM banking), 1) AS pct_of_total,
    ROUND(AVG(estimated_income), 2)                     AS avg_income,
    ROUND(AVG(bank_loans), 2)                           AS avg_loan,
    ROUND(AVG(bank_deposits), 2)                        AS avg_deposit
FROM banking
GROUP BY br_id
ORDER BY client_count DESC;

-- -------------------------------------------------------
-- 3.3 — Clients by Loyalty Classification
-- -------------------------------------------------------
SELECT
    loyalty_classification,
    COUNT(*)                                            AS client_count,
    ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM banking), 1) AS pct_of_total,
    ROUND(AVG(estimated_income), 2)                     AS avg_income,
    ROUND(SUM(bank_loans), 2)                           AS total_loans,
    ROUND(SUM(bank_deposits), 2)                        AS total_deposits
FROM banking
GROUP BY loyalty_classification
ORDER BY client_count DESC;

-- -------------------------------------------------------
-- 3.4 — Clients by Nationality
-- -------------------------------------------------------
SELECT
    nationality,
    COUNT(*)                                            AS client_count,
    ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM banking), 1) AS pct_of_total,
    ROUND(AVG(estimated_income), 2)                     AS avg_income,
    ROUND(SUM(bank_loans), 2)                           AS total_loans,
    ROUND(SUM(bank_deposits), 2)                        AS total_deposits,
    ROUND(AVG(bank_loans), 2)                           AS avg_loan
FROM banking
GROUP BY nationality
ORDER BY client_count DESC;

-- -------------------------------------------------------
-- 3.5 — Clients by Gender
-- -------------------------------------------------------
SELECT
    CASE gender_id WHEN 1 THEN 'Male' WHEN 2 THEN 'Female' END AS gender,
    COUNT(*)                                            AS client_count,
    ROUND(AVG(estimated_income), 2)                     AS avg_income,
    ROUND(SUM(bank_loans), 2)                           AS total_loans,
    ROUND(SUM(bank_deposits), 2)                        AS total_deposits,
    ROUND(SUM(business_lending), 2)                     AS total_business_lending
FROM banking
GROUP BY gender_id
ORDER BY gender_id;

-- -------------------------------------------------------
-- 3.6 — Clients by Income Band
-- -------------------------------------------------------
SELECT
    CASE
        WHEN estimated_income < 100000 THEN 'Low'
        WHEN estimated_income < 300000 THEN 'Mid'
        ELSE 'High'
    END AS income_band,
    COUNT(*)                                            AS client_count,
    ROUND(AVG(estimated_income), 2)                     AS avg_income,
    ROUND(SUM(bank_loans), 2)                           AS total_loans,
    ROUND(AVG(bank_loans), 2)                           AS avg_loan,
    ROUND(SUM(bank_deposits), 2)                        AS total_deposits
FROM banking
GROUP BY income_band
ORDER BY FIELD(income_band, 'Low', 'Mid', 'High');

-- -------------------------------------------------------
-- 3.7 — Clients by Age Band
-- -------------------------------------------------------
SELECT
    CASE
        WHEN age < 31 THEN '18-30'
        WHEN age < 46 THEN '31-45'
        WHEN age < 61 THEN '46-60'
        ELSE '61+'
    END AS age_band,
    COUNT(*)                                            AS client_count,
    ROUND(AVG(estimated_income), 2)                     AS avg_income,
    ROUND(AVG(bank_loans), 2)                           AS avg_loan,
    ROUND(AVG(bank_deposits), 2)                        AS avg_deposit,
    ROUND(AVG(superannuation_savings), 2)               AS avg_superannuation
FROM banking
GROUP BY age_band
ORDER BY FIELD(age_band, '18-30', '31-45', '46-60', '61+');

-- -------------------------------------------------------
-- 3.8 — Top 10 Occupations by Client Count
-- -------------------------------------------------------
SELECT
    occupation,
    COUNT(*)                                            AS client_count,
    ROUND(AVG(estimated_income), 2)                     AS avg_income,
    ROUND(AVG(bank_loans), 2)                           AS avg_loan
FROM banking
GROUP BY occupation
ORDER BY client_count DESC
LIMIT 10;


-- ============================================================
-- SECTION 4 — LOAN PORTFOLIO ANALYSIS
-- ============================================================

-- -------------------------------------------------------
-- 4.1 — Total loan exposure breakdown
-- -------------------------------------------------------
SELECT
    ROUND(SUM(bank_loans), 2)                           AS total_bank_loans,
    ROUND(SUM(business_lending), 2)                     AS total_business_lending,
    ROUND(SUM(credit_card_balance), 2)                  AS total_cc_balance,
    ROUND(SUM(bank_loans + business_lending + credit_card_balance), 2) AS total_loan_exposure,
    ROUND(AVG(bank_loans), 2)                           AS avg_bank_loan_per_client,
    ROUND(AVG(business_lending), 2)                     AS avg_business_lending_per_client
FROM banking;

-- -------------------------------------------------------
-- 4.2 — Bank Loan by Banking Relationship
-- -------------------------------------------------------
SELECT
    CASE br_id
        WHEN 1 THEN 'Premium'
        WHEN 2 THEN 'Business'
        WHEN 3 THEN 'Personal'
        WHEN 4 THEN 'SME'
    END AS banking_relationship,
    COUNT(*)                                            AS client_count,
    ROUND(SUM(bank_loans), 2)                           AS total_bank_loans,
    ROUND(AVG(bank_loans), 2)                           AS avg_bank_loan,
    ROUND(SUM(business_lending), 2)                     AS total_business_lending,
    ROUND(SUM(credit_card_balance), 2)                  AS total_cc_balance,
    ROUND(SUM(bank_loans + business_lending + credit_card_balance), 2) AS total_loan
FROM banking
GROUP BY br_id
ORDER BY total_loan DESC;

-- -------------------------------------------------------
-- 4.3 — Bank Loan by Nationality
-- -------------------------------------------------------
SELECT
    nationality,
    COUNT(*)                                            AS client_count,
    ROUND(SUM(bank_loans), 2)                           AS total_bank_loans,
    ROUND(AVG(bank_loans), 2)                           AS avg_bank_loan,
    ROUND(SUM(bank_loans) * 100.0 /
        (SELECT SUM(bank_loans) FROM banking), 2)       AS pct_of_total_loans
FROM banking
GROUP BY nationality
ORDER BY total_bank_loans DESC;

-- -------------------------------------------------------
-- 4.4 — Bank Loan by Income Band
-- -------------------------------------------------------
SELECT
    CASE
        WHEN estimated_income < 100000 THEN 'Low'
        WHEN estimated_income < 300000 THEN 'Mid'
        ELSE 'High'
    END AS income_band,
    COUNT(*)                                            AS client_count,
    ROUND(SUM(bank_loans), 2)                           AS total_bank_loans,
    ROUND(AVG(bank_loans), 2)                           AS avg_bank_loan,
    ROUND(SUM(business_lending), 2)                     AS total_business_lending
FROM banking
GROUP BY income_band
ORDER BY FIELD(income_band, 'Low', 'Mid', 'High');

-- -------------------------------------------------------
-- 4.5 — Top 10 Occupations by Bank Loan Volume
-- -------------------------------------------------------
SELECT
    occupation,
    COUNT(*)                                            AS client_count,
    ROUND(SUM(bank_loans), 2)                           AS total_bank_loans,
    ROUND(AVG(bank_loans), 2)                           AS avg_bank_loan,
    ROUND(SUM(business_lending), 2)                     AS total_business_lending
FROM banking
GROUP BY occupation
ORDER BY total_bank_loans DESC
LIMIT 10;

-- -------------------------------------------------------
-- 4.6 — Loan Distribution by Fee Structure
-- -------------------------------------------------------
SELECT
    fee_structure,
    COUNT(*)                                            AS client_count,
    ROUND(SUM(bank_loans), 2)                           AS total_bank_loans,
    ROUND(AVG(bank_loans), 2)                           AS avg_bank_loan,
    ROUND(SUM(business_lending), 2)                     AS total_business_lending
FROM banking
GROUP BY fee_structure
ORDER BY FIELD(fee_structure, 'High', 'Mid', 'Low');


-- ============================================================
-- SECTION 5 — DEPOSIT PORTFOLIO ANALYSIS
-- ============================================================

-- -------------------------------------------------------
-- 5.1 — Total deposit breakdown
-- -------------------------------------------------------
SELECT
    ROUND(SUM(bank_deposits), 2)                        AS total_bank_deposits,
    ROUND(SUM(saving_accounts), 2)                      AS total_saving_accounts,
    ROUND(SUM(checking_accounts), 2)                    AS total_checking_accounts,
    ROUND(SUM(foreign_currency_account), 2)             AS total_fx_accounts,
    ROUND(SUM(bank_deposits + saving_accounts +
              checking_accounts + foreign_currency_account), 2) AS total_deposits,
    ROUND(AVG(bank_deposits), 2)                        AS avg_deposit_per_client
FROM banking;

-- -------------------------------------------------------
-- 5.2 — Deposits by Banking Relationship
-- -------------------------------------------------------
SELECT
    CASE br_id
        WHEN 1 THEN 'Premium'
        WHEN 2 THEN 'Business'
        WHEN 3 THEN 'Personal'
        WHEN 4 THEN 'SME'
    END AS banking_relationship,
    COUNT(*)                                            AS client_count,
    ROUND(SUM(bank_deposits), 2)                        AS total_bank_deposits,
    ROUND(SUM(saving_accounts), 2)                      AS total_saving,
    ROUND(SUM(checking_accounts), 2)                    AS total_checking,
    ROUND(SUM(foreign_currency_account), 2)             AS total_fx,
    ROUND(SUM(bank_deposits + saving_accounts +
              checking_accounts + foreign_currency_account), 2) AS total_deposit
FROM banking
GROUP BY br_id
ORDER BY total_deposit DESC;

-- -------------------------------------------------------
-- 5.3 — Deposits by Nationality
-- -------------------------------------------------------
SELECT
    nationality,
    COUNT(*)                                            AS client_count,
    ROUND(SUM(bank_deposits), 2)                        AS total_deposits,
    ROUND(AVG(bank_deposits), 2)                        AS avg_deposit,
    ROUND(SUM(bank_deposits) * 100.0 /
        (SELECT SUM(bank_deposits) FROM banking), 2)    AS pct_of_total_deposits
FROM banking
GROUP BY nationality
ORDER BY total_deposits DESC;

-- -------------------------------------------------------
-- 5.4 — Deposits by Gender
-- -------------------------------------------------------
SELECT
    CASE gender_id WHEN 1 THEN 'Male' WHEN 2 THEN 'Female' END AS gender,
    COUNT(*)                                            AS client_count,
    ROUND(SUM(bank_deposits), 2)                        AS total_deposits,
    ROUND(AVG(bank_deposits), 2)                        AS avg_deposit,
    ROUND(SUM(saving_accounts), 2)                      AS total_saving,
    ROUND(SUM(checking_accounts), 2)                    AS total_checking
FROM banking
GROUP BY gender_id
ORDER BY gender_id;

-- -------------------------------------------------------
-- 5.5 — Deposits by Income Band
-- -------------------------------------------------------
SELECT
    CASE
        WHEN estimated_income < 100000 THEN 'Low'
        WHEN estimated_income < 300000 THEN 'Mid'
        ELSE 'High'
    END AS income_band,
    COUNT(*)                                            AS client_count,
    ROUND(SUM(bank_deposits), 2)                        AS total_deposits,
    ROUND(AVG(bank_deposits), 2)                        AS avg_deposit,
    ROUND(SUM(saving_accounts), 2)                      AS total_saving,
    ROUND(SUM(checking_accounts), 2)                    AS total_checking
FROM banking
GROUP BY income_band
ORDER BY FIELD(income_band, 'Low', 'Mid', 'High');

-- -------------------------------------------------------
-- 5.6 — Top 10 Occupations by Deposit Volume
-- -------------------------------------------------------
SELECT
    occupation,
    COUNT(*)                                            AS client_count,
    ROUND(SUM(bank_deposits), 2)                        AS total_deposits,
    ROUND(AVG(bank_deposits), 2)                        AS avg_deposit
FROM banking
GROUP BY occupation
ORDER BY total_deposits DESC
LIMIT 10;

-- -------------------------------------------------------
-- 5.7 — Deposits by Loyalty Classification
-- -------------------------------------------------------
SELECT
    loyalty_classification,
    CASE br_id
        WHEN 1 THEN 'Premium'
        WHEN 2 THEN 'Business'
        WHEN 3 THEN 'Personal'
        WHEN 4 THEN 'SME'
    END AS banking_relationship,
    COUNT(*)                                            AS client_count,
    ROUND(SUM(bank_deposits), 2)                        AS total_deposits,
    ROUND(AVG(bank_deposits), 2)                        AS avg_deposit
FROM banking
GROUP BY loyalty_classification, br_id
ORDER BY loyalty_classification, total_deposits DESC;


-- ============================================================
-- SECTION 6 — RISK ANALYSIS
-- ============================================================

-- -------------------------------------------------------
-- 6.1 — Portfolio risk overview
-- -------------------------------------------------------
SELECT
    -- High Risk: loan above average
    SUM(CASE WHEN bank_loans >
        (SELECT AVG(bank_loans) FROM banking)
        THEN 1 ELSE 0 END)                              AS high_risk_loan_clients,

    -- Overleveraged: loan > deposit
    SUM(CASE WHEN bank_loans > bank_deposits
        THEN 1 ELSE 0 END)                              AS overleveraged_clients,

    -- High Loan Low Income
    SUM(CASE WHEN estimated_income < 100000
        AND bank_loans > (SELECT AVG(bank_loans) FROM banking)
        THEN 1 ELSE 0 END)                              AS high_loan_low_income_clients,

    -- Total records. Note this is NOT the same as distinct clients on this
    -- data — see 1.2 and 1.2b; the two differ by 60.
    COUNT(*)                                            AS total_records,

    -- Loan to Deposit Ratio
    ROUND(SUM(bank_loans + business_lending + credit_card_balance) /
          NULLIF(SUM(bank_deposits + saving_accounts +
                     checking_accounts + foreign_currency_account), 0), 4) AS loan_to_deposit_ratio,

    -- Credit Risk Ratio
    ROUND(SUM(credit_card_balance) /
          NULLIF(SUM(bank_loans + business_lending + credit_card_balance), 0), 4) AS credit_risk_ratio
FROM banking;

-- -------------------------------------------------------
-- 6.2 — Loan Concentration by Nationality
-- -------------------------------------------------------
SELECT
    nationality,
    CASE
        WHEN estimated_income < 100000 THEN 'Low'
        WHEN estimated_income < 300000 THEN 'Mid'
        ELSE 'High'
    END AS income_band,
    COUNT(*)                                            AS client_count,
    ROUND(SUM(bank_loans), 2)                           AS total_loans,
    ROUND(SUM(bank_loans) * 100.0 /
        (SELECT SUM(bank_loans) FROM banking), 2)       AS loan_concentration_pct
FROM banking
GROUP BY nationality, income_band
ORDER BY nationality, loan_concentration_pct DESC;

-- -------------------------------------------------------
-- 6.3 — Loan to Deposit Ratio by Banking Relationship
-- -------------------------------------------------------
SELECT
    CASE br_id
        WHEN 1 THEN 'Premium'
        WHEN 2 THEN 'Business'
        WHEN 3 THEN 'Personal'
        WHEN 4 THEN 'SME'
    END AS banking_relationship,
    COUNT(*)                                            AS client_count,
    ROUND(SUM(bank_loans + business_lending + credit_card_balance), 2)   AS total_loan,
    ROUND(SUM(bank_deposits + saving_accounts +
              checking_accounts + foreign_currency_account), 2)           AS total_deposit,
    ROUND(SUM(bank_loans + business_lending + credit_card_balance) /
          NULLIF(SUM(bank_deposits + saving_accounts +
                     checking_accounts + foreign_currency_account), 0), 4) AS loan_to_deposit_ratio
FROM banking
GROUP BY br_id
ORDER BY loan_to_deposit_ratio DESC;

-- -------------------------------------------------------
-- 6.4 — High Loan Low Income Clients by Nationality
-- High risk: low income + loan above portfolio average
-- -------------------------------------------------------
SELECT
    nationality,
    COUNT(*)                                            AS high_loan_low_income_count,
    ROUND(AVG(bank_loans), 2)                           AS avg_loan,
    ROUND(AVG(estimated_income), 2)                     AS avg_income,
    ROUND(SUM(bank_loans), 2)                           AS total_loan_exposure
FROM banking
WHERE estimated_income < 100000
  AND bank_loans > (SELECT AVG(bank_loans) FROM banking)
GROUP BY nationality
ORDER BY high_loan_low_income_count DESC;

-- -------------------------------------------------------
-- 6.5 — Risk by Engagement Timeframe
-- Long-term clients carrying high loans
-- -------------------------------------------------------
SELECT
    CASE
        WHEN DATEDIFF(CURDATE(), joined_bank) < 365   THEN 'Less than 1 Year'
        WHEN DATEDIFF(CURDATE(), joined_bank) < 1825  THEN '1-5 Years'
        WHEN DATEDIFF(CURDATE(), joined_bank) < 3650  THEN '5-10 Years'
        ELSE '10+ Years'
    END AS engagement_timeframe,
    COUNT(*)                                            AS client_count,
    SUM(CASE WHEN bank_loans >
        (SELECT AVG(bank_loans) FROM banking)
        THEN 1 ELSE 0 END)                              AS high_risk_count,
    ROUND(AVG(bank_loans), 2)                           AS avg_loan,
    ROUND(AVG(bank_deposits), 2)                        AS avg_deposit
FROM banking
GROUP BY engagement_timeframe
ORDER BY FIELD(engagement_timeframe,
    'Less than 1 Year', '1-5 Years', '5-10 Years', '10+ Years');

-- -------------------------------------------------------
-- 6.6 — Risk by Age Band
-- Average loan burden across age segments
-- -------------------------------------------------------
SELECT
    CASE
        WHEN age < 31 THEN '18-30'
        WHEN age < 46 THEN '31-45'
        WHEN age < 61 THEN '46-60'
        ELSE '61+'
    END AS age_band,
    COUNT(*)                                            AS client_count,
    ROUND(AVG(bank_loans), 2)                           AS avg_loan,
    ROUND(AVG(bank_deposits), 2)                        AS avg_deposit,
    SUM(CASE WHEN bank_loans > bank_deposits
        THEN 1 ELSE 0 END)                              AS overleveraged_count,
    ROUND(AVG(bank_loans) / NULLIF(AVG(bank_deposits), 0), 4) AS avg_ldr
FROM banking
GROUP BY age_band
ORDER BY FIELD(age_band, '18-30', '31-45', '46-60', '61+');

-- -------------------------------------------------------
-- 6.7 — Credit Card Exposure by Banking Relationship
-- -------------------------------------------------------
SELECT
    CASE br_id
        WHEN 1 THEN 'Premium'
        WHEN 2 THEN 'Business'
        WHEN 3 THEN 'Personal'
        WHEN 4 THEN 'SME'
    END AS banking_relationship,
    COUNT(*)                                            AS client_count,
    ROUND(SUM(credit_card_balance), 2)                  AS total_cc_balance,
    ROUND(AVG(credit_card_balance), 2)                  AS avg_cc_balance,
    ROUND(SUM(credit_card_balance) * 100.0 /
        (SELECT SUM(credit_card_balance) FROM banking), 2) AS pct_of_total_cc
FROM banking
GROUP BY br_id
ORDER BY total_cc_balance DESC;


-- ============================================================
-- SECTION 7 — GROWTH & TREND ANALYSIS
-- ============================================================

-- -------------------------------------------------------
-- 7.1 — Client acquisition by year
-- -------------------------------------------------------
SELECT
    YEAR(joined_bank)                                   AS joining_year,
    COUNT(*)                                            AS new_clients,
    ROUND(SUM(bank_loans), 2)                           AS total_loans,
    ROUND(SUM(bank_deposits), 2)                        AS total_deposits,
    ROUND(AVG(estimated_income), 2)                     AS avg_income
FROM banking
GROUP BY joining_year
ORDER BY joining_year;

-- -------------------------------------------------------
-- 7.2 — Cumulative client growth over time
-- -------------------------------------------------------
SELECT
    YEAR(joined_bank)                                   AS joining_year,
    COUNT(*)                                            AS new_clients,
    SUM(COUNT(*)) OVER (ORDER BY YEAR(joined_bank))     AS cumulative_clients
FROM banking
GROUP BY joining_year
ORDER BY joining_year;

-- -------------------------------------------------------
-- 7.3 — YoY client growth rate
-- -------------------------------------------------------
SELECT
    joining_year,
    new_clients,
    LAG(new_clients) OVER (ORDER BY joining_year)       AS prior_year_clients,
    ROUND((new_clients - LAG(new_clients) OVER (ORDER BY joining_year)) * 100.0 /
          NULLIF(LAG(new_clients) OVER (ORDER BY joining_year), 0), 2) AS yoy_growth_pct
FROM (
    SELECT
        YEAR(joined_bank) AS joining_year,
        COUNT(*)          AS new_clients
    FROM banking
    GROUP BY joining_year
) yearly
ORDER BY joining_year;

-- -------------------------------------------------------
-- 7.4 — YoY loan volume growth
-- -------------------------------------------------------
SELECT
    joining_year,
    total_loans,
    LAG(total_loans) OVER (ORDER BY joining_year)       AS prior_year_loans,
    ROUND((total_loans - LAG(total_loans) OVER (ORDER BY joining_year)) * 100.0 /
          NULLIF(LAG(total_loans) OVER (ORDER BY joining_year), 0), 2) AS yoy_loan_growth_pct
FROM (
    SELECT
        YEAR(joined_bank)       AS joining_year,
        ROUND(SUM(bank_loans), 2) AS total_loans
    FROM banking
    GROUP BY joining_year
) yearly
ORDER BY joining_year;

-- -------------------------------------------------------
-- 7.5 — Client growth by Nationality per year
-- -------------------------------------------------------
SELECT
    YEAR(joined_bank)                                   AS joining_year,
    nationality,
    COUNT(*)                                            AS new_clients
FROM banking
GROUP BY joining_year, nationality
ORDER BY joining_year, new_clients DESC;

-- -------------------------------------------------------
-- 7.6 — Client growth by Loyalty Classification over time
-- -------------------------------------------------------
SELECT
    YEAR(joined_bank)                                   AS joining_year,
    loyalty_classification,
    COUNT(*)                                            AS new_clients
FROM banking
GROUP BY joining_year, loyalty_classification
ORDER BY joining_year, loyalty_classification;


-- ============================================================
-- SECTION 8 — REVENUE & PROFITABILITY ANALYSIS
-- ============================================================

-- -------------------------------------------------------
-- 8.1 — Total fee revenue overview
-- -------------------------------------------------------
SELECT
    ROUND(SUM(
        (bank_loans + business_lending + credit_card_balance) *
        CASE fee_structure
            WHEN 'High' THEN 0.05
            WHEN 'Mid'  THEN 0.03
            ELSE 0.01
        END
    ), 2)                                               AS total_fee_revenue,

    ROUND(SUM(
        (bank_loans + business_lending + credit_card_balance) *
        CASE fee_structure
            WHEN 'High' THEN 0.05
            WHEN 'Mid'  THEN 0.03
            ELSE 0.01
        END
    ) / COUNT(*), 2)                                    AS avg_fee_per_client,

    ROUND(SUM(
        (bank_loans + business_lending + credit_card_balance) *
        CASE fee_structure
            WHEN 'High' THEN 0.05
            WHEN 'Mid'  THEN 0.03
            ELSE 0.01
        END
    ) / NULLIF(SUM(bank_loans + business_lending + credit_card_balance), 0), 4) AS revenue_per_loan_dollar
FROM banking;

-- -------------------------------------------------------
-- 8.2 — Fee Revenue by Banking Relationship × Loyalty
-- -------------------------------------------------------
SELECT
    CASE br_id
        WHEN 1 THEN 'Premium'
        WHEN 2 THEN 'Business'
        WHEN 3 THEN 'Personal'
        WHEN 4 THEN 'SME'
    END AS banking_relationship,
    loyalty_classification,
    COUNT(*)                                            AS client_count,
    ROUND(SUM(
        (bank_loans + business_lending + credit_card_balance) *
        CASE fee_structure
            WHEN 'High' THEN 0.05
            WHEN 'Mid'  THEN 0.03
            ELSE 0.01
        END
    ), 2)                                               AS total_fee_revenue,
    ROUND(AVG(
        (bank_loans + business_lending + credit_card_balance) *
        CASE fee_structure
            WHEN 'High' THEN 0.05
            WHEN 'Mid'  THEN 0.03
            ELSE 0.01
        END
    ), 2)                                               AS avg_fee_per_client
FROM banking
GROUP BY br_id, loyalty_classification
ORDER BY total_fee_revenue DESC;

-- -------------------------------------------------------
-- 8.3 — Fee Revenue by Income Band × Fee Structure
-- -------------------------------------------------------
SELECT
    CASE
        WHEN estimated_income < 100000 THEN 'Low'
        WHEN estimated_income < 300000 THEN 'Mid'
        ELSE 'High'
    END AS income_band,
    fee_structure,
    COUNT(*)                                            AS client_count,
    ROUND(SUM(
        (bank_loans + business_lending + credit_card_balance) *
        CASE fee_structure
            WHEN 'High' THEN 0.05
            WHEN 'Mid'  THEN 0.03
            ELSE 0.01
        END
    ), 2)                                               AS total_fee_revenue
FROM banking
GROUP BY income_band, fee_structure
ORDER BY FIELD(income_band, 'Low', 'Mid', 'High'), total_fee_revenue DESC;

-- -------------------------------------------------------
-- 8.4 — Fee Revenue Trend by Year
-- -------------------------------------------------------
SELECT
    YEAR(joined_bank)                                   AS joining_year,
    fee_structure,
    ROUND(SUM(
        (bank_loans + business_lending + credit_card_balance) *
        CASE fee_structure
            WHEN 'High' THEN 0.05
            WHEN 'Mid'  THEN 0.03
            ELSE 0.01
        END
    ), 2)                                               AS total_fee_revenue
FROM banking
GROUP BY joining_year, fee_structure
ORDER BY joining_year, FIELD(fee_structure, 'High', 'Mid', 'Low');

-- -------------------------------------------------------
-- 8.5 — Avg Fee Per Client by Loyalty Classification
-- -------------------------------------------------------
SELECT
    loyalty_classification,
    CASE
        WHEN estimated_income < 100000 THEN 'Low'
        WHEN estimated_income < 300000 THEN 'Mid'
        ELSE 'High'
    END AS income_band,
    COUNT(*)                                            AS client_count,
    ROUND(AVG(
        (bank_loans + business_lending + credit_card_balance) *
        CASE fee_structure
            WHEN 'High' THEN 0.05
            WHEN 'Mid'  THEN 0.03
            ELSE 0.01
        END
    ), 2)                                               AS avg_fee_per_client
FROM banking
GROUP BY loyalty_classification, income_band
ORDER BY avg_fee_per_client DESC;

-- -------------------------------------------------------
-- 8.6 — Fee Revenue by Nationality
-- -------------------------------------------------------
SELECT
    nationality,
    COUNT(*)                                            AS client_count,
    ROUND(SUM(
        (bank_loans + business_lending + credit_card_balance) *
        CASE fee_structure
            WHEN 'High' THEN 0.05
            WHEN 'Mid'  THEN 0.03
            ELSE 0.01
        END
    ), 2)                                               AS total_fee_revenue,
    ROUND(SUM(
        (bank_loans + business_lending + credit_card_balance) *
        CASE fee_structure
            WHEN 'High' THEN 0.05
            WHEN 'Mid'  THEN 0.03
            ELSE 0.01
        END
    ) * 100.0 / SUM(SUM(
        (bank_loans + business_lending + credit_card_balance) *
        CASE fee_structure
            WHEN 'High' THEN 0.05
            WHEN 'Mid'  THEN 0.03
            ELSE 0.01
        END
    )) OVER (), 2)                                      AS pct_of_total_fees
FROM banking
GROUP BY nationality
ORDER BY total_fee_revenue DESC;


-- ============================================================
-- SECTION 9 — VIEWS FOR POWER BI
-- ============================================================
-- These views can be connected directly into Power BI
-- via Get Data → SQL Server / MySQL

-- -------------------------------------------------------
-- 9.1 — Master cleaned view with all derived columns
-- -------------------------------------------------------
CREATE OR REPLACE VIEW vw_banking_master AS
SELECT
    client_id,
    name,
    age,
    CASE
        WHEN age < 31 THEN '18-30'
        WHEN age < 46 THEN '31-45'
        WHEN age < 61 THEN '46-60'
        ELSE '61+'
    END                                                 AS age_band,
    joined_bank,
    YEAR(joined_bank)                                   AS joining_year,
    DATEDIFF(CURDATE(), joined_bank)                    AS engagement_days,
    CASE
        WHEN DATEDIFF(CURDATE(), joined_bank) < 365   THEN 'Less than 1 Year'
        WHEN DATEDIFF(CURDATE(), joined_bank) < 1825  THEN '1-5 Years'
        WHEN DATEDIFF(CURDATE(), joined_bank) < 3650  THEN '5-10 Years'
        ELSE '10+ Years'
    END                                                 AS engagement_timeframe,
    nationality,
    occupation,
    fee_structure,
    CASE fee_structure
        WHEN 'High' THEN 0.05
        WHEN 'Mid'  THEN 0.03
        ELSE 0.01
    END                                                 AS processing_fee_rate,
    loyalty_classification,
    estimated_income,
    CASE
        WHEN estimated_income < 100000 THEN 'Low'
        WHEN estimated_income < 300000 THEN 'Mid'
        ELSE 'High'
    END                                                 AS income_band,
    superannuation_savings,
    amount_of_credit_cards,
    credit_card_balance,
    bank_loans,
    bank_deposits,
    checking_accounts,
    saving_accounts,
    foreign_currency_account,
    business_lending,
    (bank_loans + business_lending + credit_card_balance)           AS total_loan,
    (bank_deposits + saving_accounts + checking_accounts + foreign_currency_account) AS total_deposit,
    (bank_loans + business_lending + credit_card_balance) *
        CASE fee_structure
            WHEN 'High' THEN 0.05
            WHEN 'Mid'  THEN 0.03
            ELSE 0.01
        END                                             AS fee_revenue,
    properties_owned,
    risk_weighting,
    CASE br_id
        WHEN 1 THEN 'Premium'
        WHEN 2 THEN 'Business'
        WHEN 3 THEN 'Personal'
        WHEN 4 THEN 'SME'
    END                                                 AS banking_relationship,
    CASE gender_id
        WHEN 1 THEN 'Male'
        WHEN 2 THEN 'Female'
    END                                                 AS gender,
    ia_id
FROM banking;

-- -------------------------------------------------------
-- 9.2 — Risk summary view
-- -------------------------------------------------------
CREATE OR REPLACE VIEW vw_risk_summary AS
SELECT
    client_id,
    nationality,
    CASE br_id
        WHEN 1 THEN 'Premium'
        WHEN 2 THEN 'Business'
        WHEN 3 THEN 'Personal'
        WHEN 4 THEN 'SME'
    END                                                 AS banking_relationship,
    CASE
        WHEN estimated_income < 100000 THEN 'Low'
        WHEN estimated_income < 300000 THEN 'Mid'
        ELSE 'High'
    END                                                 AS income_band,
    bank_loans,
    bank_deposits,
    business_lending,
    credit_card_balance,
    (bank_loans + business_lending + credit_card_balance)           AS total_loan,
    (bank_deposits + saving_accounts + checking_accounts + foreign_currency_account) AS total_deposit,
    CASE WHEN bank_loans > (SELECT AVG(bank_loans) FROM banking)
        THEN 'High Risk' ELSE 'Standard' END            AS loan_risk_flag,
    CASE WHEN bank_loans > bank_deposits
        THEN 'Overleveraged' ELSE 'Balanced' END        AS leverage_flag,
    CASE WHEN estimated_income < 100000
        AND bank_loans > (SELECT AVG(bank_loans) FROM banking)
        THEN 'High Risk Low Income' ELSE 'Standard' END AS combined_risk_flag
FROM banking;

-- -------------------------------------------------------
-- 9.3 — Profitability summary view
-- -------------------------------------------------------
CREATE OR REPLACE VIEW vw_profitability AS
SELECT
    client_id,
    nationality,
    loyalty_classification,
    fee_structure,
    CASE br_id
        WHEN 1 THEN 'Premium'
        WHEN 2 THEN 'Business'
        WHEN 3 THEN 'Personal'
        WHEN 4 THEN 'SME'
    END                                                 AS banking_relationship,
    CASE
        WHEN estimated_income < 100000 THEN 'Low'
        WHEN estimated_income < 300000 THEN 'Mid'
        ELSE 'High'
    END                                                 AS income_band,
    (bank_loans + business_lending + credit_card_balance)           AS total_loan,
    CASE fee_structure
        WHEN 'High' THEN 0.05
        WHEN 'Mid'  THEN 0.03
        ELSE 0.01
    END                                                 AS fee_rate,
    (bank_loans + business_lending + credit_card_balance) *
        CASE fee_structure
            WHEN 'High' THEN 0.05
            WHEN 'Mid'  THEN 0.03
            ELSE 0.01
        END                                             AS fee_revenue,
    YEAR(joined_bank)                                   AS joining_year
FROM banking;


-- ============================================================
-- SECTION 10 — EXECUTIVE SUMMARY
-- ============================================================

-- -------------------------------------------------------
-- 10.1 — Full portfolio executive snapshot
-- -------------------------------------------------------
SELECT
    -- See section 3.1: records and distinct clients diverge by 60 on this data.
    COUNT(*)                                            AS total_records,
    COUNT(DISTINCT client_id)                           AS distinct_client_ids,

    -- Loan metrics
    ROUND(SUM(bank_loans), 2)                           AS total_bank_loans,
    ROUND(SUM(business_lending), 2)                     AS total_business_lending,
    ROUND(SUM(credit_card_balance), 2)                  AS total_cc_balance,
    ROUND(SUM(bank_loans + business_lending + credit_card_balance), 2) AS total_loan_exposure,

    -- Deposit metrics
    ROUND(SUM(bank_deposits + saving_accounts +
              checking_accounts + foreign_currency_account), 2) AS total_deposits,

    -- Ratios
    ROUND(SUM(bank_loans + business_lending + credit_card_balance) /
          NULLIF(SUM(bank_deposits + saving_accounts +
                     checking_accounts + foreign_currency_account), 0), 4) AS loan_to_deposit_ratio,

    -- Revenue
    ROUND(SUM(
        (bank_loans + business_lending + credit_card_balance) *
        CASE fee_structure
            WHEN 'High' THEN 0.05
            WHEN 'Mid'  THEN 0.03
            ELSE 0.01
        END
    ), 2)                                               AS total_fee_revenue,

    -- Risk
    SUM(CASE WHEN bank_loans >
        (SELECT AVG(bank_loans) FROM banking)
        THEN 1 ELSE 0 END)                              AS high_risk_loan_clients,

    SUM(CASE WHEN bank_loans > bank_deposits
        THEN 1 ELSE 0 END)                              AS overleveraged_clients,

    -- Averages
    ROUND(AVG(estimated_income), 2)                     AS avg_client_income,
    ROUND(AVG(bank_loans), 2)                           AS avg_loan_per_client,
    ROUND(AVG(bank_deposits), 2)                        AS avg_deposit_per_client

FROM banking;

-- -------------------------------------------------------
-- 10.2 — Full segment comparison (BR × Income Band)
-- -------------------------------------------------------
SELECT
    CASE br_id
        WHEN 1 THEN 'Premium'
        WHEN 2 THEN 'Business'
        WHEN 3 THEN 'Personal'
        WHEN 4 THEN 'SME'
    END AS banking_relationship,
    CASE
        WHEN estimated_income < 100000 THEN 'Low'
        WHEN estimated_income < 300000 THEN 'Mid'
        ELSE 'High'
    END AS income_band,
    COUNT(*)                                            AS client_count,
    ROUND(SUM(bank_loans), 2)                           AS total_loans,
    ROUND(SUM(bank_deposits), 2)                        AS total_deposits,
    ROUND(SUM(
        (bank_loans + business_lending + credit_card_balance) *
        CASE fee_structure
            WHEN 'High' THEN 0.05
            WHEN 'Mid'  THEN 0.03
            ELSE 0.01
        END
    ), 2)                                               AS fee_revenue,
    SUM(CASE WHEN bank_loans > bank_deposits
        THEN 1 ELSE 0 END)                              AS overleveraged_count
FROM banking
GROUP BY br_id, income_band
ORDER BY br_id, FIELD(income_band, 'Low', 'Mid', 'High');

-- ============================================================
-- END OF SCRIPT
-- Banking Risk Analytics — SQL Component
-- ============================================================
