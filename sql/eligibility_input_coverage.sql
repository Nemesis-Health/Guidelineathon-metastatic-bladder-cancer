-- Eligibility inputs crossed with Target 1A (@cohort1_id). Among Target 1A
-- members, per test-id slot:
--   n_tested  = had the measurement at all (from @raw_lab_results_table; labs only)
--   n_passed  = met the criterion / has the cohort (from @lab_cohort_table)
-- both within @lab_window_before_days days before to @lab_window_after_days days after the Target 1A index date.
-- ECOG/condition slots (24-27, 33-40) have no n_tested (not lab measurements).
--
-- SqlRender params: @work_database_schema, @cohort_table, @lab_cohort_table,
--                   @raw_lab_results_table, @cohort1_id, @lab_window_before_days, @lab_window_after_days
WITH t1a AS (
  SELECT subject_id, cohort_start_date
    FROM @work_database_schema.@cohort_table
   WHERE cohort_definition_id = @cohort1_id
),
passed AS (
  SELECT lab.cohort_definition_id AS test_id,
         COUNT(DISTINCT t1a.subject_id) AS n_passed
    FROM t1a
    JOIN @work_database_schema.@lab_cohort_table lab
      ON lab.subject_id = t1a.subject_id
     AND lab.cohort_start_date BETWEEN DATEADD(day, -@lab_window_before_days, t1a.cohort_start_date)
                                   AND DATEADD(day,  @lab_window_after_days, t1a.cohort_start_date)
   GROUP BY lab.cohort_definition_id
),
tested AS (
  SELECT raw.test_id AS test_id,
         COUNT(DISTINCT t1a.subject_id) AS n_tested
    FROM t1a
    JOIN @work_database_schema.@raw_lab_results_table raw
      ON raw.person_id = t1a.subject_id
     AND raw.measurement_date BETWEEN DATEADD(day, -@lab_window_before_days, t1a.cohort_start_date)
                                  AND DATEADD(day,  @lab_window_after_days, t1a.cohort_start_date)
   GROUP BY raw.test_id
)
SELECT COALESCE(p.test_id, t.test_id) AS test_id,
       t.n_tested,
       p.n_passed
  FROM passed p
  FULL OUTER JOIN tested t ON p.test_id = t.test_id
 ORDER BY test_id;
