-- 36) A. Per-patient RECORD-COUNT percentiles for the anchor Diagnosis and the
--     anchor Metastasis. Companion to chunk 18 (which bins the same per-patient
--     record counts into coarse buckets: DX 1 / 2-5 / 6+, MET 1 / 2+). This chunk
--     emits the true per-patient distribution as a dense percentile grid so the
--     report can draw the records-per-patient distribution with a median + IQR,
--     rather than a three/two-bar bucket chart.
--
--     One row per event_family (DX, MET). The unit is RECORDS per patient (rows in
--     the source table), the same quantity chunk 18 buckets — #dx_summary.n_dx_records
--     and #met_summary.n_met_records (00_setup.sql). Every counted patient has >= 1
--     record, so all percentile values are >= 1 and the distribution is one-sided.
--
--     Denominators (n_patients, repeated on the row):
--       DX  = cohort patients carrying the anchor Diagnosis (#dx_summary, one row per
--             cohort patient; every cohort patient has >= 1 DX record). Full cohort.
--       MET = the metastasis subset: cohort patients carrying an anchor Metastasis
--             (#met_summary, one row per cohort patient with a MET). This is the
--             DX-cohort-gated metastasis subset (n = 629 at HUS), NOT the ungated
--             all-metastasis population.
--
--     Percentile method: the framework's portable ordered-set percentile (ROW_NUMBER
--     + COUNT windows, then MIN(CASE WHEN 100.0*rn >= P*cnt ...)); identical to the
--     percentile logic in 00_setup.sql and chunk 11. No PERCENTILE_CONT, so it
--     translates cleanly to every dialect (SQLite included).
--
--     Small-cell suppression: n_patients is an aggregate denominator and is not
--     suppressed; the percentile / min / max / mean values are counts of records
--     (not patient-identifying) and are set to NULL only when the family's whole
--     denominator is <= @min_cell_count.
--     Source: #dx_summary.n_dx_records, #met_summary.n_met_records (00_setup.sql).

WITH family_counts AS (
    SELECT 'DX'  AS event_family, person_id, n_dx_records  AS n_records FROM #dx_summary
    UNION ALL
    SELECT 'MET' AS event_family, person_id, n_met_records AS n_records FROM #met_summary
),
ranked AS (
    SELECT
        event_family,
        n_records,
        ROW_NUMBER() OVER (PARTITION BY event_family ORDER BY n_records) AS rn,
        COUNT(*)     OVER (PARTITION BY event_family)                    AS cnt
    FROM family_counts
),
pct AS (
    SELECT
        event_family,
        MAX(cnt)                                                                 AS n_patients,
        MIN(CAST(n_records AS FLOAT))                                            AS min_records,
        MAX(CAST(n_records AS FLOAT))                                            AS max_records,
        AVG(CAST(n_records AS FLOAT))                                            AS mean_records,
        MIN(CASE WHEN 100.0 * rn >=  1 * cnt THEN CAST(n_records AS FLOAT) END)  AS p01_records,
        MIN(CASE WHEN 100.0 * rn >=  5 * cnt THEN CAST(n_records AS FLOAT) END)  AS p05_records,
        MIN(CASE WHEN 100.0 * rn >= 10 * cnt THEN CAST(n_records AS FLOAT) END)  AS p10_records,
        MIN(CASE WHEN 100.0 * rn >= 20 * cnt THEN CAST(n_records AS FLOAT) END)  AS p20_records,
        MIN(CASE WHEN 100.0 * rn >= 25 * cnt THEN CAST(n_records AS FLOAT) END)  AS p25_records,
        MIN(CASE WHEN 100.0 * rn >= 30 * cnt THEN CAST(n_records AS FLOAT) END)  AS p30_records,
        MIN(CASE WHEN 100.0 * rn >= 40 * cnt THEN CAST(n_records AS FLOAT) END)  AS p40_records,
        MIN(CASE WHEN 100.0 * rn >= 50 * cnt THEN CAST(n_records AS FLOAT) END)  AS p50_records,
        MIN(CASE WHEN 100.0 * rn >= 60 * cnt THEN CAST(n_records AS FLOAT) END)  AS p60_records,
        MIN(CASE WHEN 100.0 * rn >= 70 * cnt THEN CAST(n_records AS FLOAT) END)  AS p70_records,
        MIN(CASE WHEN 100.0 * rn >= 75 * cnt THEN CAST(n_records AS FLOAT) END)  AS p75_records,
        MIN(CASE WHEN 100.0 * rn >= 80 * cnt THEN CAST(n_records AS FLOAT) END)  AS p80_records,
        MIN(CASE WHEN 100.0 * rn >= 90 * cnt THEN CAST(n_records AS FLOAT) END)  AS p90_records,
        MIN(CASE WHEN 100.0 * rn >= 95 * cnt THEN CAST(n_records AS FLOAT) END)  AS p95_records,
        MIN(CASE WHEN 100.0 * rn >= 99 * cnt THEN CAST(n_records AS FLOAT) END)  AS p99_records
    FROM ranked
    GROUP BY event_family
)
SELECT
    event_family,
    n_patients,
    CASE WHEN n_patients <= @min_cell_count THEN NULL ELSE min_records  END AS min_records,
    CASE WHEN n_patients <= @min_cell_count THEN NULL ELSE max_records  END AS max_records,
    CASE WHEN n_patients <= @min_cell_count THEN NULL ELSE mean_records END AS mean_records,
    CASE WHEN n_patients <= @min_cell_count THEN NULL ELSE p01_records  END AS p01_records,
    CASE WHEN n_patients <= @min_cell_count THEN NULL ELSE p05_records  END AS p05_records,
    CASE WHEN n_patients <= @min_cell_count THEN NULL ELSE p10_records  END AS p10_records,
    CASE WHEN n_patients <= @min_cell_count THEN NULL ELSE p20_records  END AS p20_records,
    CASE WHEN n_patients <= @min_cell_count THEN NULL ELSE p25_records  END AS p25_records,
    CASE WHEN n_patients <= @min_cell_count THEN NULL ELSE p30_records  END AS p30_records,
    CASE WHEN n_patients <= @min_cell_count THEN NULL ELSE p40_records  END AS p40_records,
    CASE WHEN n_patients <= @min_cell_count THEN NULL ELSE p50_records  END AS p50_records,
    CASE WHEN n_patients <= @min_cell_count THEN NULL ELSE p60_records  END AS p60_records,
    CASE WHEN n_patients <= @min_cell_count THEN NULL ELSE p70_records  END AS p70_records,
    CASE WHEN n_patients <= @min_cell_count THEN NULL ELSE p75_records  END AS p75_records,
    CASE WHEN n_patients <= @min_cell_count THEN NULL ELSE p80_records  END AS p80_records,
    CASE WHEN n_patients <= @min_cell_count THEN NULL ELSE p90_records  END AS p90_records,
    CASE WHEN n_patients <= @min_cell_count THEN NULL ELSE p95_records  END AS p95_records,
    CASE WHEN n_patients <= @min_cell_count THEN NULL ELSE p99_records  END AS p99_records
FROM pct
ORDER BY CASE event_family WHEN 'DX' THEN 0 ELSE 1 END
;
