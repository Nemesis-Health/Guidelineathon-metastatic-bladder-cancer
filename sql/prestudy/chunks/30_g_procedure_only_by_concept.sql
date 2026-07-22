-- 30) G. Drug Therapy procedure characterization, part 1b. Which Drug Therapy
--     procedure concept drives the procedure-only group.
--     Among the procedure-only patients defined in chunk 29 (a Drug Therapy
--     procedure on or after the first Metastasis, but NO antineoplastic
--     drug_exposure on or after the first Metastasis), how many carry each of the
--     four Drug Therapy procedure roots:
--
--       root_concept_id 4273629  Chemotherapy
--       root_concept_id 4295112  Immunological therapy
--       root_concept_id 37158316 Targeted chemotherapy for cancer
--       root_concept_id 4061650  Hormone therapy
--
--     A patient counts under every root they carry a procedure for (on or after
--     the first MET), so the per-root counts OVERLAP and do NOT sum to the
--     procedure-only total. Only procedures on or after the first MET are counted,
--     consistent with the chunk-29 procedure-only definition.
--
--     Denominator (n_procedure_only_total, repeated on each row):
--       the DTP_ONLY_ON_OR_AFTER_MET group of chunk 29 (procedure on or after MET,
--       no drug_exposure on or after MET). Re-derived here from the same source
--       logic so the two chunks stay consistent.
--
--     Population, observation-period and source notes: same as chunk 29 (DX-anchored
--     MET population from #met_events; L01 from #l01_events, gated to #anchor_person;
--     Drug Therapy procedures from procedure_occurrence + #dtp_concepts restricted to
--     the same cohort by the join to met_all; no observation-period gate). Per-root
--     n_patients in (0, @min_cell_count] set to -@min_cell_count; n_procedure_only_total
--     is an aggregate denominator, not suppressed. A root carried by zero
--     procedure-only patients is absent.

WITH met_all AS (
    SELECT
        person_id,
        MIN(event_date) AS first_met_date
    FROM #met_events
    GROUP BY person_id
),
drugexp_flag AS (
    -- MET patients with an antineoplastic drug_exposure on or after the first MET.
    SELECT DISTINCT ma.person_id
    FROM met_all ma
    JOIN #l01_events le
      ON le.person_id = ma.person_id
    WHERE le.event_date >= ma.first_met_date
),
proc_on_after AS (
    -- Every Drug Therapy procedure on or after the first MET, tagged with its root.
    SELECT DISTINCT
        ma.person_id,
        dtp.root_concept_id
    FROM met_all ma
    JOIN @cdm_database_schema.procedure_occurrence po
      ON po.person_id = ma.person_id
    JOIN #dtp_concepts dtp
      ON po.procedure_concept_id = dtp.concept_id
    WHERE po.procedure_date >= ma.first_met_date
),
proc_only AS (
    -- Procedure-only group: a procedure on or after MET, and NOT in drugexp_flag.
    SELECT p.person_id, p.root_concept_id
    FROM proc_on_after p
    LEFT JOIN drugexp_flag d ON d.person_id = p.person_id
    WHERE d.person_id IS NULL
),
totals AS (
    SELECT COUNT(DISTINCT person_id) AS n_procedure_only_total FROM proc_only
)
SELECT
    po.root_concept_id,
    CASE WHEN COUNT(DISTINCT po.person_id) > 0
          AND COUNT(DISTINCT po.person_id) <= @min_cell_count THEN -@min_cell_count
         ELSE COUNT(DISTINCT po.person_id) END AS n_patients,
    t.n_procedure_only_total
FROM proc_only po
CROSS JOIN totals t
GROUP BY po.root_concept_id, t.n_procedure_only_total
ORDER BY COUNT(DISTINCT po.person_id) DESC, po.root_concept_id
;
