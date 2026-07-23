-- 5) Pairwise timing summary stratified by anchor year
--    Same structure as chunk 04 (final_timing_pairwise.csv) but grouped by year.
--    Year is anchored on the from_event: DX-anchored pairs use YEAR(index_date),
--    MET-anchored pairs use YEAR(first_met_date).
--    Used for year-over-year plots and for the per-year columns in the §06 stability matrix.
--    Small-cell suppression applied.

SELECT
    x.timing_type,
    x.index_year,
    x.from_event,
    x.to_event,
    CASE WHEN x.n_patients_with_pair <= @min_cell_count THEN -@min_cell_count ELSE x.n_patients_with_pair END AS n_patients_with_pair,
    CASE WHEN x.n_patients_with_pair <= @min_cell_count THEN NULL ELSE x.p25_days  END AS p25_days,
    CASE WHEN x.n_patients_with_pair <= @min_cell_count THEN NULL ELSE x.p50_days  END AS p50_days,
    CASE WHEN x.n_patients_with_pair <= @min_cell_count THEN NULL ELSE x.p75_days  END AS p75_days
FROM (
    -- first_to_first by anchor year
    SELECT
        'first_to_first' AS timing_type,
        CAST(index_year_int AS VARCHAR(4)) AS index_year,
        from_event,
        to_event,
        COUNT(*) AS n_patients_with_pair,
        MIN(CASE WHEN 4.0 * rn >= cnt THEN CAST(days_diff AS FLOAT) END) AS p25_days,
        MIN(CASE WHEN 2.0 * rn >= cnt THEN CAST(days_diff AS FLOAT) END) AS p50_days,
        MIN(CASE WHEN 4.0 * rn >= 3 * cnt THEN CAST(days_diff AS FLOAT) END) AS p75_days
    FROM (
        SELECT p.from_event, p.to_event, p.days_diff,
            CASE WHEN p.from_event = 'MET' THEN YEAR(ms.first_met_date) ELSE YEAR(pc.index_date) END AS index_year_int,
            ROW_NUMBER() OVER (PARTITION BY CASE WHEN p.from_event = 'MET' THEN YEAR(ms.first_met_date) ELSE YEAR(pc.index_date) END, p.from_event, p.to_event ORDER BY p.days_diff) AS rn,
            COUNT(*)     OVER (PARTITION BY CASE WHEN p.from_event = 'MET' THEN YEAR(ms.first_met_date) ELSE YEAR(pc.index_date) END, p.from_event, p.to_event)                    AS cnt
        FROM #patient_timing_pairs p
        JOIN #patient_char pc    ON p.person_id = pc.person_id
        LEFT JOIN #met_summary ms ON p.person_id = ms.person_id
    ) y
    GROUP BY index_year_int, from_event, to_event

    UNION ALL

    -- first_to_closest_after by anchor year (MET-anchored pairs use MET year)
    SELECT
        'first_to_closest_after' AS timing_type,
        CAST(index_year_int AS VARCHAR(4)) AS index_year,
        from_event,
        to_event,
        COUNT(*) AS n_patients_with_pair,
        MIN(CASE WHEN 4.0 * rn >= cnt THEN CAST(days_diff AS FLOAT) END) AS p25_days,
        MIN(CASE WHEN 2.0 * rn >= cnt THEN CAST(days_diff AS FLOAT) END) AS p50_days,
        MIN(CASE WHEN 4.0 * rn >= 3 * cnt THEN CAST(days_diff AS FLOAT) END) AS p75_days
    FROM (
        SELECT p.from_event, p.to_event, p.days_diff,
            CASE WHEN p.from_event = 'MET' THEN YEAR(ms.first_met_date) ELSE YEAR(pc.index_date) END AS index_year_int,
            ROW_NUMBER() OVER (PARTITION BY CASE WHEN p.from_event = 'MET' THEN YEAR(ms.first_met_date) ELSE YEAR(pc.index_date) END, p.from_event, p.to_event ORDER BY p.days_diff) AS rn,
            COUNT(*)     OVER (PARTITION BY CASE WHEN p.from_event = 'MET' THEN YEAR(ms.first_met_date) ELSE YEAR(pc.index_date) END, p.from_event, p.to_event)                    AS cnt
        FROM #patient_timing_pairs_first_to_closest_after p
        JOIN #patient_char pc    ON p.person_id = pc.person_id
        LEFT JOIN #met_summary ms ON p.person_id = ms.person_id
    ) y
    GROUP BY index_year_int, from_event, to_event
) x
ORDER BY
    x.timing_type,
    x.from_event,
    x.to_event,
    CAST(x.index_year AS INT)
;
