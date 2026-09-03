-- ===========================================================================
-- subject_strata.sql — per-subject strata (age group / sex / index year)
-- ===========================================================================
-- One row per (cohort_definition_id, subject_id) in @cohort_table, carrying
-- the three protocol stratification columns:
--   age_group   >65 / <=65   (age = year(index) - year_of_birth; protocol:
--               "age groups (<=65 and >65 years old)")
--   sex         Male / Female / Other-Unknown
--   index_year  year of cohort_start_date
--
-- SINGLE SOURCE OF TRUTH for this bucketing logic -- every other consumer
-- builds on this file's exact text instead of re-deriving the CASE
-- expressions, so the buckets can't drift apart:
--   R/09_outcomes.R              — queried directly, left-joined onto
--                                   targetData to stratify
--                                   computeTimeToEvent()/computeTimeDiffStats().
--   R/12_treatment_patterns.R    — queried directly, same left-join pattern.
--   demographics.sql             — this file's text is rendered first and
--                                   injected as its `coh` CTE body (see that
--                                   file's header), then aggregated to counts.
--   R/03_main_cohorts.R          — same injection, filtered to one root
--                                   cohort, to materialize the age/sex
--                                   sub-cohorts (T1 (Age>65), etc.).
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
       YEAR(c.cohort_start_date)                                AS index_year
  FROM @work_database_schema.@cohort_table c
  JOIN @cdm_database_schema.person p
    ON p.person_id = c.subject_id
