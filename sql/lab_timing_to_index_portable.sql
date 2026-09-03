-- Dialect-portable: for each target cohort (Target 1A / Target 1A PC allowed)
-- and lab (cat), how far from the cohort index (cohort_start_date, the
-- metastasis-marker date) is the closest recorded measurement -- looking at
-- a subject's ENTIRE measurement history, not the +/- 14/7-day eligibility
-- window lab_value_distribution_portable.sql restricts to. Reports the
-- distribution of days-to-closest in three directions:
--   before -- closest measurement on/before index (days = index - date, >= 0)
--   after  -- closest measurement on/after index  (days = date - index, >= 0)
--   any    -- closest measurement in either direction (min absolute distance)
-- A same-day measurement (days = 0) is the closest for all three directions.
--
-- Median/quartiles use ROW_NUMBER()/COUNT(*)/FLOOR instead of
-- PERCENTILE_CONT ... WITHIN GROUP ... OVER (same interpolation as
-- lab_value_distribution_portable.sql -- see that file's header for the
-- R quantile-type-7 formula this reproduces).
--
-- Expects @raw_lab_results_table populated by lab_cohorts.sql
-- (normalised rows: person_id, measurement_date, cat, std_value, …).
--
-- Output columns:
--   cohort_definition_id, cat, direction, n_with_lab,
--   mean_days, sd_days, median_days, lq_days, uq_days
--
-- SqlRender parameters:
--   @target_database_schema
--   @target_cohort_table
--   @raw_lab_results_table
--   @cohort_definition_ids   comma-separated cohort_definition_id list
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
         lab.cat
    FROM @target_database_schema.@raw_lab_results_table lab
   WHERE lab.std_value IS NOT NULL
),
closest_before AS (
  SELECT tc.cohort_definition_id, tc.subject_id, lab.cat,
         DATEDIFF(day, lab.measurement_date, tc.cohort_start_date) AS day_diff,
         ROW_NUMBER() OVER (
           PARTITION BY tc.cohort_definition_id, tc.subject_id, lab.cat
           ORDER BY DATEDIFF(day, lab.measurement_date, tc.cohort_start_date),
                    lab.measurement_date DESC
         ) AS rn
    FROM target_cohorts tc
   INNER JOIN lab_measurements lab
      ON lab.person_id = tc.subject_id
     AND lab.measurement_date <= tc.cohort_start_date
),
closest_after AS (
  SELECT tc.cohort_definition_id, tc.subject_id, lab.cat,
         DATEDIFF(day, tc.cohort_start_date, lab.measurement_date) AS day_diff,
         ROW_NUMBER() OVER (
           PARTITION BY tc.cohort_definition_id, tc.subject_id, lab.cat
           ORDER BY DATEDIFF(day, tc.cohort_start_date, lab.measurement_date),
                    lab.measurement_date ASC
         ) AS rn
    FROM target_cohorts tc
   INNER JOIN lab_measurements lab
      ON lab.person_id = tc.subject_id
     AND lab.measurement_date >= tc.cohort_start_date
),
closest_any AS (
  SELECT tc.cohort_definition_id, tc.subject_id, lab.cat,
         ABS(DATEDIFF(day, lab.measurement_date, tc.cohort_start_date)) AS day_diff,
         ROW_NUMBER() OVER (
           PARTITION BY tc.cohort_definition_id, tc.subject_id, lab.cat
           ORDER BY ABS(DATEDIFF(day, lab.measurement_date, tc.cohort_start_date)),
                    lab.measurement_date DESC
         ) AS rn
    FROM target_cohorts tc
   INNER JOIN lab_measurements lab
      ON lab.person_id = tc.subject_id
),
one_per_subject AS (
  SELECT 'before' AS direction, cohort_definition_id, subject_id, cat, day_diff
    FROM closest_before WHERE rn = 1
  UNION ALL
  SELECT 'after' AS direction, cohort_definition_id, subject_id, cat, day_diff
    FROM closest_after WHERE rn = 1
  UNION ALL
  SELECT 'any' AS direction, cohort_definition_id, subject_id, cat, day_diff
    FROM closest_any WHERE rn = 1
),
ranked AS (
  SELECT direction, cohort_definition_id, cat, day_diff,
         ROW_NUMBER() OVER (PARTITION BY direction, cohort_definition_id, cat ORDER BY day_diff) AS rn,
         COUNT(*)     OVER (PARTITION BY direction, cohort_definition_id, cat)                   AS n
    FROM one_per_subject
),
lab_stats AS (
  SELECT direction,
         cohort_definition_id,
         cat,
         COUNT(*)                          AS n_with_lab,
         AVG(CAST(day_diff AS FLOAT))      AS mean_days,
         STDEV(CAST(day_diff AS FLOAT))    AS sd_days,
         SUM(CASE WHEN rn = FLOOR(0.50 * (n - 1)) + 1
                  THEN day_diff * (1.0 - (0.50 * (n - 1) - FLOOR(0.50 * (n - 1))))
                  WHEN rn = FLOOR(0.50 * (n - 1)) + 2
                  THEN day_diff * (0.50 * (n - 1) - FLOOR(0.50 * (n - 1)))
                  ELSE 0 END)              AS median_days,
         SUM(CASE WHEN rn = FLOOR(0.25 * (n - 1)) + 1
                  THEN day_diff * (1.0 - (0.25 * (n - 1) - FLOOR(0.25 * (n - 1))))
                  WHEN rn = FLOOR(0.25 * (n - 1)) + 2
                  THEN day_diff * (0.25 * (n - 1) - FLOOR(0.25 * (n - 1)))
                  ELSE 0 END)              AS lq_days,
         SUM(CASE WHEN rn = FLOOR(0.75 * (n - 1)) + 1
                  THEN day_diff * (1.0 - (0.75 * (n - 1) - FLOOR(0.75 * (n - 1))))
                  WHEN rn = FLOOR(0.75 * (n - 1)) + 2
                  THEN day_diff * (0.75 * (n - 1) - FLOOR(0.75 * (n - 1)))
                  ELSE 0 END)              AS uq_days
    FROM ranked
   GROUP BY direction, cohort_definition_id, cat
)
SELECT cohort_definition_id,
       cat,
       direction,
       -- Privacy: censor cells with 0 < n_with_lab < @min_cell_count
       -- (count -> -@min_cell_count, distribution stats -> NULL), matching
       -- censorCounts() so standalone runs are censored like the pipeline.
       CASE WHEN n_with_lab > 0 AND n_with_lab < @min_cell_count
            THEN -1 * @min_cell_count ELSE n_with_lab END      AS n_with_lab,
       CASE WHEN n_with_lab > 0 AND n_with_lab < @min_cell_count
            THEN NULL ELSE mean_days   END                     AS mean_days,
       CASE WHEN n_with_lab > 0 AND n_with_lab < @min_cell_count
            THEN NULL ELSE sd_days     END                     AS sd_days,
       CASE WHEN n_with_lab > 0 AND n_with_lab < @min_cell_count
            THEN NULL ELSE median_days END                     AS median_days,
       CASE WHEN n_with_lab > 0 AND n_with_lab < @min_cell_count
            THEN NULL ELSE lq_days     END                     AS lq_days,
       CASE WHEN n_with_lab > 0 AND n_with_lab < @min_cell_count
            THEN NULL ELSE uq_days     END                     AS uq_days
  FROM lab_stats
 ORDER BY cohort_definition_id, cat, direction;
