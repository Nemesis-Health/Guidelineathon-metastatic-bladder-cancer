-- =============================================================================
-- charlson_components.sql — per (cohort, subject) Charlson component flags
-- =============================================================================
-- One row per (cohort, subject) in cohort_definition_ids (the full main
-- tree), with one 0/1 flag column per Charlson component actually wired this
-- run (built dynamically in R as component_flags_sql -- see below -- since
-- which comorbidity cohorts are present varies by site/run) plus
-- subject_strata.sql's age_group/sex/age_sex. All computed here via
-- conditional aggregation (MAX(CASE WHEN ...)), not pulled subject-level and
-- pivoted/joined in R: this keeps the row-scanning/joining work (which
-- scales with data volume) in the database. R
-- (R/11_baseline_characterization.R) only runs the final Charlson scoring
-- math (computeCharlsonScore(), a small weighted-sum + hierarchy adjustment
-- over this already-compact, already-joined table) and the per-stratum
-- count.
--
-- A subject with no qualifying record for a component at all still gets a
-- flag of 0 (not NULL): the LEFT JOIN against the covariate cohort table can
-- produce zero matching rows for a subject with no comorbidities, but
-- MAX(CASE WHEN ...) over that single (all-NULL) row still evaluates to 0.
-- Each component's flag is TRUE if cov.cohort_start_date <= tc.cohort_start_date
-- (on/before that cohort's own index -- same unbounded look-back as
-- covariate_overlap.csv), regardless of how many qualifying records exist.
--
-- SqlRender parameters:
--   @work_database_schema @cohort_table @covariate_cohort_table
--   @cohort_definition_ids  comma-separated cohort_definition_id list
--   component_flags_sql     comma-separated "MAX(CASE WHEN cov.cohort_definition_id
--                           = <id> THEN 1 ELSE 0 END) AS <component>" list,
--                           built in R from covSet x charlsonMap (varies by
--                           which comorbidity cohorts are present this run)
--   subject_strata_sql      pre-rendered fragment -- see the `strata` CTE below
-- =============================================================================

WITH strata AS (
  @subject_strata_sql
)
SELECT tc.cohort_definition_id,
       tc.subject_id,
       s.age_group, s.sex, s.age_sex,
       @component_flags_sql
  FROM @work_database_schema.@cohort_table tc
  LEFT JOIN @work_database_schema.@covariate_cohort_table cov
    ON cov.subject_id = tc.subject_id
   AND cov.cohort_start_date <= tc.cohort_start_date
  LEFT JOIN strata s
    ON s.cohort_definition_id = tc.cohort_definition_id AND s.subject_id = tc.subject_id
 WHERE tc.cohort_definition_id IN (@cohort_definition_ids)
 GROUP BY tc.cohort_definition_id, tc.subject_id, s.age_group, s.sex, s.age_sex
;
