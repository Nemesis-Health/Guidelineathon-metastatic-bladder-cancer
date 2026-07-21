-- Approach A: copy a generated eligibility cohort's membership into the unified
-- eligibility table (@lab_cohort_table) under a reserved test-id slot, so the
-- eligibility_2*.sql templates read ECOG + conditions the same way as labs.
--
-- SqlRender params: @work_database_schema, @lab_cohort_table, @cohort_table,
--                   @source_cohort_id (generated id), @test_id (slot).
INSERT INTO @work_database_schema.@lab_cohort_table
  (cohort_definition_id, subject_id, cohort_start_date, cohort_end_date)
SELECT @test_id AS cohort_definition_id,
       subject_id, cohort_start_date, cohort_end_date
  FROM @work_database_schema.@cohort_table
 WHERE cohort_definition_id = @source_cohort_id;
