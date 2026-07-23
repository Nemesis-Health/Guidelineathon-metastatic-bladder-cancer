-- 35) B. General cancer diagnosis (GDX) coding trajectory — part 3, per-concept
--     directional windowed counts. One row per general cancer diagnosis (broad /
--     non-specific ancestor) concept carried by the anchor cohort, with the number
--     of distinct cohort patients holding a code of that concept in each window
--     relative to the first specific Diagnosis (INDEX = #cohort.index_date). All
--     timing is directional with day 0 explicit:
--
--       days = general_code_date - first_specific_diagnosis_date
--
--     Columns (distinct patients holding >= 1 code of the concept in the region;
--     the three regions overlap, so before + at day 0 + after can exceed n_patients
--     because one patient may hold codes on more than one side):
--       n_patients        any time (the concept's overall patient count)
--       before side (strictly before, days < 0), cumulative outward from day 0:
--         n_before_30d   -30 <= days <= -1
--         n_before_90d, n_before_180d, n_before_365d
--         n_ever_before  days < 0 (no upper look-back bound)
--       n_at_day0         days = 0 (explicit central category)
--       after side (strictly after, days > 0), cumulative outward from day 0:
--         n_after_30d     1 <= days <= 30
--         n_after_90d, n_after_180d, n_after_365d
--         n_ever_after   days > 0 (no upper follow-up bound)
--
--     Purpose: exclusion-criteria safety at the concept level. Concepts carried
--     mostly BEFORE the first specific Diagnosis (high n_ever_before) are the ones a
--     naive "any malignant neoplasm" exclusion would wrongly remove; the report
--     builds an adjustable capture window from these directional counts.
--
--     JUDGMENT CALL / FLAG (directional vs the mock's modelled split). The approved
--     V3 mock supplied REAL HUS patient counts per concept (n_patients / ever, and
--     ever-before / ever-after) but MODELLED the by-window before/after split from
--     symmetric +/-30/90/180/365 counts because a directional windowed output did
--     not yet exist. This chunk produces that directional output directly: the
--     before and after windows are true strictly-before and strictly-after counts,
--     not a modelled split of a symmetric window, and day 0 is its own separate
--     mass. Two columns reconcile exactly to the mock's real counts: n_patients
--     matches the mock "ever" (e.g. Malignant tumor of kidney 368, Primary malignant
--     neoplasm of urinary system 57) and n_ever_before matches the mock ever-before
--     (kidney 164, urinary system 14). n_ever_after here is strictly after (days > 0)
--     with day 0 carved out into n_at_day0, so it is <= the mock's ever-after, which
--     used days >= 0; this is the intended day-0-explicit correction.
--
--     JUDGMENT CALL / FLAG (concept coverage and the >10 filter). All general
--     cancer diagnosis concepts present in the cohort are emitted, each cell
--     small-cell suppressed, matching chunk 06's behaviour. The approved mock's
--     "more than 10 patients" cut-off is an adjustable DISPLAY threshold applied by
--     the report builder, not a hard filter here, so the report can raise or lower
--     it without re-running SQL.
--
--     JUDGMENT CALL / FLAG (anchor). INDEX (first specific Diagnosis) only, matching
--     Analysis B's spec and the approved mock. General-code prevalence around the
--     first Metastasis is covered generically by chunk 06.
--
--     Denominator: n_patients per concept (on the row); the anchor-cohort total
--     (chunk 33 n_cohort_total) is the population base for the report's
--     percent-of-cohort figures.
--
--     Population note. #gen_cancer_events is restricted to anchor-cohort persons in
--     00_setup.sql and joined to #cohort here; general-code dates are not restricted
--     to an observation period, matching the mock.
--
--     Small-cell suppression: every count in (0, @min_cell_count] set to
--     -@min_cell_count.

WITH patient_concept AS (
    -- Per (concept, patient): flags for each directional window. days is the
    -- general code date minus the first specific Diagnosis date.
    SELECT
        g.concept_id,
        g.person_id,
        MAX(CASE WHEN DATEDIFF(DAY, c.index_date, g.event_date) >= -30  AND DATEDIFF(DAY, c.index_date, g.event_date) <= -1 THEN 1 ELSE 0 END) AS in_before_30d,
        MAX(CASE WHEN DATEDIFF(DAY, c.index_date, g.event_date) >= -90  AND DATEDIFF(DAY, c.index_date, g.event_date) <= -1 THEN 1 ELSE 0 END) AS in_before_90d,
        MAX(CASE WHEN DATEDIFF(DAY, c.index_date, g.event_date) >= -180 AND DATEDIFF(DAY, c.index_date, g.event_date) <= -1 THEN 1 ELSE 0 END) AS in_before_180d,
        MAX(CASE WHEN DATEDIFF(DAY, c.index_date, g.event_date) >= -365 AND DATEDIFF(DAY, c.index_date, g.event_date) <= -1 THEN 1 ELSE 0 END) AS in_before_365d,
        MAX(CASE WHEN DATEDIFF(DAY, c.index_date, g.event_date) <  0 THEN 1 ELSE 0 END) AS in_ever_before,
        MAX(CASE WHEN DATEDIFF(DAY, c.index_date, g.event_date) =  0 THEN 1 ELSE 0 END) AS in_day0,
        MAX(CASE WHEN DATEDIFF(DAY, c.index_date, g.event_date) >= 1 AND DATEDIFF(DAY, c.index_date, g.event_date) <= 30  THEN 1 ELSE 0 END) AS in_after_30d,
        MAX(CASE WHEN DATEDIFF(DAY, c.index_date, g.event_date) >= 1 AND DATEDIFF(DAY, c.index_date, g.event_date) <= 90  THEN 1 ELSE 0 END) AS in_after_90d,
        MAX(CASE WHEN DATEDIFF(DAY, c.index_date, g.event_date) >= 1 AND DATEDIFF(DAY, c.index_date, g.event_date) <= 180 THEN 1 ELSE 0 END) AS in_after_180d,
        MAX(CASE WHEN DATEDIFF(DAY, c.index_date, g.event_date) >= 1 AND DATEDIFF(DAY, c.index_date, g.event_date) <= 365 THEN 1 ELSE 0 END) AS in_after_365d,
        MAX(CASE WHEN DATEDIFF(DAY, c.index_date, g.event_date) >  0 THEN 1 ELSE 0 END) AS in_ever_after
    FROM #gen_cancer_events g
    JOIN #cohort c
      ON g.person_id = c.person_id
    GROUP BY g.concept_id, g.person_id
),
agg AS (
    SELECT
        concept_id,
        COUNT(*)               AS n_patients,
        SUM(in_before_30d)     AS n_before_30d,
        SUM(in_before_90d)     AS n_before_90d,
        SUM(in_before_180d)    AS n_before_180d,
        SUM(in_before_365d)    AS n_before_365d,
        SUM(in_ever_before)    AS n_ever_before,
        SUM(in_day0)           AS n_at_day0,
        SUM(in_after_30d)      AS n_after_30d,
        SUM(in_after_90d)      AS n_after_90d,
        SUM(in_after_180d)     AS n_after_180d,
        SUM(in_after_365d)     AS n_after_365d,
        SUM(in_ever_after)     AS n_ever_after
    FROM patient_concept
    GROUP BY concept_id
)
SELECT
    a.concept_id,
    CASE WHEN a.n_patients    > 0 AND a.n_patients    <= @min_cell_count THEN -@min_cell_count ELSE a.n_patients    END AS n_patients,
    CASE WHEN a.n_before_30d  > 0 AND a.n_before_30d  <= @min_cell_count THEN -@min_cell_count ELSE a.n_before_30d  END AS n_before_30d,
    CASE WHEN a.n_before_90d  > 0 AND a.n_before_90d  <= @min_cell_count THEN -@min_cell_count ELSE a.n_before_90d  END AS n_before_90d,
    CASE WHEN a.n_before_180d > 0 AND a.n_before_180d <= @min_cell_count THEN -@min_cell_count ELSE a.n_before_180d END AS n_before_180d,
    CASE WHEN a.n_before_365d > 0 AND a.n_before_365d <= @min_cell_count THEN -@min_cell_count ELSE a.n_before_365d END AS n_before_365d,
    CASE WHEN a.n_ever_before > 0 AND a.n_ever_before <= @min_cell_count THEN -@min_cell_count ELSE a.n_ever_before END AS n_ever_before,
    CASE WHEN a.n_at_day0     > 0 AND a.n_at_day0     <= @min_cell_count THEN -@min_cell_count ELSE a.n_at_day0     END AS n_at_day0,
    CASE WHEN a.n_after_30d   > 0 AND a.n_after_30d   <= @min_cell_count THEN -@min_cell_count ELSE a.n_after_30d   END AS n_after_30d,
    CASE WHEN a.n_after_90d   > 0 AND a.n_after_90d   <= @min_cell_count THEN -@min_cell_count ELSE a.n_after_90d   END AS n_after_90d,
    CASE WHEN a.n_after_180d  > 0 AND a.n_after_180d  <= @min_cell_count THEN -@min_cell_count ELSE a.n_after_180d  END AS n_after_180d,
    CASE WHEN a.n_after_365d  > 0 AND a.n_after_365d  <= @min_cell_count THEN -@min_cell_count ELSE a.n_after_365d  END AS n_after_365d,
    CASE WHEN a.n_ever_after  > 0 AND a.n_ever_after  <= @min_cell_count THEN -@min_cell_count ELSE a.n_ever_after  END AS n_ever_after
FROM agg a
ORDER BY
    a.n_patients DESC,
    a.concept_id
;
