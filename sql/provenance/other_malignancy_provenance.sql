-- "Other malignancy" condition records for patients with metastatic bladder
-- cancer, split by provenance (condition_type_concept_id: EHR, claims,
-- registry, ...).
-- Concept set is [GDE] Excluded primaries (codeset 3 in Target_1A.json), the
-- set T1A's "no other cancer" rule excludes on.
-- One row per condition_type_concept_id, plus an 'ALL' row (NULL type id).
-- Counts every record for a population patient, not only those near index.
-- Population: first metastasis record per patient, measurement or condition
-- ([GDE] metastasis (measurement), codeset 0 in Target_1A.json), limited to
-- patients with a bladder cancer code ([GDE] Bladder Cancer, codeset 5) from
-- 180 days before to 30 days after it. T1A's age and other-cancer rules are not applied.
--
-- SqlRender parameters: cdm_database_schema, vocabulary_database_schema

-- Concept sets below are generated from Target_1A.json and expanded as Atlas
-- does: included concepts (with descendants where flagged), minus excluded
-- ones. Regenerate them when the Target 1A concept sets change.

WITH bc_concepts AS (
  SELECT i.concept_id
    FROM (
      SELECT concept_id
        FROM @vocabulary_database_schema.concept
       WHERE concept_id IN (197508)
      UNION
      SELECT c.concept_id
        FROM @vocabulary_database_schema.concept c
        JOIN @vocabulary_database_schema.concept_ancestor ca
          ON ca.descendant_concept_id = c.concept_id
       WHERE ca.ancestor_concept_id IN (197508)
         AND c.invalid_reason IS NULL
    ) i
   WHERE i.concept_id NOT IN (4200889, 4280899, 4280900, 4280901, 4283614, 4289097, 4289374, 4312566)
     AND i.concept_id NOT IN (
       SELECT c.concept_id
         FROM @vocabulary_database_schema.concept c
         JOIN @vocabulary_database_schema.concept_ancestor ca
           ON ca.descendant_concept_id = c.concept_id
        WHERE ca.ancestor_concept_id IN (4200889, 4280899, 4280900, 4280901, 4283614, 4289097, 4289374, 4312566)
          AND c.invalid_reason IS NULL)
),
-- [GDE] metastasis (measurement)
met_concepts AS (
  SELECT i.concept_id
    FROM (
      SELECT concept_id
        FROM @vocabulary_database_schema.concept
       WHERE concept_id IN (192735, 1340420, 1346178, 1346230, 1633308, 1635142, 36769180, 37019862)
      UNION
      SELECT c.concept_id
        FROM @vocabulary_database_schema.concept c
        JOIN @vocabulary_database_schema.concept_ancestor ca
          ON ca.descendant_concept_id = c.concept_id
       WHERE ca.ancestor_concept_id IN (1633308, 1635142, 36769180)
         AND c.invalid_reason IS NULL
    ) i
   WHERE i.concept_id NOT IN (35225577, 35225579, 35225625, 35226025, 35226028, 35226041, 35226264,
                         35226304)
),
-- First metastasis record per patient, from measurements or conditions, as
-- Target 1A's entry event.
met_index AS (
  SELECT r.person_id, MIN(r.event_date) AS index_date
    FROM (
      SELECT m.person_id, m.measurement_date AS event_date
        FROM @cdm_database_schema.measurement m
        JOIN met_concepts mc ON mc.concept_id = m.measurement_concept_id
      UNION ALL
      SELECT co.person_id, co.condition_start_date AS event_date
        FROM @cdm_database_schema.condition_occurrence co
        JOIN met_concepts mc ON mc.concept_id = co.condition_concept_id
    ) r
   GROUP BY r.person_id
),
population AS (
  SELECT DISTINCT mi.person_id
    FROM met_index mi
    JOIN @cdm_database_schema.condition_occurrence co ON co.person_id = mi.person_id
    JOIN bc_concepts c ON c.concept_id = co.condition_concept_id
   WHERE co.condition_start_date >= DATEADD(day, -180, mi.index_date)
     AND co.condition_start_date <= DATEADD(day, 30, mi.index_date)
),
-- [GDE] Excluded primaries
om_concepts AS (
  SELECT i.concept_id
    FROM (
      SELECT concept_id
        FROM @vocabulary_database_schema.concept
       WHERE concept_id IN (443392, 4280899, 4280900, 4280901, 4283614, 4289097, 4289374, 4312566)
      UNION
      SELECT c.concept_id
        FROM @vocabulary_database_schema.concept c
        JOIN @vocabulary_database_schema.concept_ancestor ca
          ON ca.descendant_concept_id = c.concept_id
       WHERE ca.ancestor_concept_id IN (443392)
         AND c.invalid_reason IS NULL
    ) i
   WHERE i.concept_id NOT IN (73720, 76349, 197506, 197508, 197804, 198988, 200680, 443392, 1244789,
                         4091486, 4111019, 4111921, 4112752, 4154630,
                         4169598, 4177236, 4180915, 4183631, 4200889,
                         4226357, 4289099, 4289101, 4289251, 4289373,
                         4289675, 36402643, 36537757, 36563190,
                         36684472, 36712771, 36716620, 37017320,
                         37109929, 37110269, 37110270, 37163176,
                         37163178, 37163865, 37164585, 37166263,
                         37166559, 37166561, 37166563, 37166564,
                         37167985, 37172812, 37172814, 40488919,
                         40492037, 42513085, 42513090, 42513091,
                         44500641, 44501785, 45757101, 45757107,
                         45769408)
     AND i.concept_id NOT IN (
       SELECT c.concept_id
         FROM @vocabulary_database_schema.concept c
         JOIN @vocabulary_database_schema.concept_ancestor ca
           ON ca.descendant_concept_id = c.concept_id
        WHERE ca.ancestor_concept_id IN (197508, 4111921, 4112752)
          AND c.invalid_reason IS NULL)
),
om AS (
  SELECT co.person_id, COALESCE(co.condition_type_concept_id, 0) AS type_concept_id
    FROM @cdm_database_schema.condition_occurrence co
    JOIN om_concepts c ON c.concept_id = co.condition_concept_id
    JOIN population p ON p.person_id = co.person_id
),
counts AS (
  SELECT type_concept_id,
         COUNT(DISTINCT person_id) AS n_patients, COUNT(*) AS n_records
    FROM om
   GROUP BY om.type_concept_id
  UNION ALL
  SELECT CAST(NULL AS INT) AS type_concept_id,
         COUNT(DISTINCT person_id) AS n_patients, COUNT(*) AS n_records
    FROM om
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
