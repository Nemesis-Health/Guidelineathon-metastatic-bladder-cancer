-- ===========================================================================
-- subject_strata.sql — per-subject strata (age group / sex / age x sex / age band /
--                       index period / index year)
-- ===========================================================================
-- One row per (cohort_definition_id, subject_id) in @cohort_table, carrying
-- the protocol stratification columns:
--   age_group   >65 / <=65   (age = year(index) - year_of_birth; protocol:
--               "age groups (<=65 and >65 years old)")
--   sex         Male / Female / Other-Unknown
--   age_sex     age_group and sex combined ('<=65|Male', '>65|Female', ...)
--               -- a ready-made crossed grouping column, so a caller wanting
--               the age x sex view doesn't need its own CASE/concat logic.
--   age_band    <=65 / 66-80 / >80 (same age as age_group; the protocol's
--               <=65/>65 split stays in age_group, this adds the >80 band)
--   index_period       2015-2020 / 2021-2023 / 2024+ (year of index;
--                      <2015 only for cohorts that can index earlier)
--   index_period_2021  2015-2020 / 2021+ -- a separate column because 2021+
--                      overlaps 2021-2023 and 2024+, and each column holds
--                      one value per subject
--   index_year  year of cohort_start_date
--
-- SINGLE SOURCE OF TRUTH for this bucketing logic -- every other consumer
-- builds on this file's exact text instead of re-deriving the CASE
-- expressions, so the buckets can't drift apart. Consumers, SQL-side (UNION
-- ALL blocks, this file's text injected as a fragment): demographics.sql,
-- lab_value_distribution.sql, lab_timing_to_index.sql,
-- eligibility_input_coverage.sql, cohort_counts_stratified.sql. Consumers,
-- R-side (queried directly, joined/filtered in R then looped over stratum
-- columns): R/steps/50_outcomes.R, R/steps/70_treatment_patterns.R,
-- R/steps/22_baseline_characterization.R (baseline_body_measurements), R/steps/60_adherence.R
-- (guideline_relevance/guideline_adherence). The standard pattern either
-- way: join/filter the analysis's own per-subject data by
-- (cohort_definition_id, subject_id), then compute the SAME metric once
-- overall and once per stratum column (age_group, sex, age_sex), tagging
-- rows with a stratum_type/stratum_value pair rather than baking the
-- stratum into a name string.
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
       CASE WHEN YEAR(c.cohort_start_date) - p.year_of_birth > 80 THEN '>80'
            WHEN YEAR(c.cohort_start_date) - p.year_of_birth > 65 THEN '66-80'
            ELSE '<=65' END                                     AS age_band,
       CASE WHEN YEAR(c.cohort_start_date) >= 2024 THEN '2024+'
            WHEN YEAR(c.cohort_start_date) >= 2021 THEN '2021-2023'
            WHEN YEAR(c.cohort_start_date) >= 2015 THEN '2015-2020'
            ELSE '<2015' END                                    AS index_period,
       CASE WHEN YEAR(c.cohort_start_date) >= 2021 THEN '2021+'
            WHEN YEAR(c.cohort_start_date) >= 2015 THEN '2015-2020'
            ELSE '<2015' END                                    AS index_period_2021,
       YEAR(c.cohort_start_date)                                AS index_year
  FROM @work_database_schema.@cohort_table c
  JOIN @cdm_database_schema.person p
    ON p.person_id = c.subject_id
