-- =============================================================================
-- Target 1A 2b — Cisplatin-eligible (enfortumab-ineligible)
-- =============================================================================
-- Protocol: Cohort 1 + washout + combination-therapy eligible + NOT enfortumab-
-- eligible + cisplatin-eligible. Index/end dates inherited from Cohort 1.
--
-- See eligibility_2a.sql for full test_id reference (lab_cohorts.sql ids 1-23),
-- for why this template is written as flag columns rather than nested
-- EXISTS/OR (Redshift rejects correlated subqueries combined with OR — error
-- 500310, and several of these criteria are OR alternatives: Cr/CrCl, TBil,
-- AST, ALT, coag), and for why the flags are materialised into a #temp table
-- via SELECT...INTO rather than combined directly with INSERT (WITH+INSERT
-- clause ordering is not portable across dialects).
-- Planned ids: 24-26 ECOG; 28 liver mets; 32 neuropathy;
-- 37 NYHA < III; 39 hearing loss grade < 2.
-- =============================================================================

DELETE FROM @target_database_schema.@target_cohort_table
 WHERE cohort_definition_id = @target_cohort_id;

DROP TABLE IF EXISTS #elig2b_tmp;

WITH base AS (
  SELECT tc.subject_id, tc.cohort_start_date, tc.cohort_end_date,
         DATEADD(day, -@lab_window_before_days, tc.cohort_start_date) AS win_lo,
         DATEADD(day,  @lab_window_after_days,  tc.cohort_start_date) AS win_hi
    FROM @target_database_schema.@target_cohort_table tc

    /* ----- NOT enfortumab-eligible: exact anti-join on cohort 2a ----- */
    -- 2a is generated before this cohort, so we exclude anyone already claimed
    -- by the EV arm (captures the full EV definition: HbA1c AND neuropathy AND
    -- skin). Plain anti-join, no correlated subquery.
    LEFT JOIN @target_database_schema.@target_cohort_table ev
      ON ev.subject_id = tc.subject_id
     AND ev.cohort_definition_id = @cohort2a_id
   WHERE tc.cohort_definition_id = @cohort1_id
     AND ev.subject_id IS NULL

     /* ----- Washout ----- */
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
     AND lab.cohort_start_date <= b.win_hi
),
flags AS (
  SELECT subject_id, cohort_start_date, cohort_end_date,
    MAX(CASE WHEN test_id IN (24, 25, 26) AND lab_date BETWEEN win_lo AND win_hi THEN 1 ELSE 0 END) AS f_ecog_0_2,
    MAX(CASE WHEN test_id IN (24, 25)     AND lab_date BETWEEN win_lo AND win_hi THEN 1 ELSE 0 END) AS f_ecog_0_1,
    MAX(CASE WHEN test_id = 14            AND lab_date BETWEEN win_lo AND win_hi THEN 1 ELSE 0 END) AS f_gfr30,
    MAX(CASE WHEN test_id = 13            AND lab_date BETWEEN win_lo AND win_hi THEN 1 ELSE 0 END) AS f_gfr60,
    MAX(CASE WHEN test_id = 4             AND lab_date BETWEEN win_lo AND win_hi THEN 1 ELSE 0 END) AS f_anc,
    MAX(CASE WHEN test_id = 19            AND lab_date BETWEEN win_lo AND win_hi THEN 1 ELSE 0 END) AS f_plt,
    MAX(CASE WHEN test_id = 15            AND lab_date BETWEEN win_lo AND win_hi THEN 1 ELSE 0 END) AS f_hb,
    MAX(CASE WHEN test_id = 8             AND lab_date BETWEEN win_lo AND win_hi THEN 1 ELSE 0 END) AS f_cr,
    MAX(CASE WHEN test_id = 7             AND lab_date BETWEEN win_lo AND win_hi THEN 1 ELSE 0 END) AS f_crcl,
    MAX(CASE WHEN test_id = 22            AND lab_date BETWEEN win_lo AND win_hi THEN 1 ELSE 0 END) AS f_tbil_le15,
    MAX(CASE WHEN test_id = 23            AND lab_date BETWEEN win_lo AND win_hi THEN 1 ELSE 0 END) AS f_tbil_gt15,
    MAX(CASE WHEN test_id = 9             AND lab_date BETWEEN win_lo AND win_hi THEN 1 ELSE 0 END) AS f_dbil,
    MAX(CASE WHEN test_id = 21            AND lab_date BETWEEN win_lo AND win_hi THEN 1 ELSE 0 END) AS f_tbil_le3,
    MAX(CASE WHEN test_id = 29            AND lab_date <= win_hi                 THEN 1 ELSE 0 END) AS f_gilbert,
    MAX(CASE WHEN test_id = 5             AND lab_date BETWEEN win_lo AND win_hi THEN 1 ELSE 0 END) AS f_ast_le25,
    MAX(CASE WHEN test_id = 6             AND lab_date BETWEEN win_lo AND win_hi THEN 1 ELSE 0 END) AS f_ast_le5,
    MAX(CASE WHEN test_id = 28            AND lab_date <= win_hi                 THEN 1 ELSE 0 END) AS f_livermet,
    MAX(CASE WHEN test_id = 2             AND lab_date BETWEEN win_lo AND win_hi THEN 1 ELSE 0 END) AS f_alt_le25,
    MAX(CASE WHEN test_id = 3             AND lab_date BETWEEN win_lo AND win_hi THEN 1 ELSE 0 END) AS f_alt_le5,
    MAX(CASE WHEN test_id = 18            AND lab_date BETWEEN win_lo AND win_hi THEN 1 ELSE 0 END) AS f_inr,
    MAX(CASE WHEN test_id = 31            AND lab_date BETWEEN win_lo AND win_hi THEN 1 ELSE 0 END) AS f_anticoag,
    MAX(CASE WHEN test_id = 20            AND lab_date BETWEEN win_lo AND win_hi THEN 1 ELSE 0 END) AS f_pt,
    MAX(CASE WHEN test_id = 1             AND lab_date BETWEEN win_lo AND win_hi THEN 1 ELSE 0 END) AS f_aptt,
    MAX(CASE WHEN test_id = 40            AND lab_date <= win_hi                 THEN 1 ELSE 0 END) AS f_hearing,
    MAX(CASE WHEN test_id = 33            AND lab_date <= win_hi                 THEN 1 ELSE 0 END) AS f_neuropathy
  FROM labs
  GROUP BY subject_id, cohort_start_date, cohort_end_date
)
SELECT subject_id, cohort_start_date, cohort_end_date
  INTO #elig2b_tmp
  FROM flags
 WHERE

   /* ----- Combination-therapy eligible (same criteria as 2a) ----- */
       f_ecog_0_2 = 1
   AND f_gfr30    = 1
   AND f_anc      = 1
   AND f_plt      = 1
   AND f_hb       = 1
   AND (f_cr = 1 OR f_crcl = 1)
   AND (
         f_tbil_le15 = 1
         OR (f_tbil_gt15 = 1 AND f_dbil    = 1)
         OR (f_tbil_le3  = 1 AND f_gilbert = 1)
       )
   AND (f_ast_le25 = 1 OR (f_ast_le5 = 1 AND f_livermet = 1))
   AND (f_alt_le25 = 1 OR (f_alt_le5 = 1 AND f_livermet = 1))
   AND (f_inr = 1 OR f_pt = 1 OR f_anticoag = 1)
   AND (f_aptt = 1 OR f_anticoag = 1)

   -- NOT enfortumab-eligible handled by the ev anti-join in `base` above.

   /* ----- Cisplatin-eligible ----- */
   AND f_ecog_0_1 = 1     -- [24-25] ECOG 0-1
   AND f_gfr60    = 1     -- [13] GFR > 60 mL/min
   AND 1 = 1              -- NYHA class < III: IGNORED for now (assume-pass) — no NYHA concept set yet.
   AND f_hearing    = 0   -- Cisplatin: no significant audiometric hearing loss (test 40).
   AND f_neuropathy = 0   -- Cisplatin: no significant peripheral neuropathy (test 33).
;

INSERT INTO @target_database_schema.@target_cohort_table
  (cohort_definition_id, subject_id, cohort_start_date, cohort_end_date)
SELECT @target_cohort_id AS cohort_definition_id,
       subject_id, cohort_start_date, cohort_end_date
  FROM #elig2b_tmp
;

DROP TABLE IF EXISTS #elig2b_tmp;
