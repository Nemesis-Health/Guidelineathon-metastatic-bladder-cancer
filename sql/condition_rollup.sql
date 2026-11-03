-- =============================================================================
-- condition_rollup.sql — conditions on/before index, rolled up into disease
-- categories (the protocol's concept-based "condition groups")
-- =============================================================================
-- For every cohort in @cohort_definition_ids, counts subjects with >=1
-- condition_occurrence record on or before their own index date (no lower
-- bound) in each category. A category is the descendants of its SNOMED parent
-- concepts (rollup_categories below). A condition concept under several
-- parents goes to the category with the lowest precedence, so categories are
-- exclusive per concept, much like ICD-10 chapters, a subject is counted once
-- in every category any of their conditions falls in.
--
-- Changes from the roll-up this is based on:
--   * precedence 0 'Bladder cancer' (197508 +desc) is taken out first, so
--     'Neoplasm' counts other neoplasms. R/steps/23_rollups.R doesn't report
--     'Neoplasm': metastases recorded as conditions map to the primary-site
--     malignancy, so it mixes other primaries with metastases. It stays here
--     so neoplasm codes don't fall into the organ categories,
--   * 'Drug-related disorder' (444363) dropped: non-standard, so it has no
--     descendants in concept_ancestor,
--   * 'Inflammatory disorder' and 'Edema' dropped from 'Soft tissue or bone':
--     they pulled in inflammation and oedema anywhere (e.g. cystitis),
--   * 'ENT disease' ('Disorder of head') replaced by 'Ear disease' ('Disorder
--     of ear'), nose, sinus, pharynx and larynx fall under Respiratory, as in
--     ICD-10.
-- Concepts under no category parent (outside 'Clinical finding') are
-- 'Other condition', unmapped records (concept 0) are not counted.
--
-- Output: cohort_definition_id, stratum_type, stratum_value, category_order,
--         category, n_subjects, n_subjects_2plus, n_records, plus one
--         category_order = -1 row per cohort x stratum carrying the
--         denominator in n_subjects.
--
-- cancer = TRUE (other cancers): only codes in cancer_codeset_sql
-- (the cohorts' "Excluded primaries" concept set, pre-rendered) within
-- [index - 180d, index + 30d], the cohort rule's window, rolled up to cancer
-- sites that follow the ICD-10 C-blocks, the rest is 'Other cancer'. Adds
-- n_records and n_subjects_2plus (subjects with >= 2 records).
--
-- SqlRender parameters: @work_database_schema @cohort_table
--   @cdm_database_schema @vocabulary_database_schema @cohort_definition_ids
--   @cancer, subject_strata_sql (pre-rendered subject_strata.sql),
--   cancer_codeset_sql
-- =============================================================================

WITH strata AS (
  @subject_strata_sql
),
rollup_categories AS (
{@cancer} ? {
  SELECT 1 AS category_order, 'Lung' AS category, 443388 AS ancestor_concept_id
  UNION ALL SELECT 1, 'Lung', 443399
  UNION ALL SELECT 2, 'Pleura and mesothelioma', 4180795
  UNION ALL SELECT 2, 'Pleura and mesothelioma', 37166566
  UNION ALL SELECT 3, 'Head and neck', 436045
  UNION ALL SELECT 4, 'Prostate', 4163261
  UNION ALL SELECT 5, 'Testis', 4177115
  UNION ALL SELECT 6, 'Breast', 4112853
  UNION ALL SELECT 7, 'Ovary', 4181351
  UNION ALL SELECT 8, 'Uterus and cervix', 197230
  UNION ALL SELECT 8, 'Uterus and cervix', 198984
  UNION ALL SELECT 9, 'Kidney', 196653
  UNION ALL SELECT 10, 'Renal pelvis and ureter', 4181357
  UNION ALL SELECT 10, 'Renal pelvis and ureter', 4178972
  UNION ALL SELECT 11, 'Urethra', 4177230
  UNION ALL SELECT 12, 'Colorectal and anus', 443396
  UNION ALL SELECT 12, 'Colorectal and anus', 4180911
  UNION ALL SELECT 13, 'Oesophagus', 4181343
  UNION ALL SELECT 14, 'Stomach', 443387
  UNION ALL SELECT 15, 'Liver', 4246127
  UNION ALL SELECT 16, 'Pancreas', 4180793
  UNION ALL SELECT 17, 'Brain and CNS', 4155285
  UNION ALL SELECT 18, 'Thyroid', 4178976
  UNION ALL SELECT 19, 'Bone', 443564
  UNION ALL SELECT 19, 'Bone', 35610234
  UNION ALL SELECT 20, 'Melanoma', 4162276
  UNION ALL SELECT 21, 'Lymphoma', 432571
  UNION ALL SELECT 22, 'Myeloma', 437233
  UNION ALL SELECT 23, 'Leukaemia', 317510
  UNION ALL SELECT 24, 'Unknown primary site', 4149322
  UNION ALL SELECT 25, 'Other respiratory', 40493428
  UNION ALL SELECT 26, 'Other digestive', 4116238
  UNION ALL SELECT 27, 'Other male genital', 4181487
  UNION ALL SELECT 28, 'Other female genital', 4177244
  UNION ALL SELECT 29, 'Other endocrine', 4156115
  UNION ALL SELECT 30, 'Other skin', 4155297
  UNION ALL SELECT 31, 'Other haematological', 4147164
  UNION ALL SELECT 32, 'Soft tissue and sarcoma', 4153882
  UNION ALL SELECT 32, 'Soft tissue and sarcoma', 4311439
} : {
  SELECT 0 AS category_order, 'Bladder cancer' AS category, 197508 AS ancestor_concept_id
  UNION ALL SELECT 1, 'Blood or immune disease', 440371
  UNION ALL SELECT 1, 'Blood or immune disease', 443723
  UNION ALL SELECT 2, 'Injury and poisoning', 432795
  UNION ALL SELECT 2, 'Injury and poisoning', 442562
  UNION ALL SELECT 3, 'Congenital disease', 440508
  UNION ALL SELECT 4, 'Pregnancy or childbirth', 435875
  UNION ALL SELECT 4, 'Pregnancy or childbirth', 4088927
  UNION ALL SELECT 4, 'Pregnancy or childbirth', 4154314
  UNION ALL SELECT 4, 'Pregnancy or childbirth', 4136529
  UNION ALL SELECT 5, 'Perinatal disease', 441406
  UNION ALL SELECT 6, 'Infection', 432250
  UNION ALL SELECT 7, 'Neoplasm (other than bladder cancer)', 4266186
  UNION ALL SELECT 8, 'Endocrine or metabolic disease', 31821
  UNION ALL SELECT 8, 'Endocrine or metabolic disease', 4090739
  UNION ALL SELECT 8, 'Endocrine or metabolic disease', 436670
  UNION ALL SELECT 9, 'Mental disease', 432586
  UNION ALL SELECT 9, 'Mental disease', 4023059
  UNION ALL SELECT 9, 'Mental disease', 4293175
  UNION ALL SELECT 10, 'Nerve disease and pain', 376337
  UNION ALL SELECT 10, 'Nerve disease and pain', 4011630
  UNION ALL SELECT 11, 'Eye disease', 4038502
  UNION ALL SELECT 12, 'Ear disease', 378161
  UNION ALL SELECT 13, 'Cardiovascular disease', 134057
  UNION ALL SELECT 14, 'Respiratory disease', 320136
  UNION ALL SELECT 14, 'Respiratory disease', 4115386
  UNION ALL SELECT 15, 'Digestive disease', 4302537
  UNION ALL SELECT 16, 'Skin disease', 4028387
  UNION ALL SELECT 17, 'Soft tissue or bone disease', 4244662
  UNION ALL SELECT 17, 'Soft tissue or bone disease', 4344497
  UNION ALL SELECT 17, 'Soft tissue or bone disease', 40482430
  UNION ALL SELECT 18, 'Genitourinary disease', 4041285
  UNION ALL SELECT 19, 'Iatrogenic condition', 4105886
  UNION ALL SELECT 19, 'Iatrogenic condition', 4053838
  UNION ALL SELECT 19, 'Iatrogenic condition', 444199
  UNION ALL SELECT 20, 'Not categorized', 441840

}
),
category_names AS (
  SELECT DISTINCT category_order, category FROM rollup_categories
  UNION ALL SELECT 99, {@cancer} ? {'Other cancer'} : {'Other condition'}
),
target AS (
  SELECT DISTINCT cohort_definition_id, subject_id, cohort_start_date
    FROM @work_database_schema.@cohort_table
   WHERE cohort_definition_id IN (@cohort_definition_ids)
),
subject_concepts AS (
  SELECT t.cohort_definition_id, t.subject_id, co.condition_concept_id, COUNT(*) AS n_rec
    FROM target t
    JOIN @cdm_database_schema.condition_occurrence co
      ON co.person_id = t.subject_id
{@cancer} ? {
     AND co.condition_start_date >= DATEADD(day, -180, t.cohort_start_date)
     AND co.condition_start_date <= DATEADD(day, 30, t.cohort_start_date)
   WHERE co.condition_concept_id IN (SELECT concept_id FROM (@cancer_codeset_sql) cs)
} : {
     AND co.condition_start_date <= t.cohort_start_date
   WHERE co.condition_concept_id <> 0
}
   GROUP BY t.cohort_definition_id, t.subject_id, co.condition_concept_id
),
concept_category AS (
  SELECT ca.descendant_concept_id AS concept_id,
         MIN(rc.category_order)   AS category_order
    FROM @vocabulary_database_schema.concept_ancestor ca
    JOIN rollup_categories rc
      ON rc.ancestor_concept_id = ca.ancestor_concept_id
   WHERE ca.descendant_concept_id IN (SELECT condition_concept_id FROM subject_concepts)
   GROUP BY ca.descendant_concept_id
),
subject_category AS (
  SELECT sc.cohort_definition_id, sc.subject_id,
         COALESCE(cc.category_order, 99) AS category_order, SUM(sc.n_rec) AS n_rec
    FROM subject_concepts sc
    LEFT JOIN concept_category cc
      ON cc.concept_id = sc.condition_concept_id
   GROUP BY sc.cohort_definition_id, sc.subject_id, COALESCE(cc.category_order, 99)
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
  SELECT tg.stratum_type, tg.stratum_value, tg.cohort_definition_id, sc.category_order,
         COUNT(DISTINCT tg.subject_id) AS n_subjects,
         COUNT(DISTINCT CASE WHEN sc.n_rec >= 2 THEN tg.subject_id END) AS n_subjects_2plus,
         SUM(sc.n_rec) AS n_records
    FROM tagged tg
    JOIN subject_category sc
      ON sc.cohort_definition_id = tg.cohort_definition_id AND sc.subject_id = tg.subject_id
   GROUP BY tg.stratum_type, tg.stratum_value, tg.cohort_definition_id, sc.category_order
),
denominators AS (
  SELECT tg.stratum_type, tg.stratum_value, tg.cohort_definition_id, -1 AS category_order,
         COUNT(DISTINCT tg.subject_id) AS n_subjects,
         CAST(NULL AS INT) AS n_subjects_2plus, CAST(NULL AS INT) AS n_records
    FROM tagged tg
   GROUP BY tg.stratum_type, tg.stratum_value, tg.cohort_definition_id
)
SELECT c.stratum_type, c.stratum_value, c.cohort_definition_id, c.category_order,
       cn.category, c.n_subjects, c.n_subjects_2plus, c.n_records
  FROM counts c
  JOIN category_names cn ON cn.category_order = c.category_order
UNION ALL
SELECT d.stratum_type, d.stratum_value, d.cohort_definition_id, d.category_order,
       'n_cohort' AS category, d.n_subjects, d.n_subjects_2plus, d.n_records
  FROM denominators d
;
