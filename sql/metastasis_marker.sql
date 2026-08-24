-- ===========================================================================
-- metastasis_marker.sql — subjects with a metastasis-measurement record
-- ===========================================================================
-- Which of @target_cohort_ids' subjects have >=1 MEASUREMENT record among
-- @ancestor_concept_ids (+ descendants via concept_ancestor) — the same
-- measurement-domain marker (AJCC/UICC Stage 4, AJCC/UICC M1 Category,
-- Metastasis) that cohorts/01_Target/Target_1A.json's PrimaryCriteria uses
-- to define Cohort 1 membership in the first place. Used by
-- R/11_baseline_characterization.R for Charlson's `metastatic_solid_tumor`
-- component instead of a generic claims-oriented SNOMED condition list (see
-- that file's header for why).
--
-- No date restriction: this measurement is the literal qualifying event for
-- Cohort 1 membership, so every genuine T1 member already has one on record
-- — this just re-derives that fact from data instead of assuming it.
--
-- SqlRender parameters:
--   @cdm_database_schema @vocab_database_schema @work_database_schema
--   @cohort_table
--   @target_cohort_ids    comma-separated cohort_definition_id list
--   @ancestor_concept_ids comma-separated concept_id list (descendants included)
-- ===========================================================================

SELECT DISTINCT c.subject_id
  FROM @work_database_schema.@cohort_table c
  JOIN @cdm_database_schema.measurement m ON m.person_id = c.subject_id
 WHERE c.cohort_definition_id IN (@target_cohort_ids)
   AND m.measurement_concept_id IN (
         SELECT descendant_concept_id
           FROM @vocab_database_schema.concept_ancestor
          WHERE ancestor_concept_id IN (@ancestor_concept_ids)
       )
