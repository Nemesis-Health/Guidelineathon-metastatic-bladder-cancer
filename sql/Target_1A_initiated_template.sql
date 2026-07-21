-- ===========================================================================
-- Target 1A initiated base — treatment-initiation cohort derived from Cohort 1
-- ===========================================================================
-- Descends directly from Target_1A (Cohort 1): for each Cohort 1 member, take
-- their EARLIEST qualifying regimen episode and index the patient at that
-- regimen's start date (treatment start). A regimen episode qualifies when:
--
--   * it maps to a regimen in the classification table (so it is classifiable
--     into the 4/5/6 a-f arms downstream), and
--   * episode_start_date is within [Cohort 1 index - 30, Cohort 1 index + 90], and
--   * episode_end_date is after the Cohort 1 index (regimen still active at or
--     after the metastatic-disease index).
--
-- cohort_start_date = the first qualifying episode's start (treatment start).
-- cohort_end_date   = Cohort 1's end date (inherits Cohort 1 follow-up, incl.
--                     its second-malignancy censoring).
--
-- Inclusion criteria (age >= 18, metastasis, prior bladder cancer, no other
-- cancer) are NOT re-derived here — they are inherited from Cohort 1 membership.
--
-- Rendered placeholders (filled in run_bladder_study.R before generation):
--   @cohort1_id, @regimen_episode_table, @regimen_classification_table
-- Generation placeholders (filled by CohortGenerator):
--   @target_database_schema, @target_cohort_table, @target_cohort_id
-- ===========================================================================

DELETE FROM @target_database_schema.@target_cohort_table
 WHERE cohort_definition_id = @target_cohort_id;

INSERT INTO @target_database_schema.@target_cohort_table
  (cohort_definition_id, subject_id, cohort_start_date, cohort_end_date)
SELECT @target_cohort_id AS cohort_definition_id,
       f.subject_id, f.cohort_start_date, f.cohort_end_date
FROM (
  SELECT tc.subject_id,
         re.episode_start_date AS cohort_start_date,
         tc.cohort_end_date    AS cohort_end_date,
         ROW_NUMBER() OVER (
           PARTITION BY tc.subject_id
           ORDER BY re.episode_start_date ASC,
                    re.episode_end_date ASC,
                    re.episode_source_value ASC
         ) AS rn
  FROM @target_database_schema.@target_cohort_table tc
  JOIN @target_database_schema.@regimen_episode_table re
    ON tc.subject_id = CAST(re.person_id AS BIGINT)
  JOIN @target_database_schema.@regimen_classification_table rc
    ON re.episode_source_value = rc.regName
  WHERE tc.cohort_definition_id = @cohort1_id
    AND re.episode_start_date >= DATEADD(day, -30, tc.cohort_start_date)
    AND re.episode_start_date <= DATEADD(day,  90, tc.cohort_start_date)
    AND re.episode_end_date   >  tc.cohort_start_date
) f
WHERE f.rn = 1;
