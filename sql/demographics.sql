-- =============================================================================
-- demographics.sql — per-cohort demographic strata counts
-- =============================================================================
-- For every cohort in @cohort_table, count subjects by:
--   * age group at index   (>65 / <=65, age = year(index) - year_of_birth)
--   * sex                  (Male / Female / Other-Unknown)
--   * index year           (year of cohort_start_date)
--
-- Emitted long/tidy so one template covers all three:
--   (cohort_definition_id, characteristic, stratum, sort_key, n_subjects)
-- Percentages are computed in R (within cohort x characteristic; denominator =
-- cohort N) and small cells are censored there.
--
-- SqlRender parameters: @work_database_schema @cohort_table @cdm_database_schema
-- =============================================================================

WITH coh AS (
  SELECT c.cohort_definition_id,
         c.subject_id,
         p.gender_concept_id,
         YEAR(c.cohort_start_date) - p.year_of_birth AS age_at_index,
         YEAR(c.cohort_start_date)                   AS index_year
    FROM @work_database_schema.@cohort_table c
    JOIN @cdm_database_schema.person p
      ON p.person_id = c.subject_id
)
-- age group at index
SELECT cohort_definition_id,
       'age_group' AS characteristic,
       CASE WHEN age_at_index > 65 THEN '>65' ELSE '<=65' END AS stratum,
       CASE WHEN age_at_index > 65 THEN 2 ELSE 1 END          AS sort_key,
       COUNT(*)                                               AS n_subjects
  FROM coh
 GROUP BY cohort_definition_id,
          CASE WHEN age_at_index > 65 THEN '>65' ELSE '<=65' END,
          CASE WHEN age_at_index > 65 THEN 2 ELSE 1 END

UNION ALL
-- sex
SELECT cohort_definition_id,
       'sex' AS characteristic,
       CASE gender_concept_id WHEN 8507 THEN 'Male'
                              WHEN 8532 THEN 'Female'
                              ELSE 'Other-Unknown' END AS stratum,
       CASE gender_concept_id WHEN 8507 THEN 1
                              WHEN 8532 THEN 2
                              ELSE 3 END               AS sort_key,
       COUNT(*)                                        AS n_subjects
  FROM coh
 GROUP BY cohort_definition_id,
          CASE gender_concept_id WHEN 8507 THEN 'Male'
                                 WHEN 8532 THEN 'Female'
                                 ELSE 'Other-Unknown' END,
          CASE gender_concept_id WHEN 8507 THEN 1
                                 WHEN 8532 THEN 2
                                 ELSE 3 END

UNION ALL
-- index year
SELECT cohort_definition_id,
       'index_year' AS characteristic,
       CAST(index_year AS VARCHAR(4)) AS stratum,
       index_year                     AS sort_key,
       COUNT(*)                       AS n_subjects
  FROM coh
 GROUP BY cohort_definition_id,
          CAST(index_year AS VARCHAR(4)),
          index_year
;
