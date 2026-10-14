-- =============================================================================
-- eligibility_combination.sql -- Combination-therapy eligible mBC (Cohort
-- logics item 3: "1 AND 2 AND" the combination panel)
-- =============================================================================
-- Cohort 1 members who pass the washout and the full combination-therapy
-- panel: the attrition step between "Not previously treated" and the
-- eligibility leaves. Contains T2a, T2b, T2c, and the part of T2e that fits
-- no arm.
--
-- The washout, windows and panel are eligibility_2a.sql's, with the
-- enfortumab criteria (HbA1c, neuropathy, skin) removed; keep the two in step.
-- See eligibility_2a.sql's header for the test-id reference and the notes on
-- query shape.
--
-- SqlRender params: as eligibility_2a.sql.
-- =============================================================================

DELETE FROM @target_database_schema.@target_cohort_table
 WHERE cohort_definition_id = @target_cohort_id;

DROP TABLE IF EXISTS #eligce_tmp;

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
    LEFT JOIN @target_database_schema.@lab_cohort_table lab
      ON lab.subject_id = b.subject_id
     -- every criterion below needs at most the wider of win_hi/win_hi_cond
     AND lab.cohort_start_date <= (CASE WHEN b.win_hi >= b.win_hi_cond THEN b.win_hi ELSE b.win_hi_cond END)
),
flags AS (
  SELECT subject_id, cohort_start_date, cohort_end_date,
    MAX(CASE WHEN test_id IN (24, 25, 26)           AND lab_date <= win_hi AND lab_end_date >= win_lo THEN 1 ELSE 0 END) AS f_ecog_0_2,
    MAX(CASE WHEN test_id = 14                      AND lab_date <= win_hi AND lab_end_date >= win_lo THEN 1 ELSE 0 END) AS f_gfr30,
    MAX(CASE WHEN test_id = 4                       AND lab_date <= win_hi AND lab_end_date >= win_lo THEN 1 ELSE 0 END) AS f_anc,
    MAX(CASE WHEN test_id = 19                      AND lab_date <= win_hi AND lab_end_date >= win_lo THEN 1 ELSE 0 END) AS f_plt,
    MAX(CASE WHEN test_id = 15                      AND lab_date <= win_hi AND lab_end_date >= win_lo THEN 1 ELSE 0 END) AS f_hb,
    MAX(CASE WHEN test_id = 8                       AND lab_date <= win_hi AND lab_end_date >= win_lo THEN 1 ELSE 0 END) AS f_cr,
    MAX(CASE WHEN test_id = 7                       AND lab_date <= win_hi AND lab_end_date >= win_lo THEN 1 ELSE 0 END) AS f_crcl,
    MAX(CASE WHEN test_id = 22                      AND lab_date <= win_hi AND lab_end_date >= win_lo THEN 1 ELSE 0 END) AS f_tbil_le15,
    MAX(CASE WHEN test_id = 23                      AND lab_date <= win_hi AND lab_end_date >= win_lo THEN 1 ELSE 0 END) AS f_tbil_gt15,
    MAX(CASE WHEN test_id = 9                       AND lab_date <= win_hi AND lab_end_date >= win_lo THEN 1 ELSE 0 END) AS f_dbil,
    MAX(CASE WHEN test_id = 21                      AND lab_date <= win_hi AND lab_end_date >= win_lo THEN 1 ELSE 0 END) AS f_tbil_le3,
    MAX(CASE WHEN test_id = 29                      AND lab_date <= win_hi_cond AND lab_end_date >= win_lo_cond THEN 1 ELSE 0 END) AS f_gilbert,
    MAX(CASE WHEN test_id = 5                       AND lab_date <= win_hi AND lab_end_date >= win_lo THEN 1 ELSE 0 END) AS f_ast_le25,
    MAX(CASE WHEN test_id = 6                       AND lab_date <= win_hi AND lab_end_date >= win_lo THEN 1 ELSE 0 END) AS f_ast_le5,
    MAX(CASE WHEN test_id = 28                      AND lab_date <= win_hi_cond AND lab_end_date >= win_lo_cond THEN 1 ELSE 0 END) AS f_livermet,
    MAX(CASE WHEN test_id = 2                       AND lab_date <= win_hi AND lab_end_date >= win_lo THEN 1 ELSE 0 END) AS f_alt_le25,
    MAX(CASE WHEN test_id = 3                       AND lab_date <= win_hi AND lab_end_date >= win_lo THEN 1 ELSE 0 END) AS f_alt_le5,
    MAX(CASE WHEN test_id = 18                      AND lab_date <= win_hi AND lab_end_date >= win_lo THEN 1 ELSE 0 END) AS f_inr,
    MAX(CASE WHEN test_id = 31                      AND lab_date <= win_hi AND lab_end_date >= win_lo THEN 1 ELSE 0 END) AS f_anticoag,
    MAX(CASE WHEN test_id = 20                      AND lab_date <= win_hi AND lab_end_date >= win_lo THEN 1 ELSE 0 END) AS f_pt,
    MAX(CASE WHEN test_id = 1                       AND lab_date <= win_hi AND lab_end_date >= win_lo THEN 1 ELSE 0 END) AS f_aptt
  FROM labs
  GROUP BY subject_id, cohort_start_date, cohort_end_date
)
SELECT f.subject_id, f.cohort_start_date, f.cohort_end_date
  INTO #eligce_tmp
  FROM flags f
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
;

INSERT INTO @target_database_schema.@target_cohort_table
  (cohort_definition_id, subject_id, cohort_start_date, cohort_end_date)
SELECT @target_cohort_id AS cohort_definition_id,
       subject_id, cohort_start_date, cohort_end_date
  FROM #eligce_tmp
;

DROP TABLE IF EXISTS #eligce_tmp;
