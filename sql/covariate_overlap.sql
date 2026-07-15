-- =============================================================================
-- covariate_overlap.sql — comorbidity covariate overlap with cohort 1A (mBC)
-- =============================================================================
-- For every covariate cohort in @covariate_cohort_table, count the cohort-1A
-- subjects who have a qualifying record ON OR BEFORE their 1A index date
-- (prevalent baseline comorbidity: "determined prior to or at index").
--
-- Generic over whatever cohorts are in @covariate_cohort_table, so adding a new
-- comorbidity is just a matter of adding its JSON to cohorts/02_Covariate/ (see
-- R/08_covariates.R). Returns (covariate_id, n_overlap); the R step maps the id
-- back to a code/label and adds the 1A total as the denominator column.
--
-- SqlRender parameters:
--   @work_database_schema @cohort_table @covariate_cohort_table @cohort1_id
-- =============================================================================

SELECT cov.cohort_definition_id       AS covariate_id,
       COUNT(DISTINCT tc.subject_id)  AS n_overlap
  FROM @work_database_schema.@cohort_table tc
  JOIN @work_database_schema.@covariate_cohort_table cov
    ON cov.subject_id = tc.subject_id
   AND cov.cohort_start_date <= tc.cohort_start_date   -- on/before mBC index
 WHERE tc.cohort_definition_id = @cohort1_id
 GROUP BY cov.cohort_definition_id
;
