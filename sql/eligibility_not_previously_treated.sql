-- =============================================================================
-- eligibility_not_previously_treated.sql -- Not previously treated mBC (Cohort
-- logics item 2)
-- =============================================================================
-- Cohort 1 members who pass the washout: no systemic regimen in the year
-- before index, up to 30 days before. Contains T2a-T2d and the
-- treatment-naive part of T2e.
--
-- The washout is eligibility_2a.sql's (an ARTEMIS regimen episode overlapping
-- [index - 365d, index - 30d)); keep the two in step.
--
-- SqlRender params: @target_database_schema @target_cohort_table
--   @target_cohort_id @cohort1_id @regimen_episode_table
-- =============================================================================

DELETE FROM @target_database_schema.@target_cohort_table
 WHERE cohort_definition_id = @target_cohort_id;

INSERT INTO @target_database_schema.@target_cohort_table
  (cohort_definition_id, subject_id, cohort_start_date, cohort_end_date)
SELECT @target_cohort_id AS cohort_definition_id,
       tc.subject_id, tc.cohort_start_date, tc.cohort_end_date
  FROM @target_database_schema.@target_cohort_table tc
 WHERE tc.cohort_definition_id = @cohort1_id
     AND NOT EXISTS (
           SELECT 1
             FROM @target_database_schema.@regimen_episode_table re
            WHERE CAST(re.person_id AS BIGINT) = tc.subject_id
              AND re.episode_start_date <  DATEADD(day, -30, tc.cohort_start_date)
              AND re.episode_end_date   >= DATEADD(day, -365, tc.cohort_start_date)
         )
;
