-- =============================================================================
-- demographics_continuous.sql — per-cohort continuous age summary
-- =============================================================================
-- Companion to demographics.sql's categorical strata: age at index
-- (YEAR(cohort_start_date) - person.year_of_birth), summarized per cohort as
-- mean/SD/median/quartiles/min/max, matching the protocol's "continuous
-- variables summarized as mean (SD), minimum, maximum, median and IQR."
--
-- Median/quartiles use ROW_NUMBER()/COUNT()/FLOOR interpolation rather than
-- PERCENTILE_CONT, which SqlRender leaves untranslated (breaks PostgreSQL /
-- BigQuery / SQLite / Spark / Hive / Impala) — same technique as
-- lab_value_distribution_portable.sql; see that file's header for the
-- interpolation formula. Percentages/censoring are computed in R
-- (R/07_demographics.R), matching demographics.sql's own convention.
--
-- SqlRender parameters: @work_database_schema @cohort_table @cdm_database_schema
-- =============================================================================

WITH coh AS (
  SELECT c.cohort_definition_id,
         YEAR(c.cohort_start_date) - p.year_of_birth AS age_at_index
    FROM @work_database_schema.@cohort_table c
    JOIN @cdm_database_schema.person p
      ON p.person_id = c.subject_id
),
ranked AS (
  SELECT cohort_definition_id,
         age_at_index,
         ROW_NUMBER() OVER (PARTITION BY cohort_definition_id ORDER BY age_at_index) AS rn,
         COUNT(*)     OVER (PARTITION BY cohort_definition_id)                       AS n
    FROM coh
)
SELECT cohort_definition_id,
       COUNT(*)                                AS n,
       AVG(CAST(age_at_index AS FLOAT))         AS mean_age,
       STDEV(CAST(age_at_index AS FLOAT))       AS sd_age,
       MIN(age_at_index)                        AS min_age,
       SUM(CASE WHEN rn = FLOOR(0.25 * (n - 1)) + 1
                THEN age_at_index * (1.0 - (0.25 * (n - 1) - FLOOR(0.25 * (n - 1))))
                WHEN rn = FLOOR(0.25 * (n - 1)) + 2
                THEN age_at_index * (0.25 * (n - 1) - FLOOR(0.25 * (n - 1)))
                ELSE 0 END)                     AS lq_age,
       SUM(CASE WHEN rn = FLOOR(0.50 * (n - 1)) + 1
                THEN age_at_index * (1.0 - (0.50 * (n - 1) - FLOOR(0.50 * (n - 1))))
                WHEN rn = FLOOR(0.50 * (n - 1)) + 2
                THEN age_at_index * (0.50 * (n - 1) - FLOOR(0.50 * (n - 1)))
                ELSE 0 END)                     AS median_age,
       SUM(CASE WHEN rn = FLOOR(0.75 * (n - 1)) + 1
                THEN age_at_index * (1.0 - (0.75 * (n - 1) - FLOOR(0.75 * (n - 1))))
                WHEN rn = FLOOR(0.75 * (n - 1)) + 2
                THEN age_at_index * (0.75 * (n - 1) - FLOOR(0.75 * (n - 1)))
                ELSE 0 END)                     AS uq_age,
       MAX(age_at_index)                        AS max_age
  FROM ranked
 GROUP BY cohort_definition_id
;
