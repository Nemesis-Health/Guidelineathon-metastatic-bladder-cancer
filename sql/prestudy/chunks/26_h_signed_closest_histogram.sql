-- 26) H. Metastasis-to-treatment timing (Part 2, histogram) — the signed
--     distribution of each treated patient's CLOSEST antineoplastic treatment
--     relative to the first Metastasis.
--     Over the treated MET patients (>= 1 L01 record), each patient is reduced to
--     the single signed days_diff of their CLOSEST L01 record (same value and
--     convention as chunk 24) and placed in one signed-day bin. Before and after
--     are separate; day 0 is its own central bin. bin_order runs left to right
--     along the signed axis (farthest before -> day 0 -> farthest after) so the
--     report renders the bars directly.
--
--       bin_order  side    day_range_label   contents (signed days_diff)
--          1       BEFORE   366+              days_diff <= -366
--          2       BEFORE   181-365           -365 .. -181
--          3       BEFORE   91-180            -180 .. -91
--          4       BEFORE   61-90             -90 .. -61
--          5       BEFORE   31-60             -60 .. -31
--          6       BEFORE   1-30              -30 .. -1
--          7       DAY0     Day 0             days_diff = 0
--          8       AFTER    1-30              1 .. 30
--          9       AFTER    31-60             31 .. 60
--         10       AFTER    61-90             61 .. 90
--         11       AFTER    91-180            91 .. 180
--         12       AFTER    181-365           181 .. 365
--         13       AFTER    366+              days_diff >= 366
--
--     The 366+ terminal bins carry everything beyond one year on each side. The bin
--     share (n_patients / n_treated_total) is what the report plots.
--
--     NOTE (relationship to the after-curve, chunk 28). This histogram is entirely
--     CLOSEST-based: the after bins (order 8-13) sum to the closest-after patients
--     (chunk 25 n_closest_after), NOT to the after-curve population (n_after_any).
--     The after-curve is intentionally over a broader population and is therefore
--     NOT the cumulative of these after bars. The before bins (order 1-6) sum to the
--     closest-before patients and DO agree with the before-curve (chunk 27).
--
--     Denominator (n_treated_total, repeated on each row):
--       treated MET patients = before + day0 + after (= chunk 24 sum of the three
--       treated categories; = chunk 25 n_treated).
--
--     Population, observation-period and L01-source notes: same as chunk 24
--     (DX-anchored MET population from #met_events; L01 from #l01_events, gated to the
--     same #anchor_person cohort; no observation-period gate). No change to 00_setup.sql.
--
--     Small-cell suppression: n_patients in (0, @min_cell_count] set to
--     -@min_cell_count. n_treated_total is an aggregate denominator, not
--     suppressed. A bin with zero patients is absent (as in chunks 18-25).

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
c1 AS (
    SELECT person_id, days_diff FROM closest WHERE rn = 1
),
binned AS (
    SELECT
        person_id,
        CASE
            WHEN days_diff = 0                          THEN 7
            WHEN days_diff <= -366                       THEN 1
            WHEN days_diff <= -181                       THEN 2
            WHEN days_diff <= -91                        THEN 3
            WHEN days_diff <= -61                        THEN 4
            WHEN days_diff <= -31                        THEN 5
            WHEN days_diff <= -1                         THEN 6
            WHEN days_diff <= 30                         THEN 8
            WHEN days_diff <= 60                         THEN 9
            WHEN days_diff <= 90                         THEN 10
            WHEN days_diff <= 180                        THEN 11
            WHEN days_diff <= 365                        THEN 12
            ELSE                                             13
        END AS bin_order
    FROM c1
),
labelled AS (
    SELECT
        person_id,
        bin_order,
        CASE WHEN bin_order <= 6 THEN 'BEFORE'
             WHEN bin_order = 7  THEN 'DAY0'
             ELSE                     'AFTER' END AS side,
        CASE bin_order
            WHEN 1  THEN '366+'
            WHEN 2  THEN '181-365'
            WHEN 3  THEN '91-180'
            WHEN 4  THEN '61-90'
            WHEN 5  THEN '31-60'
            WHEN 6  THEN '1-30'
            WHEN 7  THEN 'Day 0'
            WHEN 8  THEN '1-30'
            WHEN 9  THEN '31-60'
            WHEN 10 THEN '61-90'
            WHEN 11 THEN '91-180'
            WHEN 12 THEN '181-365'
            ELSE         '366+'
        END AS day_range_label
    FROM binned
),
totals AS (
    SELECT COUNT(*) AS n_treated_total FROM c1
)
SELECT
    b.bin_order,
    b.side,
    b.day_range_label,
    CASE WHEN COUNT(*) > 0 AND COUNT(*) <= @min_cell_count THEN -@min_cell_count
         ELSE COUNT(*) END AS n_patients,
    t.n_treated_total
FROM labelled b
CROSS JOIN totals t
GROUP BY b.bin_order, b.side, b.day_range_label, t.n_treated_total
ORDER BY b.bin_order
;
