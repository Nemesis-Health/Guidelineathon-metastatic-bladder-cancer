-- 42) E. Densified pairwise-timing percentile grid. Same pairwise timing as chunk 04
--     (all four timing types across all event-family pairs), but emitted on a denser
--     percentile grid (21 points: p01, then every 5th percentile p05-p95, then p99) so
--     the report can fit a smooth monotone-spline density curve over well-supported
--     support points, per decision 5. Chunk 04 (13 percentiles p05-p95) is left intact
--     for backward compatibility; this chunk is additive.
--
--     No raw per-patient rows leave the site: only percentile values are emitted,
--     exactly as chunk 04 does. Reads the per-patient pair tables built in
--     00_setup.sql (section J): #patient_timing_pairs (first_to_first),
--     #patient_timing_pairs_first_to_closest, ..._before, ..._after. One row per
--     (timing_type, from_event, to_event).
--
--     Percentile method: portable ordered-set percentile (ROW_NUMBER + COUNT windows,
--     MIN(CASE WHEN 100.0*rn >= P*cnt ...)), the uniform integer form of the same
--     method chunk 04 / 00_setup.sql use. No PERCENTILE_CONT, so it translates cleanly
--     to every dialect (SQLite included).
--
--     Small-cell suppression matches chunk 04: n_patients_with_pair <= @min_cell_count
--     is emitted as -@min_cell_count and every percentile on that row set to NULL.
--
--     NOTE (scope). Decision 5 densifies the pairwise timing figures (the aggregate
--     smooth-density curves in Sections 4-7). Per-concept timing (chunk 02) is NOT
--     densified here: decision 14 defers per-concept density curves, so chunk 02 keeps
--     its LQ/median/UQ triple. If per-concept density is revisited, densify chunk 02's
--     #event_code_timing_summary the same way.

WITH pairs AS (
    SELECT 'first_to_first'          AS timing_type, from_event, to_event, days_diff FROM #patient_timing_pairs
    UNION ALL
    SELECT 'first_to_closest'        AS timing_type, from_event, to_event, days_diff FROM #patient_timing_pairs_first_to_closest
    UNION ALL
    SELECT 'first_to_closest_before' AS timing_type, from_event, to_event, days_diff FROM #patient_timing_pairs_first_to_closest_before
    UNION ALL
    SELECT 'first_to_closest_after'  AS timing_type, from_event, to_event, days_diff FROM #patient_timing_pairs_first_to_closest_after
),
ranked AS (
    SELECT
        timing_type, from_event, to_event, days_diff,
        ROW_NUMBER() OVER (PARTITION BY timing_type, from_event, to_event ORDER BY days_diff) AS rn,
        COUNT(*)     OVER (PARTITION BY timing_type, from_event, to_event)                    AS cnt
    FROM pairs
),
pct AS (
    SELECT
        timing_type, from_event, to_event,
        MAX(cnt) AS n_patients_with_pair,
        MIN(CASE WHEN 100.0 * rn >=  1 * cnt THEN CAST(days_diff AS FLOAT) END) AS p01_days,
        MIN(CASE WHEN 100.0 * rn >=  5 * cnt THEN CAST(days_diff AS FLOAT) END) AS p05_days,
        MIN(CASE WHEN 100.0 * rn >= 10 * cnt THEN CAST(days_diff AS FLOAT) END) AS p10_days,
        MIN(CASE WHEN 100.0 * rn >= 15 * cnt THEN CAST(days_diff AS FLOAT) END) AS p15_days,
        MIN(CASE WHEN 100.0 * rn >= 20 * cnt THEN CAST(days_diff AS FLOAT) END) AS p20_days,
        MIN(CASE WHEN 100.0 * rn >= 25 * cnt THEN CAST(days_diff AS FLOAT) END) AS p25_days,
        MIN(CASE WHEN 100.0 * rn >= 30 * cnt THEN CAST(days_diff AS FLOAT) END) AS p30_days,
        MIN(CASE WHEN 100.0 * rn >= 35 * cnt THEN CAST(days_diff AS FLOAT) END) AS p35_days,
        MIN(CASE WHEN 100.0 * rn >= 40 * cnt THEN CAST(days_diff AS FLOAT) END) AS p40_days,
        MIN(CASE WHEN 100.0 * rn >= 45 * cnt THEN CAST(days_diff AS FLOAT) END) AS p45_days,
        MIN(CASE WHEN 100.0 * rn >= 50 * cnt THEN CAST(days_diff AS FLOAT) END) AS p50_days,
        MIN(CASE WHEN 100.0 * rn >= 55 * cnt THEN CAST(days_diff AS FLOAT) END) AS p55_days,
        MIN(CASE WHEN 100.0 * rn >= 60 * cnt THEN CAST(days_diff AS FLOAT) END) AS p60_days,
        MIN(CASE WHEN 100.0 * rn >= 65 * cnt THEN CAST(days_diff AS FLOAT) END) AS p65_days,
        MIN(CASE WHEN 100.0 * rn >= 70 * cnt THEN CAST(days_diff AS FLOAT) END) AS p70_days,
        MIN(CASE WHEN 100.0 * rn >= 75 * cnt THEN CAST(days_diff AS FLOAT) END) AS p75_days,
        MIN(CASE WHEN 100.0 * rn >= 80 * cnt THEN CAST(days_diff AS FLOAT) END) AS p80_days,
        MIN(CASE WHEN 100.0 * rn >= 85 * cnt THEN CAST(days_diff AS FLOAT) END) AS p85_days,
        MIN(CASE WHEN 100.0 * rn >= 90 * cnt THEN CAST(days_diff AS FLOAT) END) AS p90_days,
        MIN(CASE WHEN 100.0 * rn >= 95 * cnt THEN CAST(days_diff AS FLOAT) END) AS p95_days,
        MIN(CASE WHEN 100.0 * rn >= 99 * cnt THEN CAST(days_diff AS FLOAT) END) AS p99_days
    FROM ranked
    GROUP BY timing_type, from_event, to_event
)
SELECT
    timing_type,
    from_event,
    to_event,
    CASE WHEN n_patients_with_pair <= @min_cell_count THEN -@min_cell_count ELSE n_patients_with_pair END AS n_patients_with_pair,
    CASE WHEN n_patients_with_pair <= @min_cell_count THEN NULL ELSE p01_days END AS p01_days,
    CASE WHEN n_patients_with_pair <= @min_cell_count THEN NULL ELSE p05_days END AS p05_days,
    CASE WHEN n_patients_with_pair <= @min_cell_count THEN NULL ELSE p10_days END AS p10_days,
    CASE WHEN n_patients_with_pair <= @min_cell_count THEN NULL ELSE p15_days END AS p15_days,
    CASE WHEN n_patients_with_pair <= @min_cell_count THEN NULL ELSE p20_days END AS p20_days,
    CASE WHEN n_patients_with_pair <= @min_cell_count THEN NULL ELSE p25_days END AS p25_days,
    CASE WHEN n_patients_with_pair <= @min_cell_count THEN NULL ELSE p30_days END AS p30_days,
    CASE WHEN n_patients_with_pair <= @min_cell_count THEN NULL ELSE p35_days END AS p35_days,
    CASE WHEN n_patients_with_pair <= @min_cell_count THEN NULL ELSE p40_days END AS p40_days,
    CASE WHEN n_patients_with_pair <= @min_cell_count THEN NULL ELSE p45_days END AS p45_days,
    CASE WHEN n_patients_with_pair <= @min_cell_count THEN NULL ELSE p50_days END AS p50_days,
    CASE WHEN n_patients_with_pair <= @min_cell_count THEN NULL ELSE p55_days END AS p55_days,
    CASE WHEN n_patients_with_pair <= @min_cell_count THEN NULL ELSE p60_days END AS p60_days,
    CASE WHEN n_patients_with_pair <= @min_cell_count THEN NULL ELSE p65_days END AS p65_days,
    CASE WHEN n_patients_with_pair <= @min_cell_count THEN NULL ELSE p70_days END AS p70_days,
    CASE WHEN n_patients_with_pair <= @min_cell_count THEN NULL ELSE p75_days END AS p75_days,
    CASE WHEN n_patients_with_pair <= @min_cell_count THEN NULL ELSE p80_days END AS p80_days,
    CASE WHEN n_patients_with_pair <= @min_cell_count THEN NULL ELSE p85_days END AS p85_days,
    CASE WHEN n_patients_with_pair <= @min_cell_count THEN NULL ELSE p90_days END AS p90_days,
    CASE WHEN n_patients_with_pair <= @min_cell_count THEN NULL ELSE p95_days END AS p95_days,
    CASE WHEN n_patients_with_pair <= @min_cell_count THEN NULL ELSE p99_days END AS p99_days
FROM pct
ORDER BY timing_type, from_event, to_event
;
