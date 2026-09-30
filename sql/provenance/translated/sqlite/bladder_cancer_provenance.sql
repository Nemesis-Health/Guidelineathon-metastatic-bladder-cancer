-- Generated from bladder_cancer_provenance.sql by translate.R for sqlite.
-- Replace @cdm_database_schema and @vocabulary_database_schema
-- before running.

-- Bladder cancer condition records for patients with metastatic bladder
-- cancer, split by provenance (condition_type_concept_id: EHR, claims,
-- registry, ...).
-- Concept set is [GDE] Bladder Cancer (codeset 5 in Target_1A.json).
-- One row per condition_type_concept_id, plus an 'ALL' row (NULL type id).
-- Counts every record for a population patient, not only those near index.
-- Population: first metastasis measurement per patient ([GDE] metastasis
-- (measurement), codeset 0 in Target_1A.json), limited to patients with a
-- bladder cancer code ([GDE] Bladder Cancer, codeset 5) from 180 days before
-- to 30 days after it. T1A's age and other-cancer rules are not applied.
--
-- SqlRender parameters: cdm_database_schema, vocabulary_database_schema
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
met_index AS (
  SELECT m.person_id, MIN(m.measurement_date) AS index_date
    FROM @cdm_database_schema.measurement m
   WHERE m.measurement_concept_id IN (
     SELECT descendant_concept_id
       FROM @vocabulary_database_schema.concept_ancestor
      WHERE ancestor_concept_id IN (1633308, 1635142, 36769180))
   GROUP BY m.person_id
),
population AS (
  SELECT DISTINCT mi.person_id
    FROM met_index mi
    JOIN @cdm_database_schema.condition_occurrence co ON co.person_id = mi.person_id
    JOIN bc_concepts c ON c.concept_id = co.condition_concept_id
   WHERE co.condition_start_date >= CAST(STRFTIME('%s', DATETIME(mi.index_date, 'unixepoch', (-180)||' days')) AS REAL)
     AND co.condition_start_date <= CAST(STRFTIME('%s', DATETIME(mi.index_date, 'unixepoch', (30)||' days')) AS REAL)
),
bc AS (
  SELECT co.person_id, COALESCE(co.condition_type_concept_id, 0) AS type_concept_id
    FROM @cdm_database_schema.condition_occurrence co
    JOIN bc_concepts c ON c.concept_id = co.condition_concept_id
    JOIN population p ON p.person_id = co.person_id
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
