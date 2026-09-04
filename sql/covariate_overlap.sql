-- =============================================================================
-- covariate_overlap.sql — comorbidity overlap, every main cohort x stratum
-- =============================================================================
-- For every covariate cohort in @covariate_cohort_table, and every cohort in
-- @cohort_definition_ids (the full main tree, same scope as
-- eligibility_input_coverage.csv/lab_value_distribution.csv), count members
-- with a qualifying comorbidity record ON OR BEFORE THAT COHORT'S OWN index
-- date -- an unbounded look-back (prevalent baseline comorbidity: "determined
-- prior to or at index"), not a windowed one. Every (cohort, covariate) pair
-- is computed once overall and once per subject_strata.sql stratum
-- (age_group/sex/age_sex) -- same UNION-ALL-over-shared-aggregation pattern
-- as eligibility_input_coverage.sql (see that file's header for the standard
-- consumption recipe this follows). The matching n_cohort denominator per
-- (cohort, stratum) is added in R (R/08_covariates.R), from the same
-- subject_strata.sql query, not duplicated here.
--
-- SqlRender parameters:
--   @work_database_schema @cohort_table @covariate_cohort_table
--   @cohort_definition_ids  comma-separated cohort_definition_id list
--   subject_strata_sql      pre-rendered fragment, not a plain schema/table
--                           name -- see the `strata` CTE below
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
)
SELECT tc_strat.stratum_type,
       tc_strat.stratum_value,
       tc_strat.cohort_definition_id,
       cov.cohort_definition_id             AS covariate_id,
       COUNT(DISTINCT tc_strat.subject_id)  AS n_overlap
  FROM tc_strat
  JOIN @work_database_schema.@covariate_cohort_table cov
    ON cov.subject_id = tc_strat.subject_id
   AND cov.cohort_start_date <= tc_strat.cohort_start_date
 GROUP BY tc_strat.stratum_type, tc_strat.stratum_value, tc_strat.cohort_definition_id,
          cov.cohort_definition_id
;
