-- ===========================================================================
-- outcome_target_data.sql — cohort membership + index/end dates for outcomes
-- ===========================================================================
-- One row per (cohort_definition_id, subject_id) restricted to the outcome-
-- relevant cohort ids (T1 / T2a-e / T3a-e / T4-6a-f). cohort_end_date is
-- inherited from Cohort 1's end date all the way down the tree (see
-- sql/Target_1A_initiated_template.sql), so it already serves as the OS
-- censor date (end of observation / second-malignancy censoring).
--
-- SqlRender parameters:
--   @work_database_schema @cohort_table
--   @target_cohort_ids   comma-separated cohort_definition_id list
-- ===========================================================================

SELECT cohort_definition_id,
       subject_id,
       cohort_start_date,
       cohort_end_date
  FROM @work_database_schema.@cohort_table
 WHERE cohort_definition_id IN (@target_cohort_ids)
