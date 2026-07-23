-- 7) L01 treatment exposure in 30-day windows around anchor dates
--    For each 30-day window k (window_start = anchor + 30*k days,
--    window_end = anchor + 30*(k+1) - 1 days), counts the number of
--    distinct patients with at least one L01 drug_exposure_start_date in
--    that window, as a fraction of the eligible denominator.
--
--    Two anchors:
--      INDEX    : all DX cohort patients; windows -12 to +48 (3 yr post-DX)
--      FIRST_MET: all patients with first_met_date; windows -6 to +24 (2 yr post-MET)
--
--    The denominator for each window is the number of patients whose
--    observation period covers the window midpoint (anchor + 30*k + 15 days).
--    This avoids deflating late windows due to censoring.
--    If observation_period data is unavailable, denominator = all anchor patients
--    (conservative; may underestimate late-window rates).
--
--    Output: one row per (anchor_event, window_index).
--    window_index: integer; window covers [anchor + 30*k, anchor + 30*(k+1) - 1].
--    Small-cell suppression on n_patients_with_l01.

WITH window_bounds AS (
    -- All (anchor, patient, window_index) combinations in scope
    SELECT
        'INDEX' AS anchor_event,
        c.person_id,
        c.index_date AS anchor_date,
        w.window_index
    FROM #cohort c
    CROSS JOIN (
        SELECT -12 AS window_index UNION ALL SELECT -11 UNION ALL SELECT -10
        UNION ALL SELECT -9  UNION ALL SELECT -8  UNION ALL SELECT -7
        UNION ALL SELECT -6  UNION ALL SELECT -5  UNION ALL SELECT -4
        UNION ALL SELECT -3  UNION ALL SELECT -2  UNION ALL SELECT -1
        UNION ALL SELECT  0  UNION ALL SELECT  1  UNION ALL SELECT  2
        UNION ALL SELECT  3  UNION ALL SELECT  4  UNION ALL SELECT  5
        UNION ALL SELECT  6  UNION ALL SELECT  7  UNION ALL SELECT  8
        UNION ALL SELECT  9  UNION ALL SELECT 10  UNION ALL SELECT 11
        UNION ALL SELECT 12  UNION ALL SELECT 13  UNION ALL SELECT 14
        UNION ALL SELECT 15  UNION ALL SELECT 16  UNION ALL SELECT 17
        UNION ALL SELECT 18  UNION ALL SELECT 19  UNION ALL SELECT 20
        UNION ALL SELECT 21  UNION ALL SELECT 22  UNION ALL SELECT 23
        UNION ALL SELECT 24  UNION ALL SELECT 25  UNION ALL SELECT 26
        UNION ALL SELECT 27  UNION ALL SELECT 28  UNION ALL SELECT 29
        UNION ALL SELECT 30  UNION ALL SELECT 31  UNION ALL SELECT 32
        UNION ALL SELECT 33  UNION ALL SELECT 34  UNION ALL SELECT 35
        UNION ALL SELECT 36  UNION ALL SELECT 37  UNION ALL SELECT 38
        UNION ALL SELECT 39  UNION ALL SELECT 40  UNION ALL SELECT 41
        UNION ALL SELECT 42  UNION ALL SELECT 43  UNION ALL SELECT 44
        UNION ALL SELECT 45  UNION ALL SELECT 46  UNION ALL SELECT 47
    ) w

    UNION ALL

    SELECT
        'FIRST_MET' AS anchor_event,
        ms.person_id,
        ms.first_met_date AS anchor_date,
        w.window_index
    FROM #met_summary ms
    CROSS JOIN (
        SELECT -6  AS window_index UNION ALL SELECT -5  UNION ALL SELECT -4
        UNION ALL SELECT -3  UNION ALL SELECT -2  UNION ALL SELECT -1
        UNION ALL SELECT  0  UNION ALL SELECT  1  UNION ALL SELECT  2
        UNION ALL SELECT  3  UNION ALL SELECT  4  UNION ALL SELECT  5
        UNION ALL SELECT  6  UNION ALL SELECT  7  UNION ALL SELECT  8
        UNION ALL SELECT  9  UNION ALL SELECT 10  UNION ALL SELECT 11
        UNION ALL SELECT 12  UNION ALL SELECT 13  UNION ALL SELECT 14
        UNION ALL SELECT 15  UNION ALL SELECT 16  UNION ALL SELECT 17
        UNION ALL SELECT 18  UNION ALL SELECT 19  UNION ALL SELECT 20
        UNION ALL SELECT 21  UNION ALL SELECT 22  UNION ALL SELECT 23
    ) w
    WHERE ms.first_met_date IS NOT NULL
),
-- Mark which patients have at least one L01 exposure in each window
window_l01 AS (
    SELECT
        wb.anchor_event,
        wb.person_id,
        wb.window_index,
        wb.anchor_date,
        MAX(
            CASE
                WHEN le.event_date >= DATEADD(DAY, 30 * wb.window_index,     wb.anchor_date)
                 AND le.event_date <  DATEADD(DAY, 30 * (wb.window_index + 1), wb.anchor_date)
                THEN 1 ELSE 0
            END
        ) AS has_l01_in_window
    FROM window_bounds wb
    LEFT JOIN #l01_events le
      ON wb.person_id = le.person_id
    GROUP BY wb.anchor_event, wb.person_id, wb.window_index, wb.anchor_date
),
-- Denominator: patients observed through the window midpoint
-- (anchor + 30*k + 15 days must be within at least one observation period)
window_denom AS (
    SELECT
        wb.anchor_event,
        wb.person_id,
        wb.window_index,
        wb.anchor_date,
        MAX(
            CASE
                WHEN op.observation_period_start_date <= DATEADD(DAY, 30 * wb.window_index + 15, wb.anchor_date)
                 AND op.observation_period_end_date   >= DATEADD(DAY, 30 * wb.window_index + 15, wb.anchor_date)
                THEN 1 ELSE 0
            END
        ) AS observed_at_midpoint
    FROM window_bounds wb
    LEFT JOIN @cdm_database_schema.observation_period op
      ON op.person_id = wb.person_id
    GROUP BY wb.anchor_event, wb.person_id, wb.window_index, wb.anchor_date
),
agg AS (
    SELECT
        wl.anchor_event,
        wl.window_index,
        COUNT(*)                    AS n_eligible,
        SUM(wd.observed_at_midpoint) AS n_observed,
        SUM(wl.has_l01_in_window)   AS n_patients_with_l01
    FROM window_l01 wl
    JOIN window_denom wd
      ON wd.anchor_event = wl.anchor_event
     AND wd.person_id    = wl.person_id
     AND wd.window_index = wl.window_index
    GROUP BY wl.anchor_event, wl.window_index
)
SELECT
    a.anchor_event,
    a.window_index,
    a.n_eligible,
    CASE WHEN a.n_observed          <= @min_cell_count THEN -@min_cell_count ELSE a.n_observed          END AS n_observed,
    CASE WHEN a.n_patients_with_l01 <= @min_cell_count THEN -@min_cell_count ELSE a.n_patients_with_l01 END AS n_patients_with_l01
FROM agg a
ORDER BY a.anchor_event, a.window_index
;
