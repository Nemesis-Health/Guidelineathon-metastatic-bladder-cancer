-- =============================================================================
-- lab_results_summary_portable.sql
-- Dialect-portable version of lab_results_summary.sql: identical output, but
-- the quartiles are computed with ROW_NUMBER()/COUNT(*)/FLOOR instead of
-- PERCENTILE_CONT ... WITHIN GROUP ... OVER, which SqlRender leaves
-- untranslated (breaks PostgreSQL / BigQuery / SQLite / Spark / Hive / Impala).
--
-- Interpolation reproduces PERCENTILE_CONT exactly (R quantile type 7):
--   pos = p * (n - 1)  (zero-based), k = FLOOR(pos), frac = pos - k
--   percentile = v[k] * (1 - frac) + v[k+1] * frac
-- so ranked rows rn = k+1 and rn = k+2 contribute weights (1-frac) and frac.
--
-- Export/QC summary of @raw_lab_results_table (the former #eval table written by
-- lab_cohorts.sql). One row per (cat, measurement_concept_id, unit_concept_id,
-- status, is_ambiguous): patient + measurement counts and the distribution of
-- the normalised value (std_value).
--
-- Privacy: cells with fewer than @min_cell_count DISTINCT patients are censored
-- — n_patients -> -@min_cell_count and all counts/stats -> NULL.
--
-- NOTE: @raw_lab_results_table holds one row per (measurement x test_id); the
-- `meas` CTE collapses that to one row per physical measurement before counting
-- so a lab with N test_ids (e.g. GFR) is not counted N times.
--
-- SqlRender parameters:
--   @work_database_schema
--   @raw_lab_results_table
--   @vocabulary_database_schema   (for concept names; LEFT JOIN, optional)
--   @min_cell_count               integer (e.g. 5)
-- =============================================================================

WITH meas AS (
  SELECT DISTINCT
         cat, measurement_concept_id, unit_concept_id, status, is_ambiguous,
         person_id, measurement_date, std_value
    FROM @work_database_schema.@raw_lab_results_table
   WHERE std_value IS NOT NULL
),
ranked AS (
  SELECT cat, measurement_concept_id, unit_concept_id, status, is_ambiguous,
         person_id, std_value,
         ROW_NUMBER() OVER (PARTITION BY measurement_concept_id, unit_concept_id, status, is_ambiguous
                            ORDER BY std_value) AS rn,
         COUNT(*)     OVER (PARTITION BY measurement_concept_id, unit_concept_id, status, is_ambiguous) AS n
    FROM meas
),
agg AS (
  SELECT cat, measurement_concept_id, unit_concept_id, status, is_ambiguous,
         COUNT(DISTINCT person_id)          AS n_patients,
         COUNT(*)                           AS n_measurements,
         AVG(CAST(std_value AS FLOAT))      AS mean_value,
         STDEV(CAST(std_value AS FLOAT))    AS sd_value,
         MIN(std_value)                     AS min_value,
         SUM(CASE WHEN rn = FLOOR(0.25 * (n - 1)) + 1
                  THEN std_value * (1.0 - (0.25 * (n - 1) - FLOOR(0.25 * (n - 1))))
                  WHEN rn = FLOOR(0.25 * (n - 1)) + 2
                  THEN std_value * (0.25 * (n - 1) - FLOOR(0.25 * (n - 1)))
                  ELSE 0 END)               AS lq_value,
         SUM(CASE WHEN rn = FLOOR(0.50 * (n - 1)) + 1
                  THEN std_value * (1.0 - (0.50 * (n - 1) - FLOOR(0.50 * (n - 1))))
                  WHEN rn = FLOOR(0.50 * (n - 1)) + 2
                  THEN std_value * (0.50 * (n - 1) - FLOOR(0.50 * (n - 1)))
                  ELSE 0 END)               AS median_value,
         SUM(CASE WHEN rn = FLOOR(0.75 * (n - 1)) + 1
                  THEN std_value * (1.0 - (0.75 * (n - 1) - FLOOR(0.75 * (n - 1))))
                  WHEN rn = FLOOR(0.75 * (n - 1)) + 2
                  THEN std_value * (0.75 * (n - 1) - FLOOR(0.75 * (n - 1)))
                  ELSE 0 END)               AS uq_value,
         MAX(std_value)                     AS max_value
    FROM ranked
   GROUP BY cat, measurement_concept_id, unit_concept_id, status, is_ambiguous
)
SELECT a.cat,
       a.measurement_concept_id,
       mc.concept_name AS measurement_concept_name,
       a.unit_concept_id,
       uc.concept_name AS unit_concept_name,
       a.status,
       a.is_ambiguous,
       CASE WHEN a.n_patients < @min_cell_count THEN -1 * @min_cell_count ELSE a.n_patients END      AS n_patients,
       CASE WHEN a.n_patients < @min_cell_count THEN NULL ELSE a.n_measurements END                   AS n_measurements,
       CASE WHEN a.n_patients < @min_cell_count THEN NULL ELSE a.mean_value END                       AS mean_value,
       CASE WHEN a.n_patients < @min_cell_count THEN NULL ELSE a.sd_value END                         AS sd_value,
       CASE WHEN a.n_patients < @min_cell_count THEN NULL ELSE a.min_value END                        AS min_value,
       CASE WHEN a.n_patients < @min_cell_count THEN NULL ELSE a.lq_value END                         AS lq_value,
       CASE WHEN a.n_patients < @min_cell_count THEN NULL ELSE a.median_value END                     AS median_value,
       CASE WHEN a.n_patients < @min_cell_count THEN NULL ELSE a.uq_value END                         AS uq_value,
       CASE WHEN a.n_patients < @min_cell_count THEN NULL ELSE a.max_value END                        AS max_value
  FROM agg a
  LEFT JOIN @vocabulary_database_schema.concept mc ON mc.concept_id = a.measurement_concept_id
  LEFT JOIN @vocabulary_database_schema.concept uc ON uc.concept_id = a.unit_concept_id
 ORDER BY a.cat, a.measurement_concept_id, a.unit_concept_id, a.status;
