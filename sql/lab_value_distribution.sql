-- Expects @raw_lab_results_table populated by lab_cohorts.sql
-- (normalised rows: person_id, measurement_date, test_id, cat, std_value, …).
--
-- For each target cohort and lab (cat), among subjects with a measurement in
-- @raw_lab_results_table within @lab_window_before_days days before to @lab_window_after_days days after the cohort
-- index (cohort_start_date), pick the measurement closest to index (one per
-- subject × cat) and summarise std_value.
--
-- NB: @raw_lab_results_table fans each measurement out to one row per
-- eligibility criterion (test_id) of the same cat, but std_value is
-- test_id-independent (value * factor + offset). Summarising per test_id
-- therefore emitted N identical rows per lab (and a spurious wobble when a
-- same-day tie was broken differently across partitions). We collapse to
-- distinct (person_id, measurement_date, cat, std_value) first, so the output
-- is one row per cohort × lab.
--
-- Output columns:
--   cohort_definition_id, cat,
--   n_with_lab, mean_value, sd_value, median_value, lq_value, uq_value
--
-- SqlRender parameters:
--   @target_database_schema
--   @target_cohort_table
--   @raw_lab_results_table
--   @cohort_definition_ids   comma-separated cohort_definition_id list
--   @lab_window_before_days integer (default 14)  @lab_window_after_days integer (default 7)
--   @min_cell_count          privacy floor for n_with_lab (e.g. 5)
-- =============================================================================

WITH target_cohorts AS (
  SELECT c.cohort_definition_id,
         c.subject_id,
         c.cohort_start_date
    FROM @target_database_schema.@target_cohort_table c
   WHERE c.cohort_definition_id IN (@cohort_definition_ids)
),
-- Collapse the per-criterion (test_id) fan-out: one row per actual
-- measurement of a lab, so a cat used by several thresholds is not counted
-- (or averaged) multiple times.
lab_measurements AS (
  SELECT DISTINCT
         lab.person_id,
         lab.measurement_date,
         lab.cat,
         lab.std_value
    FROM @target_database_schema.@raw_lab_results_table lab
   WHERE lab.std_value IS NOT NULL
),
lab_near_index AS (
  SELECT tc.cohort_definition_id,
         tc.subject_id,
         lab.cat,
         lab.std_value,
         ROW_NUMBER() OVER (
           PARTITION BY tc.cohort_definition_id, tc.subject_id, lab.cat
           ORDER BY ABS(DATEDIFF(day, lab.measurement_date, tc.cohort_start_date)),
                    lab.measurement_date DESC,
                    lab.std_value DESC          -- deterministic same-day tie-break
         ) AS rn
    FROM target_cohorts tc
   INNER JOIN lab_measurements lab
      ON lab.person_id = tc.subject_id
     AND lab.measurement_date BETWEEN DATEADD(day, -@lab_window_before_days, tc.cohort_start_date)
                                  AND DATEADD(day,  @lab_window_after_days, tc.cohort_start_date)
),
lab_one_per_subject AS (
  SELECT cohort_definition_id,
         subject_id,
         cat,
         std_value
    FROM lab_near_index
   WHERE rn = 1
),
-- SQL Server allows PERCENTILE_CONT only as a window function (never as an
-- aggregate with GROUP BY), so compute every summary as a window over the
-- (cohort, cat) group and collapse with SELECT DISTINCT.
lab_stats AS (
  SELECT cohort_definition_id,
         cat,
         COUNT(*)                        OVER (PARTITION BY cohort_definition_id, cat) AS n_with_lab,
         AVG(CAST(std_value AS FLOAT))   OVER (PARTITION BY cohort_definition_id, cat) AS mean_value,
         STDEV(CAST(std_value AS FLOAT)) OVER (PARTITION BY cohort_definition_id, cat) AS sd_value,
         PERCENTILE_CONT(0.50) WITHIN GROUP (ORDER BY std_value)
           OVER (PARTITION BY cohort_definition_id, cat) AS median_value,
         PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY std_value)
           OVER (PARTITION BY cohort_definition_id, cat) AS lq_value,
         PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY std_value)
           OVER (PARTITION BY cohort_definition_id, cat) AS uq_value
    FROM lab_one_per_subject
)
SELECT DISTINCT
       cohort_definition_id,
       cat,
       -- Privacy: censor cells with 0 < n_with_lab < @min_cell_count
       -- (count -> -@min_cell_count, distribution stats -> NULL), matching
       -- censorCounts() so standalone runs are censored like the pipeline.
       CASE WHEN n_with_lab > 0 AND n_with_lab < @min_cell_count
            THEN -1 * @min_cell_count ELSE n_with_lab END      AS n_with_lab,
       CASE WHEN n_with_lab > 0 AND n_with_lab < @min_cell_count
            THEN NULL ELSE mean_value   END                    AS mean_value,
       CASE WHEN n_with_lab > 0 AND n_with_lab < @min_cell_count
            THEN NULL ELSE sd_value     END                    AS sd_value,
       CASE WHEN n_with_lab > 0 AND n_with_lab < @min_cell_count
            THEN NULL ELSE median_value END                    AS median_value,
       CASE WHEN n_with_lab > 0 AND n_with_lab < @min_cell_count
            THEN NULL ELSE lq_value     END                    AS lq_value,
       CASE WHEN n_with_lab > 0 AND n_with_lab < @min_cell_count
            THEN NULL ELSE uq_value     END                    AS uq_value
  FROM lab_stats
 ORDER BY cohort_definition_id, cat;
