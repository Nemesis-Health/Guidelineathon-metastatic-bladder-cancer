-- lab_value_distribution.sql
-- Median/quartiles use ROW_NUMBER()/COUNT(*)/FLOOR instead of
-- PERCENTILE_CONT ... WITHIN GROUP ... OVER, which SqlRender leaves
-- untranslated (breaks PostgreSQL / BigQuery / SQLite / Spark / Hive / Impala).
--
-- Interpolation reproduces PERCENTILE_CONT exactly (R quantile type 7):
--   pos = p * (n - 1)  (zero-based), k = FLOOR(pos), frac = pos - k
--   percentile = v[k] * (1 - frac) + v[k+1] * frac
-- so ranked rows rn = k+1 and rn = k+2 contribute weights (1-frac) and frac.
--
-- For each target cohort and lab (cat), among subjects with a scorable result
-- in the window, the one result eligibility uses (lab_rows_sql:
-- eligibility_lab_rows.sql rendered by labRowsSql() with the closest rule;
-- same window and tie-breaks) -- one value per subject x cat, summarised.
--
-- Also stratified: every (cohort, cat) row is computed four times --
-- overall, and split by age_group / sex / age_sex (subject_strata.sql --
-- see that file's header for the standard consumption pattern this
-- follows, and lab_timing_to_index.sql for the same UNION-ALL
-- ranking / shared-percentile-formula shape). stratum_type/stratum_value
-- identify which view a row belongs to.
--
-- Output columns:
--   stratum_type, stratum_value, cohort_definition_id, cat,
--   n_with_lab, mean_value, sd_value, median_value, lq_value, uq_value,
--   min_value, max_value
--
-- SqlRender parameters:
--   @min_cell_count          privacy floor for n_with_lab (e.g. 5)
--   lab_rows_sql, subject_strata_sql (pre-rendered fragments, not plain
--   schema/table names): the closest lab rows for the target cohorts,
--   and subject_strata.sql's age_group/sex/... per (cohort, subject)
-- =============================================================================

WITH lab_one_per_subject AS (
  SELECT DISTINCT anchor_cohort_id AS cohort_definition_id, subject_id, cat, std_value
    FROM (@lab_rows_sql) lr
   WHERE cat IS NOT NULL
),
strata AS (
  @subject_strata_sql
),
tagged AS (
  SELECT lo.cohort_definition_id, lo.subject_id, lo.cat, lo.std_value,
         s.age_group, s.sex, s.age_sex, s.age_band, s.index_period, s.index_period_2021
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
  UNION ALL
  SELECT 'age_band' AS stratum_type, age_band AS stratum_value,
         cohort_definition_id, cat, std_value,
         ROW_NUMBER() OVER (
           PARTITION BY cohort_definition_id, cat, age_band
           ORDER BY std_value)                                       AS rn,
         COUNT(*) OVER (
           PARTITION BY cohort_definition_id, cat, age_band)           AS n
    FROM tagged
  UNION ALL
  SELECT 'index_period' AS stratum_type, index_period AS stratum_value,
         cohort_definition_id, cat, std_value,
         ROW_NUMBER() OVER (
           PARTITION BY cohort_definition_id, cat, index_period
           ORDER BY std_value)                                       AS rn,
         COUNT(*) OVER (
           PARTITION BY cohort_definition_id, cat, index_period)           AS n
    FROM tagged
  UNION ALL
  SELECT 'index_period_2021' AS stratum_type, index_period_2021 AS stratum_value,
         cohort_definition_id, cat, std_value,
         ROW_NUMBER() OVER (
           PARTITION BY cohort_definition_id, cat, index_period_2021
           ORDER BY std_value)                                       AS rn,
         COUNT(*) OVER (
           PARTITION BY cohort_definition_id, cat, index_period_2021)           AS n
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
                  ELSE 0 END)            AS uq_value,
         MIN(std_value)                  AS min_value,
         MAX(std_value)                  AS max_value
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
            THEN NULL ELSE uq_value     END                    AS uq_value,
       CASE WHEN n_with_lab > 0 AND n_with_lab < @min_cell_count
            THEN NULL ELSE min_value    END                    AS min_value,
       CASE WHEN n_with_lab > 0 AND n_with_lab < @min_cell_count
            THEN NULL ELSE max_value    END                    AS max_value
  FROM lab_stats
 ORDER BY cohort_definition_id, cat, stratum_type, stratum_value;
