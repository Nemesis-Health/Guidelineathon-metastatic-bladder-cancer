-- 11) L01 consecutive record gap distribution — decile summary
--     Intermediate tables #l01_event_days and #l01_consecutive_gaps are
--     built in 00_setup.sql (section L).
--
--     Two subgroups:
--       ALL_L01 : all DX cohort patients with any L01 record
--       MET_L01 : patients who also have a first_met_date
--
--     Output: one row per subgroup with gap-day deciles.

--     Small-cell suppression: n_gaps <= @min_cell_count suppresses percentiles to NULL
--     and replaces counts with -@min_cell_count.

SELECT
    subgroup,
    CASE WHEN COUNT(*) > 0 AND COUNT(*) <= @min_cell_count THEN -@min_cell_count ELSE COUNT(*) END AS n_gaps,
    CASE WHEN COUNT(*) > 0 AND COUNT(*) <= @min_cell_count THEN -@min_cell_count ELSE COUNT(DISTINCT person_id) END AS n_patients_with_gaps,
    MIN(CASE WHEN cnt > @min_cell_count AND 10.0 * rn >= cnt      THEN CAST(gap_days AS FLOAT) END) AS p10_days,
    MIN(CASE WHEN cnt > @min_cell_count AND  4.0 * rn >= cnt      THEN CAST(gap_days AS FLOAT) END) AS p25_days,
    MIN(CASE WHEN cnt > @min_cell_count AND  2.0 * rn >= cnt      THEN CAST(gap_days AS FLOAT) END) AS p50_days,
    MIN(CASE WHEN cnt > @min_cell_count AND  4.0 * rn >= 3 * cnt  THEN CAST(gap_days AS FLOAT) END) AS p75_days,
    MIN(CASE WHEN cnt > @min_cell_count AND 10.0 * rn >= 9 * cnt  THEN CAST(gap_days AS FLOAT) END) AS p90_days
FROM (
    SELECT subgroup, person_id, gap_days,
        ROW_NUMBER() OVER (PARTITION BY subgroup ORDER BY gap_days) AS rn,
        COUNT(*)     OVER (PARTITION BY subgroup)                   AS cnt
    FROM #l01_consecutive_gaps
) x
GROUP BY subgroup
ORDER BY subgroup
;
