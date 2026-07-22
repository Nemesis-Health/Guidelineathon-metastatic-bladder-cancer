-- 3) Temporal directionality buckets
--    Exact patient counts by direction category for key event pairs:
--      DX -> MET  (using index_date -> first_met_date from #patient_char)
--      DX -> L01  (using index_date -> first_l01_date from #patient_char)
--      MET -> L01 (using first_met_date -> first_l01_date from #patient_char)
--
--    Categories (days = TO_date - FROM_date):
--      BEFORE_GT90  : TO event > 90 days before FROM  (days < -90)
--      BEFORE_1_90  : TO event 1-90 days before FROM  (-90 <= days < 0)
--      SAME_DAY     : same calendar day                (days = 0)
--      AFTER_1_30   : 1-30 days after                  (1 <= days <= 30)
--      AFTER_31_90  : 31-90 days after                 (31 <= days <= 90)
--      AFTER_91_365 : 91-365 days after                (91 <= days <= 365)
--      AFTER_GT365  : > 365 days after                 (days > 365)
--      NO_EVENT     : FROM event present but TO event absent
--
--    Stratified by OVERALL and by anchor year:
--      DX_MET / DX_L01 use YEAR(index_date); MET_L01 uses YEAR(first_met_date).
--    Small-cell suppression: n suppressed to -@min_cell_count when <= @min_cell_count.

WITH dx_met_base AS (
    SELECT
        YEAR(index_date) AS index_year_int,
        CASE
            WHEN first_met_date IS NULL  THEN 'NO_EVENT'
            WHEN days_dx_to_met < -90    THEN 'BEFORE_GT90'
            WHEN days_dx_to_met < 0      THEN 'BEFORE_1_90'
            WHEN days_dx_to_met = 0      THEN 'SAME_DAY'
            WHEN days_dx_to_met <= 30    THEN 'AFTER_1_30'
            WHEN days_dx_to_met <= 90    THEN 'AFTER_31_90'
            WHEN days_dx_to_met <= 365   THEN 'AFTER_91_365'
            ELSE 'AFTER_GT365'
        END AS direction
    FROM #patient_char
),
dx_l01_base AS (
    SELECT
        YEAR(index_date) AS index_year_int,
        CASE
            WHEN first_l01_date IS NULL  THEN 'NO_EVENT'
            WHEN days_dx_to_l01 < -90    THEN 'BEFORE_GT90'
            WHEN days_dx_to_l01 < 0      THEN 'BEFORE_1_90'
            WHEN days_dx_to_l01 = 0      THEN 'SAME_DAY'
            WHEN days_dx_to_l01 <= 30    THEN 'AFTER_1_30'
            WHEN days_dx_to_l01 <= 90    THEN 'AFTER_31_90'
            WHEN days_dx_to_l01 <= 365   THEN 'AFTER_91_365'
            ELSE 'AFTER_GT365'
        END AS direction
    FROM #patient_char
),
met_l01_base AS (
    SELECT
        YEAR(first_met_date) AS index_year_int,
        CASE
            WHEN first_l01_date IS NULL  THEN 'NO_EVENT'
            WHEN days_met_to_l01 < -90   THEN 'BEFORE_GT90'
            WHEN days_met_to_l01 < 0     THEN 'BEFORE_1_90'
            WHEN days_met_to_l01 = 0     THEN 'SAME_DAY'
            WHEN days_met_to_l01 <= 30   THEN 'AFTER_1_30'
            WHEN days_met_to_l01 <= 90   THEN 'AFTER_31_90'
            WHEN days_met_to_l01 <= 365  THEN 'AFTER_91_365'
            ELSE 'AFTER_GT365'
        END AS direction
    FROM #patient_char
    WHERE first_met_date IS NOT NULL
)
SELECT
    x.pair,
    x.index_year,
    x.direction,
    CASE WHEN x.n_patients <= @min_cell_count THEN -@min_cell_count ELSE x.n_patients END AS n_patients
FROM (
    -- DX -> MET: OVERALL
    SELECT 'DX_MET' AS pair, 'OVERALL' AS index_year, direction, COUNT(*) AS n_patients
    FROM dx_met_base
    GROUP BY direction

    UNION ALL

    -- DX -> MET: by DX year
    SELECT 'DX_MET' AS pair, CAST(index_year_int AS VARCHAR(4)) AS index_year, direction, COUNT(*) AS n_patients
    FROM dx_met_base
    GROUP BY index_year_int, direction

    UNION ALL

    -- DX -> L01: OVERALL
    SELECT 'DX_L01' AS pair, 'OVERALL' AS index_year, direction, COUNT(*) AS n_patients
    FROM dx_l01_base
    GROUP BY direction

    UNION ALL

    -- DX -> L01: by DX year
    SELECT 'DX_L01' AS pair, CAST(index_year_int AS VARCHAR(4)) AS index_year, direction, COUNT(*) AS n_patients
    FROM dx_l01_base
    GROUP BY index_year_int, direction

    UNION ALL

    -- MET -> L01: OVERALL
    SELECT 'MET_L01' AS pair, 'OVERALL' AS index_year, direction, COUNT(*) AS n_patients
    FROM met_l01_base
    GROUP BY direction

    UNION ALL

    -- MET -> L01: by MET year
    SELECT 'MET_L01' AS pair, CAST(index_year_int AS VARCHAR(4)) AS index_year, direction, COUNT(*) AS n_patients
    FROM met_l01_base
    GROUP BY index_year_int, direction
) x
ORDER BY
    x.pair,
    CASE WHEN x.index_year = 'OVERALL' THEN 0 ELSE 1 END,
    CASE WHEN x.index_year = 'OVERALL' THEN NULL ELSE CAST(x.index_year AS INT) END,
    CASE x.direction
        WHEN 'BEFORE_GT90'  THEN 1
        WHEN 'BEFORE_1_90'  THEN 2
        WHEN 'SAME_DAY'     THEN 3
        WHEN 'AFTER_1_30'   THEN 4
        WHEN 'AFTER_31_90'  THEN 5
        WHEN 'AFTER_91_365' THEN 6
        WHEN 'AFTER_GT365'  THEN 7
        WHEN 'NO_EVENT'     THEN 8
        ELSE 9
    END
;
