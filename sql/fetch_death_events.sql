-- ===========================================================================
-- fetch_death_events.sql — death dates for subjects in a set of cohorts
-- ===========================================================================
-- One row per subject with a death record who is a member of at least one of
-- @target_cohort_ids. Shape matches the event-tibble convention used by
-- computeTimeToEvent() / the outcomes step: subject_id, cohort_start_date
-- (here: the death date). Powers the OS outcome (R/09_outcomes.R).
--
-- SqlRender parameters:
--   @work_database_schema @cohort_table @cdm_database_schema
--   @target_cohort_ids   comma-separated cohort_definition_id list
-- ===========================================================================

SELECT DISTINCT
       c.subject_id                AS subject_id,
       d.death_date                AS cohort_start_date
  FROM @work_database_schema.@cohort_table c
  JOIN @cdm_database_schema.death d
    ON d.person_id = c.subject_id
 WHERE c.cohort_definition_id IN (@target_cohort_ids)
