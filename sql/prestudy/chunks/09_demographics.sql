-- 9) Demographics at anchor dates (INDEX = first DX, FIRST_MET = first MET)
-- Gender concept IDs (OMOP): 8507=Male, 8532=Female. Others treated as unknown.
WITH anchor_persons AS (
    SELECT
        'INDEX' AS anchor_event,
        c.person_id,
        c.index_date AS anchor_date
    FROM #patient_char c
    WHERE c.index_date IS NOT NULL
    UNION ALL
    SELECT
        'FIRST_MET' AS anchor_event,
        c.person_id,
        c.first_met_date AS anchor_date
    FROM #patient_char c
    WHERE c.first_met_date IS NOT NULL
),
base AS (
    SELECT
        a.anchor_event,
        a.person_id,
        a.anchor_date,
        p.gender_concept_id,
        p.birth_datetime,
        p.year_of_birth
    FROM anchor_persons a
    JOIN @cdm_database_schema.person p
      ON a.person_id = p.person_id
),
ages AS (
    SELECT
        anchor_event,
        person_id,
        gender_concept_id,
        CASE
            WHEN birth_datetime IS NOT NULL
                THEN DATEDIFF(DAY, CAST(birth_datetime AS DATE), anchor_date) / 365.25
            WHEN year_of_birth IS NOT NULL
                THEN DATEDIFF(DAY, DATEFROMPARTS(year_of_birth, 7, 1), anchor_date) / 365.25
            ELSE NULL
        END AS age_years
    FROM base
)
-- Small-cell suppression: n_patients/n_male/n_female in (0, @min_cell_count]
-- set to -@min_cell_count, independently; pct_male/pct_female and the age
-- quartiles blanked whenever their underlying count is censored (a raw
-- pct alongside a censored n would let the true small count be recomputed).
SELECT
    agg.anchor_event,
    CASE WHEN agg.n_patients > 0 AND agg.n_patients <= @min_cell_count
         THEN -@min_cell_count ELSE agg.n_patients END AS n_patients,
    CASE WHEN agg.n_male > 0 AND agg.n_male <= @min_cell_count
         THEN -@min_cell_count ELSE agg.n_male END AS n_male,
    CASE WHEN agg.n_female > 0 AND agg.n_female <= @min_cell_count
         THEN -@min_cell_count ELSE agg.n_female END AS n_female,
    CASE WHEN agg.n_male > 0 AND agg.n_male <= @min_cell_count
         THEN NULL ELSE agg.pct_male END AS pct_male,
    CASE WHEN agg.n_female > 0 AND agg.n_female <= @min_cell_count
         THEN NULL ELSE agg.pct_female END AS pct_female,
    CASE WHEN agg.n_patients > 0 AND agg.n_patients <= @min_cell_count
         THEN NULL ELSE p.age_lq_years END AS age_lq_years,
    CASE WHEN agg.n_patients > 0 AND agg.n_patients <= @min_cell_count
         THEN NULL ELSE p.age_median_years END AS age_median_years,
    CASE WHEN agg.n_patients > 0 AND agg.n_patients <= @min_cell_count
         THEN NULL ELSE p.age_uq_years END AS age_uq_years
FROM (
    SELECT
        anchor_event,
        COUNT(*) AS n_patients,
        SUM(CASE WHEN gender_concept_id = 8507 THEN 1 ELSE 0 END) AS n_male,
        SUM(CASE WHEN gender_concept_id = 8532 THEN 1 ELSE 0 END) AS n_female,
        CAST(100.0 * SUM(CASE WHEN gender_concept_id = 8507 THEN 1 ELSE 0 END) / NULLIF(COUNT(*), 0) AS FLOAT) AS pct_male,
        CAST(100.0 * SUM(CASE WHEN gender_concept_id = 8532 THEN 1 ELSE 0 END) / NULLIF(COUNT(*), 0) AS FLOAT) AS pct_female
    FROM ages
    WHERE age_years IS NOT NULL
    GROUP BY anchor_event
) agg
JOIN (
    SELECT
        anchor_event,
        MIN(CASE WHEN 4.0 * rn >= cnt THEN CAST(age_years AS FLOAT) END) AS age_lq_years,
        MIN(CASE WHEN 2.0 * rn >= cnt THEN CAST(age_years AS FLOAT) END) AS age_median_years,
        MIN(CASE WHEN 4.0 * rn >= 3 * cnt THEN CAST(age_years AS FLOAT) END) AS age_uq_years
    FROM (
        SELECT anchor_event, age_years,
            ROW_NUMBER() OVER (PARTITION BY anchor_event ORDER BY age_years) AS rn,
            COUNT(*)     OVER (PARTITION BY anchor_event)                    AS cnt
        FROM ages
        WHERE age_years IS NOT NULL
    ) y
    GROUP BY anchor_event
) p
  ON agg.anchor_event = p.anchor_event
ORDER BY CASE WHEN agg.anchor_event = 'INDEX' THEN 0 ELSE 1 END
;

