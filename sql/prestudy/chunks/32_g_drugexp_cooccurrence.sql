-- 32) G. Drug Therapy procedure characterization, part 3. Does an antineoplastic
--     drug_exposure sit near the Drug Therapy procedure, per procedure concept.
--     For patients who carry a Drug Therapy procedure (DTP) of a given concept root,
--     the number who also have an antineoplastic (L01) drug_exposure record within a
--     fixed window of the procedure date. Directional: a drug_exposure in the window
--     BEFORE the procedure, ON the procedure day (day 0), and in the window AFTER the
--     procedure are counted separately and never combined into one symmetric window.
--     All candidate window widths are emitted in one row so the report / UI can read
--     off any before/after pair:
--
--       n_patients_with_procedure   patients carrying this DTP concept root
--                                    (the row denominator)
--       n_drugexp_le{7,14,30,90}d_before
--                                    of those, how many have an L01 record whose
--                                    closest occurrence before a procedure of this
--                                    root is within 7 / 14 / 30 / 90 days
--       n_drugexp_on_day0            how many have an L01 record on a procedure day
--       n_drugexp_le{7,14,30,90}d_after
--                                    closest L01 after a procedure within 7/14/30/90 d
--       n_drugexp_ever               how many have any L01 record at any time (context)
--
--     Timing is measured from EACH procedure of the root: a patient counts in the
--     "within N days before" column if any of their L01 records falls 1..N days
--     before any of their procedures of that root (via the closest such record).
--     The before / day-0 / after columns can overlap for a patient, so they need not
--     sum. A high share means the procedure is corroborated by the drug table and
--     adds little new capture; a low share means the procedure is largely the only
--     record that treatment happened for that concept.
--
--     Denominator (n_patients_with_procedure, per row):
--       patients who carry a Drug Therapy procedure of this concept root WITHIN the
--       DX-anchored cohort (they also carry an anchor DX code). Part 3 characterizes
--       procedure/drug redundancy per concept root, across the cohort rather than
--       only the metastatic subset, so its per-concept denominators exceed the MET
--       count but are still bounded by the DX-anchored cohort.
--
--     JUDGMENT CALL / FLAG (DX-anchoring, changed in this revision). This chunk now
--     restricts both the DTP procedures and the L01 records to the DX-anchored cohort
--     (#anchor_person), the same entry point as every other analysis in the package.
--     Previously it read procedure_occurrence and drug_exposure UNGATED over all
--     persons, including patients with no anchor cancer DX at all. Under the corrected
--     foundational principle (every patient in this analysis carries an anchor DX code
--     by construction), a Drug Therapy procedure or L01 record in a patient with no
--     anchor DX gives no evidence about the cancer of interest's coding, the same
--     argument that governs the Metastasis population in Analyses D, G-part-1 and H.
--     Restricting to #anchor_person makes G-part-3 consistent with that principle.
--     Note this does change the per-concept denominators versus the earlier ungated
--     output: they are now smaller (cohort-only). This chunk does NOT use the MET
--     population; MET-scoping would be wrong for a general procedure/drug redundancy
--     check, so the correct anchoring here is the DX cohort, not the MET subset. If
--     the intent is instead a cohort-independent instrument check (redundancy of the
--     procedure concept itself across the whole database), revert the three
--     #anchor_person joins below; flagged for AA rather than assumed.
--
--     JUDGMENT CALL / FLAG (observation period). Not restricted to an observation
--     period, consistent with the rest of Analyses D, G and H. Anchored on
--     #anchor_person (has an anchor DX code), not #cohort (DX inside an observation
--     period). See the report for the recommendation.
--
--     JUDGMENT CALL / FLAG (suppression of the per-concept denominator).
--     n_patients_with_procedure is itself a per-concept patient count, so it is
--     suppressed like the other per-concept cells (chunk 06 convention): a value in
--     (0, @min_cell_count] is set to -@min_cell_count. When it is suppressed the
--     report cannot form a share for that row, the intended disclosure-control
--     behaviour. Every co-occurrence count is suppressed the same way. A root carried
--     by zero patients is absent.

WITH proc_carriers AS (
    -- Distinct patients carrying each DTP concept root (row denominator), restricted
    -- to the DX-anchored cohort (#anchor_person).
    SELECT DISTINCT
        po.person_id,
        dtp.root_concept_id
    FROM @cdm_database_schema.procedure_occurrence po
    JOIN #anchor_person ap
      ON ap.person_id = po.person_id
    JOIN #dtp_concepts dtp
      ON po.procedure_concept_id = dtp.concept_id
),
proc_dates AS (
    -- Distinct (patient, root, procedure_date) for the timing comparison, restricted
    -- to the DX-anchored cohort.
    SELECT DISTINCT
        po.person_id,
        dtp.root_concept_id,
        po.procedure_date
    FROM @cdm_database_schema.procedure_occurrence po
    JOIN #anchor_person ap
      ON ap.person_id = po.person_id
    JOIN #dtp_concepts dtp
      ON po.procedure_concept_id = dtp.concept_id
),
l01_dates AS (
    -- Distinct antineoplastic drug_exposure dates per patient. #l01_events is already
    -- gated to #anchor_person (drug_exposure JOIN #l01_concepts JOIN #anchor_person).
    SELECT DISTINCT
        person_id,
        event_date AS l01_date
    FROM #l01_events
),
pairs AS (
    -- Signed gap from each procedure to each L01 record of the same patient.
    -- gap_days = DATEDIFF(procedure_date, l01_date): negative = L01 before the
    -- procedure, 0 = same day, positive = L01 after the procedure.
    SELECT
        pd.person_id,
        pd.root_concept_id,
        DATEDIFF(DAY, pd.procedure_date, ld.l01_date) AS gap_days
    FROM proc_dates pd
    JOIN l01_dates ld
      ON ld.person_id = pd.person_id
),
per_patient AS (
    -- Per (patient, root): closest L01 on each side and any-ever flag.
    SELECT
        person_id,
        root_concept_id,
        MIN(CASE WHEN gap_days < 0 THEN -gap_days END) AS closest_before_days,
        MAX(CASE WHEN gap_days = 0 THEN 1 ELSE 0 END)  AS has_day0,
        MIN(CASE WHEN gap_days > 0 THEN gap_days END)  AS closest_after_days,
        1                                              AS has_l01_ever
    FROM pairs
    GROUP BY person_id, root_concept_id
),
joined AS (
    -- All procedure carriers; co-occurrence attributes NULL when the patient has
    -- no L01 record at all (still counted in the denominator, contributes 0).
    SELECT
        c.person_id,
        c.root_concept_id,
        pp.closest_before_days,
        pp.has_day0,
        pp.closest_after_days,
        pp.has_l01_ever
    FROM proc_carriers c
    LEFT JOIN per_patient pp
      ON pp.person_id = c.person_id
     AND pp.root_concept_id = c.root_concept_id
),
agg AS (
    SELECT
        root_concept_id,
        COUNT(*)                                                          AS n_with_proc,
        SUM(CASE WHEN closest_before_days <= 7   THEN 1 ELSE 0 END)        AS n_before_7d,
        SUM(CASE WHEN closest_before_days <= 14  THEN 1 ELSE 0 END)        AS n_before_14d,
        SUM(CASE WHEN closest_before_days <= 30  THEN 1 ELSE 0 END)        AS n_before_30d,
        SUM(CASE WHEN closest_before_days <= 90  THEN 1 ELSE 0 END)        AS n_before_90d,
        SUM(CASE WHEN has_day0 = 1               THEN 1 ELSE 0 END)        AS n_day0,
        SUM(CASE WHEN closest_after_days <= 7    THEN 1 ELSE 0 END)        AS n_after_7d,
        SUM(CASE WHEN closest_after_days <= 14   THEN 1 ELSE 0 END)        AS n_after_14d,
        SUM(CASE WHEN closest_after_days <= 30   THEN 1 ELSE 0 END)        AS n_after_30d,
        SUM(CASE WHEN closest_after_days <= 90   THEN 1 ELSE 0 END)        AS n_after_90d,
        SUM(CASE WHEN has_l01_ever = 1           THEN 1 ELSE 0 END)        AS n_ever
    FROM joined
    GROUP BY root_concept_id
)
SELECT
    a.root_concept_id,
    CASE WHEN a.n_with_proc  > 0 AND a.n_with_proc  <= @min_cell_count THEN -@min_cell_count ELSE a.n_with_proc  END AS n_patients_with_procedure,
    CASE WHEN a.n_before_7d  > 0 AND a.n_before_7d  <= @min_cell_count THEN -@min_cell_count ELSE a.n_before_7d  END AS n_drugexp_le7d_before,
    CASE WHEN a.n_before_14d > 0 AND a.n_before_14d <= @min_cell_count THEN -@min_cell_count ELSE a.n_before_14d END AS n_drugexp_le14d_before,
    CASE WHEN a.n_before_30d > 0 AND a.n_before_30d <= @min_cell_count THEN -@min_cell_count ELSE a.n_before_30d END AS n_drugexp_le30d_before,
    CASE WHEN a.n_before_90d > 0 AND a.n_before_90d <= @min_cell_count THEN -@min_cell_count ELSE a.n_before_90d END AS n_drugexp_le90d_before,
    CASE WHEN a.n_day0       > 0 AND a.n_day0       <= @min_cell_count THEN -@min_cell_count ELSE a.n_day0       END AS n_drugexp_on_day0,
    CASE WHEN a.n_after_7d   > 0 AND a.n_after_7d   <= @min_cell_count THEN -@min_cell_count ELSE a.n_after_7d   END AS n_drugexp_le7d_after,
    CASE WHEN a.n_after_14d  > 0 AND a.n_after_14d  <= @min_cell_count THEN -@min_cell_count ELSE a.n_after_14d  END AS n_drugexp_le14d_after,
    CASE WHEN a.n_after_30d  > 0 AND a.n_after_30d  <= @min_cell_count THEN -@min_cell_count ELSE a.n_after_30d  END AS n_drugexp_le30d_after,
    CASE WHEN a.n_after_90d  > 0 AND a.n_after_90d  <= @min_cell_count THEN -@min_cell_count ELSE a.n_after_90d  END AS n_drugexp_le90d_after,
    CASE WHEN a.n_ever       > 0 AND a.n_ever       <= @min_cell_count THEN -@min_cell_count ELSE a.n_ever       END AS n_drugexp_ever
FROM agg a
ORDER BY a.n_with_proc DESC, a.root_concept_id
;
