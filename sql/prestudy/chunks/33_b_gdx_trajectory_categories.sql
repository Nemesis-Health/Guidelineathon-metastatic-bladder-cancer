-- 33) B. General cancer diagnosis (GDX) coding trajectory — part 1, categorical
--     trajectory breakdown. Every patient in the anchor cohort (INDEX = first
--     specific Diagnosis, #cohort.index_date) is placed in exactly one category by
--     where their General cancer diagnosis (broad / non-specific "any malignant
--     neoplasm"-type ancestor) codes fall relative to that first specific Diagnosis:
--
--       NONE                          no general cancer diagnosis code anywhere
--       GENERAL_BEFORE_ONLY           general code(s) only strictly before the
--                                       first specific Diagnosis (days < 0):
--                                       pre-diagnostic / workup coding
--       GENERAL_BOTH_BEFORE_AND_AFTER general code(s) on both sides: at least one
--                                       strictly before AND at least one at or
--                                       after the first specific Diagnosis
--       GENERAL_AFTER_ONLY            general code(s) only at or after the first
--                                       specific Diagnosis (days >= 0): reversion
--                                       to non-specific coding once specific
--
--     Purpose: exclusion-criteria safety. A phenotype that excludes "any malignant
--     neoplasm" via general codes would drop the BEFORE_ONLY and BOTH patients,
--     whose general code appears before their specific Diagnosis and is really the
--     same disease being worked up. This chunk quantifies that population.
--
--     Denominator (n_cohort_total, repeated on each row):
--       the full anchor cohort = every patient with a first specific Diagnosis
--       inside an observation period (#cohort, the INDEX population).
--
--     JUDGMENT CALL / FLAG (day-0 convention in the four categories). The four
--     categories use the same before(days < 0) / at-or-after(days >= 0) split as the
--     approved V3 mock and chunk 06's ever_before / ever_after convention, so the
--     category counts reconcile exactly to the validated HUS numbers (of 618
--     patients with a general code: before-only 74 / both 186 / after-only 358). A
--     general code falling exactly on the first-Diagnosis date (day 0) is therefore
--     counted on the at-or-after side. To honour the framework's day-0-explicit
--     principle WITHOUT changing those validated totals, the extra column
--     n_general_at_day0 reports, within each category, how many patients carry a
--     general code exactly at day 0. The fully day-0-separated timing (before / at
--     day 0 / after as distinct masses) is delivered in chunks 34 (first-general
--     timing CDF) and 35 (per-concept windowed counts). If a pure four-column
--     breakdown is preferred, the n_general_at_day0 column can be dropped without
--     affecting the category counts.
--
--     JUDGMENT CALL / FLAG (anchor). This trajectory is anchored to the first
--     specific Diagnosis (INDEX) only, matching Analysis B's spec ("relative to the
--     first specific DX") and the approved V3 mock. A first-Metastasis-anchored
--     variant is not part of B; general-code prevalence around the first Metastasis
--     is covered generically by chunk 06.
--
--     Population note. #gen_cancer_events is restricted to anchor-cohort persons in
--     00_setup.sql; #cohort is the observation-period-gated DX cohort and is a
--     subset of those persons, so the join is complete. General-code dates are not
--     themselves restricted to an observation period, matching the mock ("anywhere
--     in the record" relative to the first specific Diagnosis).
--
--     Small-cell suppression: n_patients and n_general_at_day0 in (0, @min_cell_count]
--     set to -@min_cell_count. n_cohort_total is an aggregate denominator, not
--     suppressed. A category with zero patients is absent.

WITH gdx_flags AS (
    -- Per anchor-cohort patient with >= 1 general cancer diagnosis code:
    -- flags for whether any code sits strictly before, exactly at, or strictly
    -- after the first specific Diagnosis.
    SELECT
        g.person_id,
        MAX(CASE WHEN DATEDIFF(DAY, c.index_date, g.event_date) <  0 THEN 1 ELSE 0 END) AS has_before,
        MAX(CASE WHEN DATEDIFF(DAY, c.index_date, g.event_date) =  0 THEN 1 ELSE 0 END) AS has_day0,
        MAX(CASE WHEN DATEDIFF(DAY, c.index_date, g.event_date) >  0 THEN 1 ELSE 0 END) AS has_after_strict
    FROM #gen_cancer_events g
    JOIN #cohort c
      ON g.person_id = c.person_id
    GROUP BY g.person_id
),
classified AS (
    -- Every cohort patient placed in exactly one category. at_or_after folds the
    -- day-0 mass onto the after side to reconcile with the validated HUS counts;
    -- has_day0 is retained separately for the explicit day-0 column.
    SELECT
        c.person_id,
        CASE
            WHEN g.person_id IS NULL                                      THEN 'NONE'
            WHEN g.has_before = 1 AND (g.has_day0 = 1 OR g.has_after_strict = 1) THEN 'GENERAL_BOTH_BEFORE_AND_AFTER'
            WHEN g.has_before = 1                                         THEN 'GENERAL_BEFORE_ONLY'
            ELSE                                                               'GENERAL_AFTER_ONLY'
        END AS trajectory_category,
        CASE WHEN g.has_day0 = 1 THEN 1 ELSE 0 END AS at_day0
    FROM #cohort c
    LEFT JOIN gdx_flags g
      ON g.person_id = c.person_id
),
totals AS (
    SELECT COUNT(*) AS n_cohort_total FROM #cohort
)
SELECT
    c.trajectory_category,
    CASE WHEN COUNT(*) > 0 AND COUNT(*) <= @min_cell_count
         THEN -@min_cell_count ELSE COUNT(*) END AS n_patients,
    CASE WHEN SUM(c.at_day0) > 0 AND SUM(c.at_day0) <= @min_cell_count
         THEN -@min_cell_count ELSE SUM(c.at_day0) END AS n_general_at_day0,
    t.n_cohort_total
FROM classified c
CROSS JOIN totals t
GROUP BY c.trajectory_category, t.n_cohort_total
ORDER BY
    CASE c.trajectory_category
        WHEN 'NONE'                          THEN 0
        WHEN 'GENERAL_BEFORE_ONLY'           THEN 1
        WHEN 'GENERAL_BOTH_BEFORE_AND_AFTER' THEN 2
        WHEN 'GENERAL_AFTER_ONLY'            THEN 3
        ELSE 9
    END
;
