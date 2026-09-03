-- ===========================================================================
-- subject_strata.sql — per-subject strata (age group / sex / age x sex / index year)
-- ===========================================================================
-- One row per (cohort_definition_id, subject_id) in @cohort_table, carrying
-- the protocol stratification columns:
--   age_group   >65 / <=65   (age = year(index) - year_of_birth; protocol:
--               "age groups (<=65 and >65 years old)")
--   sex         Male / Female / Other-Unknown
--   age_sex     age_group and sex combined ('<=65|Male', '>65|Female', ...)
--               -- a ready-made crossed grouping column, so a caller wanting
--               the age x sex view doesn't need its own CASE/concat logic.
--   index_year  year of cohort_start_date
--
-- SINGLE SOURCE OF TRUTH for this bucketing logic -- every other consumer
-- builds on this file's exact text instead of re-deriving the CASE
-- expressions, so the buckets can't drift apart. The standard consumption
-- pattern (demographics.sql, lab_timing_to_index_portable.sql,
-- R/09_outcomes.R, R/12_treatment_patterns.R): join this file's output onto
-- the analysis's own per-subject data by (cohort_definition_id, subject_id),
-- then compute the SAME metric once overall and once per stratum column
-- (age_group, sex, age_sex) -- either via UNION ALL blocks (demographics.sql
-- and lab_timing_to_index_portable.sql's shape) or an R-side loop over
-- stratum columns (R/09, R/12's shape) -- tagging rows with a
-- stratum_type/stratum_value pair rather than baking the stratum into a
-- name string.
--
-- SqlRender parameters: @work_database_schema @cohort_table @cdm_database_schema
-- ===========================================================================

SELECT c.cohort_definition_id                                  AS cohort_definition_id,
       c.subject_id                                            AS subject_id,
       CASE WHEN YEAR(c.cohort_start_date) - p.year_of_birth > 65
            THEN '>65' ELSE '<=65' END                         AS age_group,
       CASE p.gender_concept_id WHEN 8507 THEN 'Male'
                                WHEN 8532 THEN 'Female'
                                ELSE 'Other-Unknown' END        AS sex,
       CONCAT(CONCAT(
         CASE WHEN YEAR(c.cohort_start_date) - p.year_of_birth > 65
              THEN '>65' ELSE '<=65' END, '|'),
         CASE p.gender_concept_id WHEN 8507 THEN 'Male'
                                  WHEN 8532 THEN 'Female'
                                  ELSE 'Other-Unknown' END)     AS age_sex,
       YEAR(c.cohort_start_date)                                AS index_year
  FROM @work_database_schema.@cohort_table c
  JOIN @cdm_database_schema.person p
    ON p.person_id = c.subject_id
