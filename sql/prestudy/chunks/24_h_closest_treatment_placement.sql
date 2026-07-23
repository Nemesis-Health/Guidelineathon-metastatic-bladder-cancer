-- 24) H. Metastasis-to-treatment timing, part 1. Where each patient's CLOSEST
--     antineoplastic treatment falls relative to the first Metastasis.
--     Each patient who carries an anchor Metastasis (MET) code (and therefore also
--     an anchor DX code) is placed in exactly one category by the side of the first
--     MET on which their single CLOSEST antineoplastic (L01) drug_exposure record
--     falls. "Closest" = the L01 record with the minimum absolute days-difference to
--     the first MET, signed:
--
--       CLOSEST_L01_BEFORE_MET   closest L01 record is before the first MET   (days_diff < 0)
--       CLOSEST_L01_ON_MET_DAY   closest L01 record is on the first MET date  (days_diff = 0, day 0)
--       CLOSEST_L01_AFTER_MET    closest L01 record is after the first MET    (days_diff > 0)
--       NO_L01_EVER              no antineoplastic drug_exposure record at all
--
--     days_diff = DATEDIFF(DAY, first_met_date, l01_event_date): negative = before,
--     0 = same calendar day as the first MET (day 0, its own explicit category,
--     never folded into "after"), positive = after. One value per patient. Ties in
--     absolute distance are broken by earlier event_date, the framework's CLOSEST
--     convention (ROW_NUMBER ... ORDER BY ABS(days_diff), event_date), so an
--     equidistant tie resolves to the before record.
--
--     Denominator (n_patients_met_total, repeated on each row):
--       all patients with >= 1 anchor MET measurement code AND >= 1 anchor DX code
--       at this site (before + day0 + after + never = this total).
--
--     POPULATION. Built from #met_events (00_setup.sql, section F):
--     @cdm_database_schema.measurement JOIN #met_concepts JOIN #anchor_person, so
--     every patient carries an anchor DX code. The cohort is DX-anchored; a MET code
--     is observed WITHIN that cohort, never as a separate entry point. There is no
--     "MET-only, no DX" patient: the MET concept set is generic across cancer types,
--     so a MET code without an anchor DX gives no evidence of the cancer of interest.
--     #anchor_person carries no observation-period-at-index gate (that is #cohort);
--     see the observation-period flag below. Identical DX-anchored population to
--     Analysis D (chunks 20-23).
--
--     L01 SOURCE. Antineoplastic records come from #l01_events (00_setup.sql,
--     section F): @cdm_database_schema.drug_exposure JOIN #l01_concepts JOIN
--     #anchor_person. #l01_events is gated to the same DX anchor cohort as the MET
--     population, so every MET patient's L01 records are present and none are missed.
--
--     JUDGMENT CALL / FLAG (observation period). Neither the MET population nor the
--     L01 records are restricted to an observation period. The population is anchored
--     on "has an anchor DX code" (#anchor_person), not "inside an observation period"
--     (#cohort). Observation-period coverage is characterized separately in Analysis
--     E (chunks 16-17). See the accompanying report for the reasoned recommendation.
--
--     Small-cell suppression: n_patients in (0, @min_cell_count] set to
--     -@min_cell_count. n_patients_met_total is an aggregate denominator, not
--     suppressed. A category with zero patients is absent (as in chunks 18-23).

WITH met_all AS (
    -- DX-anchored MET population: earliest MET date per patient (#met_events is
    -- gated to #anchor_person and carries no observation-period gate).
    SELECT
        person_id,
        MIN(event_date) AS first_met_date
    FROM #met_events
    GROUP BY person_id
),
l01_all AS (
    -- Antineoplastic drug_exposure records for the DX anchor cohort (#l01_events is
    -- gated to #anchor_person, the same cohort as the MET population).
    SELECT
        person_id,
        event_date
    FROM #l01_events
),
pair AS (
    -- Signed L01-to-first-MET distance for every L01 record of a MET patient.
    SELECT
        ma.person_id,
        DATEDIFF(DAY, ma.first_met_date, la.event_date) AS days_diff,
        la.event_date
    FROM met_all ma
    JOIN l01_all la
      ON la.person_id = ma.person_id
),
closest AS (
    -- Single closest L01 record per patient (framework CLOSEST convention).
    SELECT
        person_id,
        days_diff,
        ROW_NUMBER() OVER (
            PARTITION BY person_id
            ORDER BY ABS(days_diff), event_date
        ) AS rn
    FROM pair
),
classified AS (
    SELECT
        ma.person_id,
        CASE
            WHEN c.days_diff IS NULL THEN 'NO_L01_EVER'
            WHEN c.days_diff < 0     THEN 'CLOSEST_L01_BEFORE_MET'
            WHEN c.days_diff = 0     THEN 'CLOSEST_L01_ON_MET_DAY'
            ELSE                          'CLOSEST_L01_AFTER_MET'
        END AS placement_category
    FROM met_all ma
    LEFT JOIN (SELECT person_id, days_diff FROM closest WHERE rn = 1) c
      ON c.person_id = ma.person_id
),
totals AS (
    SELECT COUNT(*) AS n_patients_met_total FROM met_all
)
SELECT
    c.placement_category,
    CASE WHEN COUNT(*) > 0 AND COUNT(*) <= @min_cell_count THEN -@min_cell_count
         ELSE COUNT(*) END AS n_patients,
    t.n_patients_met_total
FROM classified c
CROSS JOIN totals t
GROUP BY c.placement_category, t.n_patients_met_total
ORDER BY
    CASE c.placement_category
        WHEN 'CLOSEST_L01_BEFORE_MET' THEN 0
        WHEN 'CLOSEST_L01_ON_MET_DAY' THEN 1
        WHEN 'CLOSEST_L01_AFTER_MET'  THEN 2
        WHEN 'NO_L01_EVER'            THEN 3
        ELSE 9
    END
;
