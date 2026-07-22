-- 6) Directional ODX / GDX concept prevalence relative to the anchor date, at
--    fixed clinical time points, with before and after kept strictly separate and
--    day 0 as its own category. Replaces the earlier symmetric (+/-) windowed
--    output (the +/- windows conflated pre- and post-anchor coding, which have
--    different clinical meaning for exclusion-criteria design).
--
--    For each anchor / event family / concept this counts DISTINCT PATIENTS by
--    where the code sits in time relative to the anchor. Before and after are
--    never combined into a symmetric window. The event closest to the anchor on
--    each side places the patient into exactly one before band and/or one after
--    band, so within a side the bands partition that side's patients. This is the
--    disjoint-band "quick scan" companion to the cumulative CDF in chunk 06b.
--
--    Anchors (framework two-anchor convention, both surfaced):
--      INDEX     : DX index_date (full DX cohort, #cohort)
--      FIRST_MET : first_met_date (MET subgroup only; patients with a first MET)
--
--    Event families:
--      ODX : other specific cancer diagnoses (competing-cancer exclusion codes)
--      GDX : general / non-specific cancer diagnoses (broad ancestor codes)
--
--    days = DATEDIFF(DAY, anchor_date, event_date). Bands are placed on the event
--    CLOSEST to the anchor on each side (nearest-before for the before bands,
--    nearest-after for the after bands):
--      before side (days <= -1), by days-before = -days of the closest-before event:
--        n_before_gt730   : > 730 days before  (more than 2 yr)
--        n_before_366_730 : 366-730 days before (1-2 yr)
--        n_before_181_365 : 181-365 days before
--        n_before_91_180  : 91-180 days before
--        n_before_31_90   : 31-90 days before
--        n_before_1_30    : 1-30 days before
--      day 0 (its own category, never folded into before or after):
--        n_day0           : an event on the anchor day (days = 0)
--      after side (days >= 1), by days-after of the closest-after event:
--        n_after_1_30 ... n_after_gt730 : mirror of the before bands, forward
--    Side totals (each = the sum of that side's bands = any event on that side):
--        n_before_ever, n_after_ever
--    Overall:
--        n_ever : distinct patients with any event of the concept at any time.
--
--    n_ever is NOT the sum of the columns: one patient may have events before,
--    on, and after the anchor and so appear in a before band, in n_day0, and in
--    an after band. Within a single side the bands ARE a clean partition
--    (n_before_ever = sum of before bands; n_after_ever = sum of after bands).
--
--    Covers ODX and GDX. All concepts are reported; the report builder limits to
--    top N by n_ever.
--
--    Small-cell suppression: each count in (0, @min_cell_count] set to
--    -@min_cell_count.

WITH events AS (
    SELECT 'INDEX' AS anchor_event, 'ODX' AS event_family, e.person_id, e.concept_id,
        DATEDIFF(DAY, c.index_date, e.event_date) AS days_from_anchor
    FROM #other_dx_events e
    JOIN #cohort c ON e.person_id = c.person_id

    UNION ALL

    SELECT 'INDEX' AS anchor_event, 'GDX' AS event_family, e.person_id, e.concept_id,
        DATEDIFF(DAY, c.index_date, e.event_date) AS days_from_anchor
    FROM #gen_cancer_events e
    JOIN #cohort c ON e.person_id = c.person_id

    UNION ALL

    SELECT 'FIRST_MET' AS anchor_event, 'ODX' AS event_family, e.person_id, e.concept_id,
        DATEDIFF(DAY, ms.first_met_date, e.event_date) AS days_from_anchor
    FROM #other_dx_events e
    JOIN #cohort c ON e.person_id = c.person_id
    JOIN #met_summary ms ON ms.person_id = c.person_id
    WHERE ms.first_met_date IS NOT NULL

    UNION ALL

    SELECT 'FIRST_MET' AS anchor_event, 'GDX' AS event_family, e.person_id, e.concept_id,
        DATEDIFF(DAY, ms.first_met_date, e.event_date) AS days_from_anchor
    FROM #gen_cancer_events e
    JOIN #cohort c ON e.person_id = c.person_id
    JOIN #met_summary ms ON ms.person_id = c.person_id
    WHERE ms.first_met_date IS NOT NULL
),
per_person AS (
    -- One row per (anchor, family, concept, person): day-0 flag, and the days
    -- offset of the closest event on each side (MAX of negatives = nearest before;
    -- MIN of positives = nearest after; NULL when that side has no event).
    SELECT
        anchor_event,
        event_family,
        concept_id,
        person_id,
        MAX(CASE WHEN days_from_anchor = 0 THEN 1 ELSE 0 END)      AS has_day0,
        MAX(CASE WHEN days_from_anchor < 0 THEN days_from_anchor END) AS closest_before_days,
        MIN(CASE WHEN days_from_anchor > 0 THEN days_from_anchor END) AS closest_after_days
    FROM events
    GROUP BY anchor_event, event_family, concept_id, person_id
),
dir AS (
    SELECT
        anchor_event,
        event_family,
        concept_id,
        person_id,
        has_day0,
        CASE WHEN closest_before_days IS NULL THEN NULL ELSE -closest_before_days END AS days_before,
        closest_after_days AS days_after
    FROM per_person
),
agg AS (
    SELECT
        anchor_event,
        event_family,
        concept_id,
        COUNT(*)                                                       AS n_ever,
        SUM(CASE WHEN days_before IS NOT NULL       THEN 1 ELSE 0 END) AS n_before_ever,
        SUM(CASE WHEN days_before > 730             THEN 1 ELSE 0 END) AS n_before_gt730,
        SUM(CASE WHEN days_before BETWEEN 366 AND 730 THEN 1 ELSE 0 END) AS n_before_366_730,
        SUM(CASE WHEN days_before BETWEEN 181 AND 365 THEN 1 ELSE 0 END) AS n_before_181_365,
        SUM(CASE WHEN days_before BETWEEN 91  AND 180 THEN 1 ELSE 0 END) AS n_before_91_180,
        SUM(CASE WHEN days_before BETWEEN 31  AND 90  THEN 1 ELSE 0 END) AS n_before_31_90,
        SUM(CASE WHEN days_before BETWEEN 1   AND 30  THEN 1 ELSE 0 END) AS n_before_1_30,
        SUM(has_day0)                                                  AS n_day0,
        SUM(CASE WHEN days_after BETWEEN 1   AND 30  THEN 1 ELSE 0 END) AS n_after_1_30,
        SUM(CASE WHEN days_after BETWEEN 31  AND 90  THEN 1 ELSE 0 END) AS n_after_31_90,
        SUM(CASE WHEN days_after BETWEEN 91  AND 180 THEN 1 ELSE 0 END) AS n_after_91_180,
        SUM(CASE WHEN days_after BETWEEN 181 AND 365 THEN 1 ELSE 0 END) AS n_after_181_365,
        SUM(CASE WHEN days_after BETWEEN 366 AND 730 THEN 1 ELSE 0 END) AS n_after_366_730,
        SUM(CASE WHEN days_after > 730              THEN 1 ELSE 0 END) AS n_after_gt730,
        SUM(CASE WHEN days_after IS NOT NULL        THEN 1 ELSE 0 END) AS n_after_ever
    FROM dir
    GROUP BY anchor_event, event_family, concept_id
)
SELECT
    a.anchor_event,
    a.event_family,
    a.concept_id,
    CASE WHEN a.n_ever           > 0 AND a.n_ever           <= @min_cell_count THEN -@min_cell_count ELSE a.n_ever           END AS n_ever,
    CASE WHEN a.n_before_ever    > 0 AND a.n_before_ever    <= @min_cell_count THEN -@min_cell_count ELSE a.n_before_ever    END AS n_before_ever,
    CASE WHEN a.n_before_gt730   > 0 AND a.n_before_gt730   <= @min_cell_count THEN -@min_cell_count ELSE a.n_before_gt730   END AS n_before_gt730,
    CASE WHEN a.n_before_366_730 > 0 AND a.n_before_366_730 <= @min_cell_count THEN -@min_cell_count ELSE a.n_before_366_730 END AS n_before_366_730,
    CASE WHEN a.n_before_181_365 > 0 AND a.n_before_181_365 <= @min_cell_count THEN -@min_cell_count ELSE a.n_before_181_365 END AS n_before_181_365,
    CASE WHEN a.n_before_91_180  > 0 AND a.n_before_91_180  <= @min_cell_count THEN -@min_cell_count ELSE a.n_before_91_180  END AS n_before_91_180,
    CASE WHEN a.n_before_31_90   > 0 AND a.n_before_31_90   <= @min_cell_count THEN -@min_cell_count ELSE a.n_before_31_90   END AS n_before_31_90,
    CASE WHEN a.n_before_1_30    > 0 AND a.n_before_1_30    <= @min_cell_count THEN -@min_cell_count ELSE a.n_before_1_30    END AS n_before_1_30,
    CASE WHEN a.n_day0           > 0 AND a.n_day0           <= @min_cell_count THEN -@min_cell_count ELSE a.n_day0           END AS n_day0,
    CASE WHEN a.n_after_1_30     > 0 AND a.n_after_1_30     <= @min_cell_count THEN -@min_cell_count ELSE a.n_after_1_30     END AS n_after_1_30,
    CASE WHEN a.n_after_31_90    > 0 AND a.n_after_31_90    <= @min_cell_count THEN -@min_cell_count ELSE a.n_after_31_90    END AS n_after_31_90,
    CASE WHEN a.n_after_91_180   > 0 AND a.n_after_91_180   <= @min_cell_count THEN -@min_cell_count ELSE a.n_after_91_180   END AS n_after_91_180,
    CASE WHEN a.n_after_181_365  > 0 AND a.n_after_181_365  <= @min_cell_count THEN -@min_cell_count ELSE a.n_after_181_365  END AS n_after_181_365,
    CASE WHEN a.n_after_366_730  > 0 AND a.n_after_366_730  <= @min_cell_count THEN -@min_cell_count ELSE a.n_after_366_730  END AS n_after_366_730,
    CASE WHEN a.n_after_gt730    > 0 AND a.n_after_gt730    <= @min_cell_count THEN -@min_cell_count ELSE a.n_after_gt730    END AS n_after_gt730,
    CASE WHEN a.n_after_ever     > 0 AND a.n_after_ever     <= @min_cell_count THEN -@min_cell_count ELSE a.n_after_ever     END AS n_after_ever
FROM agg a
ORDER BY
    CASE WHEN a.anchor_event = 'INDEX' THEN 0 ELSE 1 END,
    a.event_family,
    a.n_ever DESC,
    a.concept_id
;
