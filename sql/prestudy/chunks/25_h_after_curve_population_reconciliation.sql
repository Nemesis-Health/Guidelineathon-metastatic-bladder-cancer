-- 25) H. Metastasis-to-treatment timing (Part 1 support) — reconciliation of the
--     two treated-patient populations Part 2 uses, and the bilateral-treatment
--     count referenced in the Part 1 caption.
--     Part 2 deliberately reads its two cumulative curves over DIFFERENT
--     denominators (AA's decision, 13 Jul 2026): the before-curve and the signed
--     histogram are CLOSEST-based, while the after-curve is over EVERY patient with
--     any antineoplastic (L01) record strictly after the first Metastasis. This
--     chunk quantifies exactly how those populations relate, so the after-curve's
--     superset construction is auditable rather than asserted. One row.
--
--     Over the treated MET patients (>= 1 L01 record), per-patient side flags are
--     built from the signed L01-to-first-MET distances:
--       has_before = any L01 record strictly before the first MET (days_diff < 0)
--       has_day0   = any L01 record on the first MET date        (days_diff = 0)
--       has_after  = any L01 record strictly after the first MET (days_diff > 0)
--     and each treated patient's CLOSEST side (BEFORE / DAY0 / AFTER) is taken from
--     the single closest record (same convention as chunk 24).
--
--     Columns (each a patient count over the treated subgroup):
--       n_treated                   before + day0 + after treated patients
--                                   (= chunk 24 before + day0 + after)
--       n_closest_after             treated patients whose CLOSEST record is after
--                                   the first MET (the histogram's after bars, and
--                                   the old closest-after after-curve population)
--       n_after_any                 treated patients with ANY strictly-after L01
--                                   record (the Part 2 after-curve denominator);
--                                   a SUPERSET of n_closest_after
--       n_after_any_added           n_after_any - n_closest_after: patients added to
--                                   the after-curve by re-basing it on any-after
--                                   rather than closest-after (their closest record
--                                   is before or on the MET day, but they also have
--                                   a real after-MET record)
--       n_bilateral                 treated patients with a record on BOTH sides
--                                   (has_before = 1 AND has_after = 1)
--       n_bilateral_closest_before  bilateral patients whose CLOSEST record is
--                                   before the MET (collapsed to the before side by
--                                   the closest-only view; these are the core of
--                                   n_after_any_added)
--       n_bilateral_closest_after   bilateral patients whose CLOSEST record is after
--                                   the MET (already inside n_closest_after)
--
--     JUDGMENT CALL / FLAG (after = strictly after, day 0 excluded). The after-curve
--     population is patients with any record with days_diff > 0. Day 0 is its own
--     explicit category and belongs to NEITHER curve, per the locked design
--     principle and the approved mock. The task prose phrased this as "on or after,"
--     but the mock (source of truth) and the day-0-explicit rule make it strictly
--     after; day-0 treatment is not counted toward the after-curve. Flagged rather
--     than silently decided.
--
--     JUDGMENT CALL / FLAG (superset arithmetic). n_after_any_added collects
--     every treated patient with an after-MET record whose closest record is NOT
--     after: closest-before-with-after (= n_bilateral_closest_before) plus the
--     residual closest-on-day-0-with-after. The mock modelled the added group as
--     40 closest-before patients only and assumed no day-0-closest patient also has
--     a later after-MET record; in real data that day-0 residual may be non-zero,
--     so n_after_any is computed directly as "any strictly-after record" and will
--     be >= the mock's 392 + 40 decomposition. n_after_any_added minus
--     n_bilateral_closest_before is that day-0 residual.
--
--     Population, observation-period and L01-source notes: same as chunk 24
--     (DX-anchored MET population from #met_events; L01 from #l01_events, gated to the
--     same #anchor_person cohort; no observation-period gate). No change to 00_setup.sql.
--
--     Small-cell suppression: each count in (0, @min_cell_count] set to
--     -@min_cell_count.

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
flags AS (
    -- Per treated patient: which sides of the first MET carry any L01 record.
    SELECT
        person_id,
        MAX(CASE WHEN days_diff < 0 THEN 1 ELSE 0 END) AS has_before,
        MAX(CASE WHEN days_diff = 0 THEN 1 ELSE 0 END) AS has_day0,
        MAX(CASE WHEN days_diff > 0 THEN 1 ELSE 0 END) AS has_after
    FROM pair
    GROUP BY person_id
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
closest_side AS (
    SELECT
        person_id,
        CASE WHEN days_diff < 0 THEN 'BEFORE'
             WHEN days_diff = 0 THEN 'DAY0'
             ELSE                    'AFTER' END AS cside
    FROM closest
    WHERE rn = 1
),
combined AS (
    SELECT
        f.person_id,
        f.has_before,
        f.has_after,
        cs.cside
    FROM flags f
    JOIN closest_side cs
      ON cs.person_id = f.person_id
),
agg AS (
    SELECT
        COUNT(*)                                                                       AS n_treated,
        SUM(CASE WHEN cside = 'AFTER' THEN 1 ELSE 0 END)                               AS n_closest_after,
        SUM(has_after)                                                                 AS n_after_any,
        SUM(CASE WHEN has_before = 1 AND has_after = 1 THEN 1 ELSE 0 END)              AS n_bilateral,
        SUM(CASE WHEN has_before = 1 AND has_after = 1 AND cside = 'BEFORE' THEN 1 ELSE 0 END) AS n_bilateral_closest_before,
        SUM(CASE WHEN has_before = 1 AND has_after = 1 AND cside = 'AFTER'  THEN 1 ELSE 0 END) AS n_bilateral_closest_after
    FROM combined
)
SELECT
    CASE WHEN n_treated                  > 0 AND n_treated                  <= @min_cell_count THEN -@min_cell_count ELSE n_treated                  END AS n_treated,
    CASE WHEN n_closest_after            > 0 AND n_closest_after            <= @min_cell_count THEN -@min_cell_count ELSE n_closest_after            END AS n_closest_after,
    CASE WHEN n_after_any                > 0 AND n_after_any                <= @min_cell_count THEN -@min_cell_count ELSE n_after_any                END AS n_after_any,
    CASE WHEN (n_after_any - n_closest_after) > 0 AND (n_after_any - n_closest_after) <= @min_cell_count THEN -@min_cell_count ELSE (n_after_any - n_closest_after) END AS n_after_any_added,
    CASE WHEN n_bilateral                > 0 AND n_bilateral                <= @min_cell_count THEN -@min_cell_count ELSE n_bilateral                END AS n_bilateral,
    CASE WHEN n_bilateral_closest_before > 0 AND n_bilateral_closest_before <= @min_cell_count THEN -@min_cell_count ELSE n_bilateral_closest_before END AS n_bilateral_closest_before,
    CASE WHEN n_bilateral_closest_after  > 0 AND n_bilateral_closest_after  <= @min_cell_count THEN -@min_cell_count ELSE n_bilateral_closest_after  END AS n_bilateral_closest_after
FROM agg
;
