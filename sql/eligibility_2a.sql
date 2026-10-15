-- =============================================================================
-- Target 1A 2a — Enfortumab-eligible
-- =============================================================================
-- Protocol: Cohort 1 + washout + combination-therapy eligible + enfortumab-
-- eligible. Index/end dates inherited from Cohort 1 (metastasis).
--
-- SqlRender parameters:
--   @target_database_schema, @target_cohort_table, @target_cohort_id
--   @lab_cohort_table   — eligibility measurement table (lab_cohorts.sql output)
--   eligibility_lab_rows_sql — eligibility_lab_rows.sql, rendered: the rows
--                         read below (closest lab value or any, per setting)
--   @regimen_episode_table
--   @cohort1_id
--
-- Eligibility rows: cohort_definition_id = test_id, from eligibility_lab_rows.sql.
-- A row counts when its [cohort_start_date, cohort_end_date] interval overlaps
-- the criterion's window, so how long a condition stays live is set by its
-- cohort's end strategy (a lab row starts and ends on the measurement date, so
-- for labs this is a point-in-window check). The window is [index -
-- labWindowBeforeDays, index + labWindowAfterDays] days
-- (settings$labWindowBeforeDays/AfterDays, default 30/30), EXCEPT the
-- condition flags (liver metastasis [28], Gilbert's syndrome [29], neuropathy
-- [33], skin disorders [34]), which use their own [index -
-- conditionFlagWindowBeforeDays, index + conditionFlagWindowAfterDays] window
-- (settings$conditionFlagWindowBeforeDays/AfterDays, default 30/30).
--
-- Test ids are declared in cohorts/extras/eligibility_test_ids.csv and
-- referenced here as @t_<key> (e.g. key gfr_ge30); the [N] comments below are
-- their slot numbers.
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
         DATEADD(day,  @lab_window_after_days,  tc.cohort_start_date) AS win_hi,
         DATEADD(day, -@condition_flag_window_before_days, tc.cohort_start_date) AS win_lo_cond,
         DATEADD(day,  @condition_flag_window_after_days,  tc.cohort_start_date) AS win_hi_cond
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
  SELECT b.subject_id, b.cohort_start_date, b.cohort_end_date, b.win_lo, b.win_hi, b.win_lo_cond, b.win_hi_cond,
         lab.cohort_definition_id AS test_id, lab.cohort_start_date AS lab_date,
         lab.cohort_end_date AS lab_end_date
    FROM base b
    LEFT JOIN (@eligibility_lab_rows_sql) lab
      ON lab.subject_id = b.subject_id
     -- every criterion below needs at most the wider of win_hi/win_hi_cond
     AND lab.cohort_start_date <= (CASE WHEN b.win_hi >= b.win_hi_cond THEN b.win_hi ELSE b.win_hi_cond END)
),
flags AS (
  SELECT subject_id, cohort_start_date, cohort_end_date,
    MAX(CASE WHEN test_id IN (@t_ecog0, @t_ecog1, @t_ecog2) AND lab_date <= win_hi AND lab_end_date >= win_lo THEN 1 ELSE 0 END) AS f_ecog_0_2,
    MAX(CASE WHEN test_id = @t_gfr_ge30                     AND lab_date <= win_hi AND lab_end_date >= win_lo THEN 1 ELSE 0 END) AS f_gfr30,
    MAX(CASE WHEN test_id = @t_anc_ge1500                   AND lab_date <= win_hi AND lab_end_date >= win_lo THEN 1 ELSE 0 END) AS f_anc,
    MAX(CASE WHEN test_id = @t_plt_ge100k                   AND lab_date <= win_hi AND lab_end_date >= win_lo THEN 1 ELSE 0 END) AS f_plt,
    MAX(CASE WHEN test_id = @t_hb_ge9                       AND lab_date <= win_hi AND lab_end_date >= win_lo THEN 1 ELSE 0 END) AS f_hb,
    MAX(CASE WHEN test_id = @t_cr_le1_5uln                  AND lab_date <= win_hi AND lab_end_date >= win_lo THEN 1 ELSE 0 END) AS f_cr,
    MAX(CASE WHEN test_id = @t_crcl_ge30                    AND lab_date <= win_hi AND lab_end_date >= win_lo THEN 1 ELSE 0 END) AS f_crcl,
    MAX(CASE WHEN test_id = @t_tbil_le1_5uln                AND lab_date <= win_hi AND lab_end_date >= win_lo THEN 1 ELSE 0 END) AS f_tbil_le15,
    MAX(CASE WHEN test_id = @t_tbil_gt1_5uln                AND lab_date <= win_hi AND lab_end_date >= win_lo THEN 1 ELSE 0 END) AS f_tbil_gt15,
    MAX(CASE WHEN test_id = @t_dbil_le_uln                  AND lab_date <= win_hi AND lab_end_date >= win_lo THEN 1 ELSE 0 END) AS f_dbil,
    MAX(CASE WHEN test_id = @t_tbil_le3uln                  AND lab_date <= win_hi AND lab_end_date >= win_lo THEN 1 ELSE 0 END) AS f_tbil_le3,
    MAX(CASE WHEN test_id = @t_gilbert                      AND lab_date <= win_hi_cond AND lab_end_date >= win_lo_cond THEN 1 ELSE 0 END) AS f_gilbert,
    MAX(CASE WHEN test_id = @t_ast_le2_5uln                 AND lab_date <= win_hi AND lab_end_date >= win_lo THEN 1 ELSE 0 END) AS f_ast_le25,
    MAX(CASE WHEN test_id = @t_ast_le5uln                   AND lab_date <= win_hi AND lab_end_date >= win_lo THEN 1 ELSE 0 END) AS f_ast_le5,
    MAX(CASE WHEN test_id = @t_liver_met                    AND lab_date <= win_hi_cond AND lab_end_date >= win_lo_cond THEN 1 ELSE 0 END) AS f_livermet,
    MAX(CASE WHEN test_id = @t_alt_le2_5uln                 AND lab_date <= win_hi AND lab_end_date >= win_lo THEN 1 ELSE 0 END) AS f_alt_le25,
    MAX(CASE WHEN test_id = @t_alt_le5uln                   AND lab_date <= win_hi AND lab_end_date >= win_lo THEN 1 ELSE 0 END) AS f_alt_le5,
    MAX(CASE WHEN test_id = @t_inr_le1_5uln                 AND lab_date <= win_hi AND lab_end_date >= win_lo THEN 1 ELSE 0 END) AS f_inr,
    MAX(CASE WHEN test_id = @t_anticoagulant                AND lab_date <= win_hi AND lab_end_date >= win_lo THEN 1 ELSE 0 END) AS f_anticoag,
    MAX(CASE WHEN test_id = @t_pt_le1_5uln                  AND lab_date <= win_hi AND lab_end_date >= win_lo THEN 1 ELSE 0 END) AS f_pt,
    MAX(CASE WHEN test_id = @t_aptt_le1_5uln                AND lab_date <= win_hi AND lab_end_date >= win_lo THEN 1 ELSE 0 END) AS f_aptt,
    MAX(CASE WHEN test_id = @t_hba1c_lt7                    AND lab_date <= win_hi AND lab_end_date >= win_lo THEN 1 ELSE 0 END) AS f_hba1c_lt7,
    MAX(CASE WHEN test_id = @t_hba1c_7_8                    AND lab_date <= win_hi AND lab_end_date >= win_lo THEN 1 ELSE 0 END) AS f_hba1c_7_8,
    MAX(CASE WHEN test_id = @t_neuropathy                   AND lab_date <= win_hi_cond AND lab_end_date >= win_lo_cond THEN 1 ELSE 0 END) AS f_neuropathy,
    MAX(CASE WHEN test_id = @t_skin_disorder                AND lab_date <= win_hi_cond AND lab_end_date >= win_lo_cond THEN 1 ELSE 0 END) AS f_skin
  FROM labs
  GROUP BY subject_id, cohort_start_date, cohort_end_date
),
-- HbA1c 7-8% [16] in the index window with no polyuria [35] or polydipsia [36]
-- cohort era overlapping [HbA1c - 7d, HbA1c + 7d] of that HbA1c's own date.
-- Each symptom record stays live 7 days, so this catches records from 14 days
-- before to 7 days after the HbA1c. 1 if ANY such
-- HbA1c is symptom-free (an HbA1c with a nearby symptom joins to >= 1 row with
-- sym.subject_id set; one with none joins to a single NULL row).
a1c AS (
  SELECT l.subject_id,
         MAX(CASE WHEN sym.subject_id IS NULL THEN 1 ELSE 0 END) AS f_hba1c_7_8_nosym
    FROM labs l
    LEFT JOIN @target_database_schema.@lab_cohort_table sym
      ON sym.subject_id = l.subject_id
     AND sym.cohort_definition_id IN (@t_polyuria, @t_polydipsia)
     AND sym.cohort_start_date <= DATEADD(day,  7, l.lab_date)
     AND sym.cohort_end_date   >= DATEADD(day, -7, l.lab_date)
   WHERE l.test_id = @t_hba1c_7_8
     AND l.lab_date <= l.win_hi AND l.lab_end_date >= l.win_lo
   GROUP BY l.subject_id
)
SELECT f.subject_id, f.cohort_start_date, f.cohort_end_date
  INTO #elig2a_tmp
  FROM flags f
  LEFT JOIN a1c ON a1c.subject_id = f.subject_id
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

   -- HbA1c: [49] < 7%  OR  [16] 7% <= HbA1c < 8% with no polyuria [35] or
   -- polydipsia [36] live within 7 days of that HbA1c (see a1c CTE).
   -- Draft pending study-lead sign-off, following EV-302's exclusion
   -- ("HbA1c >= 8%, or 7 to < 8% with polyuria or polydipsia"); the Cohort
   -- logics spec has "< 6%" and "NO Polyuria OR NO Polydipsia". See
   -- docs/ELIGIBILITY_LOGIC.md, 2a.
   AND (
         f_hba1c_lt7 = 1
         OR a1c.f_hba1c_7_8_nosym = 1
       )

   -- Enfortumab: no significant peripheral neuropathy (test 33); pre-existing
   -- = a record live within [index - conditionFlagWindowBeforeDays, index +
   -- conditionFlagWindowAfterDays].
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
