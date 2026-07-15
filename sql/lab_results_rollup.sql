-- =============================================================================
-- lab_results_rollup.sql
-- Per-CATEGORY rollup of @raw_lab_results_table, the headline companion to the
-- per-stream lab_results_summary.sql. Because std_value is already normalised to
-- each category's standard unit, the distribution is pooled across every source
-- concept/unit into ONE row per (cat, is_ambiguous):
--   * is_ambiguous = 0  -> the trustworthy distribution (single scale won).
--   * is_ambiguous = 1  -> streams where >1 scale cleared 0.7 decades, so the
--                          chosen factor (hence std_value) may be wrong. Kept as
--                          a SEPARATE row so it never contaminates the clean one.
-- The number is reported in the category's standard unit (std_unit_name, from
-- @normals_table). Unit-resolution health is preserved as QC columns rather than
-- as extra rows: n_concepts / n_units feeding the category, and the share of
-- measurements whose recorded unit was overridden or could not be verified.
--
-- This original uses PERCENTILE_CONT, which SqlRender cannot translate; run
-- lab_results_rollup_portable.sql on non-SQL-Server dialects. Kept alongside for
-- comparison.
--
-- Privacy: cells with fewer than @min_cell_count DISTINCT patients are censored
-- — n_patients -> -@min_cell_count and all counts/stats -> NULL.
--
-- NOTE: @raw_lab_results_table holds one row per (measurement x test_id); the
-- `meas` CTE collapses that to one row per physical measurement before counting
-- so a lab with N test_ids (e.g. GFR) is not counted N times, and n_patients is
-- a true patient count pooled across the category's streams (not a sum of the
-- per-stream counts in lab_results_summary).
--
-- SqlRender parameters:
--   @work_database_schema
--   @raw_lab_results_table
--   @normals_table                (std unit per cat; LEFT JOIN)
--   @vocabulary_database_schema   (for the std unit name; LEFT JOIN, optional)
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
  SELECT cat, is_ambiguous, status, measurement_concept_id, unit_concept_id,
         person_id, std_value,
         PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY std_value)
           OVER (PARTITION BY cat, is_ambiguous) AS lq,
         PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY std_value)
           OVER (PARTITION BY cat, is_ambiguous) AS med,
         PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY std_value)
           OVER (PARTITION BY cat, is_ambiguous) AS uq
    FROM meas
),
agg AS (
  SELECT cat, is_ambiguous,
         COUNT(DISTINCT person_id)                                    AS n_patients,
         COUNT(*)                                                     AS n_measurements,
         COUNT(DISTINCT measurement_concept_id)                       AS n_concepts,
         COUNT(DISTINCT unit_concept_id)                              AS n_units,
         SUM(CASE WHEN status = 'overridden' THEN 1 ELSE 0 END)       AS n_overridden,
         SUM(CASE WHEN status = 'unverified' THEN 1 ELSE 0 END)       AS n_unverified,
         AVG(CAST(std_value AS FLOAT))                                AS mean_value,
         STDEV(CAST(std_value AS FLOAT))                              AS sd_value,
         MIN(std_value)                                               AS min_value,
         MAX(lq)                                                      AS lq_value,
         MAX(med)                                                     AS median_value,
         MAX(uq)                                                      AS uq_value,
         MAX(std_value)                                               AS max_value
    FROM pct
   GROUP BY cat, is_ambiguous
)
SELECT a.cat,
       nu.concept_name AS std_unit_name,
       a.is_ambiguous,
       CASE WHEN a.n_patients < @min_cell_count THEN -1 * @min_cell_count ELSE a.n_patients END       AS n_patients,
       CASE WHEN a.n_patients < @min_cell_count THEN NULL ELSE a.n_measurements END                    AS n_measurements,
       CASE WHEN a.n_patients < @min_cell_count THEN NULL ELSE a.n_concepts END                        AS n_concepts,
       CASE WHEN a.n_patients < @min_cell_count THEN NULL ELSE a.n_units END                           AS n_units,
       CASE WHEN a.n_patients < @min_cell_count THEN NULL ELSE 100.0 * a.n_overridden / a.n_measurements END AS pct_overridden,
       CASE WHEN a.n_patients < @min_cell_count THEN NULL ELSE 100.0 * a.n_unverified / a.n_measurements END AS pct_unverified,
       CASE WHEN a.n_patients < @min_cell_count THEN NULL ELSE a.mean_value END                        AS mean_value,
       CASE WHEN a.n_patients < @min_cell_count THEN NULL ELSE a.sd_value END                          AS sd_value,
       CASE WHEN a.n_patients < @min_cell_count THEN NULL ELSE a.min_value END                         AS min_value,
       CASE WHEN a.n_patients < @min_cell_count THEN NULL ELSE a.lq_value END                          AS lq_value,
       CASE WHEN a.n_patients < @min_cell_count THEN NULL ELSE a.median_value END                      AS median_value,
       CASE WHEN a.n_patients < @min_cell_count THEN NULL ELSE a.uq_value END                          AS uq_value,
       CASE WHEN a.n_patients < @min_cell_count THEN NULL ELSE a.max_value END                         AS max_value
  FROM agg a
  LEFT JOIN @work_database_schema.@normals_table nm ON nm.cat = a.cat
  LEFT JOIN @vocabulary_database_schema.concept    nu ON nu.concept_id = nm.std_unit_concept_id
 ORDER BY a.cat, a.is_ambiguous;
