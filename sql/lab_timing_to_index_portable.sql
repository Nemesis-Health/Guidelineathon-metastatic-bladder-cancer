-- Dialect-portable: for each target cohort (Target 1A / Target 1A PC allowed)
-- and lab (cat), how far from the cohort index (cohort_start_date, the
-- metastasis-marker date) is the closest recorded measurement -- looking at
-- a subject's ENTIRE measurement history, not the +/- 14/7-day eligibility
-- window lab_value_distribution_portable.sql restricts to. Reports, in three
-- directions:
--   before -- closest measurement on/before index (days = index - date, >= 0)
--   after  -- closest measurement on/after index  (days = date - index, >= 0)
--   any    -- closest measurement in either direction (min absolute distance)
-- A same-day measurement (days = 0) is the closest for all three directions.
--
-- Also stratified: every (cohort, cat, direction) row is computed four
-- times -- overall, and split by age_group / sex / age_sex (subject_strata.sql
-- -- see that file's header for the standard consumption pattern this
-- follows). stratum_type/stratum_value identify which view a row belongs to.
--
-- Two kinds of output per (stratum_type, stratum_value, cohort, cat, direction):
--   1. Coverage buckets -- how many subjects have their closest measurement
--      within N days, for N = 14/30/60/90/180, plus n_ever (no day cap at
--      all -- everyone with a measurement in that direction, at any time).
--      Cumulative from 0, not disjoint bins (n_0_30 includes everyone
--      counted in n_0_14).
--   2. Percentiles (p5/p10/p25/p50/p75/p90/p95) of days-to-closest, among
--      subjects counted in n_ever (i.e. conditional on having a
--      measurement at all in that direction).
--
-- Percentiles use ROW_NUMBER()/COUNT(*)/FLOOR instead of
-- PERCENTILE_CONT ... WITHIN GROUP ... OVER, which SqlRender leaves
-- untranslated (breaks PostgreSQL / BigQuery / SQLite / Spark / Hive /
-- Impala). Interpolation reproduces PERCENTILE_CONT exactly (R quantile
-- type 7): pos = p * (n - 1) (zero-based), k = FLOOR(pos), frac = pos - k;
-- percentile = v[k] * (1 - frac) + v[k+1] * frac, so ranked rows rn = k+1
-- and rn = k+2 contribute weights (1-frac) and frac.
--
-- The ranking (ROW_NUMBER/COUNT window functions, partitioned differently
-- per stratum view) is computed once per view via UNION ALL in `ranked`;
-- the percentile formulas themselves are written once, in `lab_stats`,
-- shared across every view via one shared GROUP BY -- adding a future
-- stratum view means one more `ranked` branch, not a duplicated formula.
--
-- Expects @raw_lab_results_table populated by lab_cohorts.sql
-- (normalised rows: person_id, measurement_date, cat, std_value, …).
--
-- Output columns:
--   stratum_type, stratum_value, cohort_definition_id, cat, direction,
--   n_0_14, n_0_30, n_0_60, n_0_90, n_0_180, n_ever,
--   p5_days, p10_days, p25_days, p50_days, p75_days, p90_days, p95_days
--
-- SqlRender parameters:
--   @target_database_schema
--   @target_cohort_table
--   @raw_lab_results_table
--   @cohort_definition_ids   comma-separated cohort_definition_id list
--   @min_cell_count          privacy floor for every n_* column (e.g. 5)
--   subject_strata_sql (pre-rendered fragment, not a plain schema/table
--   name -- see the `strata` CTE below): subject_strata.sql's own output,
--   age_group/sex/age_sex per (cohort_definition_id, subject_id)
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
strata AS (
  @subject_strata_sql
),
tagged AS (
  SELECT ops.direction, ops.cohort_definition_id, ops.subject_id, ops.cat,
         ops.day_diff, s.age_group, s.sex, s.age_sex
    FROM one_per_subject ops
    JOIN strata s
      ON s.cohort_definition_id = ops.cohort_definition_id
     AND s.subject_id           = ops.subject_id
),
ranked AS (
  SELECT 'overall' AS stratum_type, 'overall' AS stratum_value,
         direction, cohort_definition_id, cat, day_diff,
         ROW_NUMBER() OVER (
           PARTITION BY direction, cohort_definition_id, cat
           ORDER BY day_diff)                                              AS rn,
         COUNT(*) OVER (
           PARTITION BY direction, cohort_definition_id, cat)               AS n
    FROM tagged
  UNION ALL
  SELECT 'age_group' AS stratum_type, age_group AS stratum_value,
         direction, cohort_definition_id, cat, day_diff,
         ROW_NUMBER() OVER (
           PARTITION BY direction, cohort_definition_id, cat, age_group
           ORDER BY day_diff)                                              AS rn,
         COUNT(*) OVER (
           PARTITION BY direction, cohort_definition_id, cat, age_group)    AS n
    FROM tagged
  UNION ALL
  SELECT 'sex' AS stratum_type, sex AS stratum_value,
         direction, cohort_definition_id, cat, day_diff,
         ROW_NUMBER() OVER (
           PARTITION BY direction, cohort_definition_id, cat, sex
           ORDER BY day_diff)                                              AS rn,
         COUNT(*) OVER (
           PARTITION BY direction, cohort_definition_id, cat, sex)          AS n
    FROM tagged
  UNION ALL
  SELECT 'age_sex' AS stratum_type, age_sex AS stratum_value,
         direction, cohort_definition_id, cat, day_diff,
         ROW_NUMBER() OVER (
           PARTITION BY direction, cohort_definition_id, cat, age_sex
           ORDER BY day_diff)                                              AS rn,
         COUNT(*) OVER (
           PARTITION BY direction, cohort_definition_id, cat, age_sex)      AS n
    FROM tagged
),
lab_stats AS (
  SELECT stratum_type,
         stratum_value,
         direction,
         cohort_definition_id,
         cat,
         COUNT(*)                                             AS n_ever,
         SUM(CASE WHEN day_diff <= 14  THEN 1 ELSE 0 END)      AS n_0_14,
         SUM(CASE WHEN day_diff <= 30  THEN 1 ELSE 0 END)      AS n_0_30,
         SUM(CASE WHEN day_diff <= 60  THEN 1 ELSE 0 END)      AS n_0_60,
         SUM(CASE WHEN day_diff <= 90  THEN 1 ELSE 0 END)      AS n_0_90,
         SUM(CASE WHEN day_diff <= 180 THEN 1 ELSE 0 END)      AS n_0_180,
         SUM(CASE WHEN rn = FLOOR(0.05 * (n - 1)) + 1
                  THEN day_diff * (1.0 - (0.05 * (n - 1) - FLOOR(0.05 * (n - 1))))
                  WHEN rn = FLOOR(0.05 * (n - 1)) + 2
                  THEN day_diff * (0.05 * (n - 1) - FLOOR(0.05 * (n - 1)))
                  ELSE 0 END)                                  AS p5_days,
         SUM(CASE WHEN rn = FLOOR(0.10 * (n - 1)) + 1
                  THEN day_diff * (1.0 - (0.10 * (n - 1) - FLOOR(0.10 * (n - 1))))
                  WHEN rn = FLOOR(0.10 * (n - 1)) + 2
                  THEN day_diff * (0.10 * (n - 1) - FLOOR(0.10 * (n - 1)))
                  ELSE 0 END)                                  AS p10_days,
         SUM(CASE WHEN rn = FLOOR(0.25 * (n - 1)) + 1
                  THEN day_diff * (1.0 - (0.25 * (n - 1) - FLOOR(0.25 * (n - 1))))
                  WHEN rn = FLOOR(0.25 * (n - 1)) + 2
                  THEN day_diff * (0.25 * (n - 1) - FLOOR(0.25 * (n - 1)))
                  ELSE 0 END)                                  AS p25_days,
         SUM(CASE WHEN rn = FLOOR(0.50 * (n - 1)) + 1
                  THEN day_diff * (1.0 - (0.50 * (n - 1) - FLOOR(0.50 * (n - 1))))
                  WHEN rn = FLOOR(0.50 * (n - 1)) + 2
                  THEN day_diff * (0.50 * (n - 1) - FLOOR(0.50 * (n - 1)))
                  ELSE 0 END)                                  AS p50_days,
         SUM(CASE WHEN rn = FLOOR(0.75 * (n - 1)) + 1
                  THEN day_diff * (1.0 - (0.75 * (n - 1) - FLOOR(0.75 * (n - 1))))
                  WHEN rn = FLOOR(0.75 * (n - 1)) + 2
                  THEN day_diff * (0.75 * (n - 1) - FLOOR(0.75 * (n - 1)))
                  ELSE 0 END)                                  AS p75_days,
         SUM(CASE WHEN rn = FLOOR(0.90 * (n - 1)) + 1
                  THEN day_diff * (1.0 - (0.90 * (n - 1) - FLOOR(0.90 * (n - 1))))
                  WHEN rn = FLOOR(0.90 * (n - 1)) + 2
                  THEN day_diff * (0.90 * (n - 1) - FLOOR(0.90 * (n - 1)))
                  ELSE 0 END)                                  AS p90_days,
         SUM(CASE WHEN rn = FLOOR(0.95 * (n - 1)) + 1
                  THEN day_diff * (1.0 - (0.95 * (n - 1) - FLOOR(0.95 * (n - 1))))
                  WHEN rn = FLOOR(0.95 * (n - 1)) + 2
                  THEN day_diff * (0.95 * (n - 1) - FLOOR(0.95 * (n - 1)))
                  ELSE 0 END)                                  AS p95_days
    FROM ranked
-- Qualified with the `ranked` CTE name rather than bare column names:
-- BigQuery-only fix, see docs/BIGQUERY.md (SqlRender's ordinal-GROUP-BY
-- rewrite for this dialect can mis-resolve bare GROUP BY columns onto an
-- aggregate expression's position, which BigQuery then rejects outright).
   GROUP BY ranked.stratum_type, ranked.stratum_value, ranked.direction, ranked.cohort_definition_id, ranked.cat
)
SELECT stratum_type,
       stratum_value,
       cohort_definition_id,
       cat,
       direction,
       -- Privacy: censor each bucket independently (0 < count < @min_cell_count
       -- -> -@min_cell_count sentinel; a true 0 stays 0), matching
       -- censorCounts() so standalone runs are censored like the pipeline.
       -- Percentiles are blanked whenever the n_ever population itself is
       -- censored (they're computed over that same population).
       CASE WHEN n_0_14  > 0 AND n_0_14  < @min_cell_count THEN -1 * @min_cell_count ELSE n_0_14  END AS n_0_14,
       CASE WHEN n_0_30  > 0 AND n_0_30  < @min_cell_count THEN -1 * @min_cell_count ELSE n_0_30  END AS n_0_30,
       CASE WHEN n_0_60  > 0 AND n_0_60  < @min_cell_count THEN -1 * @min_cell_count ELSE n_0_60  END AS n_0_60,
       CASE WHEN n_0_90  > 0 AND n_0_90  < @min_cell_count THEN -1 * @min_cell_count ELSE n_0_90  END AS n_0_90,
       CASE WHEN n_0_180 > 0 AND n_0_180 < @min_cell_count THEN -1 * @min_cell_count ELSE n_0_180 END AS n_0_180,
       CASE WHEN n_ever  > 0 AND n_ever  < @min_cell_count THEN -1 * @min_cell_count ELSE n_ever  END AS n_ever,
       CASE WHEN n_ever > 0 AND n_ever < @min_cell_count THEN NULL ELSE p5_days  END AS p5_days,
       CASE WHEN n_ever > 0 AND n_ever < @min_cell_count THEN NULL ELSE p10_days END AS p10_days,
       CASE WHEN n_ever > 0 AND n_ever < @min_cell_count THEN NULL ELSE p25_days END AS p25_days,
       CASE WHEN n_ever > 0 AND n_ever < @min_cell_count THEN NULL ELSE p50_days END AS p50_days,
       CASE WHEN n_ever > 0 AND n_ever < @min_cell_count THEN NULL ELSE p75_days END AS p75_days,
       CASE WHEN n_ever > 0 AND n_ever < @min_cell_count THEN NULL ELSE p90_days END AS p90_days,
       CASE WHEN n_ever > 0 AND n_ever < @min_cell_count THEN NULL ELSE p95_days END AS p95_days
  FROM lab_stats
 ORDER BY cohort_definition_id, cat, direction, stratum_type, stratum_value;
