-- 29) G. Drug Therapy procedure characterization, part 1a. Where each patient's
--     antineoplastic treatment signal lives, ON OR AFTER the first Metastasis.
--     Each patient who carries an anchor Metastasis (MET) code (and therefore also
--     an anchor DX code) is placed in exactly one category by the source of their
--     treatment signal on or after their first MET date:
--
--       DRUG_EXPOSURE_ON_OR_AFTER_MET  >= 1 antineoplastic (L01) drug_exposure
--                                        record on or after the first MET
--                                        (captured by the current L01 analysis,
--                                        whether or not a procedure is also present)
--       DTP_ONLY_ON_OR_AFTER_MET       no such drug_exposure, but >= 1 Drug Therapy
--                                        procedure on or after the first MET
--                                        (procedure-only; missed by the current
--                                        L01 analysis)
--       NEITHER_ON_OR_AFTER_MET        no treatment signal of either kind on or
--                                        after the first MET (includes patients
--                                        treated only BEFORE the first MET)
--
--     "On or after" = event_date >= first_met_date. Day 0 (a record on the first
--     MET date) counts on the on-or-after side, its own explicit inclusion, never
--     treated as before. The window is unbounded on the right (no end cap),
--     confirmed with AA. The DTP_ONLY group is the completeness signal: these
--     patients received metastatic-disease treatment yet look treatment-naive in
--     the drug-level analysis.
--
--     WHY ON-OR-AFTER-MET AND NOT WHOLE-RECORD (design note). G exists to size
--     procedure-only capture of metastatic-disease treatment specifically. An
--     unanchored whole-record check would hide it: a patient with adjuvant
--     drug_exposure years before ever developing metastatic disease, then only
--     procedure codes near their metastatic treatment, would read as
--     "drug_exposure present" and look fully captured. Scoping to on or after the
--     first MET places that patient in DTP_ONLY where they belong. Treatment
--     before the first MET is a different quantity and is held in NEITHER, the
--     same convention Analysis H (chunk 24) uses for pre-MET treatment.
--
--     Denominator (n_patients_met_total, repeated on each row):
--       all patients with >= 1 anchor MET measurement code AND >= 1 anchor DX code
--       at this site (the three categories sum to this total). This is the same
--       DX-anchored first-Metastasis cohort used in Analyses D and H.
--
--     POPULATION. The MET population is built from #met_events (00_setup.sql, section
--     F): @cdm_database_schema.measurement JOIN #met_concepts JOIN #anchor_person, so
--     every patient carries an anchor DX code. The cohort is DX-anchored; a MET code
--     is observed WITHIN it, never as a separate entry point. A generic MET code
--     without an anchor DX gives no evidence of the cancer of interest, so no
--     "MET-only, no DX" patient exists. Identical DX-anchored population to Analyses
--     D and H (chunks 20-28).
--
--     L01 AND DTP SOURCES. Antineoplastic drug_exposure records come from #l01_events
--     (drug_exposure JOIN #l01_concepts JOIN #anchor_person, 00_setup.sql section F),
--     gated to the same DX anchor cohort as the MET population. Drug Therapy
--     procedures come from @cdm_database_schema.procedure_occurrence JOIN
--     #dtp_concepts; there is no procedure event table in setup, so the join to the
--     DX-anchored met_all restricts them to the same cohort. Both signals are
--     therefore evaluated over exactly the DX-anchored MET patients.
--
--     JUDGMENT CALL / FLAG (observation period). Neither the MET population nor the
--     treatment records are restricted to an observation period. The population is
--     anchored on "has an anchor DX code" (#anchor_person), not "inside an
--     observation period" (#cohort). Observation-period coverage is characterized
--     separately in Analysis E (chunks 16-17). See the report for the recommendation.
--
--     Small-cell suppression: n_patients in (0, @min_cell_count] set to
--     -@min_cell_count. n_patients_met_total is an aggregate denominator, not
--     suppressed. A category with zero patients is absent (as in chunks 20-28).

WITH met_all AS (
    -- DX-anchored MET population: earliest MET date per patient (#met_events is
    -- gated to #anchor_person and carries no observation-period gate).
    SELECT
        person_id,
        MIN(event_date) AS first_met_date
    FROM #met_events
    GROUP BY person_id
),
drugexp_flag AS (
    -- MET patients with >= 1 antineoplastic drug_exposure on or after the first MET.
    -- #l01_events is gated to #anchor_person, the same cohort as met_all.
    SELECT DISTINCT ma.person_id
    FROM met_all ma
    JOIN #l01_events le
      ON le.person_id = ma.person_id
    WHERE le.event_date >= ma.first_met_date
),
dtp_flag AS (
    -- MET patients with >= 1 Drug Therapy procedure on or after the first MET.
    -- No procedure event table exists in setup; the join to the DX-anchored met_all
    -- restricts procedure_occurrence to the same cohort.
    SELECT DISTINCT ma.person_id
    FROM met_all ma
    JOIN @cdm_database_schema.procedure_occurrence po
      ON po.person_id = ma.person_id
    JOIN #dtp_concepts dtp
      ON po.procedure_concept_id = dtp.concept_id
    WHERE po.procedure_date >= ma.first_met_date
),
classified AS (
    SELECT
        ma.person_id,
        CASE
            WHEN d.person_id IS NOT NULL THEN 'DRUG_EXPOSURE_ON_OR_AFTER_MET'
            WHEN p.person_id IS NOT NULL THEN 'DTP_ONLY_ON_OR_AFTER_MET'
            ELSE                              'NEITHER_ON_OR_AFTER_MET'
        END AS signal_source
    FROM met_all ma
    LEFT JOIN drugexp_flag d ON d.person_id = ma.person_id
    LEFT JOIN dtp_flag     p ON p.person_id = ma.person_id
),
totals AS (
    SELECT COUNT(*) AS n_patients_met_total FROM met_all
)
SELECT
    c.signal_source,
    CASE WHEN COUNT(*) > 0 AND COUNT(*) <= @min_cell_count THEN -@min_cell_count
         ELSE COUNT(*) END AS n_patients,
    t.n_patients_met_total
FROM classified c
CROSS JOIN totals t
GROUP BY c.signal_source, t.n_patients_met_total
ORDER BY
    CASE c.signal_source
        WHEN 'DRUG_EXPOSURE_ON_OR_AFTER_MET' THEN 0
        WHEN 'DTP_ONLY_ON_OR_AFTER_MET'      THEN 1
        WHEN 'NEITHER_ON_OR_AFTER_MET'       THEN 2
        ELSE 9
    END
;
