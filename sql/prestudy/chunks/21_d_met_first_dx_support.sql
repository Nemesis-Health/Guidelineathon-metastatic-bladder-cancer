-- 21) D. MET-first subgroup, part 2. Whether, and how well supported, the specific
--     Diagnosis anchor is within the MET-first subgroup.
--     For the MET-first patients (first MET strictly before the first specific DX,
--     the MET_FIRST_THEN_DX group of chunk 20), a phenotype would still have to
--     anchor on their specific Diagnosis once it arrives. This part places each such
--     patient in exactly one bucket by how their specific-Diagnosis coding is
--     supported:
--
--       SPECIFIC_DX_SINGLE_DAY   specific DX on exactly one distinct day (unconfirmed anchor)
--       SPECIFIC_DX_2PLUS_DAYS   specific DX on 2 or more distinct days (repeated anchor)
--
--     There is NO "no specific DX ever" bucket. Under the corrected DX-anchored
--     population every patient carries an anchor DX code by construction (see chunk
--     20), so the reliability question here is single (unconfirmed) versus repeated
--     anchor, not present versus absent. The two buckets together are the
--     MET_FIRST_THEN_DX group of chunk 20.
--
--     Denominator (n_patients_subgroup_total, repeated on each row):
--       the MET-first subgroup = patients with a MET code whose first MET precedes
--       their first specific DX (the shaded row of chunk 20).
--
--     JUDGMENT CALL / FLAG (records vs distinct days). The reliability question is a
--     rule-of-two (two codes on two separate encounters), so this chunk measures
--     DISTINCT specific-DX DAYS, not raw records: two same-day administrative
--     duplicates should not count as a confirmed repeated anchor. This matches the
--     distinct-day treatment in chunk 19. To count raw records instead, change
--     COUNT(DISTINCT event_date) to COUNT(*) in dx_all; that would move some
--     same-day-duplicate patients from SPECIFIC_DX_SINGLE_DAY into
--     SPECIFIC_DX_2PLUS_DAYS.
--
--     Population and observation-period notes: same as chunk 20 (DX-anchored MET
--     population from #met_events, first specific DX from #dx_events, anchored on
--     #anchor_person, no observation-period gate).
--
--     Small-cell suppression: n_patients in (0, @min_cell_count] set to
--     -@min_cell_count. n_patients_subgroup_total is an aggregate denominator,
--     not suppressed. A bucket with zero patients is absent (as in chunks 18-19).

WITH met_all AS (
    SELECT
        person_id,
        MIN(event_date) AS first_met_date
    FROM #met_events
    GROUP BY person_id
),
dx_all AS (
    SELECT
        person_id,
        MIN(event_date)            AS first_dx_date,
        COUNT(DISTINCT event_date) AS n_dx_days
    FROM #dx_events
    GROUP BY person_id
),
subgroup AS (
    -- MET-first subgroup: the first MET strictly precedes the first specific DX.
    -- Every patient has a specific DX (DX-anchored cohort), so the only remaining
    -- distinction is how well supported that DX anchor is.
    SELECT
        ma.person_id,
        dx.n_dx_days
    FROM met_all ma
    JOIN dx_all dx
      ON dx.person_id = ma.person_id
    WHERE ma.first_met_date < dx.first_dx_date
),
bucketed AS (
    SELECT
        person_id,
        CASE
            WHEN n_dx_days = 1 THEN 'SPECIFIC_DX_SINGLE_DAY'
            ELSE                    'SPECIFIC_DX_2PLUS_DAYS'
        END AS dx_support_bucket
    FROM subgroup
),
totals AS (
    SELECT COUNT(*) AS n_patients_subgroup_total FROM bucketed
)
SELECT
    b.dx_support_bucket,
    CASE WHEN COUNT(*) > 0 AND COUNT(*) <= @min_cell_count THEN -@min_cell_count
         ELSE COUNT(*) END AS n_patients,
    t.n_patients_subgroup_total
FROM bucketed b
CROSS JOIN totals t
GROUP BY b.dx_support_bucket, t.n_patients_subgroup_total
ORDER BY
    CASE b.dx_support_bucket
        WHEN 'SPECIFIC_DX_SINGLE_DAY' THEN 1
        WHEN 'SPECIFIC_DX_2PLUS_DAYS' THEN 2
        ELSE 9
    END
;
