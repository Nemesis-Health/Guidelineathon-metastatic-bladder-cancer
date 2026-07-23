-- 20) D. MET-first subgroup, part 1. Ordering of the first Metastasis and the
--     first specific Diagnosis, among patients who carry a Metastasis code within
--     the DX-anchored cohort.
--     Every patient in this framework carries an anchor Diagnosis (DX) code by
--     construction. The cohort is DX-anchored: a Diagnosis code from the anchor
--     concept set is the entry point, and Metastasis is observed WITHIN that cohort,
--     never as a separate way to enter it. Each patient who carries an anchor
--     Metastasis (MET) measurement code (and therefore also an anchor DX code) is
--     placed in exactly one category by which of two events is recorded first: the
--     first MET and the first specific (anchor) DX. Same-day is its own category,
--     never folded into either side.
--
--       DX_FIRST            first specific DX date < first MET date
--       SAME_DAY            first specific DX date = first MET date
--       MET_FIRST_THEN_DX   first MET date < first specific DX date
--                           (the MET code predates the existing DX code; the DX code
--                            always exists, it simply arrives later)
--
--     There is NO "Metastasis-only, never Diagnosis" category. A patient with a
--     generic Metastasis code but no anchor DX code is not in this cohort at all.
--     The MET concept set (AJCC/UICC stage 4, M1, Metastasis) is generic across
--     cancer types, so a MET code without an anchor DX gives no evidence the patient
--     has the cancer of interest. Only MET_FIRST_THEN_DX (is_met_first_subgroup = 1)
--     is carried into parts 2 and 3.
--
--     Denominator (n_patients_met_total, repeated on each row):
--       all patients with >= 1 anchor MET measurement code AND >= 1 anchor DX code
--       at this site (the three categories sum to this total).
--
--     POPULATION. Built from #met_events (00_setup.sql, section F), which is
--     @cdm_database_schema.measurement JOIN #met_concepts JOIN #anchor_person, so
--     every person already carries an anchor DX code. #anchor_person is the
--     DX-anchored cohort WITHOUT the observation-period-at-index gate that #cohort
--     adds, so this count sits at or above Analysis F's #met_summary count (DX plus
--     observation period at the index DX) and at or below a count of all MET carriers
--     regardless of DX. The first specific DX per patient comes from #dx_events (all
--     anchor-DX events, no observation-period gate), consistent with anchoring on
--     #anchor_person. Because every #met_events person is in #anchor_person and hence
--     in #dx_events, the DX join below matches every patient (no null-DX branch).
--
--     JUDGMENT CALL / FLAG (observation period). The population is anchored on
--     "has an anchor DX code" (#anchor_person), NOT on "has an anchor DX code inside
--     an observation period" (#cohort). Observation-period coverage is a separate,
--     still-open decision, characterized on its own in Analysis E (chunks 16-17); it
--     is deliberately not imposed here. See the accompanying report for the reasoned
--     recommendation.
--
--     JUDGMENT CALL / FLAG (same-day). SAME_DAY = the first specific DX and the
--     first MET fall on the identical calendar date; neither precedes the other.
--
--     Small-cell suppression: n_patients in (0, @min_cell_count] set to
--     -@min_cell_count. n_patients_met_total is an aggregate denominator, not
--     suppressed. A category with zero patients is absent (as in chunks 18-19).

WITH met_all AS (
    -- DX-anchored MET population: earliest MET date per patient. #met_events is
    -- already restricted to patients who carry an anchor DX code (#anchor_person)
    -- and carries no observation-period gate.
    SELECT
        person_id,
        MIN(event_date) AS first_met_date
    FROM #met_events
    GROUP BY person_id
),
dx_all AS (
    -- First specific (anchor) DX per patient, over all anchor-DX events (no
    -- observation-period gate). Every met_all patient appears here by construction.
    SELECT
        person_id,
        MIN(event_date) AS first_dx_date
    FROM #dx_events
    GROUP BY person_id
),
classified AS (
    SELECT
        ma.person_id,
        CASE
            WHEN dx.first_dx_date < ma.first_met_date THEN 'DX_FIRST'
            WHEN dx.first_dx_date = ma.first_met_date THEN 'SAME_DAY'
            ELSE                                           'MET_FIRST_THEN_DX'
        END AS ordering_category
    FROM met_all ma
    JOIN dx_all dx
      ON dx.person_id = ma.person_id
),
totals AS (
    SELECT COUNT(*) AS n_patients_met_total FROM classified
)
SELECT
    c.ordering_category,
    CASE WHEN c.ordering_category = 'MET_FIRST_THEN_DX'
         THEN 1 ELSE 0 END AS is_met_first_subgroup,
    CASE WHEN COUNT(*) > 0 AND COUNT(*) <= @min_cell_count THEN -@min_cell_count
         ELSE COUNT(*) END AS n_patients,
    t.n_patients_met_total
FROM classified c
CROSS JOIN totals t
GROUP BY c.ordering_category, t.n_patients_met_total
ORDER BY
    CASE c.ordering_category
        WHEN 'DX_FIRST'          THEN 0
        WHEN 'SAME_DAY'          THEN 1
        WHEN 'MET_FIRST_THEN_DX' THEN 2
        ELSE 9
    END
;
