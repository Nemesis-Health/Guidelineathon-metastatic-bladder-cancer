-- Dialect-portable version of lab_value_distribution.sql: identical output,
-- but median/quartiles use ROW_NUMBER()/COUNT(*)/FLOOR instead of
-- PERCENTILE_CONT ... WITHIN GROUP ... OVER, which SqlRender leaves
-- untranslated (breaks PostgreSQL / BigQuery / SQLite / Spark / Hive / Impala).
-- The GROUP BY also replaces the window+SELECT DISTINCT workaround the
-- original needed because SQL Server only allows PERCENTILE_CONT as a window.
--
-- Interpolation reproduces PERCENTILE_CONT exactly (R quantile type 7):
--   pos = p * (n - 1)  (zero-based), k = FLOOR(pos), frac = pos - k
--   percentile = v[k] * (1 - frac) + v[k+1] * frac
-- so ranked rows rn = k+1 and rn = k+2 contribute weights (1-frac) and frac.
--
-- Expects @raw_lab_results_table populated by lab_cohorts.sql
-- (normalised rows: person_id, measurement_date, test_id, cat, std_value, …).
--
-- For each target cohort and lab (cat), among subjects with a measurement in
-- @raw_lab_results_table within @lab_window_before_days days before to @lab_window_after_days days after the cohort
-- index (cohort_start_date), pick the measurement closest to index (one per
-- subject × cat) and summarise std_value.
--
-- Also stratified: every (cohort, cat) row is computed four times --
-- overall, and split by age_group / sex / age_sex (subject_strata.sql --
-- see that file's header for the standard consumption pattern this
-- follows, and lab_timing_to_index_portable.sql for the same UNION-ALL
-- ranking / shared-percentile-formula shape). stratum_type/stratum_value
-- identify which view a row belongs to.
--
-- Output columns:
--   stratum_type, stratum_value, cohort_definition_id, cat,
--   n_with_lab, mean_value, sd_value, median_value, lq_value, uq_value
--
-- SqlRender parameters:
--   @target_database_schema
--   @target_cohort_table
--   @raw_lab_results_table
--   @cohort_definition_ids   comma-separated cohort_definition_id list
--   @lab_window_before_days integer (default 14)  @lab_window_after_days integer (default 7)
--   @min_cell_count          privacy floor for n_with_lab (e.g. 5)
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
strata AS (
  @subject_strata_sql
),
tagged AS (
  SELECT lo.cohort_definition_id, lo.subject_id, lo.cat, lo.std_value,
         s.age_group, s.sex, s.age_sex
    FROM lab_one_per_subject lo
    JOIN strata s
      ON s.cohort_definition_id = lo.cohort_definition_id
     AND s.subject_id           = lo.subject_id
),
ranked AS (
  SELECT 'overall' AS stratum_type, 'overall' AS stratum_value,
         cohort_definition_id, cat, std_value,
         ROW_NUMBER() OVER (
           PARTITION BY cohort_definition_id, cat
           ORDER BY std_value)                                       AS rn,
         COUNT(*) OVER (
           PARTITION BY cohort_definition_id, cat)                    AS n
    FROM tagged
  UNION ALL
  SELECT 'age_group' AS stratum_type, age_group AS stratum_value,
         cohort_definition_id, cat, std_value,
         ROW_NUMBER() OVER (
           PARTITION BY cohort_definition_id, cat, age_group
           ORDER BY std_value)                                       AS rn,
         COUNT(*) OVER (
           PARTITION BY cohort_definition_id, cat, age_group)         AS n
    FROM tagged
  UNION ALL
  SELECT 'sex' AS stratum_type, sex AS stratum_value,
         cohort_definition_id, cat, std_value,
         ROW_NUMBER() OVER (
           PARTITION BY cohort_definition_id, cat, sex
           ORDER BY std_value)                                       AS rn,
         COUNT(*) OVER (
           PARTITION BY cohort_definition_id, cat, sex)               AS n
    FROM tagged
  UNION ALL
  SELECT 'age_sex' AS stratum_type, age_sex AS stratum_value,
         cohort_definition_id, cat, std_value,
         ROW_NUMBER() OVER (
           PARTITION BY cohort_definition_id, cat, age_sex
           ORDER BY std_value)                                       AS rn,
         COUNT(*) OVER (
           PARTITION BY cohort_definition_id, cat, age_sex)           AS n
    FROM tagged
),
lab_stats AS (
  SELECT stratum_type,
         stratum_value,
         cohort_definition_id,
         cat,
         COUNT(*)                        AS n_with_lab,
         AVG(CAST(std_value AS FLOAT))   AS mean_value,
         STDEV(CAST(std_value AS FLOAT)) AS sd_value,
         SUM(CASE WHEN rn = FLOOR(0.50 * (n - 1)) + 1
                  THEN std_value * (1.0 - (0.50 * (n - 1) - FLOOR(0.50 * (n - 1))))
                  WHEN rn = FLOOR(0.50 * (n - 1)) + 2
                  THEN std_value * (0.50 * (n - 1) - FLOOR(0.50 * (n - 1)))
                  ELSE 0 END)            AS median_value,
         SUM(CASE WHEN rn = FLOOR(0.25 * (n - 1)) + 1
                  THEN std_value * (1.0 - (0.25 * (n - 1) - FLOOR(0.25 * (n - 1))))
                  WHEN rn = FLOOR(0.25 * (n - 1)) + 2
                  THEN std_value * (0.25 * (n - 1) - FLOOR(0.25 * (n - 1)))
                  ELSE 0 END)            AS lq_value,
         SUM(CASE WHEN rn = FLOOR(0.75 * (n - 1)) + 1
                  THEN std_value * (1.0 - (0.75 * (n - 1) - FLOOR(0.75 * (n - 1))))
                  WHEN rn = FLOOR(0.75 * (n - 1)) + 2
                  THEN std_value * (0.75 * (n - 1) - FLOOR(0.75 * (n - 1)))
                  ELSE 0 END)            AS uq_value
    FROM ranked
-- Qualified with the `ranked` CTE name rather than bare column names:
-- BigQuery-only fix -- SqlRender's ordinal-GROUP-BY rewrite for this
-- dialect can mis-resolve bare GROUP BY columns onto an aggregate
-- expression's position, which BigQuery then rejects outright.
   GROUP BY ranked.stratum_type, ranked.stratum_value, ranked.cohort_definition_id, ranked.cat
)
SELECT stratum_type,
       stratum_value,
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
 ORDER BY cohort_definition_id, cat, stratum_type, stratum_value;
