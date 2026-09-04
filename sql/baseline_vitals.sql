/* ============================================================================
   baseline_vitals.sql
   Weight / height / BMI closest to index, per cohort x variable x stratum
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

   Also stratified: every (cohort, variable) row is computed four times --
   overall, and split by age_group / sex / age_sex (subject_strata.sql --
   see that file's own header for the standard consumption pattern this
   follows). Same UNION-ALL-of-shared-percentile-formula shape as
   lab_value_distribution_portable.sql -- see that file's header for the
   interpolation formula (reproduces PERCENTILE_CONT exactly, R quantile
   type 7); median/quartiles use ROW_NUMBER()/COUNT()/FLOOR rather than
   PERCENTILE_CONT, which SqlRender leaves untranslated. All computed here in
   SQL, not pulled per-subject and aggregated in R.

   The value column is named vital_value, not the bare "value" -- avoids any
   ambiguity with dialects (Snowflake's FLATTEN()/LATERAL, BigQuery) that
   treat VALUE specially in some contexts, same reasoning
   lab_value_distribution_portable.sql's std_value follows.

   Output columns:
     stratum_type, stratum_value, cohort_definition_id, variable,
     n, mean, sd, median, lq, uq, min, max

   SqlRender parameters:
     @cdm_database_schema @work_database_schema @cohort_table
     @vitals_window_days
     subject_strata_sql (pre-rendered fragment, not a plain schema/table name
     -- see the `strata` CTE below): subject_strata.sql's own output,
     age_group/sex/age_sex per (cohort_definition_id, subject_id)
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
),
vitals AS (
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
),
-- Unpivot the three variables into one (cohort, subject, variable, value)
-- row each, so the stratification + percentile machinery below is written
-- once and shared across all three, instead of tripled.
unpivoted AS (
  SELECT cohort_definition_id, subject_id, 'weight_kg' AS variable, weight_kg AS vital_value
    FROM vitals WHERE weight_kg IS NOT NULL
  UNION ALL
  SELECT cohort_definition_id, subject_id, 'height_cm', height_cm
    FROM vitals WHERE height_cm IS NOT NULL
  UNION ALL
  SELECT cohort_definition_id, subject_id, 'bmi', bmi
    FROM vitals WHERE bmi IS NOT NULL
),
strata AS (
  @subject_strata_sql
),
tagged AS (
  SELECT u.cohort_definition_id, u.subject_id, u.variable, u.vital_value,
         s.age_group, s.sex, s.age_sex
    FROM unpivoted u
    JOIN strata s
      ON s.cohort_definition_id = u.cohort_definition_id
     AND s.subject_id           = u.subject_id
),
ranked AS (
  SELECT 'overall' AS stratum_type, 'overall' AS stratum_value,
         cohort_definition_id, variable, vital_value,
         ROW_NUMBER() OVER (
           PARTITION BY cohort_definition_id, variable
           ORDER BY vital_value)                                       AS rn,
         COUNT(*) OVER (
           PARTITION BY cohort_definition_id, variable)                AS n
    FROM tagged
  UNION ALL
  SELECT 'age_group' AS stratum_type, age_group AS stratum_value,
         cohort_definition_id, variable, vital_value,
         ROW_NUMBER() OVER (
           PARTITION BY cohort_definition_id, variable, age_group
           ORDER BY vital_value)                                       AS rn,
         COUNT(*) OVER (
           PARTITION BY cohort_definition_id, variable, age_group)     AS n
    FROM tagged
  UNION ALL
  SELECT 'sex' AS stratum_type, sex AS stratum_value,
         cohort_definition_id, variable, vital_value,
         ROW_NUMBER() OVER (
           PARTITION BY cohort_definition_id, variable, sex
           ORDER BY vital_value)                                       AS rn,
         COUNT(*) OVER (
           PARTITION BY cohort_definition_id, variable, sex)           AS n
    FROM tagged
  UNION ALL
  SELECT 'age_sex' AS stratum_type, age_sex AS stratum_value,
         cohort_definition_id, variable, vital_value,
         ROW_NUMBER() OVER (
           PARTITION BY cohort_definition_id, variable, age_sex
           ORDER BY vital_value)                                       AS rn,
         COUNT(*) OVER (
           PARTITION BY cohort_definition_id, variable, age_sex)       AS n
    FROM tagged
)
SELECT stratum_type,
       stratum_value,
       cohort_definition_id,
       variable,
       COUNT(*)                             AS n,
       AVG(CAST(vital_value AS FLOAT))       AS mean,
       STDEV(CAST(vital_value AS FLOAT))     AS sd,
       MIN(vital_value)                      AS min,
       SUM(CASE WHEN rn = FLOOR(0.25 * (n - 1)) + 1
                THEN vital_value * (1.0 - (0.25 * (n - 1) - FLOOR(0.25 * (n - 1))))
                WHEN rn = FLOOR(0.25 * (n - 1)) + 2
                THEN vital_value * (0.25 * (n - 1) - FLOOR(0.25 * (n - 1)))
                ELSE 0 END)                  AS lq,
       SUM(CASE WHEN rn = FLOOR(0.50 * (n - 1)) + 1
                THEN vital_value * (1.0 - (0.50 * (n - 1) - FLOOR(0.50 * (n - 1))))
                WHEN rn = FLOOR(0.50 * (n - 1)) + 2
                THEN vital_value * (0.50 * (n - 1) - FLOOR(0.50 * (n - 1)))
                ELSE 0 END)                  AS median,
       SUM(CASE WHEN rn = FLOOR(0.75 * (n - 1)) + 1
                THEN vital_value * (1.0 - (0.75 * (n - 1) - FLOOR(0.75 * (n - 1))))
                WHEN rn = FLOOR(0.75 * (n - 1)) + 2
                THEN vital_value * (0.75 * (n - 1) - FLOOR(0.75 * (n - 1)))
                ELSE 0 END)                  AS uq,
       MAX(vital_value)                      AS max
  FROM ranked
 GROUP BY stratum_type, stratum_value, cohort_definition_id, variable
 ORDER BY cohort_definition_id, variable, stratum_type, stratum_value
;
