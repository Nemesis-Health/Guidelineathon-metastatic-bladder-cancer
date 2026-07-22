-- 27) H. Metastasis-to-treatment timing (Part 2, before-curve) — cumulative reach
--     of the CLOSEST-before treatment, over the closest-before patients.
--     Over the patients whose CLOSEST antineoplastic (L01) record is strictly
--     before the first Metastasis (chunk 24 CLOSEST_L01_BEFORE_MET), the number
--     whose closest-before record sits WITHIN each day threshold before the first
--     MET. Cumulative and monotonically non-decreasing across thresholds. Reads
--     "how far back the nearest before-MET treatment sits":
--
--       n_within_30d_before, _60d, _90d, _180d, _365d
--
--     days_before = ABS(days_diff) of the closest record (all values >= 1 by
--     construction; day 0 is a separate central category, not on this curve). The
--     curve is CLOSEST-based, so it agrees with the histogram's before bars
--     (chunk 26, bin_order 1-6). Patients whose closest-before treatment is more
--     than 365 days before the MET are the earlier-than-one-year tail, derivable as
--     n_before_total - n_within_365d_before.
--
--     median_days_before_closest: median days_before among the same patients, using
--     the framework's ordered-set median convention (lower-middle value for even n,
--     as in chunks 16-17, 23 and 00_setup.sql).
--
--     Denominator (n_before_total):
--       closest-before patients (= chunk 24 CLOSEST_L01_BEFORE_MET n_patients).
--
--     NOTE (direction). This is the BEFORE curve. It reads leftward (backward in
--     time) from the first MET and uses its own directional denominator; it is
--     never combined with the after-curve into a symmetric window.
--
--     Population, observation-period and L01-source notes: same as chunk 24
--     (DX-anchored MET population from #met_events; L01 from #l01_events, gated to the
--     same #anchor_person cohort; no observation-period gate). No change to 00_setup.sql.
--
--     Small-cell suppression: each cumulative count in (0, @min_cell_count] set to
--     -@min_cell_count; median set to NULL when its denominator is suppressed.
--     n_before_total is an aggregate denominator, not suppressed.

WITH met_all AS (
    SELECT
        person_id,
        MIN(event_date) AS first_met_date
    FROM #met_events
    GROUP BY person_id
),
l01_all AS (
    SELECT
        person_id,
        event_date
    FROM #l01_events
),
pair AS (
    SELECT
        ma.person_id,
        DATEDIFF(DAY, ma.first_met_date, la.event_date) AS days_diff,
        la.event_date
    FROM met_all ma
    JOIN l01_all la
      ON la.person_id = ma.person_id
),
closest AS (
    SELECT
        person_id,
        days_diff,
        ROW_NUMBER() OVER (
            PARTITION BY person_id
            ORDER BY ABS(days_diff), event_date
        ) AS rn
    FROM pair
),
before_closest AS (
    -- Closest record is strictly before the first MET.
    SELECT
        person_id,
        ABS(days_diff) AS days_before
    FROM closest
    WHERE rn = 1
      AND days_diff < 0
),
med AS (
    SELECT MIN(CASE WHEN 2.0 * rn >= cnt THEN CAST(days_before AS FLOAT) END) AS median_days
    FROM (
        SELECT
            days_before,
            ROW_NUMBER() OVER (ORDER BY days_before) AS rn,
            COUNT(*)     OVER ()                     AS cnt
        FROM before_closest
    ) x
),
agg AS (
    SELECT
        COUNT(*)                                           AS n_total,
        SUM(CASE WHEN days_before <= 30  THEN 1 ELSE 0 END) AS n_30,
        SUM(CASE WHEN days_before <= 60  THEN 1 ELSE 0 END) AS n_60,
        SUM(CASE WHEN days_before <= 90  THEN 1 ELSE 0 END) AS n_90,
        SUM(CASE WHEN days_before <= 180 THEN 1 ELSE 0 END) AS n_180,
        SUM(CASE WHEN days_before <= 365 THEN 1 ELSE 0 END) AS n_365
    FROM before_closest
)
SELECT
    a.n_total AS n_before_total,
    CASE WHEN a.n_30  > 0 AND a.n_30  <= @min_cell_count THEN -@min_cell_count ELSE a.n_30  END AS n_within_30d_before,
    CASE WHEN a.n_60  > 0 AND a.n_60  <= @min_cell_count THEN -@min_cell_count ELSE a.n_60  END AS n_within_60d_before,
    CASE WHEN a.n_90  > 0 AND a.n_90  <= @min_cell_count THEN -@min_cell_count ELSE a.n_90  END AS n_within_90d_before,
    CASE WHEN a.n_180 > 0 AND a.n_180 <= @min_cell_count THEN -@min_cell_count ELSE a.n_180 END AS n_within_180d_before,
    CASE WHEN a.n_365 > 0 AND a.n_365 <= @min_cell_count THEN -@min_cell_count ELSE a.n_365 END AS n_within_365d_before,
    CASE WHEN a.n_total <= @min_cell_count THEN NULL ELSE m.median_days END AS median_days_before_closest
FROM agg a
CROSS JOIN med m
;
