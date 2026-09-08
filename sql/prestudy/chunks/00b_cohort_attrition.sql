-- 0b) Cohort attrition: patients with any qualifying DX vs those with a DX
--     that falls within an observation period (the study-eligible subset).
--     The difference is the number excluded by the obs-period filter.
--     Small-cell suppression: n_dx_any/n_dx_in_obs/n_excluded_no_obs_dx in
--     (0, @min_cell_count] set to -@min_cell_count, independently.
-- alias "agg" (not "raw"): RAW is a reserved word in Redshift and breaks as a
-- bare alias (same fix as sql/eligibility_input_coverage.sql's "rlr" alias).
SELECT
    CASE WHEN agg.n_dx_any > 0 AND agg.n_dx_any <= @min_cell_count
         THEN -@min_cell_count ELSE agg.n_dx_any END AS n_dx_any,
    CASE WHEN agg.n_dx_in_obs > 0 AND agg.n_dx_in_obs <= @min_cell_count
         THEN -@min_cell_count ELSE agg.n_dx_in_obs END AS n_dx_in_obs,
    CASE WHEN agg.n_excluded_no_obs_dx > 0 AND agg.n_excluded_no_obs_dx <= @min_cell_count
         THEN -@min_cell_count ELSE agg.n_excluded_no_obs_dx END AS n_excluded_no_obs_dx
FROM (
    SELECT
        SUM(CASE WHEN stage = 'dx_any'    THEN n_patients ELSE 0 END) AS n_dx_any,
        SUM(CASE WHEN stage = 'dx_in_obs' THEN n_patients ELSE 0 END) AS n_dx_in_obs,
        SUM(CASE WHEN stage = 'dx_any'    THEN n_patients ELSE 0 END)
        - SUM(CASE WHEN stage = 'dx_in_obs' THEN n_patients ELSE 0 END)  AS n_excluded_no_obs_dx
    FROM #cohort_attrition
) agg
;
