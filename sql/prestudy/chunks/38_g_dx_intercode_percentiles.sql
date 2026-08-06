-- 38) G. Diagnosis first-to-second record gap, as a dense percentile grid, for the
--     full diagnosis cohort AND the metastasis subset. Companion to chunk 19, which
--     holds the same first-to-second Diagnosis gap only as coarse timeframe buckets
--     (DX_1_TO_2: <=30d / 31-90 / 91-365 / >365). This chunk emits the percentile
--     grid so the report can draw a smooth one-sided density curve in the same style
--     as the other timing figures.
--
--     JUDGMENT CALL (identical to chunk 19). The gap is measured between DISTINCT
--     Diagnosis DAYS, not raw records: same-day duplicate DX records are collapsed
--     first (SELECT DISTINCT person_id, event_date). Every gap is therefore >= 1 day;
--     the distribution is one-sided and starts at the origin (first Diagnosis).
--
--     Strata (cohort_stratum):
--       FULL        = the full diagnosis cohort (#cohort, n = 8,134 at HUS)
--       MET_SUBSET  = the metastasis subset: cohort patients carrying an anchor
--                     Metastasis (#met_summary, the DX-cohort-gated subset,
--                     n = 629 at HUS; NOT the ungated all-metastasis population)
--     A patient contributes a gap to a stratum only if they have >= 2 distinct
--     Diagnosis days AND belong to that stratum. MET_SUBSET is a subset of FULL, so a
--     metastasis-subset patient contributes to both strata (this is intentional: the
--     two curves are the full-cohort and metastasis-subset views of the same gap).
--
--     Denominators (repeated on each stratum row):
--       n_cohort_stratum     = patients in the stratum (all of #cohort / #met_summary)
--       n_patients_with_gap  = stratum patients with >= 2 distinct Diagnosis days
--
--     Percentile method: portable ordered-set percentile (ROW_NUMBER + COUNT windows,
--     MIN(CASE WHEN 100.0*rn >= P*cnt ...)), identical to 00_setup.sql / chunk 11.
--
--     Small-cell suppression: n_patients_with_gap in (0, @min_cell_count] set to
--     -@min_cell_count; percentile / min / max / mean set to NULL when
--     n_patients_with_gap <= @min_cell_count. n_cohort_stratum is an aggregate
--     denominator, not suppressed.
--     Source: #dx_events, #cohort, #met_summary (00_setup.sql).

WITH dx_days AS (
    -- Distinct Diagnosis days per cohort patient (same-day duplicates collapsed).
    SELECT DISTINCT e.person_id, e.event_date AS event_day
    FROM #dx_events e
    JOIN #cohort c ON e.person_id = c.person_id
),
ranked_days AS (
    SELECT
        person_id,
        event_day,
        ROW_NUMBER() OVER (PARTITION BY person_id ORDER BY event_day)    AS day_rank,
        LEAD(event_day) OVER (PARTITION BY person_id ORDER BY event_day) AS next_day
    FROM dx_days
),
gaps AS (
    -- First-to-second transition only (day_rank = 1), one gap per patient.
    SELECT person_id, DATEDIFF(DAY, event_day, next_day) AS gap_days
    FROM ranked_days
    WHERE day_rank = 1
      AND next_day IS NOT NULL
),
gaps_by_stratum AS (
    SELECT 'FULL' AS cohort_stratum, g.gap_days
    FROM gaps g
    UNION ALL
    SELECT 'MET_SUBSET' AS cohort_stratum, g.gap_days
    FROM gaps g
    JOIN #met_summary ms ON g.person_id = ms.person_id
),
stratum_totals AS (
    SELECT 'FULL'       AS cohort_stratum, COUNT(*) AS n_cohort_stratum FROM #cohort
    UNION ALL
    SELECT 'MET_SUBSET' AS cohort_stratum, COUNT(*) AS n_cohort_stratum FROM #met_summary
),
ranked AS (
    SELECT
        cohort_stratum,
        gap_days,
        ROW_NUMBER() OVER (PARTITION BY cohort_stratum ORDER BY gap_days) AS rn,
        COUNT(*)     OVER (PARTITION BY cohort_stratum)                   AS cnt
    FROM gaps_by_stratum
),
pct AS (
    SELECT
        cohort_stratum,
        MAX(cnt)                                                              AS n_patients_with_gap,
        MIN(CAST(gap_days AS FLOAT))                                          AS min_days,
        MAX(CAST(gap_days AS FLOAT))                                          AS max_days,
        AVG(CAST(gap_days AS FLOAT))                                          AS mean_days,
        MIN(CASE WHEN 100.0 * rn >=  1 * cnt THEN CAST(gap_days AS FLOAT) END) AS p01_days,
        MIN(CASE WHEN 100.0 * rn >=  5 * cnt THEN CAST(gap_days AS FLOAT) END) AS p05_days,
        MIN(CASE WHEN 100.0 * rn >= 10 * cnt THEN CAST(gap_days AS FLOAT) END) AS p10_days,
        MIN(CASE WHEN 100.0 * rn >= 20 * cnt THEN CAST(gap_days AS FLOAT) END) AS p20_days,
        MIN(CASE WHEN 100.0 * rn >= 25 * cnt THEN CAST(gap_days AS FLOAT) END) AS p25_days,
        MIN(CASE WHEN 100.0 * rn >= 30 * cnt THEN CAST(gap_days AS FLOAT) END) AS p30_days,
        MIN(CASE WHEN 100.0 * rn >= 40 * cnt THEN CAST(gap_days AS FLOAT) END) AS p40_days,
        MIN(CASE WHEN 100.0 * rn >= 50 * cnt THEN CAST(gap_days AS FLOAT) END) AS p50_days,
        MIN(CASE WHEN 100.0 * rn >= 60 * cnt THEN CAST(gap_days AS FLOAT) END) AS p60_days,
        MIN(CASE WHEN 100.0 * rn >= 70 * cnt THEN CAST(gap_days AS FLOAT) END) AS p70_days,
        MIN(CASE WHEN 100.0 * rn >= 75 * cnt THEN CAST(gap_days AS FLOAT) END) AS p75_days,
        MIN(CASE WHEN 100.0 * rn >= 80 * cnt THEN CAST(gap_days AS FLOAT) END) AS p80_days,
        MIN(CASE WHEN 100.0 * rn >= 90 * cnt THEN CAST(gap_days AS FLOAT) END) AS p90_days,
        MIN(CASE WHEN 100.0 * rn >= 95 * cnt THEN CAST(gap_days AS FLOAT) END) AS p95_days,
        MIN(CASE WHEN 100.0 * rn >= 99 * cnt THEN CAST(gap_days AS FLOAT) END) AS p99_days
    FROM ranked
    GROUP BY cohort_stratum
)
SELECT
    st.cohort_stratum,
    'DX_1_TO_2' AS transition,
    st.n_cohort_stratum,
    CASE WHEN p.n_patients_with_gap > 0 AND p.n_patients_with_gap <= @min_cell_count
         THEN -@min_cell_count ELSE COALESCE(p.n_patients_with_gap, 0) END AS n_patients_with_gap,
    CASE WHEN p.n_patients_with_gap <= @min_cell_count THEN NULL ELSE p.min_days  END AS min_days,
    CASE WHEN p.n_patients_with_gap <= @min_cell_count THEN NULL ELSE p.max_days  END AS max_days,
    CASE WHEN p.n_patients_with_gap <= @min_cell_count THEN NULL ELSE p.mean_days END AS mean_days,
    CASE WHEN p.n_patients_with_gap <= @min_cell_count THEN NULL ELSE p.p01_days  END AS p01_days,
    CASE WHEN p.n_patients_with_gap <= @min_cell_count THEN NULL ELSE p.p05_days  END AS p05_days,
    CASE WHEN p.n_patients_with_gap <= @min_cell_count THEN NULL ELSE p.p10_days  END AS p10_days,
    CASE WHEN p.n_patients_with_gap <= @min_cell_count THEN NULL ELSE p.p20_days  END AS p20_days,
    CASE WHEN p.n_patients_with_gap <= @min_cell_count THEN NULL ELSE p.p25_days  END AS p25_days,
    CASE WHEN p.n_patients_with_gap <= @min_cell_count THEN NULL ELSE p.p30_days  END AS p30_days,
    CASE WHEN p.n_patients_with_gap <= @min_cell_count THEN NULL ELSE p.p40_days  END AS p40_days,
    CASE WHEN p.n_patients_with_gap <= @min_cell_count THEN NULL ELSE p.p50_days  END AS p50_days,
    CASE WHEN p.n_patients_with_gap <= @min_cell_count THEN NULL ELSE p.p60_days  END AS p60_days,
    CASE WHEN p.n_patients_with_gap <= @min_cell_count THEN NULL ELSE p.p70_days  END AS p70_days,
    CASE WHEN p.n_patients_with_gap <= @min_cell_count THEN NULL ELSE p.p75_days  END AS p75_days,
    CASE WHEN p.n_patients_with_gap <= @min_cell_count THEN NULL ELSE p.p80_days  END AS p80_days,
    CASE WHEN p.n_patients_with_gap <= @min_cell_count THEN NULL ELSE p.p90_days  END AS p90_days,
    CASE WHEN p.n_patients_with_gap <= @min_cell_count THEN NULL ELSE p.p95_days  END AS p95_days,
    CASE WHEN p.n_patients_with_gap <= @min_cell_count THEN NULL ELSE p.p99_days  END AS p99_days
FROM stratum_totals st
LEFT JOIN pct p ON p.cohort_stratum = st.cohort_stratum
ORDER BY CASE st.cohort_stratum WHEN 'FULL' THEN 0 ELSE 1 END
;
