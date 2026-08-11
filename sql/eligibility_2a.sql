-- =============================================================================
-- Target 1A 2a — Enfortumab-eligible
-- =============================================================================
-- Protocol: Cohort 1 + washout + combination-therapy eligible + enfortumab-
-- eligible. Index/end dates inherited from Cohort 1 (metastasis).
--
-- SqlRender parameters:
--   @target_database_schema, @target_cohort_table, @target_cohort_id
--   @lab_cohort_table   — eligibility measurement table (lab_cohorts.sql output)
--   @regimen_episode_table
--   @cohort1_id
--
-- Eligibility rows: cohort_definition_id = test_id in @lab_cohort_table.
-- Each qualifying measurement must fall within [index - 14, index + 14] days
-- unless noted otherwise.
--
-- test_id reference (lab_cohorts.sql #criteria, ids 1-23):
--   1  aPTT <= 1.5 ULN          14 GFR >= 30 mL/min
--   2  ALT <= 2.5 ULN            15 Hb >= 9.0 g/dL
--   3  ALT <= 5 ULN              16 HbA1c 7-8%
--   4  ANC >= 1500/uL            17 HbA1c < 6%
--   5  AST <= 2.5 ULN            18 INR <= 1.5 ULN
--   6  AST <= 5 ULN              19 Platelets >= 100k/uL
--   7  CrCl >= 30 mL/min         20 PT <= 1.5 ULN
--   8  Creatinine <= 1.5 ULN     21 TBil <= 3 ULN (Gilbert's; needs test 29)
--   9  DBil <= ULN               22 TBil <= 1.5 ULN
--                              23 TBil > 1.5 ULN
--
-- Planned test_ids (not yet in lab_cohorts.sql):
--   24 ECOG 0   25 ECOG 1   26 ECOG 2   28 Liver metastasis
--   30 Hb >= 5.6 mmol/L   32 Neuropathy grade < 2   34 No skin disorder
--   35 No polyuria   36 No polydipsia (for HbA1c 7-8% path with test 16)
--
-- NOTE on query shape — Redshift restriction: a correlated subquery cannot
-- appear inside an OR predicate ("This type of correlated subquery pattern is
-- not supported due to internal error", error 500310). This template used to
-- express every lab/condition check as EXISTS(...)/NOT EXISTS(...), several of
-- them OR-combined (e.g. Cr OR CrCl; the TBil/AST/ALT/coag alternatives) —
-- Redshift rejects that shape outright. Instead we join the base cohort to
-- @lab_cohort_table ONCE (keyed on subject only), collapse each test_id into a
-- 0/1 flag per subject via conditional aggregation (no correlation), and then
-- apply the eligibility logic as plain boolean algebra over those flags. Same
-- semantics as the EXISTS version (a flag is 1 iff a qualifying record exists
-- for that subject in the relevant window), same eligibility_2b/2c/2d pattern.
--
-- NOTE on statement shape — `WITH ... INSERT INTO ...` vs `INSERT INTO ...
-- WITH ...` is NOT portable: Snowflake requires the WITH nested after the
-- INSERT's column list (confirmed live), while SQL Server (T-SQL) requires
-- WITH to precede INSERT entirely — SqlRender does not rewrite clause order
-- across dialects, so neither placement alone works everywhere. We sidestep
-- this by materialising the CTE result into a #temp table via the
-- SqlRender-portable `SELECT ... INTO #temp FROM ...` idiom (translates to
-- native SELECT INTO on SQL Server, CREATE TEMP TABLE AS on
-- Postgres/Redshift/Snowflake — same idiom already used across OHDSI SQL),
-- then a plain, CTE-free INSERT INTO ... SELECT FROM #temp.
-- =============================================================================

DELETE FROM @target_database_schema.@target_cohort_table
 WHERE cohort_definition_id = @target_cohort_id;

DROP TABLE IF EXISTS #elig2a_tmp;

WITH base AS (
  SELECT tc.subject_id, tc.cohort_start_date, tc.cohort_end_date,
         DATEADD(day, -@lab_window_before_days, tc.cohort_start_date) AS win_lo,
         DATEADD(day,  @lab_window_after_days,  tc.cohort_start_date) AS win_hi
    FROM @target_database_schema.@target_cohort_table tc
   WHERE tc.cohort_definition_id = @cohort1_id

     /* ----- Washout: no systemic regimen in [index - 365, index - 30) ----- */
     AND NOT EXISTS (
           SELECT 1
             FROM @target_database_schema.@regimen_episode_table re
            WHERE CAST(re.person_id AS BIGINT) = tc.subject_id
              AND re.episode_start_date <  DATEADD(day, -30, tc.cohort_start_date)
              AND re.episode_end_date   >= DATEADD(day, -365, tc.cohort_start_date)
         )
),
labs AS (
  SELECT b.subject_id, b.cohort_start_date, b.cohort_end_date, b.win_lo, b.win_hi,
         lab.cohort_definition_id AS test_id, lab.cohort_start_date AS lab_date
    FROM base b
    LEFT JOIN @target_database_schema.@lab_cohort_table lab
      ON lab.subject_id = b.subject_id
     AND lab.cohort_start_date <= b.win_hi   -- every criterion below needs at most this upper bound
),
flags AS (
  SELECT subject_id, cohort_start_date, cohort_end_date,
    MAX(CASE WHEN test_id IN (24, 25, 26)           AND lab_date BETWEEN win_lo AND win_hi THEN 1 ELSE 0 END) AS f_ecog_0_2,
    MAX(CASE WHEN test_id = 14                      AND lab_date BETWEEN win_lo AND win_hi THEN 1 ELSE 0 END) AS f_gfr30,
    MAX(CASE WHEN test_id = 4                       AND lab_date BETWEEN win_lo AND win_hi THEN 1 ELSE 0 END) AS f_anc,
    MAX(CASE WHEN test_id = 19                      AND lab_date BETWEEN win_lo AND win_hi THEN 1 ELSE 0 END) AS f_plt,
    MAX(CASE WHEN test_id = 15                      AND lab_date BETWEEN win_lo AND win_hi THEN 1 ELSE 0 END) AS f_hb,
    MAX(CASE WHEN test_id = 8                       AND lab_date BETWEEN win_lo AND win_hi THEN 1 ELSE 0 END) AS f_cr,
    MAX(CASE WHEN test_id = 7                       AND lab_date BETWEEN win_lo AND win_hi THEN 1 ELSE 0 END) AS f_crcl,
    MAX(CASE WHEN test_id = 22                      AND lab_date BETWEEN win_lo AND win_hi THEN 1 ELSE 0 END) AS f_tbil_le15,
    MAX(CASE WHEN test_id = 23                      AND lab_date BETWEEN win_lo AND win_hi THEN 1 ELSE 0 END) AS f_tbil_gt15,
    MAX(CASE WHEN test_id = 9                       AND lab_date BETWEEN win_lo AND win_hi THEN 1 ELSE 0 END) AS f_dbil,
    MAX(CASE WHEN test_id = 21                      AND lab_date BETWEEN win_lo AND win_hi THEN 1 ELSE 0 END) AS f_tbil_le3,
    MAX(CASE WHEN test_id = 29                      AND lab_date <= win_hi                 THEN 1 ELSE 0 END) AS f_gilbert,
    MAX(CASE WHEN test_id = 5                       AND lab_date BETWEEN win_lo AND win_hi THEN 1 ELSE 0 END) AS f_ast_le25,
    MAX(CASE WHEN test_id = 6                       AND lab_date BETWEEN win_lo AND win_hi THEN 1 ELSE 0 END) AS f_ast_le5,
    MAX(CASE WHEN test_id = 28                      AND lab_date <= win_hi                 THEN 1 ELSE 0 END) AS f_livermet,
    MAX(CASE WHEN test_id = 2                       AND lab_date BETWEEN win_lo AND win_hi THEN 1 ELSE 0 END) AS f_alt_le25,
    MAX(CASE WHEN test_id = 3                       AND lab_date BETWEEN win_lo AND win_hi THEN 1 ELSE 0 END) AS f_alt_le5,
    MAX(CASE WHEN test_id = 18                      AND lab_date BETWEEN win_lo AND win_hi THEN 1 ELSE 0 END) AS f_inr,
    MAX(CASE WHEN test_id = 31                      AND lab_date BETWEEN win_lo AND win_hi THEN 1 ELSE 0 END) AS f_anticoag,
    MAX(CASE WHEN test_id = 20                      AND lab_date BETWEEN win_lo AND win_hi THEN 1 ELSE 0 END) AS f_pt,
    MAX(CASE WHEN test_id = 1                       AND lab_date BETWEEN win_lo AND win_hi THEN 1 ELSE 0 END) AS f_aptt,
    MAX(CASE WHEN test_id = 17                      AND lab_date BETWEEN win_lo AND win_hi THEN 1 ELSE 0 END) AS f_hba1c_lt6,
    MAX(CASE WHEN test_id = 16                      AND lab_date BETWEEN win_lo AND win_hi THEN 1 ELSE 0 END) AS f_hba1c_7_8,
    MAX(CASE WHEN test_id = 35                      AND lab_date BETWEEN win_lo AND win_hi THEN 1 ELSE 0 END) AS f_polyuria,
    MAX(CASE WHEN test_id = 36                      AND lab_date BETWEEN win_lo AND win_hi THEN 1 ELSE 0 END) AS f_polydipsia,
    MAX(CASE WHEN test_id = 33                      AND lab_date <= win_hi                 THEN 1 ELSE 0 END) AS f_neuropathy,
    MAX(CASE WHEN test_id = 34                      AND lab_date <= win_hi                 THEN 1 ELSE 0 END) AS f_skin
  FROM labs
  GROUP BY subject_id, cohort_start_date, cohort_end_date
)
SELECT subject_id, cohort_start_date, cohort_end_date
  INTO #elig2a_tmp
  FROM flags
 WHERE

   /* ----- Combination-therapy eligible ----- */
       f_ecog_0_2 = 1        -- [24-26] ECOG 0-2 at index
   AND f_gfr30    = 1        -- [14] GFR >= 30 mL/min
   AND f_anc      = 1        -- [4]  ANC >= 1500/uL
   AND f_plt      = 1        -- [19] Platelets >= 100,000/uL
   AND f_hb       = 1        -- [15] Hb >= 9.0 g/dL

   -- Creatinine: [8] Cr <= 1.5 ULN  OR  [7] CrCl >= 30
   AND (f_cr = 1 OR f_crcl = 1)

   -- Bilirubin: [22] TBil <= 1.5 ULN
   --         OR ([23] TBil > 1.5 ULN AND [9] DBil <= ULN)
   --         OR ([21] TBil <= 3 ULN AND Gilbert's syndrome [29])
   AND (
         f_tbil_le15 = 1
         OR (f_tbil_gt15 = 1 AND f_dbil    = 1)
         OR (f_tbil_le3  = 1 AND f_gilbert = 1)
       )

   -- AST: [5] <= 2.5 ULN  OR  ([6] <= 5 ULN AND [28] liver metastasis)
   AND (f_ast_le25 = 1 OR (f_ast_le5 = 1 AND f_livermet = 1))

   -- ALT: [2] <= 2.5 ULN  OR  ([3] <= 5 ULN AND [28] liver metastasis)
   AND (f_alt_le25 = 1 OR (f_alt_le5 = 1 AND f_livermet = 1))

   -- Coag: protocol (INR <= 1.5 ULN OR PT <= 1.5 ULN), aPTT <= 1.5 ULN
   -- separately; anticoagulant therapy (test 31) waives either limb.
   AND (f_inr = 1 OR f_pt = 1 OR f_anticoag = 1)
   AND (f_aptt = 1 OR f_anticoag = 1)

   /* ----- Enfortumab-eligible ----- */

   -- HbA1c: [17] < 6%  OR  ([16] 7-8% AND (NO polyuria [35] OR NO polydipsia [36]))
   --
   -- NOTE — polyuria/polydipsia limb follows the LITERAL Cohort logics.pdf spec,
   -- which is a fixed study requirement (implemented verbatim, not by discretion):
   --   "(NO Polyuria OR NO Polydipsia)"  =>  (NOT EXISTS 35) OR (NOT EXISTS 36).
   -- This excludes a 7-8% patient ONLY if they have BOTH polyuria AND polydipsia;
   -- a single symptom still passes, so the limb almost never fires.
   -- Known concern (recorded, NOT acted on here): clinically you would expect to
   -- exclude on EITHER symptom (AND), since both are cardinal signs of
   -- uncontrolled hyperglycaemia and EV carries a hyperglycaemia risk — and the
   -- PDF itself highlights this clause as "Need to discuss". DO NOT change the OR
   -- below to AND on clinical grounds alone: it encodes a stated requirement and
   -- may only change via a requirements/protocol update. See COHORT_AUDIT.md F4.
   AND (
         f_hba1c_lt6 = 1
         OR (f_hba1c_7_8 = 1 AND (f_polyuria = 0 OR f_polydipsia = 0))
       )

   -- Enfortumab: no significant peripheral neuropathy (test 33); pre-existing
   -- = any record on/before index+14d.
   AND f_neuropathy = 0

   -- Enfortumab: no pre-existing significant skin disorders (test 34).
   AND f_skin = 0
;

INSERT INTO @target_database_schema.@target_cohort_table
  (cohort_definition_id, subject_id, cohort_start_date, cohort_end_date)
SELECT @target_cohort_id AS cohort_definition_id,
       subject_id, cohort_start_date, cohort_end_date
  FROM #elig2a_tmp
;

DROP TABLE IF EXISTS #elig2a_tmp;
