-- =============================================================================
-- drug_rollup.sql — drugs on/before index, rolled up to ATC 1st level (the
-- protocol's concept-based "drug era groups")
-- =============================================================================
-- For every cohort in @cohort_definition_ids, counts subjects with >=1 drug
-- era starting on or before their own index date (no lower bound) in each
-- ATC 1st-level group (the 14 anatomical main groups, read from the
-- vocabulary). The protocol counts drug eras overlapping the baseline
-- interval, with an unbounded look-back that is any era starting on or before
-- index. @use_drug_era = 0 reads drug_exposure start dates instead, for CDMs
-- without a populated drug_era (the R step decides).
--
-- A drug counts in EVERY ATC group it belongs to (e.g. aspirin in B and N),
-- so groups overlap and don't sum to the cohort. Drugs with no ATC ancestor
-- are 'No ATC group', unmapped records (concept 0) are not counted.
--
-- Output: cohort_definition_id, stratum_type, stratum_value, category_order,
--         category, n_subjects, plus one category_order = -1 row per
--         cohort x stratum carrying the denominator in n_subjects.
--
-- SqlRender parameters: @work_database_schema @cohort_table
--   @cdm_database_schema @vocabulary_database_schema @cohort_definition_ids
--   @use_drug_era (1/0), subject_strata_sql (pre-rendered subject_strata.sql)
-- =============================================================================

WITH strata AS (
  @subject_strata_sql
),
atc_groups AS (
  SELECT concept_id AS category_id, concept_code, concept_name
    FROM @vocabulary_database_schema.concept
   WHERE vocabulary_id = 'ATC'
     AND concept_class_id = 'ATC 1st'
     AND invalid_reason IS NULL
),
target AS (
  SELECT DISTINCT cohort_definition_id, subject_id, cohort_start_date
    FROM @work_database_schema.@cohort_table
   WHERE cohort_definition_id IN (@cohort_definition_ids)
),
subject_drugs AS (
{@use_drug_era == 1} ? {
  SELECT DISTINCT t.cohort_definition_id, t.subject_id, de.drug_concept_id
    FROM target t
    JOIN @cdm_database_schema.drug_era de
      ON de.person_id = t.subject_id
     AND de.drug_era_start_date <= t.cohort_start_date
   WHERE de.drug_concept_id <> 0
} : {
  SELECT DISTINCT t.cohort_definition_id, t.subject_id, de.drug_concept_id
    FROM target t
    JOIN @cdm_database_schema.drug_exposure de
      ON de.person_id = t.subject_id
     AND de.drug_exposure_start_date <= t.cohort_start_date
   WHERE de.drug_concept_id <> 0
}
),
drug_group AS (
  SELECT DISTINCT ca.descendant_concept_id AS drug_concept_id, ag.concept_code
    FROM @vocabulary_database_schema.concept_ancestor ca
    JOIN atc_groups ag
      ON ag.category_id = ca.ancestor_concept_id
   WHERE ca.descendant_concept_id IN (SELECT drug_concept_id FROM subject_drugs)
),
subject_group AS (
  SELECT DISTINCT sd.cohort_definition_id, sd.subject_id,
         COALESCE(dg.concept_code, 'ZZ') AS concept_code
    FROM subject_drugs sd
    LEFT JOIN drug_group dg
      ON dg.drug_concept_id = sd.drug_concept_id
),
group_names AS (
  SELECT concept_code, concept_name AS category FROM atc_groups
  UNION ALL SELECT 'ZZ', 'No ATC group'
),
target_strata AS (
  SELECT s.*
    FROM strata s
    JOIN (SELECT DISTINCT cohort_definition_id, subject_id FROM target) t
      ON t.cohort_definition_id = s.cohort_definition_id AND t.subject_id = s.subject_id
),
tagged AS (
  SELECT 'overall' AS stratum_type, 'overall' AS stratum_value, cohort_definition_id, subject_id FROM target_strata
  UNION ALL
  SELECT 'age_group', age_group, cohort_definition_id, subject_id FROM target_strata
  UNION ALL
  SELECT 'sex', sex, cohort_definition_id, subject_id FROM target_strata
  UNION ALL
  SELECT 'age_sex', age_sex, cohort_definition_id, subject_id FROM target_strata
  UNION ALL
  SELECT 'age_band', age_band, cohort_definition_id, subject_id FROM target_strata
  UNION ALL
  SELECT 'index_period', index_period, cohort_definition_id, subject_id FROM target_strata
  UNION ALL
  SELECT 'index_period_2021', index_period_2021, cohort_definition_id, subject_id FROM target_strata
),
counts AS (
  SELECT tg.stratum_type, tg.stratum_value, tg.cohort_definition_id, sg.concept_code,
         COUNT(DISTINCT tg.subject_id) AS n_subjects
    FROM tagged tg
    JOIN subject_group sg
      ON sg.cohort_definition_id = tg.cohort_definition_id AND sg.subject_id = tg.subject_id
   GROUP BY tg.stratum_type, tg.stratum_value, tg.cohort_definition_id, sg.concept_code
),
denominators AS (
  SELECT tg.stratum_type, tg.stratum_value, tg.cohort_definition_id,
         COUNT(DISTINCT tg.subject_id) AS n_subjects
    FROM tagged tg
   GROUP BY tg.stratum_type, tg.stratum_value, tg.cohort_definition_id
)
SELECT c.stratum_type, c.stratum_value, c.cohort_definition_id,
       c.concept_code AS category_order, gn.category, c.n_subjects
  FROM counts c
  JOIN group_names gn ON gn.concept_code = c.concept_code
UNION ALL
SELECT d.stratum_type, d.stratum_value, d.cohort_definition_id,
       '-1' AS category_order, 'n_cohort' AS category, d.n_subjects
  FROM denominators d
;
