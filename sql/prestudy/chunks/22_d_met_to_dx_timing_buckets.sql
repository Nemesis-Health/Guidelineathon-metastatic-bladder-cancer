-- 22) D. MET-first subgroup, part 3a. Time from the first Metastasis to the first
--     specific Diagnosis, bucketed, for the MET-first patients.
--     For the MET_FIRST_THEN_DX group of chunk 20, the gap in days from the first
--     MET to the first specific DX, placed in one bucket:
--
--       LTE30D    1 to 30 days      D91_180   91 to 180 days
--       D31_60    31 to 60 days     D181_365  181 to 365 days
--       D61_90    61 to 90 days     GT365D    366 days or more
--
--     All of this time is AFTER the first MET by construction (MET-first subgroup),
--     so the gap is >= 1 day and the first bucket contains 1-30 days. Day 0 cannot
--     occur: those patients are the SAME_DAY category of chunk 20, excluded here.
--
--     Denominator (n_patients_reaching_dx_total, repeated on each row):
--       MET-first patients who reach a specific DX = the MET_FIRST_THEN_DX group of
--       chunk 20 (the two SPECIFIC_DX_* buckets of chunk 21). Under the corrected
--       DX-anchored population every MET-first patient reaches a specific DX, so this
--       denominator equals the full MET-first subgroup.
--
--     Population and observation-period notes: same as chunk 20 (DX-anchored MET
--     population from #met_events, first specific DX from #dx_events, anchored on
--     #anchor_person, no observation-period gate).
--
--     Small-cell suppression: n_patients in (0, @min_cell_count] set to
--     -@min_cell_count. n_patients_reaching_dx_total is an aggregate denominator,
--     not suppressed. A bucket with zero patients is absent (as in chunks 18-19).

WITH met_all AS (
    SELECT
        person_id,
        MIN(event_date) AS first_met_date
    FROM #met_events
    GROUP BY person_id
),
dx_all AS (
    SELECT
        person_id,
        MIN(event_date) AS first_dx_date
    FROM #dx_events
    GROUP BY person_id
),
gap AS (
    -- MET-first-then-DX only: first MET strictly before the first specific DX.
    SELECT
        ma.person_id,
        DATEDIFF(DAY, ma.first_met_date, dx.first_dx_date) AS gap_days
    FROM met_all ma
    JOIN dx_all dx
      ON dx.person_id = ma.person_id
    WHERE ma.first_met_date < dx.first_dx_date
),
bucketed AS (
    SELECT
        person_id,
        CASE
            WHEN gap_days <= 30  THEN 'LTE30D'
            WHEN gap_days <= 60  THEN 'D31_60'
            WHEN gap_days <= 90  THEN 'D61_90'
            WHEN gap_days <= 180 THEN 'D91_180'
            WHEN gap_days <= 365 THEN 'D181_365'
            ELSE                      'GT365D'
        END AS timing_bucket,
        CASE
            WHEN gap_days <= 30  THEN 1
            WHEN gap_days <= 60  THEN 2
            WHEN gap_days <= 90  THEN 3
            WHEN gap_days <= 180 THEN 4
            WHEN gap_days <= 365 THEN 5
            ELSE                      6
        END AS bucket_order
    FROM gap
),
totals AS (
    SELECT COUNT(*) AS n_patients_reaching_dx_total FROM bucketed
)
SELECT
    b.timing_bucket,
    CASE WHEN COUNT(*) > 0 AND COUNT(*) <= @min_cell_count THEN -@min_cell_count
         ELSE COUNT(*) END AS n_patients,
    t.n_patients_reaching_dx_total
FROM bucketed b
CROSS JOIN totals t
GROUP BY b.timing_bucket, t.n_patients_reaching_dx_total
ORDER BY MIN(b.bucket_order)
;
