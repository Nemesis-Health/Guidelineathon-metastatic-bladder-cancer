-- 28) H. Metastasis-to-treatment timing (Part 2, after-curve) — cumulative reach
--     of the FIRST after-Metastasis treatment, over EVERY patient with any
--     after-Metastasis treatment (the re-based after population, AA's decision
--     13 Jul 2026).
--     Over the patients who have ANY antineoplastic (L01) record strictly after the
--     first Metastasis (days_diff > 0), timed by that patient's FIRST such record
--     (the minimum positive days_diff), the number whose first after-MET treatment
--     has arrived WITHIN each day threshold after the first MET. Cumulative and
--     monotonically non-decreasing:
--
--       n_within_30d_after, _60d, _90d, _180d, _365d
--
--     This is the forward attribution window: for any forward window it reads the
--     share of everyone eventually treated after the MET who is captured by that
--     window. Patients whose first after-MET treatment is more than 365 days out
--     are the later-than-one-year tail, derivable as
--     n_after_any_total - n_within_365d_after.
--
--     median_days_after_first: median first-after-MET days among the same patients,
--     framework ordered-set median convention (lower-middle for even n, as in
--     chunks 16-17, 23, 27 and 00_setup.sql).
--
--     Denominator (n_after_any_total):
--       patients with any strictly-after L01 record (= chunk 25 n_after_any). This
--       is a SUPERSET of the closest-after patients (chunk 25 n_closest_after and
--       the histogram after bars, chunk 26): it adds patients whose closest record
--       is before or on the MET day but who also have a genuine after-MET record.
--       Consequently this curve is NOT the cumulative of the histogram's after bars,
--       by design.
--
--     JUDGMENT CALL / FLAG (population definition, differs from before-curve and
--     histogram). Unlike the CLOSEST-based before-curve (chunk 27) and histogram
--     (chunk 26), this after-curve is over the ANY-strictly-after population and is
--     timed by each patient's FIRST after-MET record, not their closest record.
--       - Day 0 is excluded (strictly after, days_diff > 0), consistent with the
--         locked day-0-explicit principle; day-0 treatment is on neither curve. The
--         task prose said "on or after," reconciled here to strictly after per the
--         mock (source of truth) and the day-0 rule.
--       - A patient with treatment ONLY before the MET and none strictly after
--         correctly falls OUT of this curve (no positive days_diff, so absent from
--         the WHERE days_diff > 0 set).
--       - A closest-before patient who ALSO has an after-MET record is INCLUDED
--         here (via their after record) while remaining on the before side of the
--         histogram and before-curve; this is the intended superset behaviour.
--
--     Population, observation-period and L01-source notes: same as chunk 24
--     (DX-anchored MET population from #met_events; L01 from #l01_events, gated to the
--     same #anchor_person cohort; no observation-period gate). No change to 00_setup.sql.
--
--     Small-cell suppression: each cumulative count in (0, @min_cell_count] set to
--     -@min_cell_count; median set to NULL when its denominator is suppressed.
--     n_after_any_total is an aggregate denominator, not suppressed.

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
        DATEDIFF(DAY, ma.first_met_date, la.event_date) AS days_diff
    FROM met_all ma
    JOIN l01_all la
      ON la.person_id = ma.person_id
),
after_first AS (
    -- One row per patient with any strictly-after record: their first after-MET day.
    SELECT
        person_id,
        MIN(days_diff) AS first_after_days
    FROM pair
    WHERE days_diff > 0
    GROUP BY person_id
),
med AS (
    SELECT MIN(CASE WHEN 2.0 * rn >= cnt THEN CAST(first_after_days AS FLOAT) END) AS median_days
    FROM (
        SELECT
            first_after_days,
            ROW_NUMBER() OVER (ORDER BY first_after_days) AS rn,
            COUNT(*)     OVER ()                          AS cnt
        FROM after_first
    ) x
),
agg AS (
    SELECT
        COUNT(*)                                                AS n_total,
        SUM(CASE WHEN first_after_days <= 30  THEN 1 ELSE 0 END) AS n_30,
        SUM(CASE WHEN first_after_days <= 60  THEN 1 ELSE 0 END) AS n_60,
        SUM(CASE WHEN first_after_days <= 90  THEN 1 ELSE 0 END) AS n_90,
        SUM(CASE WHEN first_after_days <= 180 THEN 1 ELSE 0 END) AS n_180,
        SUM(CASE WHEN first_after_days <= 365 THEN 1 ELSE 0 END) AS n_365
    FROM after_first
)
SELECT
    a.n_total AS n_after_any_total,
    CASE WHEN a.n_30  > 0 AND a.n_30  <= @min_cell_count THEN -@min_cell_count ELSE a.n_30  END AS n_within_30d_after,
    CASE WHEN a.n_60  > 0 AND a.n_60  <= @min_cell_count THEN -@min_cell_count ELSE a.n_60  END AS n_within_60d_after,
    CASE WHEN a.n_90  > 0 AND a.n_90  <= @min_cell_count THEN -@min_cell_count ELSE a.n_90  END AS n_within_90d_after,
    CASE WHEN a.n_180 > 0 AND a.n_180 <= @min_cell_count THEN -@min_cell_count ELSE a.n_180 END AS n_within_180d_after,
    CASE WHEN a.n_365 > 0 AND a.n_365 <= @min_cell_count THEN -@min_cell_count ELSE a.n_365 END AS n_within_365d_after,
    CASE WHEN a.n_total <= @min_cell_count THEN NULL ELSE m.median_days END AS median_days_after_first
FROM agg a
CROSS JOIN med m
;
