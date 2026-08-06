-- 39) B. Spread (IQR + dense percentile grid) of the number of days the observation
--     period continues PAST the recorded death date, for decedents still under
--     observation after death. Companion to chunk 17, whose
--     MEDIAN_DAYS_PERIOD_ENDS_PAST_DEATH metric already reports the median of this
--     same quantity (305d full cohort / 373d metastasis subset at HUS). This chunk
--     adds the distribution the median summarizes, so the report can show IQR and a
--     spread, not a lone median.
--
--     Quantity: days_past_death = (last observation_period_end_date) - (death_date),
--     among decedents whose last observation period ends strictly AFTER their death
--     date (period runs past death). Same population and same definition as chunk 17's
--     DECEDENTS_PERIOD_ENDS_AFTER_DEATH / MEDIAN_DAYS_PERIOD_ENDS_PAST_DEATH metrics;
--     the p50_days emitted here reconciles to chunk 17's median by construction (both
--     use the framework lower-middle ordered-set convention: 100.0*rn >= 50*cnt).
--
--     Anchors:
--       INDEX     = full DX cohort decedents with death on/after the index date
--       FIRST_MET = metastasis-subset decedents with death on/after the first MET
--                   date. The metastasis subset is #cohort joined to #met_summary
--                   (the DX-cohort-gated subset, n = 629 at HUS; NOT the ungated
--                   all-metastasis population).
--     Only decedents whose period ends after death (days_past_death IS NOT NULL) are
--     ranked, matching chunk 17's decedent_days_ranked (ranking the full decedent set
--     would let the NULL "period does not run past death" rows consume the lowest row
--     numbers and bias the ordered-set percentiles low).
--
--     Percentile method: portable ordered-set percentile (ROW_NUMBER + COUNT windows,
--     MIN(CASE WHEN 100.0*rn >= P*cnt ...)), identical to 00_setup.sql / chunk 17.
--
--     Small-cell suppression: n_decedents_period_past_death in (0, @min_cell_count]
--     set to -@min_cell_count; percentile / min / max / mean set to NULL when that
--     count <= @min_cell_count.
--     Source: #cohort, #met_summary, #death_obs_status (00_setup.sql),
--     @cdm_database_schema.observation_period.

WITH patient_obs AS (
    SELECT
        person_id,
        MAX(observation_period_end_date) AS last_obs_end
    FROM @cdm_database_schema.observation_period
    WHERE person_id IN (SELECT person_id FROM #cohort)
    GROUP BY person_id
),
decedent_anchor AS (
    -- INDEX anchor: full cohort decedents; days the period runs past death.
    SELECT
        'INDEX' AS anchor_event,
        CASE WHEN po.last_obs_end > dos.death_date
             THEN DATEDIFF(DAY, dos.death_date, po.last_obs_end) END AS days_past_death
    FROM #cohort c
    INNER JOIN #death_obs_status dos ON dos.person_id = c.person_id
    LEFT JOIN patient_obs po ON po.person_id = c.person_id
    WHERE dos.death_date >= c.index_date
    UNION ALL
    -- FIRST_MET anchor: metastasis-subset decedents (cohort joined to #met_summary).
    SELECT
        'FIRST_MET' AS anchor_event,
        CASE WHEN po.last_obs_end > dos.death_date
             THEN DATEDIFF(DAY, dos.death_date, po.last_obs_end) END
    FROM #cohort c
    INNER JOIN #met_summary ms ON ms.person_id = c.person_id AND ms.first_met_date IS NOT NULL
    INNER JOIN #death_obs_status dos ON dos.person_id = c.person_id
    LEFT JOIN patient_obs po ON po.person_id = c.person_id
    WHERE dos.death_date >= ms.first_met_date
),
ranked AS (
    -- Rank ONLY decedents whose period runs past death (days_past_death populated),
    -- matching chunk 17's decedent_days_ranked.
    SELECT
        anchor_event,
        days_past_death,
        ROW_NUMBER() OVER (PARTITION BY anchor_event ORDER BY days_past_death) AS rn,
        COUNT(*)     OVER (PARTITION BY anchor_event)                          AS cnt
    FROM decedent_anchor
    WHERE days_past_death IS NOT NULL
),
pct AS (
    SELECT
        anchor_event,
        MAX(cnt)                                                                    AS n_decedents_period_past_death,
        MIN(CAST(days_past_death AS FLOAT))                                         AS min_days,
        MAX(CAST(days_past_death AS FLOAT))                                         AS max_days,
        AVG(CAST(days_past_death AS FLOAT))                                         AS mean_days,
        MIN(CASE WHEN 100.0 * rn >=  1 * cnt THEN CAST(days_past_death AS FLOAT) END) AS p01_days,
        MIN(CASE WHEN 100.0 * rn >=  5 * cnt THEN CAST(days_past_death AS FLOAT) END) AS p05_days,
        MIN(CASE WHEN 100.0 * rn >= 10 * cnt THEN CAST(days_past_death AS FLOAT) END) AS p10_days,
        MIN(CASE WHEN 100.0 * rn >= 20 * cnt THEN CAST(days_past_death AS FLOAT) END) AS p20_days,
        MIN(CASE WHEN 100.0 * rn >= 25 * cnt THEN CAST(days_past_death AS FLOAT) END) AS p25_days,
        MIN(CASE WHEN 100.0 * rn >= 30 * cnt THEN CAST(days_past_death AS FLOAT) END) AS p30_days,
        MIN(CASE WHEN 100.0 * rn >= 40 * cnt THEN CAST(days_past_death AS FLOAT) END) AS p40_days,
        MIN(CASE WHEN 100.0 * rn >= 50 * cnt THEN CAST(days_past_death AS FLOAT) END) AS p50_days,
        MIN(CASE WHEN 100.0 * rn >= 60 * cnt THEN CAST(days_past_death AS FLOAT) END) AS p60_days,
        MIN(CASE WHEN 100.0 * rn >= 70 * cnt THEN CAST(days_past_death AS FLOAT) END) AS p70_days,
        MIN(CASE WHEN 100.0 * rn >= 75 * cnt THEN CAST(days_past_death AS FLOAT) END) AS p75_days,
        MIN(CASE WHEN 100.0 * rn >= 80 * cnt THEN CAST(days_past_death AS FLOAT) END) AS p80_days,
        MIN(CASE WHEN 100.0 * rn >= 90 * cnt THEN CAST(days_past_death AS FLOAT) END) AS p90_days,
        MIN(CASE WHEN 100.0 * rn >= 95 * cnt THEN CAST(days_past_death AS FLOAT) END) AS p95_days,
        MIN(CASE WHEN 100.0 * rn >= 99 * cnt THEN CAST(days_past_death AS FLOAT) END) AS p99_days
    FROM ranked
    GROUP BY anchor_event
),
anchor_scaffold AS (
    -- Both anchors always emitted, even when an anchor has zero decedents whose
    -- period runs past death (pct would otherwise have no row for it). The LEFT JOIN
    -- then yields n_decedents_period_past_death = 0 and NULL percentiles for that
    -- anchor, mirroring the stratum_totals scaffold in chunk 38.
    SELECT 'INDEX' AS anchor_event
    UNION ALL
    SELECT 'FIRST_MET'
)
SELECT
    s.anchor_event,
    CASE WHEN p.n_decedents_period_past_death > 0 AND p.n_decedents_period_past_death <= @min_cell_count
         THEN -@min_cell_count ELSE COALESCE(p.n_decedents_period_past_death, 0) END AS n_decedents_period_past_death,
    CASE WHEN p.n_decedents_period_past_death <= @min_cell_count THEN NULL ELSE p.min_days  END AS min_days,
    CASE WHEN p.n_decedents_period_past_death <= @min_cell_count THEN NULL ELSE p.max_days  END AS max_days,
    CASE WHEN p.n_decedents_period_past_death <= @min_cell_count THEN NULL ELSE p.mean_days END AS mean_days,
    CASE WHEN p.n_decedents_period_past_death <= @min_cell_count THEN NULL ELSE p.p01_days  END AS p01_days,
    CASE WHEN p.n_decedents_period_past_death <= @min_cell_count THEN NULL ELSE p.p05_days  END AS p05_days,
    CASE WHEN p.n_decedents_period_past_death <= @min_cell_count THEN NULL ELSE p.p10_days  END AS p10_days,
    CASE WHEN p.n_decedents_period_past_death <= @min_cell_count THEN NULL ELSE p.p20_days  END AS p20_days,
    CASE WHEN p.n_decedents_period_past_death <= @min_cell_count THEN NULL ELSE p.p25_days  END AS p25_days,
    CASE WHEN p.n_decedents_period_past_death <= @min_cell_count THEN NULL ELSE p.p30_days  END AS p30_days,
    CASE WHEN p.n_decedents_period_past_death <= @min_cell_count THEN NULL ELSE p.p40_days  END AS p40_days,
    CASE WHEN p.n_decedents_period_past_death <= @min_cell_count THEN NULL ELSE p.p50_days  END AS p50_days,
    CASE WHEN p.n_decedents_period_past_death <= @min_cell_count THEN NULL ELSE p.p60_days  END AS p60_days,
    CASE WHEN p.n_decedents_period_past_death <= @min_cell_count THEN NULL ELSE p.p70_days  END AS p70_days,
    CASE WHEN p.n_decedents_period_past_death <= @min_cell_count THEN NULL ELSE p.p75_days  END AS p75_days,
    CASE WHEN p.n_decedents_period_past_death <= @min_cell_count THEN NULL ELSE p.p80_days  END AS p80_days,
    CASE WHEN p.n_decedents_period_past_death <= @min_cell_count THEN NULL ELSE p.p90_days  END AS p90_days,
    CASE WHEN p.n_decedents_period_past_death <= @min_cell_count THEN NULL ELSE p.p95_days  END AS p95_days,
    CASE WHEN p.n_decedents_period_past_death <= @min_cell_count THEN NULL ELSE p.p99_days  END AS p99_days
FROM anchor_scaffold s
LEFT JOIN pct p ON p.anchor_event = s.anchor_event
ORDER BY CASE s.anchor_event WHEN 'INDEX' THEN 0 ELSE 1 END
;
