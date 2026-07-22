-- 31) G. Drug Therapy procedure characterization (Part 2) — timing of the first
--     Drug Therapy procedure relative to the first Metastasis, directional.
--     For patients who carry BOTH an anchor Metastasis (MET) code and a Drug
--     Therapy procedure (DTP), the gap in days from the first MET to the first DTP
--     is placed in exactly one directional bucket. Before and after the MET are
--     kept separate; day 0 is its own explicit category, never folded into after:
--
--       DTP_GT90D_BEFORE_MET     first DTP more than 90 days before the first MET
--       DTP_1_90D_BEFORE_MET     first DTP 1 to 90 days before the first MET
--       DTP_ON_MET_DAY           first DTP on the first MET date (day 0)
--       DTP_1_90D_AFTER_MET      first DTP 1 to 90 days after the first MET
--       DTP_91_365D_AFTER_MET    first DTP 91 to 365 days after the first MET
--       DTP_GT365D_AFTER_MET     first DTP more than 365 days after the first MET
--
--     gap_days = DATEDIFF(DAY, first_met_date, first_dtp_date): negative = before,
--     0 = day 0, positive = after. One value per patient (first MET vs first DTP).
--
--     Denominator (n_patients_both_total, repeated on each row):
--       patients who carry both an anchor MET code and at least one Drug Therapy
--       procedure, over the DX-anchored MET population. "Patients with both events"
--       within the DX-anchored cohort.
--
--     Population and observation-period notes: same as chunk 29 (DX-anchored MET
--     population from #met_events; Drug Therapy procedures from procedure_occurrence +
--     #dtp_concepts, restricted to the same cohort by the inner join to met_all; no
--     observation-period gate). The DTP here is any Drug Therapy procedure regardless
--     of concept root; the per-concept view is in chunks 30 and 32.
--
--     Small-cell suppression: n_patients in (0, @min_cell_count] set to
--     -@min_cell_count. n_patients_both_total is an aggregate denominator, not
--     suppressed. A bucket with zero patients is absent (as in chunks 22, 24).

WITH met_all AS (
    SELECT
        person_id,
        MIN(event_date) AS first_met_date
    FROM #met_events
    GROUP BY person_id
),
dtp_all AS (
    -- Earliest Drug Therapy procedure date per patient (any concept root). The inner
    -- join to the DX-anchored met_all below restricts this to the same cohort, so no
    -- separate DX gate is needed here.
    SELECT
        po.person_id,
        MIN(po.procedure_date) AS first_dtp_date
    FROM @cdm_database_schema.procedure_occurrence po
    JOIN #dtp_concepts dtp
      ON po.procedure_concept_id = dtp.concept_id
    GROUP BY po.person_id
),
gap AS (
    -- Patients with BOTH events; signed gap from first MET to first DTP.
    SELECT
        ma.person_id,
        DATEDIFF(DAY, ma.first_met_date, da.first_dtp_date) AS gap_days
    FROM met_all ma
    JOIN dtp_all da
      ON da.person_id = ma.person_id
),
bucketed AS (
    SELECT
        person_id,
        CASE
            WHEN gap_days < -90                  THEN 'DTP_GT90D_BEFORE_MET'
            WHEN gap_days < 0                    THEN 'DTP_1_90D_BEFORE_MET'
            WHEN gap_days = 0                    THEN 'DTP_ON_MET_DAY'
            WHEN gap_days <= 90                  THEN 'DTP_1_90D_AFTER_MET'
            WHEN gap_days <= 365                 THEN 'DTP_91_365D_AFTER_MET'
            ELSE                                      'DTP_GT365D_AFTER_MET'
        END AS timing_bucket,
        CASE
            WHEN gap_days < -90                  THEN 1
            WHEN gap_days < 0                    THEN 2
            WHEN gap_days = 0                    THEN 3
            WHEN gap_days <= 90                  THEN 4
            WHEN gap_days <= 365                 THEN 5
            ELSE                                      6
        END AS bucket_order
    FROM gap
),
totals AS (
    SELECT COUNT(*) AS n_patients_both_total FROM bucketed
)
SELECT
    b.timing_bucket,
    CASE WHEN COUNT(*) > 0 AND COUNT(*) <= @min_cell_count THEN -@min_cell_count
         ELSE COUNT(*) END AS n_patients,
    t.n_patients_both_total
FROM bucketed b
CROSS JOIN totals t
GROUP BY b.timing_bucket, t.n_patients_both_total
ORDER BY MIN(b.bucket_order)
;
