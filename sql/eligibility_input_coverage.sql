-- Eligibility inputs crossed with every cohort in @cohort_definition_ids
-- (the full main cohort tree, same scope as lab_value_distribution.csv --
-- not just Target 1A). Among each cohort's members, per test-id slot:
--   n_tested = had a scorable result in the window (labs only)
--   n_passed = met the criterion
-- Both read lab_rows_sql (eligibility_lab_rows.sql rendered for these
-- cohorts by labRowsSql()), so with the closest rule a lab passes on the
-- result eligibility would use. Windows are around each cohort's own index:
-- the lab window, or the treated window for cohorts indexed on treatment
-- start, condition flags (@condition_window_ids) use the condition window
-- for the rest. A row passes when its [cohort_start_date, cohort_end_date]
-- overlaps the window. ECOG/condition slots have no n_tested (not lab
-- measurements). Test ids are declared in cohorts/extras/eligibility_test_ids.csv.
--
-- Also stratified: every (cohort, test_id) row is computed four times --
-- overall, and split by age_group / sex / age_sex (subject_strata.sql --
-- see that file's header for the standard consumption pattern this
-- follows). stratum_type/stratum_value identify which view a row belongs
-- to. The matching n_cohort denominator per (cohort, stratum) is added in R
-- (R/steps/31_eligibility_coverage.R), from the same subject_strata.sql query,
-- not duplicated here.
--
-- SqlRender params: @work_database_schema, @cohort_table, @cohort_definition_ids
--                   (comma-separated cohort_definition_id list),
--                   @condition_window_ids (condition-flag test ids),
--                   lab_rows_sql and subject_strata_sql (pre-rendered
--                   fragments, not plain schema/table names)
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
  UNION ALL
  SELECT 'age_band' AS stratum_type, s.age_band AS stratum_value,
         tc.cohort_definition_id, tc.subject_id, tc.cohort_start_date
    FROM target_cohorts tc
    JOIN strata s ON s.cohort_definition_id = tc.cohort_definition_id AND s.subject_id = tc.subject_id
  UNION ALL
  SELECT 'index_period' AS stratum_type, s.index_period AS stratum_value,
         tc.cohort_definition_id, tc.subject_id, tc.cohort_start_date
    FROM target_cohorts tc
    JOIN strata s ON s.cohort_definition_id = tc.cohort_definition_id AND s.subject_id = tc.subject_id
  UNION ALL
  SELECT 'index_period_2021' AS stratum_type, s.index_period_2021 AS stratum_value,
         tc.cohort_definition_id, tc.subject_id, tc.cohort_start_date
    FROM target_cohorts tc
    JOIN strata s ON s.cohort_definition_id = tc.cohort_definition_id AND s.subject_id = tc.subject_id
),
lab_rows AS (
  @lab_rows_sql
),
tc_rows AS (
  SELECT tc_strat.stratum_type, tc_strat.stratum_value, tc_strat.cohort_definition_id,
         tc_strat.subject_id, lr.cohort_definition_id AS test_id, lr.cat, lr.passes,
         lr.cohort_start_date AS row_start, lr.cohort_end_date AS row_end,
         lr.win_lo, lr.win_hi, lr.cond_lo, lr.cond_hi
    FROM tc_strat
    JOIN lab_rows lr
      ON lr.anchor_cohort_id = tc_strat.cohort_definition_id
     AND lr.subject_id       = tc_strat.subject_id
     AND lr.index_date       = tc_strat.cohort_start_date
),
passed AS (
  SELECT stratum_type, stratum_value, cohort_definition_id, test_id,
         COUNT(DISTINCT subject_id) AS n_passed
    FROM tc_rows
   WHERE passes = 1
     AND ( (test_id NOT IN (@condition_window_ids) AND row_start <= win_hi  AND row_end >= win_lo)
        OR (test_id IN (@condition_window_ids)     AND row_start <= cond_hi AND row_end >= cond_lo) )
   GROUP BY stratum_type, stratum_value, cohort_definition_id, test_id
),
tested AS (
  SELECT stratum_type, stratum_value, cohort_definition_id, test_id,
         COUNT(DISTINCT subject_id) AS n_tested
    FROM tc_rows
   WHERE cat IS NOT NULL
   GROUP BY stratum_type, stratum_value, cohort_definition_id, test_id
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
