-- =============================================================================
-- demographics_continuous.sql — per-cohort x stratum continuous age summary
-- =============================================================================
-- Companion to demographics.sql's categorical strata: age at index
-- (YEAR(cohort_start_date) - person.year_of_birth), summarized per cohort as
-- mean/SD/median/quartiles/min/max, matching the protocol's "continuous
-- variables summarized as mean (SD), minimum, maximum, median and IQR."
--
-- Also stratified: every cohort's row is computed four times -- overall, and
-- split by age_group / sex / age_sex (subject_strata.sql -- see that file's
-- own header for the standard consumption pattern this follows). Same
-- UNION-ALL-of-shared-percentile-formula shape as
-- lab_value_distribution_portable.sql -- see that file's header for the
-- interpolation formula (reproduces PERCENTILE_CONT exactly, R quantile
-- type 7). Percentages/censoring are computed in R (R/07_demographics.R),
-- matching demographics.sql's own convention.
--
-- SqlRender parameters: @work_database_schema @cohort_table @cdm_database_schema
--   subject_strata_sql (pre-rendered fragment, not a plain schema/table name
--   -- see the `strata` CTE below): subject_strata.sql's own output,
--   age_group/sex/age_sex per (cohort_definition_id, subject_id)
-- =============================================================================

WITH coh AS (
  SELECT c.cohort_definition_id,
         c.subject_id,
         YEAR(c.cohort_start_date) - p.year_of_birth AS age_at_index
    FROM @work_database_schema.@cohort_table c
    JOIN @cdm_database_schema.person p
      ON p.person_id = c.subject_id
),
strata AS (
  @subject_strata_sql
),
tagged AS (
  SELECT coh.cohort_definition_id, coh.subject_id, coh.age_at_index,
         s.age_group, s.sex, s.age_sex
    FROM coh
    JOIN strata s
      ON s.cohort_definition_id = coh.cohort_definition_id
     AND s.subject_id           = coh.subject_id
),
ranked AS (
  SELECT 'overall' AS stratum_type, 'overall' AS stratum_value,
         cohort_definition_id, age_at_index,
         ROW_NUMBER() OVER (PARTITION BY cohort_definition_id ORDER BY age_at_index) AS rn,
         COUNT(*)     OVER (PARTITION BY cohort_definition_id)                       AS n
    FROM tagged
  UNION ALL
  SELECT 'age_group' AS stratum_type, age_group AS stratum_value,
         cohort_definition_id, age_at_index,
         ROW_NUMBER() OVER (PARTITION BY cohort_definition_id, age_group ORDER BY age_at_index) AS rn,
         COUNT(*)     OVER (PARTITION BY cohort_definition_id, age_group)                       AS n
    FROM tagged
  UNION ALL
  SELECT 'sex' AS stratum_type, sex AS stratum_value,
         cohort_definition_id, age_at_index,
         ROW_NUMBER() OVER (PARTITION BY cohort_definition_id, sex ORDER BY age_at_index) AS rn,
         COUNT(*)     OVER (PARTITION BY cohort_definition_id, sex)                       AS n
    FROM tagged
  UNION ALL
  SELECT 'age_sex' AS stratum_type, age_sex AS stratum_value,
         cohort_definition_id, age_at_index,
         ROW_NUMBER() OVER (PARTITION BY cohort_definition_id, age_sex ORDER BY age_at_index) AS rn,
         COUNT(*)     OVER (PARTITION BY cohort_definition_id, age_sex)                       AS n
    FROM tagged
)
SELECT stratum_type,
       stratum_value,
       cohort_definition_id,
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
-- Qualified with the `ranked` CTE name rather than bare column names:
-- BigQuery-only fix, see docs/BIGQUERY.md. SqlRender's ordinal-GROUP-BY
-- rewrite for this dialect resolved both `stratum_type` and `stratum_value`
-- (bare) to the SAME wrong position -- one that holds an aggregate
-- expression -- producing `GROUP BY 8, 8, 3`, which BigQuery then rejects
-- outright ("Column 8 contains an aggregation function, which is not
-- allowed in GROUP BY"; found live, 2026-09-06). Qualifying makes each a
-- dotted `alias.column` reference, which the rewrite copies straight
-- through untouched instead of searching for it.
 GROUP BY ranked.stratum_type, ranked.stratum_value, ranked.cohort_definition_id
 ORDER BY cohort_definition_id, stratum_type, stratum_value
;
