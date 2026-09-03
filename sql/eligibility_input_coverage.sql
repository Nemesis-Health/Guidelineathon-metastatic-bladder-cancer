-- Eligibility inputs crossed with every cohort in @cohort_definition_ids
-- (the full main cohort tree, same scope as lab_value_distribution.csv --
-- not just Target 1A). Among each cohort's members, per test-id slot:
--   n_tested  = had the measurement at all (from @raw_lab_results_table; labs only)
--   n_passed  = met the criterion / has the cohort (from @lab_cohort_table)
-- both within @lab_window_before_days days before to @lab_window_after_days days after
-- that cohort's own index date. ECOG/condition slots (24-27, 33-40) have no
-- n_tested (not lab measurements).
--
-- Also stratified: every (cohort, test_id) row is computed four times --
-- overall, and split by age_group / sex / age_sex (subject_strata.sql --
-- see that file's header for the standard consumption pattern this
-- follows). stratum_type/stratum_value identify which view a row belongs
-- to. The matching n_cohort denominator per (cohort, stratum) is added in R
-- (R/05_eligibility_coverage.R), from the same subject_strata.sql query,
-- not duplicated here.
--
-- SqlRender params: @work_database_schema, @cohort_table, @lab_cohort_table,
--                   @raw_lab_results_table, @cohort_definition_ids
--                   (comma-separated cohort_definition_id list),
--                   @lab_window_before_days, @lab_window_after_days
--                   subject_strata_sql (pre-rendered fragment, not a plain
--                   schema/table name -- see the `strata` CTE below)
WITH target_cohorts AS (
  SELECT cohort_definition_id, subject_id, cohort_start_date
    FROM @work_database_schema.@cohort_table
   WHERE cohort_definition_id IN (@cohort_definition_ids)
),
strata AS (
  @subject_strata_sql
),
tc_strat AS (
  SELECT 'overall' AS stratum_type, 'overall' AS stratum_value,
         tc.cohort_definition_id, tc.subject_id, tc.cohort_start_date
    FROM target_cohorts tc
  UNION ALL
  SELECT 'age_group' AS stratum_type, s.age_group AS stratum_value,
         tc.cohort_definition_id, tc.subject_id, tc.cohort_start_date
    FROM target_cohorts tc
    JOIN strata s ON s.cohort_definition_id = tc.cohort_definition_id AND s.subject_id = tc.subject_id
  UNION ALL
  SELECT 'sex' AS stratum_type, s.sex AS stratum_value,
         tc.cohort_definition_id, tc.subject_id, tc.cohort_start_date
    FROM target_cohorts tc
    JOIN strata s ON s.cohort_definition_id = tc.cohort_definition_id AND s.subject_id = tc.subject_id
  UNION ALL
  SELECT 'age_sex' AS stratum_type, s.age_sex AS stratum_value,
         tc.cohort_definition_id, tc.subject_id, tc.cohort_start_date
    FROM target_cohorts tc
    JOIN strata s ON s.cohort_definition_id = tc.cohort_definition_id AND s.subject_id = tc.subject_id
),
passed AS (
  SELECT tc_strat.stratum_type, tc_strat.stratum_value, tc_strat.cohort_definition_id,
         lab.cohort_definition_id AS test_id,
         COUNT(DISTINCT tc_strat.subject_id) AS n_passed
    FROM tc_strat
    JOIN @work_database_schema.@lab_cohort_table lab
      ON lab.subject_id = tc_strat.subject_id
     AND lab.cohort_start_date BETWEEN DATEADD(day, -@lab_window_before_days, tc_strat.cohort_start_date)
                                   AND DATEADD(day,  @lab_window_after_days, tc_strat.cohort_start_date)
   GROUP BY tc_strat.stratum_type, tc_strat.stratum_value, tc_strat.cohort_definition_id,
            lab.cohort_definition_id
),
tested AS (
  -- alias "rlr" (not "raw"): RAW is a reserved word in Redshift and breaks as a bare alias
  SELECT tc_strat.stratum_type, tc_strat.stratum_value, tc_strat.cohort_definition_id,
         rlr.test_id AS test_id,
         COUNT(DISTINCT tc_strat.subject_id) AS n_tested
    FROM tc_strat
    JOIN @work_database_schema.@raw_lab_results_table rlr
      ON rlr.person_id = tc_strat.subject_id
     AND rlr.measurement_date BETWEEN DATEADD(day, -@lab_window_before_days, tc_strat.cohort_start_date)
                                  AND DATEADD(day,  @lab_window_after_days, tc_strat.cohort_start_date)
   GROUP BY tc_strat.stratum_type, tc_strat.stratum_value, tc_strat.cohort_definition_id,
            rlr.test_id
)
SELECT COALESCE(p.stratum_type, t.stratum_type)             AS stratum_type,
       COALESCE(p.stratum_value, t.stratum_value)           AS stratum_value,
       COALESCE(p.cohort_definition_id, t.cohort_definition_id) AS cohort_definition_id,
       COALESCE(p.test_id, t.test_id)                       AS test_id,
       t.n_tested,
       p.n_passed
  FROM passed p
  FULL OUTER JOIN tested t
    ON p.test_id = t.test_id
   AND p.stratum_type = t.stratum_type
   AND p.stratum_value = t.stratum_value
   AND p.cohort_definition_id = t.cohort_definition_id
 ORDER BY cohort_definition_id, stratum_type, stratum_value, test_id;
