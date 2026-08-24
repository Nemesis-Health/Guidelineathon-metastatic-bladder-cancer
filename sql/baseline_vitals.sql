/* ============================================================================
   baseline_vitals.sql
   Weight / height / BMI closest to index, per (cohort_definition_id, subject_id)
   OMOP CDM. Standard vital-sign concepts (unlike lab_cohorts.sql's per-analyte
   reference table, these are consistently coded enough across sites that a
   small fixed concept list is sufficient — no unit-resolution engine needed):
     body weight  3025315 (LOINC 29463-7); units kg=9529, lb=8739
     body height  3036277 (LOINC 8302-2);  units cm=8582, in=9330
     BMI          3038553 (LOINC 39156-5); assumed kg/m^2 as recorded

   Weight and height are each independently picked as the single closest
   measurement to cohort_start_date within +/- @vitals_window_days (they may
   land on different dates — standard practice). BMI is taken from a directly
   recorded BMI measurement when present in the same window, else derived
   from the picked weight_kg/height_cm.

   SqlRender parameters:
     @cdm_database_schema @work_database_schema @cohort_table
     @vitals_window_days
   ============================================================================ */

WITH idx AS (
  SELECT cohort_definition_id, subject_id, cohort_start_date
    FROM @work_database_schema.@cohort_table
),
weight AS (
  SELECT cohort_definition_id, subject_id, weight_kg
    FROM (
      SELECT i.cohort_definition_id, i.subject_id,
             CASE WHEN m.unit_concept_id = 8739 THEN m.value_as_number * 0.45359237
                  ELSE m.value_as_number END AS weight_kg,
             ROW_NUMBER() OVER (
               PARTITION BY i.cohort_definition_id, i.subject_id
               ORDER BY ABS(DATEDIFF(day, i.cohort_start_date, m.measurement_date))
             ) AS rn
        FROM idx i
        JOIN @cdm_database_schema.measurement m ON m.person_id = i.subject_id
       WHERE m.measurement_concept_id = 3025315
         AND m.value_as_number IS NOT NULL
         AND m.measurement_date BETWEEN
               DATEADD(day, -@vitals_window_days, i.cohort_start_date) AND
               DATEADD(day,  @vitals_window_days, i.cohort_start_date)
    ) w
   WHERE rn = 1
),
height AS (
  SELECT cohort_definition_id, subject_id, height_cm
    FROM (
      SELECT i.cohort_definition_id, i.subject_id,
             CASE WHEN m.unit_concept_id = 9330 THEN m.value_as_number * 2.54
                  ELSE m.value_as_number END AS height_cm,
             ROW_NUMBER() OVER (
               PARTITION BY i.cohort_definition_id, i.subject_id
               ORDER BY ABS(DATEDIFF(day, i.cohort_start_date, m.measurement_date))
             ) AS rn
        FROM idx i
        JOIN @cdm_database_schema.measurement m ON m.person_id = i.subject_id
       WHERE m.measurement_concept_id = 3036277
         AND m.value_as_number IS NOT NULL
         AND m.measurement_date BETWEEN
               DATEADD(day, -@vitals_window_days, i.cohort_start_date) AND
               DATEADD(day,  @vitals_window_days, i.cohort_start_date)
    ) h
   WHERE rn = 1
),
bmi_recorded AS (
  SELECT cohort_definition_id, subject_id, bmi
    FROM (
      SELECT i.cohort_definition_id, i.subject_id, m.value_as_number AS bmi,
             ROW_NUMBER() OVER (
               PARTITION BY i.cohort_definition_id, i.subject_id
               ORDER BY ABS(DATEDIFF(day, i.cohort_start_date, m.measurement_date))
             ) AS rn
        FROM idx i
        JOIN @cdm_database_schema.measurement m ON m.person_id = i.subject_id
       WHERE m.measurement_concept_id = 3038553
         AND m.value_as_number IS NOT NULL
         AND m.measurement_date BETWEEN
               DATEADD(day, -@vitals_window_days, i.cohort_start_date) AND
               DATEADD(day,  @vitals_window_days, i.cohort_start_date)
    ) b
   WHERE rn = 1
)
SELECT i.cohort_definition_id,
       i.subject_id,
       w.weight_kg,
       h.height_cm,
       COALESCE(
         br.bmi,
         CASE WHEN w.weight_kg IS NOT NULL AND h.height_cm IS NOT NULL AND h.height_cm > 0
              THEN w.weight_kg / POWER(h.height_cm / 100.0, 2)
              ELSE NULL END
       ) AS bmi
  FROM idx i
  LEFT JOIN weight       w  ON w.cohort_definition_id  = i.cohort_definition_id AND w.subject_id  = i.subject_id
  LEFT JOIN height       h  ON h.cohort_definition_id  = i.cohort_definition_id AND h.subject_id  = i.subject_id
  LEFT JOIN bmi_recorded br ON br.cohort_definition_id = i.cohort_definition_id AND br.subject_id = i.subject_id
 WHERE w.weight_kg IS NOT NULL OR h.height_cm IS NOT NULL OR br.bmi IS NOT NULL
