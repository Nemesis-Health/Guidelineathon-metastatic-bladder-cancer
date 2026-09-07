-- =============================================================================
-- ps_overlap.sql — performance-status strata overlap, every main cohort
-- =============================================================================
-- ECOG membership (KPS folded in) lives in @lab_cohort_table at the reserved
-- test-id slots: 24 = ECOG 0, 25 = ECOG 1, 26 = ECOG 2, 27 = ECOG >=3, each
-- dated at the PS record. A member of a cohort in @cohort_definition_ids (the
-- full main tree, same scope as covariate_overlap.sql above) counts toward a
-- stratum if they have an ECOG record in that stratum's id-set within
-- @lab_window_before_days days before to @lab_window_after_days days after
-- THAT COHORT'S OWN index. Strata OVERLAP by design (e.g. PS 0-2 includes
-- PS1/PS2) -- deliberately a near-index window, not the unbounded look-back
-- covariate_overlap.sql uses for comorbidities: performance status is a
-- point-in-time functional assessment, not a chronic condition flag.
--
-- Every (cohort, PS code) pair is computed once overall and once per
-- subject_strata.sql stratum (age_group/sex/age_sex) -- same UNION-ALL
-- pattern as covariate_overlap.sql/eligibility_input_coverage.sql. The
-- matching n_cohort denominator is added in R (R/08_covariates.R).
--
-- SqlRender parameters:
--   @work_database_schema @cohort_table @lab_cohort_table
--   @cohort_definition_ids  comma-separated cohort_definition_id list
--   @lab_window_before_days @lab_window_after_days
--   subject_strata_sql      pre-rendered fragment -- see the `strata` CTE below
-- =============================================================================

WITH target_cohorts AS (
  SELECT cohort_definition_id, subject_id, cohort_start_date
    FROM @work_database_schema.@cohort_table
   WHERE cohort_definition_id IN (@cohort_definition_ids)
),
strata AS (
  @subject_strata_sql
),
tc_strat AS (
  SELECT 'overall' AS stratum_type, 'overall' AS stratum_value,
         tc.cohort_definition_id, tc.subject_id, tc.cohort_start_date
    FROM target_cohorts tc
  UNION ALL
  SELECT 'age_group' AS stratum_type, s.age_group AS stratum_value,
         tc.cohort_definition_id, tc.subject_id, tc.cohort_start_date
    FROM target_cohorts tc
    JOIN strata s ON s.cohort_definition_id = tc.cohort_definition_id AND s.subject_id = tc.subject_id
  UNION ALL
  SELECT 'sex' AS stratum_type, s.sex AS stratum_value,
         tc.cohort_definition_id, tc.subject_id, tc.cohort_start_date
    FROM target_cohorts tc
    JOIN strata s ON s.cohort_definition_id = tc.cohort_definition_id AND s.subject_id = tc.subject_id
  UNION ALL
  SELECT 'age_sex' AS stratum_type, s.age_sex AS stratum_value,
         tc.cohort_definition_id, tc.subject_id, tc.cohort_start_date
    FROM target_cohorts tc
    JOIN strata s ON s.cohort_definition_id = tc.cohort_definition_id AND s.subject_id = tc.subject_id
),
ps_codes AS (
  SELECT 'PS1' AS code, 24 AS test_id UNION ALL
  SELECT 'PS2', 25 UNION ALL
  SELECT 'PS2+', 26 UNION ALL
  SELECT 'PS2+', 27 UNION ALL
  SELECT 'PS 0-2', 24 UNION ALL
  SELECT 'PS 0-2', 25 UNION ALL
  SELECT 'PS 0-2', 26 UNION ALL
  SELECT 'PS 0-1', 24 UNION ALL
  SELECT 'PS 0-1', 25
)
SELECT tc_strat.stratum_type,
       tc_strat.stratum_value,
       tc_strat.cohort_definition_id,
       pc.code,
       COUNT(DISTINCT tc_strat.subject_id) AS n_overlap
  FROM tc_strat
  CROSS JOIN ps_codes pc
  JOIN @work_database_schema.@lab_cohort_table l
    ON l.subject_id = tc_strat.subject_id
   AND l.cohort_definition_id = pc.test_id
   AND l.cohort_start_date BETWEEN DATEADD(day, -@lab_window_before_days, tc_strat.cohort_start_date)
                                AND DATEADD(day,  @lab_window_after_days, tc_strat.cohort_start_date)
 GROUP BY tc_strat.stratum_type, tc_strat.stratum_value, tc_strat.cohort_definition_id,
          pc.code
;
