-- Generated from bladder_cancer_provenance.sql by translate.R for pdw.
-- Replace @cdm_database_schema, @vocabulary_database_schema and
-- @cohort_database_schema before running.

-- Bladder cancer condition records for patients in an already generated
-- cohort (e.g. Target 1A), split by provenance
-- (condition_type_concept_id: EHR, claims, registry, ...).
-- Concept set is [GDE] Bladder Cancer (codeset 5 in Target_1A.json).
-- One row per condition_type_concept_id, plus an 'ALL' row (NULL type id).
-- Counts every record for a cohort patient, not only those near index.
--
-- SqlRender parameters: cdm_database_schema, vocabulary_database_schema,
--   cohort_database_schema, cohort_table, cohort_id
-- Defaults: run.R's cohort table, and Target 1A's id (JSON cohorts are
-- numbered from 1 in sorted file order; Target_1A.json sorts first).
WITH bc_concepts AS (
  SELECT ca.descendant_concept_id AS concept_id
    FROM @vocabulary_database_schema.concept_ancestor ca
   WHERE ca.ancestor_concept_id = 197508
     AND ca.descendant_concept_id NOT IN (
       SELECT descendant_concept_id
         FROM @vocabulary_database_schema.concept_ancestor
        WHERE ancestor_concept_id IN (4200889, 4280899, 4289374, 4280900,
                                      4283614, 4289097, 4280901, 4312566))
),
bc AS (
  SELECT co.person_id, COALESCE(co.condition_type_concept_id, 0) AS type_concept_id
    FROM @cdm_database_schema.condition_occurrence co
    JOIN bc_concepts c ON c.concept_id = co.condition_concept_id
    JOIN (SELECT DISTINCT subject_id
            FROM @cohort_database_schema.bc_cohort
           WHERE cohort_definition_id = 1) coh
      ON coh.subject_id = co.person_id
),
counts AS (
  SELECT type_concept_id,
         COUNT(DISTINCT person_id) AS n_patients, COUNT(*) AS n_records
    FROM bc
   GROUP BY bc.type_concept_id
  UNION ALL
  SELECT CAST(NULL AS INT) AS type_concept_id,
         COUNT(DISTINCT person_id) AS n_patients, COUNT(*) AS n_records
    FROM bc
)
SELECT t.type_concept_id,
       CASE WHEN t.type_concept_id IS NULL THEN 'ALL'
            ELSE COALESCE(c.concept_name, 'Not in vocabulary') END AS type_concept_name,
       t.n_patients,
       t.n_records
  FROM counts t
  LEFT JOIN @vocabulary_database_schema.concept c
    ON c.concept_id = t.type_concept_id
 ORDER BY t.n_records DESC;
