-- 37) C. Metastasis first-to-second record gap, as a dense percentile grid.
--     NEW output (no prior version existed). Time between a patient's first and
--     second Metastasis DAY, for the metastasis subset, emitted as percentiles so
--     the report can draw a smooth one-sided density curve (in the same style as the
--     other timing figures) instead of gap-bucket bars.
--
--     JUDGMENT CALL (mirrors chunk 19). The gap is measured between DISTINCT
--     Metastasis DAYS, not raw records: same-day duplicate MET records are collapsed
--     first (SELECT DISTINCT person_id, event_date), the same methodology chunk 19
--     uses for Diagnosis inter-code timing and 00_setup.sql uses for L01 gaps.
--     Counting raw records would drive almost every first-to-second gap to 0 days
--     (same-day administrative duplicates) and hide the coding timescale.
--     Consequently every gap is >= 1 day: the distribution is one-sided and starts
--     at the origin (first MET), extending positive, exactly as decision 10 specifies.
--
--     Population (metastasis subset): cohort patients carrying an anchor Metastasis,
--     i.e. #met_summary (built in 00_setup.sql as #met_events joined to #cohort). This
--     is the DX-cohort-gated metastasis subset (n = 629 at HUS), NOT the ungated
--     all-metastasis population. Restricting #met_events to #met_summary persons keeps
--     the denominator on the 629 subset. Only patients with >= 2 distinct MET days
--     contribute a gap.
--
--     Denominators (repeated on the single row):
--       n_met_subset          = the metastasis subset size (all of #met_summary)
--       n_patients_with_gap   = subset patients with >= 2 distinct MET days (the
--                               percentile denominator)
--
--     Percentile method: portable ordered-set percentile (ROW_NUMBER + COUNT windows,
--     MIN(CASE WHEN 100.0*rn >= P*cnt ...)), identical to 00_setup.sql / chunk 11.
--
--     Small-cell suppression: n_patients_with_gap in (0, @min_cell_count] set to
--     -@min_cell_count; percentile / min / max / mean values set to NULL when
--     n_patients_with_gap <= @min_cell_count. n_met_subset is an aggregate
--     denominator, not suppressed.
--     Source: #met_events, #met_summary (00_setup.sql).

WITH met_days AS (
    -- Distinct Metastasis days per subset patient (same-day duplicates collapsed).
    SELECT DISTINCT e.person_id, e.event_date AS event_day
    FROM #met_events e
    JOIN #met_summary ms ON e.person_id = ms.person_id
),
ranked_days AS (
    SELECT
        person_id,
        event_day,
        ROW_NUMBER() OVER (PARTITION BY person_id ORDER BY event_day)    AS day_rank,
        LEAD(event_day) OVER (PARTITION BY person_id ORDER BY event_day) AS next_day
    FROM met_days
),
gaps AS (
    -- First-to-second transition only (day_rank = 1), one gap per patient.
    SELECT DATEDIFF(DAY, event_day, next_day) AS gap_days
    FROM ranked_days
    WHERE day_rank = 1
      AND next_day IS NOT NULL
),
subset_total AS (
    SELECT COUNT(*) AS n_met_subset FROM #met_summary
),
ranked AS (
    SELECT
        gap_days,
        ROW_NUMBER() OVER (ORDER BY gap_days) AS rn,
        COUNT(*)     OVER ()                  AS cnt
    FROM gaps
),
pct AS (
    SELECT
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
)
SELECT
    'MET_1_TO_2' AS transition,
    st.n_met_subset,
    CASE WHEN p.n_patients_with_gap > 0 AND p.n_patients_with_gap <= @min_cell_count
         THEN -@min_cell_count ELSE p.n_patients_with_gap END AS n_patients_with_gap,
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
FROM pct p
CROSS JOIN subset_total st
;
