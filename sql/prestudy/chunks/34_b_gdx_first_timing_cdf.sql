-- 34) B. General cancer diagnosis (GDX) coding trajectory — part 2, timing of the
--     FIRST general cancer diagnosis code relative to the first specific Diagnosis
--     (INDEX = #cohort.index_date), directional and CDF-style, with day 0 explicit.
--     Over the anchor-cohort patients who carry at least one general cancer
--     diagnosis code, each patient contributes one signed gap:
--
--       signed_days = first_general_code_date - first_specific_diagnosis_date
--
--     negative = the first general code precedes the first specific Diagnosis
--     (pre-diagnostic / workup coding); zero = same calendar day; positive = the
--     first general code follows the first specific Diagnosis.
--
--     Three directional masses (mutually exclusive, sum to n_with_general_code):
--       n_first_general_before   signed_days < 0
--       n_first_general_day0     signed_days = 0   (explicit central category)
--       n_first_general_after    signed_days > 0
--
--     Cumulative (CDF) reach on each side, counted outward from day 0 and
--     monotonically non-decreasing across thresholds:
--       before side (subset of n_first_general_before):
--         n_first_general_within_30d_before   -30 <= signed_days <= -1
--         _90d, _180d, _365d                  wider look-back windows
--         tail earlier than 1 year before = n_first_general_before - within_365d_before
--       after side (subset of n_first_general_after):
--         n_first_general_within_30d_after     1 <= signed_days <= 30
--         _90d, _180d, _365d                   wider follow-up windows
--         tail later than 1 year after = n_first_general_after - within_365d_after
--
--     median_signed_days_first_general: median of signed_days over all patients with
--     a general code (single value; positive means the first general code typically
--     follows the first specific Diagnosis). Framework ordered-set median convention
--     (lower-middle value for even n, as in chunks 16-17, 23, 27 and 00_setup.sql).
--     Validation reference: the approved V3 mock reports a first-general-to-first-
--     Diagnosis median of +11 days at HUS with a long pre-diagnostic (before) tail.
--
--     NOTE (direction). Before and after use their own outward-cumulative counts and
--     are never combined into a symmetric window; day 0 is its own mass, not folded
--     into the after side.
--
--     Denominator (n_with_general_code, repeated on the single row):
--       anchor-cohort patients with >= 1 general cancer diagnosis code (the union of
--       the three trajectory categories in chunk 33; validated HUS total = 618).
--
--     Population note. Uses #gen_cancer_summary.first_gen_cancer_date, the earliest
--     general-code date per cohort patient (built in 00_setup.sql over
--     #gen_cancer_events joined to #cohort). General-code dates are not restricted to
--     an observation period, matching the mock.
--
--     Small-cell suppression: each directional/cumulative count in (0, @min_cell_count]
--     set to -@min_cell_count; median set to NULL when its denominator
--     (n_with_general_code) is suppressed. n_with_general_code is an aggregate
--     denominator, not suppressed.

WITH first_general AS (
    -- Signed gap from the first specific Diagnosis to the patient's first general
    -- cancer diagnosis code, one row per cohort patient who carries a general code.
    SELECT
        gs.person_id,
        DATEDIFF(DAY, c.index_date, gs.first_gen_cancer_date) AS signed_days
    FROM #gen_cancer_summary gs
    JOIN #cohort c
      ON gs.person_id = c.person_id
    WHERE gs.first_gen_cancer_date IS NOT NULL
),
med AS (
    SELECT MIN(CASE WHEN 2.0 * rn >= cnt THEN CAST(signed_days AS FLOAT) END) AS median_days
    FROM (
        SELECT
            signed_days,
            ROW_NUMBER() OVER (ORDER BY signed_days) AS rn,
            COUNT(*)     OVER ()                     AS cnt
        FROM first_general
    ) x
),
agg AS (
    SELECT
        COUNT(*) AS n_total,
        SUM(CASE WHEN signed_days <  0 THEN 1 ELSE 0 END) AS n_before,
        SUM(CASE WHEN signed_days =  0 THEN 1 ELSE 0 END) AS n_day0,
        SUM(CASE WHEN signed_days >  0 THEN 1 ELSE 0 END) AS n_after,
        SUM(CASE WHEN signed_days >= -30  AND signed_days <= -1 THEN 1 ELSE 0 END) AS n_b30,
        SUM(CASE WHEN signed_days >= -90  AND signed_days <= -1 THEN 1 ELSE 0 END) AS n_b90,
        SUM(CASE WHEN signed_days >= -180 AND signed_days <= -1 THEN 1 ELSE 0 END) AS n_b180,
        SUM(CASE WHEN signed_days >= -365 AND signed_days <= -1 THEN 1 ELSE 0 END) AS n_b365,
        SUM(CASE WHEN signed_days >= 1   AND signed_days <= 30  THEN 1 ELSE 0 END) AS n_a30,
        SUM(CASE WHEN signed_days >= 1   AND signed_days <= 90  THEN 1 ELSE 0 END) AS n_a90,
        SUM(CASE WHEN signed_days >= 1   AND signed_days <= 180 THEN 1 ELSE 0 END) AS n_a180,
        SUM(CASE WHEN signed_days >= 1   AND signed_days <= 365 THEN 1 ELSE 0 END) AS n_a365
    FROM first_general
)
SELECT
    a.n_total AS n_with_general_code,
    CASE WHEN a.n_before > 0 AND a.n_before <= @min_cell_count THEN -@min_cell_count ELSE a.n_before END AS n_first_general_before,
    CASE WHEN a.n_b30    > 0 AND a.n_b30    <= @min_cell_count THEN -@min_cell_count ELSE a.n_b30    END AS n_first_general_within_30d_before,
    CASE WHEN a.n_b90    > 0 AND a.n_b90    <= @min_cell_count THEN -@min_cell_count ELSE a.n_b90    END AS n_first_general_within_90d_before,
    CASE WHEN a.n_b180   > 0 AND a.n_b180   <= @min_cell_count THEN -@min_cell_count ELSE a.n_b180   END AS n_first_general_within_180d_before,
    CASE WHEN a.n_b365   > 0 AND a.n_b365   <= @min_cell_count THEN -@min_cell_count ELSE a.n_b365   END AS n_first_general_within_365d_before,
    CASE WHEN a.n_day0   > 0 AND a.n_day0   <= @min_cell_count THEN -@min_cell_count ELSE a.n_day0   END AS n_first_general_day0,
    CASE WHEN a.n_after  > 0 AND a.n_after  <= @min_cell_count THEN -@min_cell_count ELSE a.n_after  END AS n_first_general_after,
    CASE WHEN a.n_a30    > 0 AND a.n_a30    <= @min_cell_count THEN -@min_cell_count ELSE a.n_a30    END AS n_first_general_within_30d_after,
    CASE WHEN a.n_a90    > 0 AND a.n_a90    <= @min_cell_count THEN -@min_cell_count ELSE a.n_a90    END AS n_first_general_within_90d_after,
    CASE WHEN a.n_a180   > 0 AND a.n_a180   <= @min_cell_count THEN -@min_cell_count ELSE a.n_a180   END AS n_first_general_within_180d_after,
    CASE WHEN a.n_a365   > 0 AND a.n_a365   <= @min_cell_count THEN -@min_cell_count ELSE a.n_a365   END AS n_first_general_within_365d_after,
    CASE WHEN a.n_total <= @min_cell_count THEN NULL ELSE m.median_days END AS median_signed_days_first_general
FROM agg a
CROSS JOIN med m
;
