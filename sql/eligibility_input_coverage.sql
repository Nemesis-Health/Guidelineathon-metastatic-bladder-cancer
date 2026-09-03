-- Eligibility inputs crossed with Target 1A (@cohort1_id). Among Target 1A
-- members, per test-id slot:
--   n_tested  = had the measurement at all (from @raw_lab_results_table; labs only)
--   n_passed  = met the criterion / has the cohort (from @lab_cohort_table)
-- both within @lab_window_before_days days before to @lab_window_after_days days after the Target 1A index date.
-- ECOG/condition slots (24-27, 33-40) have no n_tested (not lab measurements).
--
-- Also stratified: every test_id row is computed four times -- overall, and
-- split by age_group / sex / age_sex (subject_strata.sql -- see that file's
-- header for the standard consumption pattern this follows).
-- stratum_type/stratum_value identify which view a row belongs to. The
-- matching n_target1a denominator per stratum is added in R
-- (R/05_eligibility_coverage.R), from the same subject_strata.sql query,
-- not duplicated here.
--
-- SqlRender params: @work_database_schema, @cohort_table, @lab_cohort_table,
--                   @raw_lab_results_table, @cohort1_id, @lab_window_before_days,
--                   @lab_window_after_days
--                   subject_strata_sql (pre-rendered fragment, not a plain
--                   schema/table name -- see the `strata` CTE below)
WITH t1a AS (
  SELECT subject_id, cohort_start_date
    FROM @work_database_schema.@cohort_table
   WHERE cohort_definition_id = @cohort1_id
),
strata AS (
  @subject_strata_sql
),
t1a_strat AS (
  SELECT 'overall' AS stratum_type, 'overall' AS stratum_value,
         t1a.subject_id, t1a.cohort_start_date
    FROM t1a
  UNION ALL
  SELECT 'age_group' AS stratum_type, s.age_group AS stratum_value,
         t1a.subject_id, t1a.cohort_start_date
    FROM t1a
    JOIN strata s ON s.cohort_definition_id = @cohort1_id AND s.subject_id = t1a.subject_id
  UNION ALL
  SELECT 'sex' AS stratum_type, s.sex AS stratum_value,
         t1a.subject_id, t1a.cohort_start_date
    FROM t1a
    JOIN strata s ON s.cohort_definition_id = @cohort1_id AND s.subject_id = t1a.subject_id
  UNION ALL
  SELECT 'age_sex' AS stratum_type, s.age_sex AS stratum_value,
         t1a.subject_id, t1a.cohort_start_date
    FROM t1a
    JOIN strata s ON s.cohort_definition_id = @cohort1_id AND s.subject_id = t1a.subject_id
),
passed AS (
  SELECT t1a_strat.stratum_type, t1a_strat.stratum_value,
         lab.cohort_definition_id AS test_id,
         COUNT(DISTINCT t1a_strat.subject_id) AS n_passed
    FROM t1a_strat
    JOIN @work_database_schema.@lab_cohort_table lab
      ON lab.subject_id = t1a_strat.subject_id
     AND lab.cohort_start_date BETWEEN DATEADD(day, -@lab_window_before_days, t1a_strat.cohort_start_date)
                                   AND DATEADD(day,  @lab_window_after_days, t1a_strat.cohort_start_date)
   GROUP BY t1a_strat.stratum_type, t1a_strat.stratum_value, lab.cohort_definition_id
),
tested AS (
  -- alias "rlr" (not "raw"): RAW is a reserved word in Redshift and breaks as a bare alias
  SELECT t1a_strat.stratum_type, t1a_strat.stratum_value,
         rlr.test_id AS test_id,
         COUNT(DISTINCT t1a_strat.subject_id) AS n_tested
    FROM t1a_strat
    JOIN @work_database_schema.@raw_lab_results_table rlr
      ON rlr.person_id = t1a_strat.subject_id
     AND rlr.measurement_date BETWEEN DATEADD(day, -@lab_window_before_days, t1a_strat.cohort_start_date)
                                  AND DATEADD(day,  @lab_window_after_days, t1a_strat.cohort_start_date)
   GROUP BY t1a_strat.stratum_type, t1a_strat.stratum_value, rlr.test_id
)
SELECT COALESCE(p.stratum_type, t.stratum_type)   AS stratum_type,
       COALESCE(p.stratum_value, t.stratum_value) AS stratum_value,
       COALESCE(p.test_id, t.test_id)             AS test_id,
       t.n_tested,
       p.n_passed
  FROM passed p
  FULL OUTER JOIN tested t
    ON p.test_id = t.test_id
   AND p.stratum_type = t.stratum_type
   AND p.stratum_value = t.stratum_value
 ORDER BY stratum_type, stratum_value, test_id;
