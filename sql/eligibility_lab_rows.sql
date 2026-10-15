-- =============================================================================
-- eligibility_lab_rows.sql -- the eligibility rows 2a-2d and T1-CE read
-- =============================================================================
-- A SELECT fragment (no trailing semicolon), rendered in R/03_main_cohorts.R
-- and injected into the eligibility files. Returns rows shaped like the lab
-- cohort table:
--   (cohort_definition_id = test_id, subject_id, cohort_start_date, cohort_end_date)
--
-- labValueSelection = "any": every row of the lab cohort table.
--
-- labValueSelection = "closest": per Cohort 1 member and lab
-- group (cat), the one scorable result closest to index within [index -
-- labWindowBeforeDays, index + labWindowAfterDays] decides every test of the
-- group, with the pass rule of lab_cohorts.sql section 5. ECOG [24-27] is
-- treated as one group: the closest record by start date. Ties, in order:
--   1. equal distance: the result before index wins;
--   2. same day: the worst value counts (lowest Hb/ANC/Platelets/GFR/CrCl,
--      highest of the rest, ULN-based labs as value / ULN; highest ECOG);
--   3. then lowest value, then lowest ULN.
-- Other rows (ids 28-43: conditions, anticoagulants, symptoms) pass through.
-- =============================================================================
{@closest} ? {
SELECT test_id AS cohort_definition_id, subject_id,
       start_date AS cohort_start_date, end_date AS cohort_end_date
  FROM (
    -- The closest-value pick: rank 1 = the chosen result (all its test rows)
    SELECT cand.*,
           DENSE_RANK() OVER (
             PARTITION BY subject_id, index_date, grp
             ORDER BY ABS(DATEDIFF(day, index_date, start_date)),
                      CASE WHEN start_date < index_date THEN 0 ELSE 1 END,
                      worst DESC, std_value, uln_std) AS rnk
      FROM (
        -- lab results: one row per result x test of its group
        SELECT c1.subject_id, c1.cohort_start_date AS index_date, r.cat AS grp, r.test_id,
               r.measurement_date AS start_date, r.measurement_date AS end_date,
               CASE WHEN r.cat IN ('Hb', 'ANC', 'Platelets', 'GFR', 'CrCl') THEN -r.std_value
                    WHEN r.basis = 'ULN' THEN r.std_value / r.uln_std
                    ELSE r.std_value END AS worst,
               r.std_value, r.uln_std,
               CASE WHEN ( r.min_op IS NULL
                           OR (r.min_op = '>=' AND r.std_value >= r.min_bound)
                           OR (r.min_op = '>'  AND r.std_value >  r.min_bound) )
                     AND ( r.max_op IS NULL
                           OR (r.max_op = '<=' AND r.std_value <= r.max_bound)
                           OR (r.max_op = '<'  AND r.std_value <  r.max_bound) )
                    THEN 1 ELSE 0 END AS passes
          FROM @target_database_schema.@target_cohort_table c1
          JOIN @target_database_schema.@raw_lab_results_table r
            ON r.person_id = c1.subject_id
           AND r.measurement_date >= DATEADD(day, -@lab_window_before_days, c1.cohort_start_date)
           AND r.measurement_date <= DATEADD(day,  @lab_window_after_days,  c1.cohort_start_date)
         WHERE c1.cohort_definition_id = @cohort1_id
           AND (r.basis = 'ABS' OR r.uln_std IS NOT NULL)
        UNION ALL
        -- ECOG records live in the window
        SELECT c1.subject_id, c1.cohort_start_date, 'ECOG', e.cohort_definition_id,
               e.cohort_start_date, e.cohort_end_date,
               CAST(e.cohort_definition_id AS FLOAT), NULL, NULL, 1
          FROM @target_database_schema.@target_cohort_table c1
          JOIN @target_database_schema.@lab_cohort_table e
            ON e.subject_id = c1.subject_id
           AND e.cohort_definition_id IN (24, 25, 26, 27)
           AND e.cohort_start_date <= DATEADD(day,  @lab_window_after_days,  c1.cohort_start_date)
           AND e.cohort_end_date   >= DATEADD(day, -@lab_window_before_days, c1.cohort_start_date)
         WHERE c1.cohort_definition_id = @cohort1_id
      ) cand
  ) ranked
 WHERE rnk = 1 AND passes = 1
UNION ALL
SELECT cohort_definition_id, subject_id, cohort_start_date, cohort_end_date
  FROM @target_database_schema.@lab_cohort_table
 WHERE cohort_definition_id BETWEEN 28 AND 43
} : {
SELECT cohort_definition_id, subject_id, cohort_start_date, cohort_end_date
  FROM @target_database_schema.@lab_cohort_table
}
