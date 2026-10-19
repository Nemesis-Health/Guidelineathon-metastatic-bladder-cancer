-- =============================================================================
-- eligibility_lab_rows.sql -- the lab/ECOG rows eligibility is decided on
-- =============================================================================
-- A SELECT fragment (no trailing semicolon), rendered by labRowsSql()
-- (R/cohorts.R). One source for the T2 eligibility files, the attrition
-- steps, eligibility_input_coverage.sql and lab_value_distribution_portable.sql,
-- so all of them read the same result per patient and lab.
--
-- Rows are per anchor cohort member (@anchor_cohort_ids), within that member's
-- window: [index - before, index + after] days, using the treated window for
-- cohorts in @treated_cohort_ids (indexed on treatment start) and the lab
-- window for the rest.
--
-- closest = TRUE: per member and lab group (cat), the one scorable result
-- closest to index decides every test of the group, with the pass rule of
-- lab_cohorts.sql section 5. ECOG 0-3+ is treated as one group: the closest
-- record by start date. Ties, in order:
--   1. equal distance: the result before index wins;
--   2. same day: the worst value counts (lowest Hb/ANC/Platelets/GFR/CrCl,
--      highest of the rest, ULN-based labs as value / ULN; highest ECOG);
--   3. then lowest value, then lowest ULN.
-- closest = FALSE: every scorable result in the window.
-- passing_only = TRUE keeps the rows that pass (what eligibility reads);
-- FALSE also keeps the failing ones (passes = 0), for "tested" counts and
-- lab values.
--
-- Condition, anticoagulant and symptom rows pass through unwindowed; the
-- reader applies its own window (cond_lo/cond_hi here for conditions).
--
-- Columns: anchor_cohort_id, index_date, win_lo, win_hi, cond_lo, cond_hi,
--   cohort_definition_id (= test_id), subject_id, cohort_start_date,
--   cohort_end_date, cat (NULL for ECOG/pass-through), std_value, passes.
-- Test ids are declared in cohorts/extras/eligibility_test_ids.csv.
-- =============================================================================
SELECT anchor_cohort_id, index_date, win_lo, win_hi, cond_lo, cond_hi,
       test_id AS cohort_definition_id, subject_id,
       start_date AS cohort_start_date, end_date AS cohort_end_date,
       CASE WHEN grp = 'ECOG' OR is_passthrough = 1 THEN NULL ELSE grp END AS cat,
       std_value, passes
  FROM (
    SELECT cand.*,
           DENSE_RANK() OVER (
             PARTITION BY anchor_cohort_id, subject_id, index_date, grp
             ORDER BY ABS(DATEDIFF(day, index_date, start_date)),
                      CASE WHEN start_date < index_date THEN 0 ELSE 1 END,
                      worst DESC, std_value, uln_std) AS rnk
      FROM (
        SELECT a.*, x.grp, x.test_id, x.start_date, x.end_date, x.worst,
               x.std_value, x.uln_std, x.passes, x.is_passthrough
          FROM (
            SELECT c.cohort_definition_id AS anchor_cohort_id, c.subject_id,
                   c.cohort_start_date AS index_date,
                   CASE WHEN c.cohort_definition_id IN (@treated_cohort_ids)
                        THEN DATEADD(day, -@treated_lab_window_before_days, c.cohort_start_date)
                        ELSE DATEADD(day, -@lab_window_before_days, c.cohort_start_date) END AS win_lo,
                   CASE WHEN c.cohort_definition_id IN (@treated_cohort_ids)
                        THEN DATEADD(day, @treated_lab_window_after_days, c.cohort_start_date)
                        ELSE DATEADD(day, @lab_window_after_days, c.cohort_start_date) END AS win_hi,
                   CASE WHEN c.cohort_definition_id IN (@treated_cohort_ids)
                        THEN DATEADD(day, -@treated_lab_window_before_days, c.cohort_start_date)
                        ELSE DATEADD(day, -@condition_flag_window_before_days, c.cohort_start_date) END AS cond_lo,
                   CASE WHEN c.cohort_definition_id IN (@treated_cohort_ids)
                        THEN DATEADD(day, @treated_lab_window_after_days, c.cohort_start_date)
                        ELSE DATEADD(day, @condition_flag_window_after_days, c.cohort_start_date) END AS cond_hi
              FROM @target_database_schema.@target_cohort_table c
             WHERE c.cohort_definition_id IN (@anchor_cohort_ids)
          ) a
          JOIN (
            -- lab results: one row per result x test of its group
            SELECT r.person_id AS subject_id, r.cat AS grp, r.test_id,
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
                        THEN 1 ELSE 0 END AS passes,
                   0 AS is_passthrough
              FROM @target_database_schema.@raw_lab_results_table r
             WHERE r.basis = 'ABS' OR r.uln_std IS NOT NULL
            UNION ALL
            -- ECOG records; worst = the ECOG grade
            SELECT e.subject_id, 'ECOG', e.cohort_definition_id,
                   e.cohort_start_date, e.cohort_end_date,
                   CAST(CASE e.cohort_definition_id @ecog_grade_cases END AS FLOAT), NULL, NULL, 1, 0
              FROM @target_database_schema.@lab_cohort_table e
             WHERE e.cohort_definition_id IN (@ecog_ids)
            UNION ALL
            -- condition, anticoagulant and symptom rows
            SELECT p.subject_id, 'PASS', p.cohort_definition_id,
                   p.cohort_start_date, p.cohort_end_date, NULL, NULL, NULL, 1, 1
              FROM @target_database_schema.@lab_cohort_table p
             WHERE p.cohort_definition_id IN (@passthrough_ids)
          ) x
            ON x.subject_id = a.subject_id
           AND (x.is_passthrough = 1
                OR (x.start_date <= a.win_hi AND x.end_date >= a.win_lo))
      ) cand
  ) ranked
 WHERE (is_passthrough = 1{@closest} ? { OR rnk = 1} : { OR 1 = 1})
   {@passing_only} ? {AND passes = 1}
