-- 41) F. Per-concept directional windowed counts re-anchored to the FIRST
--     METASTASIS, for the metastasis subset, covering BOTH the Broad (GDX, general /
--     non-specific cancer) and Other (ODX, other specific cancer) diagnosis concepts.
--     This is the first-MET-anchored twin of chunk 35, which produces the identical
--     per-concept before/after split but anchored on the first specific Diagnosis
--     (INDEX) and for GDX only. Sections 5-6 need the metastasis-subset view anchored
--     on the first Metastasis; the aggregate MET-anchored timing already exists, but
--     the per-concept before/after MET split did not.
--
--     One row per (event_family, concept_id). For each concept, the count of distinct
--     metastasis-subset patients holding >= 1 code of that concept in each window
--     relative to the first Metastasis date (FIRST_MET = #met_summary.first_met_date):
--
--       days = code_date - first_met_date
--
--     Columns (distinct patients holding >= 1 code of the concept in the region; the
--     three regions overlap, so before + at day 0 + after can exceed n_patients
--     because one patient may hold codes on more than one side), identical layout to
--     chunk 35:
--       n_patients        any time (the concept's overall subset patient count)
--       before side (strictly before, days < 0), cumulative outward from day 0:
--         n_before_30d   -30 <= days <= -1 ; n_before_90d, n_before_180d, n_before_365d
--         n_ever_before  days < 0 (no upper look-back bound)
--       n_at_day0         days = 0 (explicit central category)
--       after side (strictly after, days > 0), cumulative outward from day 0:
--         n_after_30d     1 <= days <= 30 ; n_after_90d, n_after_180d, n_after_365d
--         n_ever_after   days > 0 (no upper follow-up bound)
--
--     Population (metastasis subset): #met_summary (cohort patients with a MET, the
--     DX-cohort-gated subset, n = 629 at HUS; NOT the ungated all-metastasis
--     population). GDX/ODX events come from #gen_cancer_events / #other_dx_events
--     (restricted to anchor-cohort persons in 00_setup.sql) joined to #met_summary, so
--     only subset patients' codes are counted and the anchor is their first MET.
--     Code dates are not restricted to an observation period, matching chunk 35.
--
--     n_met_subset_total (repeated on each row) is the subset denominator for the
--     report's percent-of-subset figures; it is an aggregate denominator, not
--     suppressed.
--
--     Small-cell suppression: every per-concept count in (0, @min_cell_count] set to
--     -@min_cell_count.
--     Source: #gen_cancer_events, #other_dx_events, #met_summary (00_setup.sql).

WITH events AS (
    SELECT 'GDX' AS event_family, e.concept_id, e.person_id,
           DATEDIFF(DAY, ms.first_met_date, e.event_date) AS days_from_met
    FROM #gen_cancer_events e
    JOIN #met_summary ms ON e.person_id = ms.person_id AND ms.first_met_date IS NOT NULL
    UNION ALL
    SELECT 'ODX' AS event_family, e.concept_id, e.person_id,
           DATEDIFF(DAY, ms.first_met_date, e.event_date) AS days_from_met
    FROM #other_dx_events e
    JOIN #met_summary ms ON e.person_id = ms.person_id AND ms.first_met_date IS NOT NULL
),
patient_concept AS (
    -- Per (family, concept, patient): directional window flags relative to first MET.
    SELECT
        event_family,
        concept_id,
        person_id,
        MAX(CASE WHEN days_from_met >= -30  AND days_from_met <= -1 THEN 1 ELSE 0 END) AS in_before_30d,
        MAX(CASE WHEN days_from_met >= -90  AND days_from_met <= -1 THEN 1 ELSE 0 END) AS in_before_90d,
        MAX(CASE WHEN days_from_met >= -180 AND days_from_met <= -1 THEN 1 ELSE 0 END) AS in_before_180d,
        MAX(CASE WHEN days_from_met >= -365 AND days_from_met <= -1 THEN 1 ELSE 0 END) AS in_before_365d,
        MAX(CASE WHEN days_from_met <  0 THEN 1 ELSE 0 END) AS in_ever_before,
        MAX(CASE WHEN days_from_met =  0 THEN 1 ELSE 0 END) AS in_day0,
        MAX(CASE WHEN days_from_met >= 1 AND days_from_met <= 30  THEN 1 ELSE 0 END) AS in_after_30d,
        MAX(CASE WHEN days_from_met >= 1 AND days_from_met <= 90  THEN 1 ELSE 0 END) AS in_after_90d,
        MAX(CASE WHEN days_from_met >= 1 AND days_from_met <= 180 THEN 1 ELSE 0 END) AS in_after_180d,
        MAX(CASE WHEN days_from_met >= 1 AND days_from_met <= 365 THEN 1 ELSE 0 END) AS in_after_365d,
        MAX(CASE WHEN days_from_met >  0 THEN 1 ELSE 0 END) AS in_ever_after
    FROM events
    GROUP BY event_family, concept_id, person_id
),
agg AS (
    SELECT
        event_family,
        concept_id,
        COUNT(*)            AS n_patients,
        SUM(in_before_30d)  AS n_before_30d,
        SUM(in_before_90d)  AS n_before_90d,
        SUM(in_before_180d) AS n_before_180d,
        SUM(in_before_365d) AS n_before_365d,
        SUM(in_ever_before) AS n_ever_before,
        SUM(in_day0)        AS n_at_day0,
        SUM(in_after_30d)   AS n_after_30d,
        SUM(in_after_90d)   AS n_after_90d,
        SUM(in_after_180d)  AS n_after_180d,
        SUM(in_after_365d)  AS n_after_365d,
        SUM(in_ever_after)  AS n_ever_after
    FROM patient_concept
    GROUP BY event_family, concept_id
),
total AS (
    SELECT COUNT(*) AS n_met_subset_total FROM #met_summary
)
SELECT
    a.event_family,
    a.concept_id,
    CASE WHEN a.n_patients    > 0 AND a.n_patients    <= @min_cell_count THEN -@min_cell_count ELSE a.n_patients    END AS n_patients,
    CASE WHEN a.n_before_30d  > 0 AND a.n_before_30d  <= @min_cell_count THEN -@min_cell_count ELSE a.n_before_30d  END AS n_before_30d,
    CASE WHEN a.n_before_90d  > 0 AND a.n_before_90d  <= @min_cell_count THEN -@min_cell_count ELSE a.n_before_90d  END AS n_before_90d,
    CASE WHEN a.n_before_180d > 0 AND a.n_before_180d <= @min_cell_count THEN -@min_cell_count ELSE a.n_before_180d END AS n_before_180d,
    CASE WHEN a.n_before_365d > 0 AND a.n_before_365d <= @min_cell_count THEN -@min_cell_count ELSE a.n_before_365d END AS n_before_365d,
    CASE WHEN a.n_ever_before > 0 AND a.n_ever_before <= @min_cell_count THEN -@min_cell_count ELSE a.n_ever_before END AS n_ever_before,
    CASE WHEN a.n_at_day0     > 0 AND a.n_at_day0     <= @min_cell_count THEN -@min_cell_count ELSE a.n_at_day0     END AS n_at_day0,
    CASE WHEN a.n_after_30d   > 0 AND a.n_after_30d   <= @min_cell_count THEN -@min_cell_count ELSE a.n_after_30d   END AS n_after_30d,
    CASE WHEN a.n_after_90d   > 0 AND a.n_after_90d   <= @min_cell_count THEN -@min_cell_count ELSE a.n_after_90d   END AS n_after_90d,
    CASE WHEN a.n_after_180d  > 0 AND a.n_after_180d  <= @min_cell_count THEN -@min_cell_count ELSE a.n_after_180d  END AS n_after_180d,
    CASE WHEN a.n_after_365d  > 0 AND a.n_after_365d  <= @min_cell_count THEN -@min_cell_count ELSE a.n_after_365d  END AS n_after_365d,
    CASE WHEN a.n_ever_after  > 0 AND a.n_ever_after  <= @min_cell_count THEN -@min_cell_count ELSE a.n_ever_after  END AS n_ever_after,
    t.n_met_subset_total
FROM agg a
CROSS JOIN total t
ORDER BY
    a.event_family,
    a.n_patients DESC,
    a.concept_id
;
