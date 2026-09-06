-- 40) D. Treatment-availability breakdown for the metastasis subset, four categories
--     shown BOTH ways: ever-recorded AND on-or-after the first Metastasis. This is the
--     ungated companion to chunk 29 (which reports only the on-or-after-MET window and
--     over the ungated all-metastasis population). Here BOTH windows are emitted, and
--     the denominator is standardized on the DX-cohort-gated metastasis subset
--     (n = 629 at HUS), NOT the ungated all-metastasis population (n = 694).
--
--     Population (metastasis subset): #met_summary (built in 00_setup.sql as
--     #met_events joined to #cohort), i.e. cohort patients carrying an anchor
--     Metastasis, with their first_met_date. n_met_subset = COUNT(#met_summary) = 629.
--
--     Two treatment signals (definitions UNCHANGED from chunk 29):
--       L01  = an antineoplastic drug_exposure (#l01_events, drug_exposure joined to
--              #l01_concepts, 00_setup.sql section E).
--       DTP  = a Drug Therapy procedure (procedure_occurrence joined to #dtp_concepts,
--              the four roots: chemotherapy 4273629, immunological therapy 4295112,
--              targeted chemotherapy for cancer 37158316, hormone therapy 4061650;
--              00_setup.sql section E2). Labelled "drug-therapy procedure," not
--              "chemotherapy," in the report.
--
--     Two windows per patient:
--       EVER            = any qualifying record at any time (no date restriction).
--       ON_OR_AFTER_MET = qualifying record with event_date >= first_met_date. Day 0
--                         (a record on the first MET date) counts on the on-or-after
--                         side, matching chunk 29's convention.
--
--     Four categories per window (these are FOUR availability measures shown side by
--     side, NOT a partition — EITHER overlaps the two ONLY categories; only
--     EITHER + NEITHER = n_met_subset):
--       L01_ONLY   has L01, no DTP
--       DTP_ONLY   has DTP, no L01
--       EITHER     has L01 or DTP (any antineoplastic treatment signal)
--       NEITHER    has neither
--     By construction, per window: L01_ONLY + DTP_ONLY + (both L01 and DTP) = EITHER,
--     and EITHER + NEITHER = n_met_subset. The report reads the four directly.
--
--     Small-cell suppression: n_patients in (0, @min_cell_count] set to
--     -@min_cell_count. n_met_subset is an aggregate denominator, not suppressed.
--     Source: #met_summary, #l01_events (00_setup.sql), #dtp_concepts (00_setup.sql),
--     @cdm_database_schema.procedure_occurrence.

WITH met_subset AS (
    -- Metastasis subset: one row per cohort patient with a MET, plus first_met_date.
    SELECT person_id, first_met_date
    FROM #met_summary
),
l01_flags AS (
    -- Per subset patient: any L01 ever, any L01 on/after first MET.
    SELECT
        ms.person_id,
        MAX(CASE WHEN le.person_id IS NOT NULL THEN 1 ELSE 0 END)                                AS has_l01_ever,
        MAX(CASE WHEN le.event_date >= ms.first_met_date THEN 1 ELSE 0 END)                      AS has_l01_oaf
    FROM met_subset ms
    LEFT JOIN #l01_events le ON le.person_id = ms.person_id
    GROUP BY ms.person_id
),
dtp_flags AS (
    -- Per subset patient: any DTP procedure ever, any DTP on/after first MET.
    SELECT
        ms.person_id,
        MAX(CASE WHEN po.person_id IS NOT NULL THEN 1 ELSE 0 END)                                AS has_dtp_ever,
        MAX(CASE WHEN po.procedure_date >= ms.first_met_date THEN 1 ELSE 0 END)                  AS has_dtp_oaf
    FROM met_subset ms
    -- Pre-filtered to DTP concepts via a real join, not `IN (subquery)` inside
    -- the ON predicate -- BigQuery rejects that ("IN subquery is not
    -- supported inside join predicate"). Semantically identical: only
    -- procedure_occurrence rows matching a #dtp_concepts row are
    -- considered, and the outer LEFT JOIN below still preserves every
    -- met_subset patient.
    LEFT JOIN (
        SELECT po.person_id, po.procedure_date
        FROM @cdm_database_schema.procedure_occurrence po
        JOIN #dtp_concepts dc ON dc.concept_id = po.procedure_concept_id
    ) po
      ON po.person_id = ms.person_id
    GROUP BY ms.person_id
),
patient_flags AS (
    SELECT
        ms.person_id,
        COALESCE(lf.has_l01_ever, 0) AS has_l01_ever,
        COALESCE(lf.has_l01_oaf,  0) AS has_l01_oaf,
        COALESCE(df.has_dtp_ever, 0) AS has_dtp_ever,
        COALESCE(df.has_dtp_oaf,  0) AS has_dtp_oaf
    FROM met_subset ms
    LEFT JOIN l01_flags lf ON lf.person_id = ms.person_id
    LEFT JOIN dtp_flags df ON df.person_id = ms.person_id
),
counts AS (
    SELECT 'EVER' AS treatment_window, 'L01_ONLY' AS category,
           SUM(CASE WHEN has_l01_ever = 1 AND has_dtp_ever = 0 THEN 1 ELSE 0 END) AS n_patients
    FROM patient_flags
    UNION ALL
    SELECT 'EVER', 'DTP_ONLY',
           SUM(CASE WHEN has_dtp_ever = 1 AND has_l01_ever = 0 THEN 1 ELSE 0 END)
    FROM patient_flags
    UNION ALL
    SELECT 'EVER', 'EITHER',
           SUM(CASE WHEN has_l01_ever = 1 OR has_dtp_ever = 1 THEN 1 ELSE 0 END)
    FROM patient_flags
    UNION ALL
    SELECT 'EVER', 'NEITHER',
           SUM(CASE WHEN has_l01_ever = 0 AND has_dtp_ever = 0 THEN 1 ELSE 0 END)
    FROM patient_flags
    UNION ALL
    SELECT 'ON_OR_AFTER_MET', 'L01_ONLY',
           SUM(CASE WHEN has_l01_oaf = 1 AND has_dtp_oaf = 0 THEN 1 ELSE 0 END)
    FROM patient_flags
    UNION ALL
    SELECT 'ON_OR_AFTER_MET', 'DTP_ONLY',
           SUM(CASE WHEN has_dtp_oaf = 1 AND has_l01_oaf = 0 THEN 1 ELSE 0 END)
    FROM patient_flags
    UNION ALL
    SELECT 'ON_OR_AFTER_MET', 'EITHER',
           SUM(CASE WHEN has_l01_oaf = 1 OR has_dtp_oaf = 1 THEN 1 ELSE 0 END)
    FROM patient_flags
    UNION ALL
    SELECT 'ON_OR_AFTER_MET', 'NEITHER',
           SUM(CASE WHEN has_l01_oaf = 0 AND has_dtp_oaf = 0 THEN 1 ELSE 0 END)
    FROM patient_flags
),
total AS (
    SELECT COUNT(*) AS n_met_subset FROM met_subset
)
SELECT
    c.treatment_window,
    c.category,
    CASE WHEN c.n_patients > 0 AND c.n_patients <= @min_cell_count
         THEN -@min_cell_count ELSE c.n_patients END AS n_patients,
    t.n_met_subset
FROM counts c
CROSS JOIN total t
ORDER BY
    CASE c.treatment_window WHEN 'EVER' THEN 0 ELSE 1 END,
    CASE c.category
        WHEN 'L01_ONLY' THEN 0
        WHEN 'DTP_ONLY' THEN 1
        WHEN 'EITHER'   THEN 2
        WHEN 'NEITHER'  THEN 3
        ELSE 9
    END
;
