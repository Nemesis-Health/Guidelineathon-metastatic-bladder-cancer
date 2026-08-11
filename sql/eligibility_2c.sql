-- =============================================================================
-- Target 1A 2c — Carboplatin-eligible (cisplatin-ineligible)
-- =============================================================================
-- Protocol: Cohort 1 + washout + combination-therapy eligible + NOT enfortumab-
-- eligible + NOT cisplatin-eligible + carboplatin-eligible.
--
-- See eligibility_2a.sql for full test_id reference and for why this template
-- uses flag columns rather than nested EXISTS/OR (Redshift rejects correlated
-- subqueries combined with OR — error 500310).
-- Planned ids: 24-26 ECOG; 28 liver mets; 33 neuropathy >= 2; 38 NYHA >= III;
--              40 hearing loss grade >= 2.
-- =============================================================================

DELETE FROM @target_database_schema.@target_cohort_table
 WHERE cohort_definition_id = @target_cohort_id;

INSERT INTO @target_database_schema.@target_cohort_table
  (cohort_definition_id, subject_id, cohort_start_date, cohort_end_date)
WITH base AS (
  SELECT tc.subject_id, tc.cohort_start_date, tc.cohort_end_date,
         DATEADD(day, -@lab_window_before_days, tc.cohort_start_date) AS win_lo,
         DATEADD(day,  @lab_window_after_days,  tc.cohort_start_date) AS win_hi
    FROM @target_database_schema.@target_cohort_table tc

    /* ----- NOT enfortumab-eligible: exact anti-join on cohort 2a ----- */
    LEFT JOIN @target_database_schema.@target_cohort_table ev
      ON ev.subject_id = tc.subject_id
     AND ev.cohort_definition_id = @cohort2a_id

    /* ----- NOT cisplatin-eligible: exact anti-join on cohort 2b ----- */
    -- 2a/2b are generated before this cohort; each anti-join excludes anyone
    -- already claimed by that arm's full definition (not just its distinguishing
    -- criteria). Plain anti-joins, no correlated subqueries.
    LEFT JOIN @target_database_schema.@target_cohort_table cis
      ON cis.subject_id = tc.subject_id
     AND cis.cohort_definition_id = @cohort2b_id
   WHERE tc.cohort_definition_id = @cohort1_id
     AND ev.subject_id  IS NULL
     AND cis.subject_id IS NULL

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
    MAX(CASE WHEN test_id = 26            AND lab_date BETWEEN win_lo AND win_hi THEN 1 ELSE 0 END) AS f_ecog2,
    MAX(CASE WHEN test_id = 14            AND lab_date BETWEEN win_lo AND win_hi THEN 1 ELSE 0 END) AS f_gfr30,
    MAX(CASE WHEN test_id = 11            AND lab_date BETWEEN win_lo AND win_hi THEN 1 ELSE 0 END) AS f_gfr_30_60,
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
SELECT @target_cohort_id AS cohort_definition_id,
       subject_id, cohort_start_date, cohort_end_date
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

   -- NOT enfortumab-eligible / NOT cisplatin-eligible handled by the ev/cis
   -- anti-joins in `base` above.

   /* ----- Carboplatin-eligible (any one) ----- */
   AND (
         f_ecog2      = 1   -- [26] ECOG 2
         OR f_gfr_30_60 = 1 -- [11] GFR 30-60 mL/min
         -- NYHA class >= III: IGNORED for now (no NYHA concept set).
         OR f_hearing   = 1 -- [40] audiometric hearing loss present (grade >= 2 proxy)
         OR f_neuropathy = 1 -- [33] peripheral neuropathy present (grade >= 2 proxy)
       )
;
