-- =============================================================================
-- ps_overlap.sql — performance-status strata overlap with cohort 1A (mBC)
-- =============================================================================
-- ECOG membership (KPS folded in) lives in @lab_cohort_table at the reserved
-- test-id slots: 24 = ECOG 0, 25 = ECOG 1, 26 = ECOG 2, 27 = ECOG >=3, each
-- dated at the PS record. A 1A subject counts toward a stratum if they have an
-- ECOG record in that stratum's id-set within @lab_window_before_days days before to @lab_window_after_days days after their 1A
-- index. Strata OVERLAP by design (e.g. PS 0-2 includes PS1/PS2).
--
-- SqlRender parameters:
--   @work_database_schema @cohort_table @lab_cohort_table @cohort1_id @lab_window_before_days @lab_window_after_days
-- =============================================================================

SELECT 'PS1' AS code, COUNT(DISTINCT tc.subject_id) AS n_overlap
  FROM @work_database_schema.@cohort_table tc
 WHERE tc.cohort_definition_id = @cohort1_id
   AND EXISTS (SELECT 1 FROM @work_database_schema.@lab_cohort_table l
                WHERE l.subject_id = tc.subject_id AND l.cohort_definition_id IN (24)
                  AND l.cohort_start_date BETWEEN DATEADD(day, -@lab_window_before_days, tc.cohort_start_date)
                                              AND DATEADD(day,  @lab_window_after_days, tc.cohort_start_date))
UNION ALL
SELECT 'PS2', COUNT(DISTINCT tc.subject_id)
  FROM @work_database_schema.@cohort_table tc
 WHERE tc.cohort_definition_id = @cohort1_id
   AND EXISTS (SELECT 1 FROM @work_database_schema.@lab_cohort_table l
                WHERE l.subject_id = tc.subject_id AND l.cohort_definition_id IN (25)
                  AND l.cohort_start_date BETWEEN DATEADD(day, -@lab_window_before_days, tc.cohort_start_date)
                                              AND DATEADD(day,  @lab_window_after_days, tc.cohort_start_date))
UNION ALL
SELECT 'PS2+', COUNT(DISTINCT tc.subject_id)
  FROM @work_database_schema.@cohort_table tc
 WHERE tc.cohort_definition_id = @cohort1_id
   AND EXISTS (SELECT 1 FROM @work_database_schema.@lab_cohort_table l
                WHERE l.subject_id = tc.subject_id AND l.cohort_definition_id IN (26, 27)
                  AND l.cohort_start_date BETWEEN DATEADD(day, -@lab_window_before_days, tc.cohort_start_date)
                                              AND DATEADD(day,  @lab_window_after_days, tc.cohort_start_date))
UNION ALL
SELECT 'PS 0-2', COUNT(DISTINCT tc.subject_id)
  FROM @work_database_schema.@cohort_table tc
 WHERE tc.cohort_definition_id = @cohort1_id
   AND EXISTS (SELECT 1 FROM @work_database_schema.@lab_cohort_table l
                WHERE l.subject_id = tc.subject_id AND l.cohort_definition_id IN (24, 25, 26)
                  AND l.cohort_start_date BETWEEN DATEADD(day, -@lab_window_before_days, tc.cohort_start_date)
                                              AND DATEADD(day,  @lab_window_after_days, tc.cohort_start_date))
UNION ALL
SELECT 'PS 0-1', COUNT(DISTINCT tc.subject_id)
  FROM @work_database_schema.@cohort_table tc
 WHERE tc.cohort_definition_id = @cohort1_id
   AND EXISTS (SELECT 1 FROM @work_database_schema.@lab_cohort_table l
                WHERE l.subject_id = tc.subject_id AND l.cohort_definition_id IN (24, 25)
                  AND l.cohort_start_date BETWEEN DATEADD(day, -@lab_window_before_days, tc.cohort_start_date)
                                              AND DATEADD(day,  @lab_window_after_days, tc.cohort_start_date))
;
