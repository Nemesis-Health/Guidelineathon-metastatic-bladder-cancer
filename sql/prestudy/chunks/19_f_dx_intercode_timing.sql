-- 19) F. Index event record counts (part 2) — on what timescale the code repeats
--     For patients with more than one Diagnosis code, the time between
--     consecutive Diagnosis codes, for the first two transitions only:
--       DX_1_TO_2 : first Diagnosis day  -> second Diagnosis day
--       DX_2_TO_3 : second Diagnosis day -> third  Diagnosis day
--     bucketed by timeframe: within 30 days / 31 to 90 / 91 to 365 / more than a year.
--
--     JUDGMENT CALL (flag for review): "consecutive codes" is measured between
--     DISTINCT Diagnosis DAYS, not raw records. Same-day duplicate records are
--     collapsed first (SELECT DISTINCT person_id, event_date), mirroring the L01
--     gap methodology (#l01_event_days in 00_setup.sql). Counting raw records
--     instead would make almost every first-to-second gap 0 days (same-day
--     administrative duplicates) and hide the coding timescale. Consequently
--     every gap is >= 1 day and the "within 30 days" bucket is 1-30 days.
--     Part 1 (chunk 18) counts records; this part measures timing between days.
--
--     Denominators (n_transitions_total, per transition = patients, since each
--     patient contributes at most one gap per transition):
--       DX_1_TO_2 = patients with >= 2 distinct Diagnosis days
--       DX_2_TO_3 = patients with >= 3 distinct Diagnosis days
--     Source: #dx_events restricted to #cohort (00_setup.sql).
--     Small-cell suppression: n_transitions in (0, @min_cell_count] set to
--     -@min_cell_count. n_transitions_total is an aggregate denominator, not suppressed.

WITH dx_days AS (
    SELECT DISTINCT e.person_id, e.event_date AS event_day
    FROM #dx_events e
    JOIN #cohort c ON e.person_id = c.person_id
),
ranked AS (
    SELECT
        person_id,
        event_day,
        ROW_NUMBER() OVER (PARTITION BY person_id ORDER BY event_day)      AS day_rank,
        LEAD(event_day) OVER (PARTITION BY person_id ORDER BY event_day)   AS next_day
    FROM dx_days
),
transitions AS (
    SELECT
        CASE day_rank WHEN 1 THEN 'DX_1_TO_2' WHEN 2 THEN 'DX_2_TO_3' END AS transition,
        DATEDIFF(DAY, event_day, next_day) AS gap_days
    FROM ranked
    WHERE day_rank IN (1, 2)
      AND next_day IS NOT NULL
),
bucketed AS (
    SELECT
        transition,
        CASE
            WHEN gap_days <= 30  THEN 'lte30d'
            WHEN gap_days <= 90  THEN '31_90d'
            WHEN gap_days <= 365 THEN '91_365d'
            ELSE 'gt365d'
        END AS gap_bucket,
        CASE
            WHEN gap_days <= 30  THEN 1
            WHEN gap_days <= 90  THEN 2
            WHEN gap_days <= 365 THEN 3
            ELSE 4
        END AS bucket_order
    FROM transitions
),
totals AS (
    SELECT transition, COUNT(*) AS n_transitions_total
    FROM bucketed
    GROUP BY transition
)
SELECT
    b.transition,
    b.gap_bucket,
    CASE WHEN COUNT(*) > 0 AND COUNT(*) <= @min_cell_count THEN -@min_cell_count ELSE COUNT(*) END AS n_transitions,
    t.n_transitions_total
FROM bucketed b
JOIN totals t ON t.transition = b.transition
GROUP BY b.transition, b.gap_bucket, t.n_transitions_total
ORDER BY b.transition, MIN(b.bucket_order)
;
