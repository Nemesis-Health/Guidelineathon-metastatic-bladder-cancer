-- ===========================================================================
-- outcome_strata.sql — per-subject strata for outcomes (age group / sex / index year)
-- ===========================================================================
-- One row per (cohort_definition_id, subject_id) in @cohort_table, carrying
-- the three protocol stratification columns:
--   age_group   >65 / <=65   (age = year(index) - year_of_birth)
--   sex         Male / Female / Other-Unknown
--   index_year  year of cohort_start_date
--
-- Row-level counterpart of demographics.sql's `coh` CTE (same bucketing, kept
-- consistent with it) — that file aggregates to counts per stratum; this one
-- stays per-subject so R/09_outcomes.R can left-join it onto targetData and
-- stratify computeTimeToEvent()/computeTimeDiffStats() calls.
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
