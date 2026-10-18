-- =============================================================================
-- charlson_recorded.sql — recorded Charlson Comorbidity Index per (cohort, subject)
-- =============================================================================
-- For each member of @cohort_definition_ids, the recorded Charlson
-- Comorbidity Index (SNOMED 762713009, concept 42538860; measurement or
-- observation) closest to that cohort's index within [index - 30d,
-- index + 30d]. Equal distance: the record before index wins, then the
-- higher value. Values outside 0-40 are ignored. The age-adjusted index
-- (concept 715970) is not used: it is not comparable with the calculated
-- score. Used by R/steps/22_baseline_characterization.R.
--
-- Output: cohort_definition_id, subject_id, cci_reported
--
-- SqlRender parameters: @cdm_database_schema @work_database_schema
--   @cohort_table @cohort_definition_ids
-- =============================================================================
SELECT cohort_definition_id, CAST(subject_id AS VARCHAR) AS subject_id, cci_reported
  FROM (
    SELECT tc.cohort_definition_id, tc.subject_id, r.value AS cci_reported,
           ROW_NUMBER() OVER (
             PARTITION BY tc.cohort_definition_id, tc.subject_id
             ORDER BY ABS(DATEDIFF(day, tc.cohort_start_date, r.record_date)),
                      CASE WHEN r.record_date < tc.cohort_start_date THEN 0 ELSE 1 END,
                      r.value DESC) AS rn
      FROM @work_database_schema.@cohort_table tc
      JOIN (
        SELECT person_id, measurement_date AS record_date, value_as_number AS value
          FROM @cdm_database_schema.measurement
         WHERE measurement_concept_id = 42538860
        UNION ALL
        SELECT person_id, observation_date, value_as_number
          FROM @cdm_database_schema.observation
         WHERE observation_concept_id = 42538860
      ) r
        ON r.person_id = tc.subject_id
       AND r.record_date >= DATEADD(day, -30, tc.cohort_start_date)
       AND r.record_date <= DATEADD(day, 30, tc.cohort_start_date)
     WHERE tc.cohort_definition_id IN (@cohort_definition_ids)
       AND r.value >= 0 AND r.value <= 40
  ) x
 WHERE rn = 1;
