-- =============================================================================
-- covariate_lab_coverage.sql — lab test coverage by comorbidity subgroup,
-- Target 1A only
-- =============================================================================
-- For Target 1A (@target_cohort_id) members, splits into with/without each of
-- three comorbidity covariates -- Heme Disorders, Liver Disease, Renal
-- Disease -- using the SAME unbounded on/before-index lookback as
-- covariate_overlap.sql ("ever before index": a qualifying record any time
-- on or before the subject's own Target 1A index date, no start bound; NOT
-- the windowed conditionFlagWindow used for the main cohort's pre-existing
-- condition eligibility flags in eligibility_2a.sql). For each subgroup
-- side, counts how many members have >=1 measurement of each lab (cat)
-- within the eligibility lab window (@lab_window_before_days before /
-- @lab_window_after_days after index) -- same window
-- lab_value_distribution_portable.sql uses, collapsed to presence/absence
-- rather than a value distribution.
--
-- Every lab (cat) present anywhere in @raw_lab_results_table is reported for
-- every subgroup side, zero-filled where a subgroup has no coverage at all
-- (same convention as covariate_overlap.sql) -- not silently absent.
--
-- SqlRender parameters:
--   @work_database_schema @cohort_table @covariate_cohort_table
--   @raw_lab_results_table
--   @target_cohort_id        single cohort_definition_id (Target 1A / T1)
--   @heme_covariate_id @liver_covariate_id @renal_covariate_id
--                             cohort_definition_id of each covariate in
--                             @covariate_cohort_table (assigned per-run by
--                             buildCohortSet(), see R/08_covariates.R's covSet)
--   @lab_window_before_days @lab_window_after_days
-- =============================================================================

WITH target_cohort AS (
  SELECT subject_id, cohort_start_date
    FROM @work_database_schema.@cohort_table
   WHERE cohort_definition_id = @target_cohort_id
),
covariate_codes AS (
  SELECT 'heme_disorder' AS code, @heme_covariate_id  AS covariate_id UNION ALL
  SELECT 'liver_disorder',        @liver_covariate_id                UNION ALL
  SELECT 'renal_disorder',        @renal_covariate_id
),
covariate_hits AS (
  SELECT DISTINCT tc.subject_id, cov.cohort_definition_id AS covariate_id
    FROM target_cohort tc
    JOIN @work_database_schema.@covariate_cohort_table cov
      ON cov.subject_id = tc.subject_id
     AND cov.cohort_start_date <= tc.cohort_start_date
   WHERE cov.cohort_definition_id IN (@heme_covariate_id, @liver_covariate_id, @renal_covariate_id)
),
flags AS (
  SELECT tc.subject_id, cc.code,
         CASE WHEN ch.subject_id IS NOT NULL THEN 1 ELSE 0 END AS has_flag
    FROM target_cohort tc
   CROSS JOIN covariate_codes cc
   LEFT JOIN covariate_hits ch
     ON ch.subject_id = tc.subject_id AND ch.covariate_id = cc.covariate_id
),
-- Collapse the per-criterion (test_id) fan-out, same as
-- lab_value_distribution_portable.sql's lab_measurements CTE: one row per
-- actual measurement, so a lab used by several thresholds isn't counted more
-- than once.
lab_measurements AS (
  SELECT DISTINCT
         lab.person_id,
         lab.measurement_date,
         lab.cat
    FROM @work_database_schema.@raw_lab_results_table lab
   WHERE lab.std_value IS NOT NULL
),
all_cats AS (
  SELECT DISTINCT cat FROM lab_measurements
),
lab_hits AS (
  SELECT DISTINCT tc.subject_id, lab.cat
    FROM target_cohort tc
    JOIN lab_measurements lab
      ON lab.person_id = tc.subject_id
     AND lab.measurement_date BETWEEN DATEADD(day, -@lab_window_before_days, tc.cohort_start_date)
                                  AND DATEADD(day,  @lab_window_after_days, tc.cohort_start_date)
)
SELECT f.code,
       f.has_flag,
       ac.cat,
       COUNT(DISTINCT f.subject_id)  AS subgroup_count,
       COUNT(DISTINCT lh.subject_id) AS n_with_test
  FROM flags f
 CROSS JOIN all_cats ac
 LEFT JOIN lab_hits lh
   ON lh.subject_id = f.subject_id AND lh.cat = ac.cat
 GROUP BY f.code, f.has_flag, ac.cat
 ORDER BY f.code, f.has_flag, ac.cat
;
