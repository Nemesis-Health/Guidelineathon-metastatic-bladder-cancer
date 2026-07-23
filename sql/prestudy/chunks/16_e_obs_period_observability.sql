-- 16) E. Observation-period characterization — observability around the index
--     How much observable time each patient has BEFORE the index (look-back) and
--     AFTER the index (follow-up), reported as cumulative day-threshold counts:
--     the number of patients with fewer than 30 / 90 / 180 / 365 days of
--     observation on each side of the index. Look-back and follow-up are kept
--     strictly separate (one row per side); day 0 sits on the follow-up side
--     (follow-up = days from the index to the observation-period end, >= 0).
--
--     Observable time is measured inside the single observation period that
--     CONTAINS the anchor date, so both sides are contiguous observable time:
--       look-back_days = index_date - observation_period_start_date
--       follow-up_days = observation_period_end_date - index_date
--     A patient contributes only if the anchor date falls within one of their
--     observation periods. For INDEX this holds for every cohort patient by
--     construction (see #cohort in 00_setup.sql); for FIRST_MET it holds only
--     for patients whose first metastasis date is inside an observation period.
--
--     Two anchors: INDEX (first qualifying DX = cohort index date) and FIRST_MET
--     (first metastasis date). Source: #cohort, #met_summary (00_setup.sql) and
--     @cdm_database_schema.observation_period.
--     Small-cell suppression: threshold counts in (0, @min_cell_count] are set to
--     -@min_cell_count; median set to NULL when the group denominator is suppressed.
--     n_patients is an aggregate cohort denominator and is not suppressed, matching
--     the existing death/prevalence chunks.

WITH obs_around_anchor AS (
    -- INDEX anchor: index_date is guaranteed to fall inside an observation period.
    SELECT
        'INDEX' AS anchor_event,
        c.person_id,
        DATEDIFF(DAY, op.observation_period_start_date, c.index_date) AS lookback_days,
        DATEDIFF(DAY, c.index_date, op.observation_period_end_date)   AS followup_days
    FROM #cohort c
    INNER JOIN @cdm_database_schema.observation_period op
        ON  op.person_id = c.person_id
        AND c.index_date BETWEEN op.observation_period_start_date
                             AND op.observation_period_end_date
    UNION ALL
    -- FIRST_MET anchor: only patients whose first metastasis date is inside a period.
    SELECT
        'FIRST_MET' AS anchor_event,
        c.person_id,
        DATEDIFF(DAY, op.observation_period_start_date, ms.first_met_date) AS lookback_days,
        DATEDIFF(DAY, ms.first_met_date, op.observation_period_end_date)   AS followup_days
    FROM #cohort c
    INNER JOIN #met_summary ms
        ON ms.person_id = c.person_id AND ms.first_met_date IS NOT NULL
    INNER JOIN @cdm_database_schema.observation_period op
        ON  op.person_id = c.person_id
        AND ms.first_met_date BETWEEN op.observation_period_start_date
                                  AND op.observation_period_end_date
),
obs_sided AS (
    SELECT anchor_event, person_id, 'LOOKBACK_BEFORE_ANCHOR' AS observation_side, lookback_days AS obs_days
    FROM obs_around_anchor
    UNION ALL
    SELECT anchor_event, person_id, 'FOLLOWUP_AFTER_ANCHOR'  AS observation_side, followup_days AS obs_days
    FROM obs_around_anchor
),
ranked AS (
    SELECT
        anchor_event,
        observation_side,
        obs_days,
        ROW_NUMBER() OVER (PARTITION BY anchor_event, observation_side ORDER BY obs_days) AS rn,
        COUNT(*)     OVER (PARTITION BY anchor_event, observation_side)                    AS cnt
    FROM obs_sided
),
agg AS (
    SELECT
        anchor_event,
        observation_side,
        COUNT(*) AS n_patients,
        SUM(CASE WHEN obs_days < 30  THEN 1 ELSE 0 END) AS n_lt_30d,
        SUM(CASE WHEN obs_days < 90  THEN 1 ELSE 0 END) AS n_lt_90d,
        SUM(CASE WHEN obs_days < 180 THEN 1 ELSE 0 END) AS n_lt_180d,
        SUM(CASE WHEN obs_days < 365 THEN 1 ELSE 0 END) AS n_lt_365d,
        MIN(CASE WHEN 2.0 * rn >= cnt THEN CAST(obs_days AS FLOAT) END) AS median_days
    FROM ranked
    GROUP BY anchor_event, observation_side
)
SELECT
    anchor_event,
    observation_side,
    n_patients,
    CASE WHEN n_lt_30d  > 0 AND n_lt_30d  <= @min_cell_count THEN -@min_cell_count ELSE n_lt_30d  END AS n_lt_30d,
    CASE WHEN n_lt_90d  > 0 AND n_lt_90d  <= @min_cell_count THEN -@min_cell_count ELSE n_lt_90d  END AS n_lt_90d,
    CASE WHEN n_lt_180d > 0 AND n_lt_180d <= @min_cell_count THEN -@min_cell_count ELSE n_lt_180d END AS n_lt_180d,
    CASE WHEN n_lt_365d > 0 AND n_lt_365d <= @min_cell_count THEN -@min_cell_count ELSE n_lt_365d END AS n_lt_365d,
    CASE WHEN n_patients <= @min_cell_count THEN NULL ELSE median_days END AS median_days
FROM agg
ORDER BY
    CASE anchor_event WHEN 'INDEX' THEN 0 ELSE 1 END,
    CASE observation_side WHEN 'LOOKBACK_BEFORE_ANCHOR' THEN 0 ELSE 1 END
;
