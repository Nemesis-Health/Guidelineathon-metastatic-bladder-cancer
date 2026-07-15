-- =============================================================================
-- Target 1A 2e — Ineligible for any recommendation
-- =============================================================================
-- Protocol: all Cohort 1 subjects not assigned to 2a, 2b, 2c, or 2d.
-- Includes washout failures, lab/criteria failures, and unclassified remainder.
-- Index/end dates inherited from Cohort 1.
--
-- SqlRender parameters:
--   @target_database_schema, @target_cohort_table, @target_cohort_id
--   @cohort1_id, @cohort2a_id, @cohort2b_id, @cohort2c_id, @cohort2d_id
--
-- Must be generated AFTER 2a-2d (references their cohort_definition_ids).
-- =============================================================================

DELETE FROM @target_database_schema.@target_cohort_table
 WHERE cohort_definition_id = @target_cohort_id;

INSERT INTO @target_database_schema.@target_cohort_table
  (cohort_definition_id, subject_id, cohort_start_date, cohort_end_date)
SELECT @target_cohort_id AS cohort_definition_id,
       tc.subject_id,
       tc.cohort_start_date,
       tc.cohort_end_date
  FROM @target_database_schema.@target_cohort_table tc
 WHERE tc.cohort_definition_id = @cohort1_id
   AND NOT EXISTS (
         SELECT 1
           FROM @target_database_schema.@target_cohort_table assigned
          WHERE assigned.subject_id = tc.subject_id
            AND assigned.cohort_definition_id IN (
                  @cohort2a_id,
                  @cohort2b_id,
                  @cohort2c_id,
                  @cohort2d_id
                )
       )
;
