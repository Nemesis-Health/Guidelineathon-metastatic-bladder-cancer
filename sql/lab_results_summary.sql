-- =============================================================================
-- lab_results_summary.sql
-- Export/QC summary of @raw_lab_results_table (the former #eval table written by
-- lab_cohorts.sql). One row per (cat, measurement_concept_id, unit_concept_id,
-- status, is_ambiguous): patient + measurement counts and the distribution of
-- the normalised value (std_value). Use it to sanity-check unit resolution —
-- every unit for a given lab should land in the same std_value range.
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
pct AS (
  SELECT cat, measurement_concept_id, unit_concept_id, status, is_ambiguous,
         person_id, std_value,
         PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY std_value)
           OVER (PARTITION BY measurement_concept_id, unit_concept_id, status, is_ambiguous) AS lq,
         PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY std_value)
           OVER (PARTITION BY measurement_concept_id, unit_concept_id, status, is_ambiguous) AS med,
         PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY std_value)
           OVER (PARTITION BY measurement_concept_id, unit_concept_id, status, is_ambiguous) AS uq
    FROM meas
),
agg AS (
  SELECT cat, measurement_concept_id, unit_concept_id, status, is_ambiguous,
         COUNT(DISTINCT person_id)          AS n_patients,
         COUNT(*)                           AS n_measurements,
         AVG(CAST(std_value AS FLOAT))      AS mean_value,
         STDEV(CAST(std_value AS FLOAT))    AS sd_value,
         MIN(std_value)                     AS min_value,
         MAX(lq)                            AS lq_value,
         MAX(med)                           AS median_value,
         MAX(uq)                            AS uq_value,
         MAX(std_value)                     AS max_value
    FROM pct
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
