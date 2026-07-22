-- 23) D. MET-first subgroup, part 3b. The same MET-to-first-specific-DX gap as
--     chunk 22, expressed cumulatively (CDF) so a linking cutoff can be read off
--     directly, plus the median gap.
--     For the MET_FIRST_THEN_DX group of chunk 20, the number of patients whose
--     first specific DX has ARRIVED BY each day threshold after the first MET.
--     Cumulative and monotonically non-decreasing across thresholds:
--
--       n_arrived_by_30d, _45d, _60d, _90d, _180d, _365d
--
--     Thresholds 30/45/60/90 are the candidate cutoffs; 180/365 give the longer
--     shape. All time is AFTER the first MET by construction, so there is no before
--     side and no day-0 mass. Patients whose specific DX arrives after 365 days are
--     the >1-year tail, derivable as n_patients_reaching_dx_total - n_arrived_by_365d.
--
--     median_days_met_to_dx: median gap (days) among the same patients, using the
--     framework's ordered-set median convention (lower-middle value for even n, as
--     in chunks 16-17 and 00_setup.sql).
--
--     Denominator (n_patients_reaching_dx_total):
--       MET-first patients who reach a specific DX (same as chunk 22). Under the
--       corrected DX-anchored population every MET-first patient reaches a specific
--       DX, so this equals the full MET-first subgroup.
--
--     Population and observation-period notes: same as chunk 20 (DX-anchored MET
--     population from #met_events, first specific DX from #dx_events, anchored on
--     #anchor_person, no observation-period gate).
--
--     Small-cell suppression: each cumulative count in (0, @min_cell_count] set to
--     -@min_cell_count; median set to NULL when its denominator is suppressed.
--     n_patients_reaching_dx_total is an aggregate denominator, not suppressed.

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
    SELECT
        ma.person_id,
        DATEDIFF(DAY, ma.first_met_date, dx.first_dx_date) AS gap_days
    FROM met_all ma
    JOIN dx_all dx
      ON dx.person_id = ma.person_id
    WHERE ma.first_met_date < dx.first_dx_date
),
med AS (
    SELECT MIN(CASE WHEN 2.0 * rn >= cnt THEN CAST(gap_days AS FLOAT) END) AS median_days
    FROM (
        SELECT
            gap_days,
            ROW_NUMBER() OVER (ORDER BY gap_days) AS rn,
            COUNT(*)     OVER ()                  AS cnt
        FROM gap
    ) x
),
agg AS (
    SELECT
        COUNT(*)                                          AS n_total,
        SUM(CASE WHEN gap_days <= 30  THEN 1 ELSE 0 END)  AS n_by_30,
        SUM(CASE WHEN gap_days <= 45  THEN 1 ELSE 0 END)  AS n_by_45,
        SUM(CASE WHEN gap_days <= 60  THEN 1 ELSE 0 END)  AS n_by_60,
        SUM(CASE WHEN gap_days <= 90  THEN 1 ELSE 0 END)  AS n_by_90,
        SUM(CASE WHEN gap_days <= 180 THEN 1 ELSE 0 END)  AS n_by_180,
        SUM(CASE WHEN gap_days <= 365 THEN 1 ELSE 0 END)  AS n_by_365
    FROM gap
)
SELECT
    a.n_total AS n_patients_reaching_dx_total,
    CASE WHEN a.n_by_30  > 0 AND a.n_by_30  <= @min_cell_count THEN -@min_cell_count ELSE a.n_by_30  END AS n_arrived_by_30d,
    CASE WHEN a.n_by_45  > 0 AND a.n_by_45  <= @min_cell_count THEN -@min_cell_count ELSE a.n_by_45  END AS n_arrived_by_45d,
    CASE WHEN a.n_by_60  > 0 AND a.n_by_60  <= @min_cell_count THEN -@min_cell_count ELSE a.n_by_60  END AS n_arrived_by_60d,
    CASE WHEN a.n_by_90  > 0 AND a.n_by_90  <= @min_cell_count THEN -@min_cell_count ELSE a.n_by_90  END AS n_arrived_by_90d,
    CASE WHEN a.n_by_180 > 0 AND a.n_by_180 <= @min_cell_count THEN -@min_cell_count ELSE a.n_by_180 END AS n_arrived_by_180d,
    CASE WHEN a.n_by_365 > 0 AND a.n_by_365 <= @min_cell_count THEN -@min_cell_count ELSE a.n_by_365 END AS n_arrived_by_365d,
    CASE WHEN a.n_total <= @min_cell_count THEN NULL ELSE m.median_days END AS median_days_met_to_dx
FROM agg a
CROSS JOIN med m
;
