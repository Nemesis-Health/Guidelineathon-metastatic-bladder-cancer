/*
============================================================
 OMOP Characterization - SQL Server Base (SqlRender-ready)
  v2: dual concept-level event-code timing (FIRST + CLOSEST)
============================================================

UC ANCHOR VARIANT
-----------------
DX anchor follows cohort_definitions/UC.json concept set id 7
("UC - Malignant neoplasm"), built from #dx_anchor_include / #dx_anchor_exclude
and @cdm_database_schema.concept_ancestor.

Purpose
-------
Same cohort and pairwise timing as `v1_sqlserver_base_uc_malignant_neoplasm.sql`, but **concept-level**
event code timing exports **both** rules in one run (no `@event_code_timing_uses_closest`):
  - **FIRST:** earliest `event_date` per (anchor, family, concept, patient) [within TIME_RELATIVE stratum when applicable].
  - **CLOSEST:** minimum |days_diff| to anchor, tie-break `event_date`.

Final CSV columns include `lq_days_first` / `median_days_first` / `uq_days_first` and
`lq_days_closest` / `median_days_closest` / `uq_days_closest`. Legacy `lq_days` / `median_days` / `uq_days`
duplicate the **FIRST** triple for backward compatibility with older report code.

How to use
----------
1) Set @cdm_database_schema (or render via SqlRender).
2) Set privacy threshold below (small-cell suppression).
3) Edit concept-set INSERT blocks at top.
4) Run in SQL Server (or render+translate with SqlRender for target DB).
5) Export result sets from final SELECT statements (10 in this file, including per-concept anchor DX patient / patient-day counts).

Cross-dialect / SqlRender
-------------------------
- **Parameters (render):** `@cdm_database_schema`, `@min_cell_count` only.
- **Portable patterns:** same as v1 (SMALLINT, ordered-set percentiles + DISTINCT, etc.).
- **Validate:** `Rscript scripts/validate_characterization_sqlrender.R data_characterization/sql_versions/v2_sqlserver_base_uc_malignant_neoplasm_dual_event_code_timing.sql`
*/

------------------------------------------------------------
-- PARAMETERS (SqlRender style)
------------------------------------------------------------
-- Example:
-- DECLARE @cdm_database_schema VARCHAR(100) = 'cdm';

------------------------------------------------------------
-- PRIVACY CONTROLS
------------------------------------------------------------
-- Suppress small cells <= this threshold in final outputs.
-- SqlRender parameter (set during render, e.g. min_cell_count = 0).
-- Do not declare @min_cell_count here because SqlRender inlines @tokens.

------------------------------------------------------------
-- A) ANCHOR DIAGNOSIS CONCEPTS (DX)
-- Anchor cohort = patients with any of these condition_concept_id values
-- Source: cohort_definitions/UC.json — ConceptSets id 7 "UC - Malignant neoplasm"
-- Expanded with concept_ancestor (includeDescendants / isExcluded match Atlas).
------------------------------------------------------------
DROP TABLE IF EXISTS #dx_anchor_include;
CREATE TABLE #dx_anchor_include (
    concept_id BIGINT NOT NULL,
    include_descendants SMALLINT NOT NULL
);

INSERT INTO #dx_anchor_include (concept_id, include_descendants) VALUES
    (197508, 1),      -- Malignant neoplasm of urinary bladder
    (4181357, 1),     -- Malignant tumor of renal pelvis
    (4177230, 1),     -- Malignant tumor of urethra
    (37163176, 1),    -- Transitional cell carcinoma of upper urinary tract
    (4178972, 1),     -- Malignant tumor of ureter
    (4091486, 0),     -- Malignant neoplasm of overlapping sites of urinary organs
    (44501785, 0),    -- Transitional cell carcinoma, NOS, of urinary system, NOS (ICDO3)
    (37110270, 1)     -- Primary urothelial carcinoma of overlapping sites of urinary organs
;

DROP TABLE IF EXISTS #dx_anchor_exclude;
CREATE TABLE #dx_anchor_exclude (
    concept_id BIGINT NOT NULL,
    include_descendants SMALLINT NOT NULL
);

INSERT INTO #dx_anchor_exclude (concept_id, include_descendants) VALUES
    (4280899, 1),
    (4289374, 1),
    (4280900, 1),
    (4283614, 1),
    (4289097, 1),
    (4280901, 1),
    (4289376, 1),
    (4280897, 1),
    (4200889, 1);

DROP TABLE IF EXISTS #dx_anchor_concepts;
CREATE TABLE #dx_anchor_concepts (
    concept_id BIGINT
);

INSERT INTO #dx_anchor_concepts (concept_id)
SELECT DISTINCT ca.descendant_concept_id
FROM #dx_anchor_include i
JOIN @cdm_database_schema.concept_ancestor ca
  ON ca.ancestor_concept_id = i.concept_id
 AND (i.include_descendants = 1 OR ca.descendant_concept_id = i.concept_id);

DELETE FROM #dx_anchor_concepts
WHERE EXISTS (
    SELECT 1
    FROM #dx_anchor_exclude e
    JOIN @cdm_database_schema.concept_ancestor ca
      ON ca.ancestor_concept_id = e.concept_id
     AND #dx_anchor_concepts.concept_id = ca.descendant_concept_id
     AND (e.include_descendants = 1 OR ca.descendant_concept_id = e.concept_id)
);



------------------------------------------------------------
-- B) OTHER GENERALIZED CANCER DX CONCEPTS (GDX)
-- Default: distinct ancestors of DX anchor concepts, excluding anchor DX concepts themselves,
-- but constrained to descendants of 443392 (Malignant neoplastic disease) to avoid overly-broad ancestors.
-- (concept_ancestor includes self-links; we only want broader/generalized codes).
------------------------------------------------------------
DROP TABLE IF EXISTS #gen_cancer_concepts;
CREATE TABLE #gen_cancer_concepts (
    concept_id BIGINT
);

INSERT INTO #gen_cancer_concepts (concept_id)
SELECT DISTINCT ca.ancestor_concept_id
FROM @cdm_database_schema.concept_ancestor ca
JOIN #dx_anchor_concepts d
  ON ca.descendant_concept_id = d.concept_id
JOIN @cdm_database_schema.concept_ancestor malign
  ON malign.ancestor_concept_id = 443392
 AND malign.descendant_concept_id = ca.ancestor_concept_id
WHERE NOT EXISTS (
    SELECT 1
    FROM #dx_anchor_concepts dx
    WHERE dx.concept_id = ca.ancestor_concept_id
)
;


------------------------------------------------------------
-- C) OTHER CANCER DIAGNOSIS CONCEPTS (ODX)
-- Default: descendants of 443392 excluding DX + GDX sets.
------------------------------------------------------------
DROP TABLE IF EXISTS #other_dx_ancestor_concepts;
CREATE TABLE #other_dx_ancestor_concepts (
    ancestor_concept_id BIGINT
);

-- EDIT THIS LIST
INSERT INTO #other_dx_ancestor_concepts (ancestor_concept_id)
VALUES
    (443392) -- Malignant neoplastic disease
;

DROP TABLE IF EXISTS #other_dx_concepts;
CREATE TABLE #other_dx_concepts (
    concept_id BIGINT
);

INSERT INTO #other_dx_concepts (concept_id)
SELECT DISTINCT ca.descendant_concept_id
FROM @cdm_database_schema.concept_ancestor ca
JOIN #other_dx_ancestor_concepts a
  ON ca.ancestor_concept_id = a.ancestor_concept_id
LEFT JOIN #dx_anchor_concepts dx
  ON dx.concept_id = ca.descendant_concept_id
LEFT JOIN #gen_cancer_concepts gdx
  ON gdx.concept_id = ca.descendant_concept_id
WHERE dx.concept_id IS NULL
  AND gdx.concept_id IS NULL
;


------------------------------------------------------------
-- D) METASTASIS CONCEPTS (MEASUREMENT)
-- Define via ancestor IDs (descendants pulled from concept_ancestor)
------------------------------------------------------------
DROP TABLE IF EXISTS #met_ancestor_concepts;
CREATE TABLE #met_ancestor_concepts (
    ancestor_concept_id BIGINT
);

-- Default: concept set "Secondary malignancy" from cohort_definitions/Target_Cohort_2B.json
INSERT INTO #met_ancestor_concepts (ancestor_concept_id)
VALUES
    (1633308),  -- AJCC/UICC Stage 4
    (1635142),  -- AJCC/UICC M1 Category
    (36769180)  -- Metastasis
;

DROP TABLE IF EXISTS #met_concepts;
CREATE TABLE #met_concepts (
    concept_id BIGINT
);

INSERT INTO #met_concepts (concept_id)
SELECT DISTINCT ca.descendant_concept_id
FROM @cdm_database_schema.concept_ancestor ca
JOIN #met_ancestor_concepts a
  ON ca.ancestor_concept_id = a.ancestor_concept_id
;


------------------------------------------------------------
-- E) L01 TREATMENT CONCEPTS (DRUG_EXPOSURE)
------------------------------------------------------------
DROP TABLE IF EXISTS #l01_ancestor_concepts;
CREATE TABLE #l01_ancestor_concepts (
    ancestor_concept_id BIGINT
);

-- EDIT THIS LIST
INSERT INTO #l01_ancestor_concepts (ancestor_concept_id)
VALUES
    (21601387)
;

DROP TABLE IF EXISTS #l01_concepts;
CREATE TABLE #l01_concepts (
    concept_id BIGINT
);

INSERT INTO #l01_concepts (concept_id)
SELECT DISTINCT ca.descendant_concept_id
FROM @cdm_database_schema.concept_ancestor ca
JOIN #l01_ancestor_concepts a
  ON ca.ancestor_concept_id = a.ancestor_concept_id
;


------------------------------------------------------------
-- E2) DRUG THERAPY PROCEDURE CONCEPTS (PROCEDURE_OCCURRENCE)
--     Added for Analysis G. Antineoplastic treatment recorded as a procedure
--     rather than a drug_exposure. Four Drug Therapy procedure roots and their
--     descendants. Same ancestor-then-descendants build as the L01 concept set
--     in section E: #dtp_ancestor_concepts holds the roots; #dtp_concepts expands
--     to descendants via concept_ancestor (which includes each root itself at
--     level 0, so the roots are in #dtp_concepts too). This is the only concept
--     set that reads procedure_occurrence.
--
--     #dtp_concepts additionally carries the root each descendant maps to
--     (root_concept_id), so Analysis G can report per category (Chemotherapy /
--     Immunological therapy / Targeted chemotherapy for cancer / Hormone therapy).
--     This is a small extension of the plain concept-id list used for L01; it is
--     needed because G's Part 1b and Part 3 are per-concept. A descendant that
--     falls under more than one root appears once per root, so a patient can be
--     counted under more than one category and the per-category counts overlap
--     and need not sum, matching the approved mock.
--
--     No procedure event table is materialised here. Like Analyses D and H, G's
--     denominator is the full ungated population (all patients who carry a MET
--     code, or all patients who carry the procedure), so the G chunks read
--     procedure_occurrence directly rather than through a DX-cohort-gated event
--     table (the #*_events tables in section F are all gated to #anchor_person).
------------------------------------------------------------
DROP TABLE IF EXISTS #dtp_ancestor_concepts;
CREATE TABLE #dtp_ancestor_concepts (
    ancestor_concept_id BIGINT
);

-- EDIT THIS LIST
-- Chemotherapy 4273629, Immunological therapy 4295112,
-- Targeted chemotherapy for cancer 37158316, Hormone therapy 4061650.
INSERT INTO #dtp_ancestor_concepts (ancestor_concept_id)
VALUES
    (4273629),
    (4295112),
    (37158316),
    (4061650)
;

DROP TABLE IF EXISTS #dtp_concepts;
CREATE TABLE #dtp_concepts (
    concept_id      BIGINT,
    root_concept_id BIGINT
);

INSERT INTO #dtp_concepts (concept_id, root_concept_id)
SELECT DISTINCT ca.descendant_concept_id, a.ancestor_concept_id
FROM @cdm_database_schema.concept_ancestor ca
JOIN #dtp_ancestor_concepts a
  ON ca.ancestor_concept_id = a.ancestor_concept_id
;


------------------------------------------------------------
-- F) EVENT TABLES
------------------------------------------------------------
DROP TABLE IF EXISTS #dx_events;
CREATE TABLE #dx_events (
    person_id BIGINT,
    event_date DATE,
    concept_id BIGINT
);

INSERT INTO #dx_events (person_id, event_date, concept_id)
SELECT
    co.person_id,
    co.condition_start_date,
    co.condition_concept_id
FROM @cdm_database_schema.condition_occurrence co
JOIN #dx_anchor_concepts d
  ON co.condition_concept_id = d.concept_id
;

-- Distinct anchor cohort persons; limits later F) pulls to rows that downstream joins to #cohort use anyway.
DROP TABLE IF EXISTS #anchor_person;
CREATE TABLE #anchor_person (
    person_id BIGINT
);

INSERT INTO #anchor_person (person_id)
SELECT DISTINCT person_id
FROM #dx_events
;

DROP TABLE IF EXISTS #other_dx_events;
CREATE TABLE #other_dx_events (
    person_id BIGINT,
    event_date DATE,
    concept_id BIGINT
);

INSERT INTO #other_dx_events (person_id, event_date, concept_id)
SELECT
    co.person_id,
    co.condition_start_date,
    co.condition_concept_id
FROM @cdm_database_schema.condition_occurrence co
JOIN #anchor_person ap
  ON co.person_id = ap.person_id
JOIN #other_dx_concepts d
  ON co.condition_concept_id = d.concept_id
;

DROP TABLE IF EXISTS #gen_cancer_events;
CREATE TABLE #gen_cancer_events (
    person_id BIGINT,
    event_date DATE,
    concept_id BIGINT
);

INSERT INTO #gen_cancer_events (person_id, event_date, concept_id)
SELECT
    co.person_id,
    co.condition_start_date,
    co.condition_concept_id
FROM @cdm_database_schema.condition_occurrence co
JOIN #anchor_person ap
  ON co.person_id = ap.person_id
JOIN #gen_cancer_concepts g
  ON co.condition_concept_id = g.concept_id
;

DROP TABLE IF EXISTS #met_events;
CREATE TABLE #met_events (
    person_id BIGINT,
    event_date DATE,
    concept_id BIGINT
);

INSERT INTO #met_events (person_id, event_date, concept_id)
SELECT
    m.person_id,
    m.measurement_date,
    m.measurement_concept_id
FROM @cdm_database_schema.measurement m
JOIN #anchor_person ap
  ON m.person_id = ap.person_id
JOIN #met_concepts mc
  ON m.measurement_concept_id = mc.concept_id
;

DROP TABLE IF EXISTS #l01_events;
CREATE TABLE #l01_events (
    person_id BIGINT,
    event_date DATE,
    concept_id BIGINT
);

INSERT INTO #l01_events (person_id, event_date, concept_id)
SELECT
    de.person_id,
    de.drug_exposure_start_date,
    de.drug_concept_id
FROM @cdm_database_schema.drug_exposure de
JOIN #anchor_person ap
  ON de.person_id = ap.person_id
JOIN #l01_concepts l
  ON de.drug_concept_id = l.concept_id
;

-- Ingredient-level L01 events used for concept-level code counts/timing.
DROP TABLE IF EXISTS #l01_ingredient_events;
CREATE TABLE #l01_ingredient_events (
    person_id BIGINT,
    event_date DATE,
    concept_id BIGINT
);

INSERT INTO #l01_ingredient_events (person_id, event_date, concept_id)
SELECT DISTINCT
    de.person_id,
    de.drug_exposure_start_date,
    ca.ancestor_concept_id
FROM @cdm_database_schema.drug_exposure de
JOIN #anchor_person ap
  ON de.person_id = ap.person_id
JOIN #l01_concepts l
  ON de.drug_concept_id = l.concept_id
JOIN @cdm_database_schema.concept_ancestor ca
  ON ca.descendant_concept_id = de.drug_concept_id
JOIN @cdm_database_schema.concept ing
  ON ing.concept_id = ca.ancestor_concept_id
 AND ing.concept_class_id = 'Ingredient'
;


------------------------------------------------------------
-- G) COHORT ANCHOR + SUMMARIES
------------------------------------------------------------

-- Track attrition: count all patients with a qualifying DX before the
-- obs-period filter so the report can show how many were excluded.
DROP TABLE IF EXISTS #cohort_attrition;
CREATE TABLE #cohort_attrition (
    stage      VARCHAR(50),
    n_patients INT
);

INSERT INTO #cohort_attrition (stage, n_patients)
SELECT 'dx_any', COUNT(DISTINCT person_id) FROM #dx_events;

DROP TABLE IF EXISTS #cohort;
CREATE TABLE #cohort (
    person_id BIGINT,
    index_date DATE
);

-- Index date = earliest qualifying DX that falls within an observation period.
-- Patients with no obs-period-covered DX are excluded entirely.
INSERT INTO #cohort (person_id, index_date)
SELECT
    dx.person_id,
    MIN(dx.event_date) AS index_date
FROM #dx_events dx
INNER JOIN @cdm_database_schema.observation_period op
    ON  op.person_id = dx.person_id
    AND dx.event_date BETWEEN op.observation_period_start_date
                          AND op.observation_period_end_date
GROUP BY dx.person_id
;

INSERT INTO #cohort_attrition (stage, n_patients)
SELECT 'dx_in_obs', COUNT(*) FROM #cohort;

DROP TABLE IF EXISTS #dx_summary;
CREATE TABLE #dx_summary (
    person_id BIGINT,
    n_dx_records INT,
    n_dx_codes INT
);

INSERT INTO #dx_summary (person_id, n_dx_records, n_dx_codes)
SELECT
    e.person_id,
    COUNT(*) AS n_dx_records,
    COUNT(DISTINCT e.concept_id) AS n_dx_codes
FROM #dx_events e
JOIN #cohort c
  ON e.person_id = c.person_id
GROUP BY e.person_id
;

DROP TABLE IF EXISTS #other_dx_summary;
CREATE TABLE #other_dx_summary (
    person_id BIGINT,
    first_other_dx_date DATE,
    n_other_dx_records INT,
    n_other_dx_codes INT
);

INSERT INTO #other_dx_summary (person_id, first_other_dx_date, n_other_dx_records, n_other_dx_codes)
SELECT
    e.person_id,
    MIN(e.event_date) AS first_other_dx_date,
    COUNT(*) AS n_other_dx_records,
    COUNT(DISTINCT e.concept_id) AS n_other_dx_codes
FROM #other_dx_events e
JOIN #cohort c
  ON e.person_id = c.person_id
GROUP BY e.person_id
;

DROP TABLE IF EXISTS #gen_cancer_summary;
CREATE TABLE #gen_cancer_summary (
    person_id BIGINT,
    first_gen_cancer_date DATE,
    n_gen_cancer_records INT,
    n_gen_cancer_codes INT
);

INSERT INTO #gen_cancer_summary (person_id, first_gen_cancer_date, n_gen_cancer_records, n_gen_cancer_codes)
SELECT
    e.person_id,
    MIN(e.event_date) AS first_gen_cancer_date,
    COUNT(*) AS n_gen_cancer_records,
    COUNT(DISTINCT e.concept_id) AS n_gen_cancer_codes
FROM #gen_cancer_events e
JOIN #cohort c
  ON e.person_id = c.person_id
GROUP BY e.person_id
;

DROP TABLE IF EXISTS #met_summary;
CREATE TABLE #met_summary (
    person_id BIGINT,
    first_met_date DATE,
    n_met_records INT
);

INSERT INTO #met_summary (person_id, first_met_date, n_met_records)
SELECT
    e.person_id,
    MIN(e.event_date) AS first_met_date,
    COUNT(*) AS n_met_records
FROM #met_events e
JOIN #cohort c
  ON e.person_id = c.person_id
GROUP BY e.person_id
;

DROP TABLE IF EXISTS #l01_summary;
CREATE TABLE #l01_summary (
    person_id BIGINT,
    first_l01_date DATE,
    n_l01_exposures INT
);

INSERT INTO #l01_summary (person_id, first_l01_date, n_l01_exposures)
SELECT
    e.person_id,
    MIN(e.event_date) AS first_l01_date,
    COUNT(*) AS n_l01_exposures
FROM #l01_events e
JOIN #cohort c
  ON e.person_id = c.person_id
GROUP BY e.person_id
;


-- H) EVENT CODE COUNTS (single table across event families)
------------------------------------------------------------
DROP TABLE IF EXISTS #event_code_counts;
CREATE TABLE #event_code_counts (
    anchor_event VARCHAR(20), -- INDEX or FIRST_MET
    event_family VARCHAR(20),
    concept_id BIGINT,
    n_records INT,
    n_patients INT
);

INSERT INTO #event_code_counts (anchor_event, event_family, concept_id, n_records, n_patients)
SELECT 'INDEX', 'DX', concept_id, COUNT(*), COUNT(DISTINCT person_id)
FROM #dx_events
WHERE person_id IN (SELECT person_id FROM #cohort)
GROUP BY concept_id
UNION ALL
SELECT 'INDEX', 'ODX', concept_id, COUNT(*), COUNT(DISTINCT person_id)
FROM #other_dx_events
WHERE person_id IN (SELECT person_id FROM #cohort)
GROUP BY concept_id
UNION ALL
SELECT 'INDEX', 'GDX', concept_id, COUNT(*), COUNT(DISTINCT person_id)
FROM #gen_cancer_events
WHERE person_id IN (SELECT person_id FROM #cohort)
GROUP BY concept_id
UNION ALL
SELECT 'INDEX', 'MET', concept_id, COUNT(*), COUNT(DISTINCT person_id)
FROM #met_events
WHERE person_id IN (SELECT person_id FROM #cohort)
GROUP BY concept_id
UNION ALL
SELECT 'INDEX', 'L01', concept_id, COUNT(*), COUNT(DISTINCT person_id)
FROM #l01_ingredient_events
WHERE person_id IN (SELECT person_id FROM #cohort)
GROUP BY concept_id
UNION ALL
SELECT 'FIRST_MET', 'DX', concept_id, COUNT(*), COUNT(DISTINCT e.person_id)
FROM #dx_events e
JOIN #met_summary ms
  ON e.person_id = ms.person_id
WHERE ms.first_met_date IS NOT NULL
GROUP BY concept_id
UNION ALL
SELECT 'FIRST_MET', 'ODX', concept_id, COUNT(*), COUNT(DISTINCT e.person_id)
FROM #other_dx_events e
JOIN #met_summary ms
  ON e.person_id = ms.person_id
WHERE ms.first_met_date IS NOT NULL
GROUP BY concept_id
UNION ALL
SELECT 'FIRST_MET', 'GDX', concept_id, COUNT(*), COUNT(DISTINCT e.person_id)
FROM #gen_cancer_events e
JOIN #met_summary ms
  ON e.person_id = ms.person_id
WHERE ms.first_met_date IS NOT NULL
GROUP BY concept_id
UNION ALL
SELECT 'FIRST_MET', 'MET', concept_id, COUNT(*), COUNT(DISTINCT e.person_id)
FROM #met_events e
JOIN #met_summary ms
  ON e.person_id = ms.person_id
WHERE ms.first_met_date IS NOT NULL
GROUP BY concept_id
UNION ALL
SELECT 'FIRST_MET', 'L01', concept_id, COUNT(*), COUNT(DISTINCT e.person_id)
FROM #l01_ingredient_events e
JOIN #met_summary ms
  ON e.person_id = ms.person_id
WHERE ms.first_met_date IS NOT NULL
GROUP BY concept_id
;

DROP TABLE IF EXISTS #event_code_counts_before_after;
CREATE TABLE #event_code_counts_before_after (
    anchor_event VARCHAR(20), -- INDEX
    event_family VARCHAR(20),
    time_relative VARCHAR(10), -- BEFORE or AFTER (relative to index_date)
    concept_id BIGINT,
    n_records INT,
    n_patients INT
);

INSERT INTO #event_code_counts_before_after (anchor_event, event_family, time_relative, concept_id, n_records, n_patients)
SELECT 'INDEX',
       'DX',
       CASE WHEN DATEDIFF(DAY, c.index_date, e.event_date) < 0 THEN 'BEFORE' ELSE 'AFTER' END AS time_relative,
       e.concept_id,
       COUNT(*) AS n_records,
       COUNT(DISTINCT e.person_id) AS n_patients
FROM #dx_events e
JOIN #cohort c
  ON e.person_id = c.person_id
GROUP BY
    CASE WHEN DATEDIFF(DAY, c.index_date, e.event_date) < 0 THEN 'BEFORE' ELSE 'AFTER' END,
    e.concept_id
UNION ALL
SELECT 'INDEX',
       'ODX',
       CASE WHEN DATEDIFF(DAY, c.index_date, e.event_date) < 0 THEN 'BEFORE' ELSE 'AFTER' END,
       e.concept_id,
       COUNT(*),
       COUNT(DISTINCT e.person_id)
FROM #other_dx_events e
JOIN #cohort c
  ON e.person_id = c.person_id
GROUP BY
    CASE WHEN DATEDIFF(DAY, c.index_date, e.event_date) < 0 THEN 'BEFORE' ELSE 'AFTER' END,
    e.concept_id
UNION ALL
SELECT 'INDEX',
       'GDX',
       CASE WHEN DATEDIFF(DAY, c.index_date, e.event_date) < 0 THEN 'BEFORE' ELSE 'AFTER' END,
       e.concept_id,
       COUNT(*),
       COUNT(DISTINCT e.person_id)
FROM #gen_cancer_events e
JOIN #cohort c
  ON e.person_id = c.person_id
GROUP BY
    CASE WHEN DATEDIFF(DAY, c.index_date, e.event_date) < 0 THEN 'BEFORE' ELSE 'AFTER' END,
    e.concept_id
UNION ALL
SELECT 'INDEX',
       'MET',
       CASE WHEN DATEDIFF(DAY, c.index_date, e.event_date) < 0 THEN 'BEFORE' ELSE 'AFTER' END,
       e.concept_id,
       COUNT(*),
       COUNT(DISTINCT e.person_id)
FROM #met_events e
JOIN #cohort c
  ON e.person_id = c.person_id
GROUP BY
    CASE WHEN DATEDIFF(DAY, c.index_date, e.event_date) < 0 THEN 'BEFORE' ELSE 'AFTER' END,
    e.concept_id
UNION ALL
SELECT 'INDEX',
       'L01',
       CASE WHEN DATEDIFF(DAY, c.index_date, e.event_date) < 0 THEN 'BEFORE' ELSE 'AFTER' END,
       e.concept_id,
       COUNT(*),
       COUNT(DISTINCT e.person_id)
FROM #l01_ingredient_events e
JOIN #cohort c
  ON e.person_id = c.person_id
GROUP BY
    CASE WHEN DATEDIFF(DAY, c.index_date, e.event_date) < 0 THEN 'BEFORE' ELSE 'AFTER' END,
    e.concept_id
;

DROP TABLE IF EXISTS #event_code_counts_before_after_first_met;
CREATE TABLE #event_code_counts_before_after_first_met (
    anchor_event VARCHAR(20), -- FIRST_MET
    event_family VARCHAR(20),
    time_relative VARCHAR(10), -- BEFORE or AFTER (relative to first_met_date)
    concept_id BIGINT,
    n_records INT,
    n_patients INT
);

INSERT INTO #event_code_counts_before_after_first_met (anchor_event, event_family, time_relative, concept_id, n_records, n_patients)
SELECT 'FIRST_MET',
       'DX',
       CASE WHEN DATEDIFF(DAY, ms.first_met_date, e.event_date) < 0 THEN 'BEFORE' ELSE 'AFTER' END AS time_relative,
       e.concept_id,
       COUNT(*) AS n_records,
       COUNT(DISTINCT e.person_id) AS n_patients
FROM #dx_events e
JOIN #met_summary ms
  ON e.person_id = ms.person_id
WHERE ms.first_met_date IS NOT NULL
GROUP BY
    CASE WHEN DATEDIFF(DAY, ms.first_met_date, e.event_date) < 0 THEN 'BEFORE' ELSE 'AFTER' END,
    e.concept_id
UNION ALL
SELECT 'FIRST_MET',
       'ODX',
       CASE WHEN DATEDIFF(DAY, ms.first_met_date, e.event_date) < 0 THEN 'BEFORE' ELSE 'AFTER' END,
       e.concept_id,
       COUNT(*),
       COUNT(DISTINCT e.person_id)
FROM #other_dx_events e
JOIN #met_summary ms
  ON e.person_id = ms.person_id
WHERE ms.first_met_date IS NOT NULL
GROUP BY
    CASE WHEN DATEDIFF(DAY, ms.first_met_date, e.event_date) < 0 THEN 'BEFORE' ELSE 'AFTER' END,
    e.concept_id
UNION ALL
SELECT 'FIRST_MET',
       'GDX',
       CASE WHEN DATEDIFF(DAY, ms.first_met_date, e.event_date) < 0 THEN 'BEFORE' ELSE 'AFTER' END,
       e.concept_id,
       COUNT(*),
       COUNT(DISTINCT e.person_id)
FROM #gen_cancer_events e
JOIN #met_summary ms
  ON e.person_id = ms.person_id
WHERE ms.first_met_date IS NOT NULL
GROUP BY
    CASE WHEN DATEDIFF(DAY, ms.first_met_date, e.event_date) < 0 THEN 'BEFORE' ELSE 'AFTER' END,
    e.concept_id
UNION ALL
SELECT 'FIRST_MET',
       'MET',
       CASE WHEN DATEDIFF(DAY, ms.first_met_date, e.event_date) < 0 THEN 'BEFORE' ELSE 'AFTER' END,
       e.concept_id,
       COUNT(*),
       COUNT(DISTINCT e.person_id)
FROM #met_events e
JOIN #met_summary ms
  ON e.person_id = ms.person_id
WHERE ms.first_met_date IS NOT NULL
GROUP BY
    CASE WHEN DATEDIFF(DAY, ms.first_met_date, e.event_date) < 0 THEN 'BEFORE' ELSE 'AFTER' END,
    e.concept_id
UNION ALL
SELECT 'FIRST_MET',
       'L01',
       CASE WHEN DATEDIFF(DAY, ms.first_met_date, e.event_date) < 0 THEN 'BEFORE' ELSE 'AFTER' END,
       e.concept_id,
       COUNT(*),
       COUNT(DISTINCT e.person_id)
FROM #l01_ingredient_events e
JOIN #met_summary ms
  ON e.person_id = ms.person_id
WHERE ms.first_met_date IS NOT NULL
GROUP BY
    CASE WHEN DATEDIFF(DAY, ms.first_met_date, e.event_date) < 0 THEN 'BEFORE' ELSE 'AFTER' END,
    e.concept_id
;

DROP TABLE IF EXISTS #event_code_all_events;
CREATE TABLE #event_code_all_events (
    anchor_event VARCHAR(20),
    event_family VARCHAR(20),
    concept_id BIGINT,
    person_id BIGINT,
    days_diff INT,
    event_date DATE
);

INSERT INTO #event_code_all_events (
    anchor_event, event_family, concept_id, person_id, days_diff, event_date
)
SELECT 'INDEX' AS anchor_event, 'DX' AS event_family, e.concept_id, e.person_id, DATEDIFF(DAY, c.index_date, e.event_date) AS days_diff, e.event_date
FROM #dx_events e
JOIN #cohort c ON e.person_id = c.person_id
UNION ALL
SELECT 'INDEX', 'ODX', e.concept_id, e.person_id, DATEDIFF(DAY, c.index_date, e.event_date), e.event_date
FROM #other_dx_events e
JOIN #cohort c ON e.person_id = c.person_id
UNION ALL
SELECT 'INDEX', 'GDX', e.concept_id, e.person_id, DATEDIFF(DAY, c.index_date, e.event_date), e.event_date
FROM #gen_cancer_events e
JOIN #cohort c ON e.person_id = c.person_id
UNION ALL
SELECT 'INDEX', 'MET', e.concept_id, e.person_id, DATEDIFF(DAY, c.index_date, e.event_date), e.event_date
FROM #met_events e
JOIN #cohort c ON e.person_id = c.person_id
UNION ALL
SELECT 'INDEX', 'L01', e.concept_id, e.person_id, DATEDIFF(DAY, c.index_date, e.event_date), e.event_date
FROM #l01_ingredient_events e
JOIN #cohort c ON e.person_id = c.person_id
UNION ALL
SELECT 'FIRST_MET', 'DX', e.concept_id, e.person_id, DATEDIFF(DAY, ms.first_met_date, e.event_date), e.event_date
FROM #dx_events e
JOIN #met_summary ms ON e.person_id = ms.person_id
WHERE ms.first_met_date IS NOT NULL
UNION ALL
SELECT 'FIRST_MET', 'ODX', e.concept_id, e.person_id, DATEDIFF(DAY, ms.first_met_date, e.event_date), e.event_date
FROM #other_dx_events e
JOIN #met_summary ms ON e.person_id = ms.person_id
WHERE ms.first_met_date IS NOT NULL
UNION ALL
SELECT 'FIRST_MET', 'GDX', e.concept_id, e.person_id, DATEDIFF(DAY, ms.first_met_date, e.event_date), e.event_date
FROM #gen_cancer_events e
JOIN #met_summary ms ON e.person_id = ms.person_id
WHERE ms.first_met_date IS NOT NULL
UNION ALL
SELECT 'FIRST_MET', 'MET', e.concept_id, e.person_id, DATEDIFF(DAY, ms.first_met_date, e.event_date), e.event_date
FROM #met_events e
JOIN #met_summary ms ON e.person_id = ms.person_id
WHERE ms.first_met_date IS NOT NULL
UNION ALL
SELECT 'FIRST_MET', 'L01', e.concept_id, e.person_id, DATEDIFF(DAY, ms.first_met_date, e.event_date), e.event_date
FROM #l01_ingredient_events e
JOIN #met_summary ms ON e.person_id = ms.person_id
WHERE ms.first_met_date IS NOT NULL
;

DROP TABLE IF EXISTS #event_code_patient_chosen_first;
CREATE TABLE #event_code_patient_chosen_first (
    anchor_event VARCHAR(20),
    event_family VARCHAR(20),
    concept_id BIGINT,
    person_id BIGINT,
    days_diff INT
);

INSERT INTO #event_code_patient_chosen_first (anchor_event, event_family, concept_id, person_id, days_diff)
SELECT anchor_event, event_family, concept_id, person_id, days_diff
FROM (
    SELECT
        anchor_event,
        event_family,
        concept_id,
        person_id,
        days_diff,
        ROW_NUMBER() OVER (
            PARTITION BY anchor_event, event_family, concept_id, person_id
            ORDER BY DATEDIFF(DAY, CAST('1900-01-01' AS DATE), event_date) ASC, event_date ASC
        ) AS rn
    FROM #event_code_all_events
) x
WHERE rn = 1
;

DROP TABLE IF EXISTS #event_code_patient_chosen_closest;
CREATE TABLE #event_code_patient_chosen_closest (
    anchor_event VARCHAR(20),
    event_family VARCHAR(20),
    concept_id BIGINT,
    person_id BIGINT,
    days_diff INT
);

INSERT INTO #event_code_patient_chosen_closest (anchor_event, event_family, concept_id, person_id, days_diff)
SELECT anchor_event, event_family, concept_id, person_id, days_diff
FROM (
    SELECT
        anchor_event,
        event_family,
        concept_id,
        person_id,
        days_diff,
        ROW_NUMBER() OVER (
            PARTITION BY anchor_event, event_family, concept_id, person_id
            ORDER BY ABS(days_diff) ASC, event_date ASC
        ) AS rn
    FROM #event_code_all_events
) x
WHERE rn = 1
;

DROP TABLE IF EXISTS #event_code_timing_summary;
CREATE TABLE #event_code_timing_summary (
    anchor_event VARCHAR(20),
    event_family VARCHAR(20),
    concept_id BIGINT,
    n_patients_with_code_timing INT,
    lq_days_first FLOAT,
    median_days_first FLOAT,
    uq_days_first FLOAT,
    lq_days_closest FLOAT,
    median_days_closest FLOAT,
    uq_days_closest FLOAT
);

INSERT INTO #event_code_timing_summary (
    anchor_event,
    event_family,
    concept_id,
    n_patients_with_code_timing,
    lq_days_first,
    median_days_first,
    uq_days_first,
    lq_days_closest,
    median_days_closest,
    uq_days_closest
)
SELECT
    f.anchor_event,
    f.event_family,
    f.concept_id,
    f.n_patients_with_code_timing,
    f.lq_days_first,
    f.median_days_first,
    f.uq_days_first,
    k.lq_days_closest,
    k.median_days_closest,
    k.uq_days_closest
FROM (
    SELECT
        anchor_event,
        event_family,
        concept_id,
        COUNT(*) AS n_patients_with_code_timing,
        MIN(CASE WHEN 4.0 * rn >= cnt THEN CAST(days_diff AS FLOAT) END) AS lq_days_first,
        MIN(CASE WHEN 2.0 * rn >= cnt THEN CAST(days_diff AS FLOAT) END) AS median_days_first,
        MIN(CASE WHEN 4.0 * rn >= 3 * cnt THEN CAST(days_diff AS FLOAT) END) AS uq_days_first
    FROM (
        SELECT anchor_event, event_family, concept_id, days_diff,
            ROW_NUMBER() OVER (PARTITION BY anchor_event, event_family, concept_id ORDER BY days_diff) AS rn,
            COUNT(*)     OVER (PARTITION BY anchor_event, event_family, concept_id)                    AS cnt
        FROM #event_code_patient_chosen_first
    ) x
    GROUP BY anchor_event, event_family, concept_id
) f
INNER JOIN (
    SELECT
        anchor_event,
        event_family,
        concept_id,
        MIN(CASE WHEN 4.0 * rn >= cnt THEN CAST(days_diff AS FLOAT) END) AS lq_days_closest,
        MIN(CASE WHEN 2.0 * rn >= cnt THEN CAST(days_diff AS FLOAT) END) AS median_days_closest,
        MIN(CASE WHEN 4.0 * rn >= 3 * cnt THEN CAST(days_diff AS FLOAT) END) AS uq_days_closest
    FROM (
        SELECT anchor_event, event_family, concept_id, days_diff,
            ROW_NUMBER() OVER (PARTITION BY anchor_event, event_family, concept_id ORDER BY days_diff) AS rn,
            COUNT(*)     OVER (PARTITION BY anchor_event, event_family, concept_id)                    AS cnt
        FROM #event_code_patient_chosen_closest
    ) x
    GROUP BY anchor_event, event_family, concept_id
) k
  ON f.anchor_event = k.anchor_event
 AND f.event_family = k.event_family
 AND f.concept_id = k.concept_id
;

DROP TABLE IF EXISTS #event_code_ba_events;
CREATE TABLE #event_code_ba_events (
    anchor_event VARCHAR(20),
    event_family VARCHAR(20),
    time_relative VARCHAR(10),
    concept_id BIGINT,
    person_id BIGINT,
    days_diff INT,
    event_date DATE
);

INSERT INTO #event_code_ba_events (
    anchor_event, event_family, time_relative, concept_id, person_id, days_diff, event_date
)
SELECT
    anchor_event,
    event_family,
    CASE WHEN days_diff < 0 THEN 'BEFORE' ELSE 'AFTER' END,
    concept_id,
    person_id,
    days_diff,
    event_date
FROM #event_code_all_events
;

DROP TABLE IF EXISTS #event_code_patient_chosen_before_after_first;
CREATE TABLE #event_code_patient_chosen_before_after_first (
    anchor_event VARCHAR(20),
    event_family VARCHAR(20),
    time_relative VARCHAR(10),
    concept_id BIGINT,
    person_id BIGINT,
    days_diff INT
);

INSERT INTO #event_code_patient_chosen_before_after_first (
    anchor_event, event_family, time_relative, concept_id, person_id, days_diff
)
SELECT anchor_event, event_family, time_relative, concept_id, person_id, days_diff
FROM (
    SELECT
        anchor_event,
        event_family,
        time_relative,
        concept_id,
        person_id,
        days_diff,
        ROW_NUMBER() OVER (
            PARTITION BY anchor_event, event_family, time_relative, concept_id, person_id
            ORDER BY DATEDIFF(DAY, CAST('1900-01-01' AS DATE), event_date) ASC, event_date ASC
        ) AS rn
    FROM #event_code_ba_events
) x
WHERE rn = 1
;

DROP TABLE IF EXISTS #event_code_patient_chosen_before_after_closest;
CREATE TABLE #event_code_patient_chosen_before_after_closest (
    anchor_event VARCHAR(20),
    event_family VARCHAR(20),
    time_relative VARCHAR(10),
    concept_id BIGINT,
    person_id BIGINT,
    days_diff INT
);

INSERT INTO #event_code_patient_chosen_before_after_closest (
    anchor_event, event_family, time_relative, concept_id, person_id, days_diff
)
SELECT anchor_event, event_family, time_relative, concept_id, person_id, days_diff
FROM (
    SELECT
        anchor_event,
        event_family,
        time_relative,
        concept_id,
        person_id,
        days_diff,
        ROW_NUMBER() OVER (
            PARTITION BY anchor_event, event_family, time_relative, concept_id, person_id
            ORDER BY ABS(days_diff) ASC, event_date ASC
        ) AS rn
    FROM #event_code_ba_events
) x
WHERE rn = 1
;

DROP TABLE IF EXISTS #event_code_timing_before_after_summary;
CREATE TABLE #event_code_timing_before_after_summary (
    anchor_event VARCHAR(20),
    event_family VARCHAR(20),
    time_relative VARCHAR(10),
    concept_id BIGINT,
    n_patients_with_code_timing INT,
    lq_days_first FLOAT,
    median_days_first FLOAT,
    uq_days_first FLOAT,
    lq_days_closest FLOAT,
    median_days_closest FLOAT,
    uq_days_closest FLOAT
);

INSERT INTO #event_code_timing_before_after_summary (
    anchor_event,
    event_family,
    time_relative,
    concept_id,
    n_patients_with_code_timing,
    lq_days_first,
    median_days_first,
    uq_days_first,
    lq_days_closest,
    median_days_closest,
    uq_days_closest
)
SELECT
    f.anchor_event,
    f.event_family,
    f.time_relative,
    f.concept_id,
    f.n_patients_with_code_timing,
    f.lq_days_first,
    f.median_days_first,
    f.uq_days_first,
    k.lq_days_closest,
    k.median_days_closest,
    k.uq_days_closest
FROM (
    SELECT
        anchor_event,
        event_family,
        time_relative,
        concept_id,
        COUNT(*) AS n_patients_with_code_timing,
        MIN(CASE WHEN 4.0 * rn >= cnt THEN CAST(days_diff AS FLOAT) END) AS lq_days_first,
        MIN(CASE WHEN 2.0 * rn >= cnt THEN CAST(days_diff AS FLOAT) END) AS median_days_first,
        MIN(CASE WHEN 4.0 * rn >= 3 * cnt THEN CAST(days_diff AS FLOAT) END) AS uq_days_first
    FROM (
        SELECT anchor_event, event_family, time_relative, concept_id, days_diff,
            ROW_NUMBER() OVER (PARTITION BY anchor_event, event_family, time_relative, concept_id ORDER BY days_diff) AS rn,
            COUNT(*)     OVER (PARTITION BY anchor_event, event_family, time_relative, concept_id)                    AS cnt
        FROM #event_code_patient_chosen_before_after_first
    ) x
    GROUP BY anchor_event, event_family, time_relative, concept_id
) f
INNER JOIN (
    SELECT
        anchor_event,
        event_family,
        time_relative,
        concept_id,
        MIN(CASE WHEN 4.0 * rn >= cnt THEN CAST(days_diff AS FLOAT) END) AS lq_days_closest,
        MIN(CASE WHEN 2.0 * rn >= cnt THEN CAST(days_diff AS FLOAT) END) AS median_days_closest,
        MIN(CASE WHEN 4.0 * rn >= 3 * cnt THEN CAST(days_diff AS FLOAT) END) AS uq_days_closest
    FROM (
        SELECT anchor_event, event_family, time_relative, concept_id, days_diff,
            ROW_NUMBER() OVER (PARTITION BY anchor_event, event_family, time_relative, concept_id ORDER BY days_diff) AS rn,
            COUNT(*)     OVER (PARTITION BY anchor_event, event_family, time_relative, concept_id)                    AS cnt
        FROM #event_code_patient_chosen_before_after_closest
    ) x
    GROUP BY anchor_event, event_family, time_relative, concept_id
) k
  ON f.anchor_event = k.anchor_event
 AND f.event_family = k.event_family
 AND f.time_relative = k.time_relative
 AND f.concept_id = k.concept_id
;


------------------------------------------------------------
-- I) PATIENT-LEVEL TABLE
------------------------------------------------------------
DROP TABLE IF EXISTS #patient_char;
CREATE TABLE #patient_char (
    person_id BIGINT,
    index_date DATE,
    n_dx_records INT,
    n_dx_codes INT,
    first_other_dx_date DATE,
    n_other_dx_records INT,
    n_other_dx_codes INT,
    first_gen_cancer_date DATE,
    n_gen_cancer_records INT,
    n_gen_cancer_codes INT,
    first_met_date DATE,
    n_met_records INT,
    first_l01_date DATE,
    n_l01_exposures INT,
    days_dx_to_met INT,
    days_dx_to_l01 INT,
    days_dx_to_other_dx INT,
    days_dx_to_gen_cancer INT,
    days_met_to_l01 INT
);

INSERT INTO #patient_char (
    person_id,
    index_date,
    n_dx_records,
    n_dx_codes,
    first_other_dx_date,
    n_other_dx_records,
    n_other_dx_codes,
    first_gen_cancer_date,
    n_gen_cancer_records,
    n_gen_cancer_codes,
    first_met_date,
    n_met_records,
    first_l01_date,
    n_l01_exposures,
    days_dx_to_met,
    days_dx_to_l01,
    days_dx_to_other_dx,
    days_dx_to_gen_cancer,
    days_met_to_l01
)
SELECT
    c.person_id,
    c.index_date,
    COALESCE(dx.n_dx_records, 0),
    COALESCE(dx.n_dx_codes, 0),
    odx.first_other_dx_date,
    COALESCE(odx.n_other_dx_records, 0),
    COALESCE(odx.n_other_dx_codes, 0),
    gdx.first_gen_cancer_date,
    COALESCE(gdx.n_gen_cancer_records, 0),
    COALESCE(gdx.n_gen_cancer_codes, 0),
    mt.first_met_date,
    COALESCE(mt.n_met_records, 0),
    l01.first_l01_date,
    COALESCE(l01.n_l01_exposures, 0),
    CASE WHEN mt.first_met_date IS NOT NULL THEN DATEDIFF(DAY, c.index_date, mt.first_met_date) END AS days_dx_to_met,
    CASE WHEN l01.first_l01_date IS NOT NULL THEN DATEDIFF(DAY, c.index_date, l01.first_l01_date) END AS days_dx_to_l01,
    CASE WHEN odx.first_other_dx_date IS NOT NULL THEN DATEDIFF(DAY, c.index_date, odx.first_other_dx_date) END AS days_dx_to_other_dx,
    CASE WHEN gdx.first_gen_cancer_date IS NOT NULL THEN DATEDIFF(DAY, c.index_date, gdx.first_gen_cancer_date) END AS days_dx_to_gen_cancer,
    CASE WHEN mt.first_met_date IS NOT NULL AND l01.first_l01_date IS NOT NULL THEN DATEDIFF(DAY, mt.first_met_date, l01.first_l01_date) END AS days_met_to_l01
FROM #cohort c
LEFT JOIN #dx_summary dx
       ON c.person_id = dx.person_id
LEFT JOIN #other_dx_summary odx
       ON c.person_id = odx.person_id
LEFT JOIN #gen_cancer_summary gdx
       ON c.person_id = gdx.person_id
LEFT JOIN #met_summary mt
       ON c.person_id = mt.person_id
LEFT JOIN #l01_summary l01
       ON c.person_id = l01.person_id
;


------------------------------------------------------------
-- J) FULL CROSSWISE TIMING PAIRS
------------------------------------------------------------
DROP TABLE IF EXISTS #patient_timing_pairs;
CREATE TABLE #patient_timing_pairs (
    person_id BIGINT,
    from_event VARCHAR(10),
    to_event VARCHAR(10),
    days_diff INT
);

WITH events AS (
    SELECT person_id, 'DX' AS event_name, index_date AS event_date FROM #patient_char
    UNION ALL
    SELECT person_id, 'ODX', first_other_dx_date FROM #patient_char
    UNION ALL
    SELECT person_id, 'GDX', first_gen_cancer_date FROM #patient_char
    UNION ALL
    SELECT person_id, 'MET', first_met_date FROM #patient_char
    UNION ALL
    SELECT person_id, 'L01', first_l01_date FROM #patient_char
)
INSERT INTO #patient_timing_pairs (person_id, from_event, to_event, days_diff)
SELECT
    e1.person_id,
    e1.event_name AS from_event,
    e2.event_name AS to_event,
    DATEDIFF(DAY, e1.event_date, e2.event_date) AS days_diff
FROM events e1
JOIN events e2
  ON e1.person_id = e2.person_id
 AND e1.event_name <> e2.event_name
WHERE e1.event_date IS NOT NULL
  AND e2.event_date IS NOT NULL
;

DROP TABLE IF EXISTS #timing_pair_summary;
CREATE TABLE #timing_pair_summary (
    from_event VARCHAR(10),
    to_event VARCHAR(10),
    n_patients_with_pair INT,
    p05_days FLOAT,
    p10_days FLOAT,
    p20_days FLOAT,
    p25_days FLOAT,
    p30_days FLOAT,
    p40_days FLOAT,
    p50_days FLOAT,
    p60_days FLOAT,
    p70_days FLOAT,
    p75_days FLOAT,
    p80_days FLOAT,
    p90_days FLOAT,
    p95_days FLOAT
);

INSERT INTO #timing_pair_summary (
    from_event,
    to_event,
    n_patients_with_pair,
    p05_days,
    p10_days,
    p20_days,
    p25_days,
    p30_days,
    p40_days,
    p50_days,
    p60_days,
    p70_days,
    p75_days,
    p80_days,
    p90_days,
    p95_days
)
SELECT
    from_event,
    to_event,
    COUNT(*) AS n_patients_with_pair,
    MIN(CASE WHEN 20.0 * rn >= cnt       THEN CAST(days_diff AS FLOAT) END) AS p05_days,
    MIN(CASE WHEN 10.0 * rn >= cnt       THEN CAST(days_diff AS FLOAT) END) AS p10_days,
    MIN(CASE WHEN  5.0 * rn >= cnt       THEN CAST(days_diff AS FLOAT) END) AS p20_days,
    MIN(CASE WHEN  4.0 * rn >= cnt       THEN CAST(days_diff AS FLOAT) END) AS p25_days,
    MIN(CASE WHEN 10.0 * rn >= 3 * cnt  THEN CAST(days_diff AS FLOAT) END) AS p30_days,
    MIN(CASE WHEN  5.0 * rn >= 2 * cnt  THEN CAST(days_diff AS FLOAT) END) AS p40_days,
    MIN(CASE WHEN  2.0 * rn >= cnt       THEN CAST(days_diff AS FLOAT) END) AS p50_days,
    MIN(CASE WHEN  5.0 * rn >= 3 * cnt  THEN CAST(days_diff AS FLOAT) END) AS p60_days,
    MIN(CASE WHEN 10.0 * rn >= 7 * cnt  THEN CAST(days_diff AS FLOAT) END) AS p70_days,
    MIN(CASE WHEN  4.0 * rn >= 3 * cnt  THEN CAST(days_diff AS FLOAT) END) AS p75_days,
    MIN(CASE WHEN  5.0 * rn >= 4 * cnt  THEN CAST(days_diff AS FLOAT) END) AS p80_days,
    MIN(CASE WHEN 10.0 * rn >= 9 * cnt  THEN CAST(days_diff AS FLOAT) END) AS p90_days,
    MIN(CASE WHEN 20.0 * rn >= 19 * cnt THEN CAST(days_diff AS FLOAT) END) AS p95_days
FROM (
    SELECT from_event, to_event, days_diff,
        ROW_NUMBER() OVER (PARTITION BY from_event, to_event ORDER BY days_diff) AS rn,
        COUNT(*)     OVER (PARTITION BY from_event, to_event)                    AS cnt
    FROM #patient_timing_pairs
) x
GROUP BY from_event, to_event
;

DROP TABLE IF EXISTS #all_events_for_pairs;
CREATE TABLE #all_events_for_pairs (
    person_id BIGINT,
    event_family VARCHAR(10),
    event_date DATE
);

INSERT INTO #all_events_for_pairs (person_id, event_family, event_date)
SELECT person_id, 'DX', event_date FROM #dx_events
UNION ALL
SELECT person_id, 'ODX', event_date FROM #other_dx_events
UNION ALL
SELECT person_id, 'GDX', event_date FROM #gen_cancer_events
UNION ALL
SELECT person_id, 'MET', event_date FROM #met_events
UNION ALL
SELECT person_id, 'L01', event_date FROM #l01_events
;

DROP TABLE IF EXISTS #first_event_dates;
CREATE TABLE #first_event_dates (
    person_id BIGINT,
    from_event VARCHAR(10),
    from_first_date DATE
);

INSERT INTO #first_event_dates (person_id, from_event, from_first_date)
SELECT person_id, 'DX', index_date FROM #patient_char
UNION ALL
SELECT person_id, 'ODX', first_other_dx_date FROM #patient_char WHERE first_other_dx_date IS NOT NULL
UNION ALL
SELECT person_id, 'GDX', first_gen_cancer_date FROM #patient_char WHERE first_gen_cancer_date IS NOT NULL
UNION ALL
SELECT person_id, 'MET', first_met_date FROM #patient_char WHERE first_met_date IS NOT NULL
UNION ALL
SELECT person_id, 'L01', first_l01_date FROM #patient_char WHERE first_l01_date IS NOT NULL
;

DROP TABLE IF EXISTS #patient_timing_pairs_first_to_closest;
CREATE TABLE #patient_timing_pairs_first_to_closest (
    person_id BIGINT,
    from_event VARCHAR(10),
    to_event VARCHAR(10),
    days_diff INT
);

WITH ranked AS (
    SELECT
        f.person_id,
        f.from_event,
        a.event_family AS to_event,
        DATEDIFF(DAY, f.from_first_date, a.event_date) AS days_diff,
        ROW_NUMBER() OVER (
            PARTITION BY f.person_id, f.from_event, a.event_family
            ORDER BY ABS(DATEDIFF(DAY, f.from_first_date, a.event_date)), a.event_date
        ) AS rn
    FROM #first_event_dates f
    JOIN #all_events_for_pairs a
      ON f.person_id = a.person_id
     AND f.from_event <> a.event_family
)
INSERT INTO #patient_timing_pairs_first_to_closest (person_id, from_event, to_event, days_diff)
SELECT
    person_id,
    from_event,
    to_event,
    days_diff
FROM ranked
WHERE rn = 1
;

DROP TABLE IF EXISTS #timing_pair_summary_first_to_closest;
CREATE TABLE #timing_pair_summary_first_to_closest (
    from_event VARCHAR(10),
    to_event VARCHAR(10),
    n_patients_with_pair INT,
    p05_days FLOAT,
    p10_days FLOAT,
    p20_days FLOAT,
    p25_days FLOAT,
    p30_days FLOAT,
    p40_days FLOAT,
    p50_days FLOAT,
    p60_days FLOAT,
    p70_days FLOAT,
    p75_days FLOAT,
    p80_days FLOAT,
    p90_days FLOAT,
    p95_days FLOAT
);

INSERT INTO #timing_pair_summary_first_to_closest (
    from_event,
    to_event,
    n_patients_with_pair,
    p05_days,
    p10_days,
    p20_days,
    p25_days,
    p30_days,
    p40_days,
    p50_days,
    p60_days,
    p70_days,
    p75_days,
    p80_days,
    p90_days,
    p95_days
)
SELECT
    from_event,
    to_event,
    COUNT(*) AS n_patients_with_pair,
    MIN(CASE WHEN 20.0 * rn >= cnt       THEN CAST(days_diff AS FLOAT) END) AS p05_days,
    MIN(CASE WHEN 10.0 * rn >= cnt       THEN CAST(days_diff AS FLOAT) END) AS p10_days,
    MIN(CASE WHEN  5.0 * rn >= cnt       THEN CAST(days_diff AS FLOAT) END) AS p20_days,
    MIN(CASE WHEN  4.0 * rn >= cnt       THEN CAST(days_diff AS FLOAT) END) AS p25_days,
    MIN(CASE WHEN 10.0 * rn >= 3 * cnt  THEN CAST(days_diff AS FLOAT) END) AS p30_days,
    MIN(CASE WHEN  5.0 * rn >= 2 * cnt  THEN CAST(days_diff AS FLOAT) END) AS p40_days,
    MIN(CASE WHEN  2.0 * rn >= cnt       THEN CAST(days_diff AS FLOAT) END) AS p50_days,
    MIN(CASE WHEN  5.0 * rn >= 3 * cnt  THEN CAST(days_diff AS FLOAT) END) AS p60_days,
    MIN(CASE WHEN 10.0 * rn >= 7 * cnt  THEN CAST(days_diff AS FLOAT) END) AS p70_days,
    MIN(CASE WHEN  4.0 * rn >= 3 * cnt  THEN CAST(days_diff AS FLOAT) END) AS p75_days,
    MIN(CASE WHEN  5.0 * rn >= 4 * cnt  THEN CAST(days_diff AS FLOAT) END) AS p80_days,
    MIN(CASE WHEN 10.0 * rn >= 9 * cnt  THEN CAST(days_diff AS FLOAT) END) AS p90_days,
    MIN(CASE WHEN 20.0 * rn >= 19 * cnt THEN CAST(days_diff AS FLOAT) END) AS p95_days
FROM (
    SELECT from_event, to_event, days_diff,
        ROW_NUMBER() OVER (PARTITION BY from_event, to_event ORDER BY days_diff) AS rn,
        COUNT(*)     OVER (PARTITION BY from_event, to_event)                    AS cnt
    FROM #patient_timing_pairs_first_to_closest
) x
GROUP BY from_event, to_event
;

DROP TABLE IF EXISTS #patient_timing_pairs_first_to_closest_before;
CREATE TABLE #patient_timing_pairs_first_to_closest_before (
    person_id BIGINT,
    from_event VARCHAR(10),
    to_event VARCHAR(10),
    days_diff INT
);

WITH ranked_before AS (
    SELECT
        f.person_id,
        f.from_event,
        a.event_family AS to_event,
        DATEDIFF(DAY, f.from_first_date, a.event_date) AS days_diff,
        ROW_NUMBER() OVER (
            PARTITION BY f.person_id, f.from_event, a.event_family
            ORDER BY ABS(DATEDIFF(DAY, f.from_first_date, a.event_date)), a.event_date DESC
        ) AS rn
    FROM #first_event_dates f
    JOIN #all_events_for_pairs a
      ON f.person_id = a.person_id
     AND f.from_event <> a.event_family
    WHERE DATEDIFF(DAY, f.from_first_date, a.event_date) < 0
)
INSERT INTO #patient_timing_pairs_first_to_closest_before (person_id, from_event, to_event, days_diff)
SELECT
    person_id,
    from_event,
    to_event,
    days_diff
FROM ranked_before
WHERE rn = 1
;

DROP TABLE IF EXISTS #timing_pair_summary_first_to_closest_before;
CREATE TABLE #timing_pair_summary_first_to_closest_before (
    from_event VARCHAR(10),
    to_event VARCHAR(10),
    n_patients_with_pair INT,
    p05_days FLOAT,
    p10_days FLOAT,
    p20_days FLOAT,
    p25_days FLOAT,
    p30_days FLOAT,
    p40_days FLOAT,
    p50_days FLOAT,
    p60_days FLOAT,
    p70_days FLOAT,
    p75_days FLOAT,
    p80_days FLOAT,
    p90_days FLOAT,
    p95_days FLOAT
);

INSERT INTO #timing_pair_summary_first_to_closest_before (
    from_event,
    to_event,
    n_patients_with_pair,
    p05_days,
    p10_days,
    p20_days,
    p25_days,
    p30_days,
    p40_days,
    p50_days,
    p60_days,
    p70_days,
    p75_days,
    p80_days,
    p90_days,
    p95_days
)
SELECT
    from_event,
    to_event,
    COUNT(*) AS n_patients_with_pair,
    MIN(CASE WHEN 20.0 * rn >= cnt       THEN CAST(days_diff AS FLOAT) END) AS p05_days,
    MIN(CASE WHEN 10.0 * rn >= cnt       THEN CAST(days_diff AS FLOAT) END) AS p10_days,
    MIN(CASE WHEN  5.0 * rn >= cnt       THEN CAST(days_diff AS FLOAT) END) AS p20_days,
    MIN(CASE WHEN  4.0 * rn >= cnt       THEN CAST(days_diff AS FLOAT) END) AS p25_days,
    MIN(CASE WHEN 10.0 * rn >= 3 * cnt  THEN CAST(days_diff AS FLOAT) END) AS p30_days,
    MIN(CASE WHEN  5.0 * rn >= 2 * cnt  THEN CAST(days_diff AS FLOAT) END) AS p40_days,
    MIN(CASE WHEN  2.0 * rn >= cnt       THEN CAST(days_diff AS FLOAT) END) AS p50_days,
    MIN(CASE WHEN  5.0 * rn >= 3 * cnt  THEN CAST(days_diff AS FLOAT) END) AS p60_days,
    MIN(CASE WHEN 10.0 * rn >= 7 * cnt  THEN CAST(days_diff AS FLOAT) END) AS p70_days,
    MIN(CASE WHEN  4.0 * rn >= 3 * cnt  THEN CAST(days_diff AS FLOAT) END) AS p75_days,
    MIN(CASE WHEN  5.0 * rn >= 4 * cnt  THEN CAST(days_diff AS FLOAT) END) AS p80_days,
    MIN(CASE WHEN 10.0 * rn >= 9 * cnt  THEN CAST(days_diff AS FLOAT) END) AS p90_days,
    MIN(CASE WHEN 20.0 * rn >= 19 * cnt THEN CAST(days_diff AS FLOAT) END) AS p95_days
FROM (
    SELECT from_event, to_event, days_diff,
        ROW_NUMBER() OVER (PARTITION BY from_event, to_event ORDER BY days_diff) AS rn,
        COUNT(*)     OVER (PARTITION BY from_event, to_event)                    AS cnt
    FROM #patient_timing_pairs_first_to_closest_before
) x
GROUP BY from_event, to_event
;

DROP TABLE IF EXISTS #patient_timing_pairs_first_to_closest_after;
CREATE TABLE #patient_timing_pairs_first_to_closest_after (
    person_id BIGINT,
    from_event VARCHAR(10),
    to_event VARCHAR(10),
    days_diff INT
);

WITH ranked_after AS (
    SELECT
        f.person_id,
        f.from_event,
        a.event_family AS to_event,
        DATEDIFF(DAY, f.from_first_date, a.event_date) AS days_diff,
        ROW_NUMBER() OVER (
            PARTITION BY f.person_id, f.from_event, a.event_family
            ORDER BY DATEDIFF(DAY, f.from_first_date, a.event_date), a.event_date
        ) AS rn
    FROM #first_event_dates f
    JOIN #all_events_for_pairs a
      ON f.person_id = a.person_id
     AND f.from_event <> a.event_family
    WHERE DATEDIFF(DAY, f.from_first_date, a.event_date) >= 0
)
INSERT INTO #patient_timing_pairs_first_to_closest_after (person_id, from_event, to_event, days_diff)
SELECT
    person_id,
    from_event,
    to_event,
    days_diff
FROM ranked_after
WHERE rn = 1
;

DROP TABLE IF EXISTS #timing_pair_summary_first_to_closest_after;
CREATE TABLE #timing_pair_summary_first_to_closest_after (
    from_event VARCHAR(10),
    to_event VARCHAR(10),
    n_patients_with_pair INT,
    p05_days FLOAT,
    p10_days FLOAT,
    p20_days FLOAT,
    p25_days FLOAT,
    p30_days FLOAT,
    p40_days FLOAT,
    p50_days FLOAT,
    p60_days FLOAT,
    p70_days FLOAT,
    p75_days FLOAT,
    p80_days FLOAT,
    p90_days FLOAT,
    p95_days FLOAT
);

INSERT INTO #timing_pair_summary_first_to_closest_after (
    from_event,
    to_event,
    n_patients_with_pair,
    p05_days,
    p10_days,
    p20_days,
    p25_days,
    p30_days,
    p40_days,
    p50_days,
    p60_days,
    p70_days,
    p75_days,
    p80_days,
    p90_days,
    p95_days
)
SELECT
    from_event,
    to_event,
    COUNT(*) AS n_patients_with_pair,
    MIN(CASE WHEN 20.0 * rn >= cnt       THEN CAST(days_diff AS FLOAT) END) AS p05_days,
    MIN(CASE WHEN 10.0 * rn >= cnt       THEN CAST(days_diff AS FLOAT) END) AS p10_days,
    MIN(CASE WHEN  5.0 * rn >= cnt       THEN CAST(days_diff AS FLOAT) END) AS p20_days,
    MIN(CASE WHEN  4.0 * rn >= cnt       THEN CAST(days_diff AS FLOAT) END) AS p25_days,
    MIN(CASE WHEN 10.0 * rn >= 3 * cnt  THEN CAST(days_diff AS FLOAT) END) AS p30_days,
    MIN(CASE WHEN  5.0 * rn >= 2 * cnt  THEN CAST(days_diff AS FLOAT) END) AS p40_days,
    MIN(CASE WHEN  2.0 * rn >= cnt       THEN CAST(days_diff AS FLOAT) END) AS p50_days,
    MIN(CASE WHEN  5.0 * rn >= 3 * cnt  THEN CAST(days_diff AS FLOAT) END) AS p60_days,
    MIN(CASE WHEN 10.0 * rn >= 7 * cnt  THEN CAST(days_diff AS FLOAT) END) AS p70_days,
    MIN(CASE WHEN  4.0 * rn >= 3 * cnt  THEN CAST(days_diff AS FLOAT) END) AS p75_days,
    MIN(CASE WHEN  5.0 * rn >= 4 * cnt  THEN CAST(days_diff AS FLOAT) END) AS p80_days,
    MIN(CASE WHEN 10.0 * rn >= 9 * cnt  THEN CAST(days_diff AS FLOAT) END) AS p90_days,
    MIN(CASE WHEN 20.0 * rn >= 19 * cnt THEN CAST(days_diff AS FLOAT) END) AS p95_days
FROM (
    SELECT from_event, to_event, days_diff,
        ROW_NUMBER() OVER (PARTITION BY from_event, to_event ORDER BY days_diff) AS rn,
        COUNT(*)     OVER (PARTITION BY from_event, to_event)                    AS cnt
    FROM #patient_timing_pairs_first_to_closest_after
) x
GROUP BY from_event, to_event
;

DROP TABLE IF EXISTS #event_presence;
CREATE TABLE #event_presence (
    person_id BIGINT,
    has_dx INT,
    has_odx INT,
    has_gdx INT,
    has_met INT,
    has_l01 INT
);

INSERT INTO #event_presence (
    person_id, has_dx, has_odx, has_gdx, has_met, has_l01
)
SELECT
    person_id,
    1,
    CASE WHEN first_other_dx_date IS NOT NULL THEN 1 ELSE 0 END,
    CASE WHEN first_gen_cancer_date IS NOT NULL THEN 1 ELSE 0 END,
    CASE WHEN first_met_date IS NOT NULL THEN 1 ELSE 0 END,
    CASE WHEN first_l01_date IS NOT NULL THEN 1 ELSE 0 END
FROM #patient_char
;


------------------------------------------------------------
-- J-bis) DEATH TIMING FROM INDEX AND FIRST_MET ANCHORS
------------------------------------------------------------

-- Pre-compute each cohort patient's earliest death date and whether it
-- falls within any of their observation periods.
DROP TABLE IF EXISTS #death_obs_status;
CREATE TABLE #death_obs_status (
    person_id BIGINT,
    death_date DATE,
    death_in_obs SMALLINT
);

INSERT INTO #death_obs_status (person_id, death_date, death_in_obs)
SELECT
    d.person_id,
    d.death_date,
    CASE WHEN EXISTS (
        SELECT 1
        FROM @cdm_database_schema.observation_period op
        WHERE op.person_id = d.person_id
          AND d.death_date BETWEEN op.observation_period_start_date
                               AND op.observation_period_end_date
    ) THEN 1 ELSE 0 END
FROM (
    SELECT person_id, MIN(death_date) AS death_date
    FROM @cdm_database_schema.death
    GROUP BY person_id
) d
WHERE d.person_id IN (SELECT person_id FROM #cohort)
;

DROP TABLE IF EXISTS #death_index_long;
CREATE TABLE #death_index_long (
    prevalence_year VARCHAR(20),
    days_to_death INT
);

INSERT INTO #death_index_long (prevalence_year, days_to_death)
SELECT 'OVERALL', DATEDIFF(DAY, c.index_date, dos.death_date)
FROM #cohort c
INNER JOIN #death_obs_status dos ON dos.person_id = c.person_id
WHERE dos.death_date >= c.index_date
UNION ALL
SELECT CAST(YEAR(c.index_date) AS VARCHAR(4)), DATEDIFF(DAY, c.index_date, dos.death_date)
FROM #cohort c
INNER JOIN #death_obs_status dos ON dos.person_id = c.person_id
WHERE dos.death_date >= c.index_date
;

DROP TABLE IF EXISTS #death_first_met_long;
CREATE TABLE #death_first_met_long (
    prevalence_year VARCHAR(20),
    days_to_death INT
);

INSERT INTO #death_first_met_long (prevalence_year, days_to_death)
SELECT 'OVERALL', DATEDIFF(DAY, ms.first_met_date, dos.death_date)
FROM #cohort c
INNER JOIN #met_summary ms ON c.person_id = ms.person_id AND ms.first_met_date IS NOT NULL
INNER JOIN #death_obs_status dos ON dos.person_id = c.person_id
WHERE dos.death_date >= ms.first_met_date
UNION ALL
SELECT CAST(YEAR(ms.first_met_date) AS VARCHAR(4)), DATEDIFF(DAY, ms.first_met_date, dos.death_date)
FROM #cohort c
INNER JOIN #met_summary ms ON c.person_id = ms.person_id AND ms.first_met_date IS NOT NULL
INNER JOIN #death_obs_status dos ON dos.person_id = c.person_id
WHERE dos.death_date >= ms.first_met_date
;

DROP TABLE IF EXISTS #death_stratum_counts;
CREATE TABLE #death_stratum_counts (
    prevalence_year VARCHAR(20),
    anchor_event VARCHAR(20),
    n_patients INT,
    n_deaths INT,
    n_deaths_in_obs INT,
    n_deaths_out_obs INT
);

INSERT INTO #death_stratum_counts (prevalence_year, anchor_event, n_patients, n_deaths, n_deaths_in_obs, n_deaths_out_obs)
SELECT
    CASE
        WHEN GROUPING(YEAR(c.index_date)) = 1 THEN 'OVERALL'
        ELSE CAST(YEAR(c.index_date) AS VARCHAR(4))
    END,
    'INDEX',
    COUNT(*),
    SUM(CASE WHEN dos.death_date IS NOT NULL AND dos.death_date >= c.index_date THEN 1 ELSE 0 END),
    SUM(CASE WHEN dos.death_date IS NOT NULL AND dos.death_date >= c.index_date AND dos.death_in_obs = 1 THEN 1 ELSE 0 END),
    SUM(CASE WHEN dos.death_date IS NOT NULL AND dos.death_date >= c.index_date AND dos.death_in_obs = 0 THEN 1 ELSE 0 END)
FROM #cohort c
LEFT JOIN #death_obs_status dos ON dos.person_id = c.person_id
GROUP BY GROUPING SETS ((), (YEAR(c.index_date)))
;

INSERT INTO #death_stratum_counts (prevalence_year, anchor_event, n_patients, n_deaths, n_deaths_in_obs, n_deaths_out_obs)
SELECT
    CASE
        WHEN GROUPING(YEAR(ms.first_met_date)) = 1 THEN 'OVERALL'
        ELSE CAST(YEAR(ms.first_met_date) AS VARCHAR(4))
    END,
    'FIRST_MET',
    COUNT(*),
    SUM(CASE WHEN dos.death_date IS NOT NULL AND dos.death_date >= ms.first_met_date THEN 1 ELSE 0 END),
    SUM(CASE WHEN dos.death_date IS NOT NULL AND dos.death_date >= ms.first_met_date AND dos.death_in_obs = 1 THEN 1 ELSE 0 END),
    SUM(CASE WHEN dos.death_date IS NOT NULL AND dos.death_date >= ms.first_met_date AND dos.death_in_obs = 0 THEN 1 ELSE 0 END)
FROM #cohort c
INNER JOIN #met_summary ms ON c.person_id = ms.person_id AND ms.first_met_date IS NOT NULL
LEFT JOIN #death_obs_status dos ON dos.person_id = c.person_id
GROUP BY GROUPING SETS ((), (YEAR(ms.first_met_date)))
;

DROP TABLE IF EXISTS #death_timing_long;
CREATE TABLE #death_timing_long (
    prevalence_year VARCHAR(20),
    anchor_event VARCHAR(20),
    days_to_death INT
);

INSERT INTO #death_timing_long (prevalence_year, anchor_event, days_to_death)
SELECT prevalence_year, 'INDEX', days_to_death FROM #death_index_long
UNION ALL
SELECT prevalence_year, 'FIRST_MET', days_to_death FROM #death_first_met_long
;

DROP TABLE IF EXISTS #death_timing_quantiles;
CREATE TABLE #death_timing_quantiles (
    prevalence_year VARCHAR(20),
    anchor_event VARCHAR(20),
    lq_days FLOAT,
    median_days FLOAT,
    uq_days FLOAT
);

INSERT INTO #death_timing_quantiles (
    prevalence_year,
    anchor_event,
    lq_days,
    median_days,
    uq_days
)
SELECT
    prevalence_year,
    anchor_event,
    MIN(CASE WHEN 4.0 * rn >= cnt THEN CAST(days_to_death AS FLOAT) END) AS lq_days,
    MIN(CASE WHEN 2.0 * rn >= cnt THEN CAST(days_to_death AS FLOAT) END) AS median_days,
    MIN(CASE WHEN 4.0 * rn >= 3 * cnt THEN CAST(days_to_death AS FLOAT) END) AS uq_days
FROM (
    SELECT prevalence_year, anchor_event, days_to_death,
        ROW_NUMBER() OVER (PARTITION BY prevalence_year, anchor_event ORDER BY days_to_death) AS rn,
        COUNT(*)     OVER (PARTITION BY prevalence_year, anchor_event)                        AS cnt
    FROM #death_timing_long
) x
GROUP BY prevalence_year, anchor_event
;

-- Follow-up duration from anchor date to last observation period end,
-- for all patients with at least one observation period covering or after anchor.
DROP TABLE IF EXISTS #followup_long;
CREATE TABLE #followup_long (
    prevalence_year VARCHAR(20),
    anchor_event VARCHAR(20),
    followup_days INT
);

INSERT INTO #followup_long (prevalence_year, anchor_event, followup_days)
SELECT 'OVERALL', 'INDEX',
       DATEDIFF(DAY, c.index_date, MAX(op.observation_period_end_date))
FROM #cohort c
INNER JOIN @cdm_database_schema.observation_period op
  ON op.person_id = c.person_id
 AND op.observation_period_end_date >= c.index_date
GROUP BY c.person_id, c.index_date
UNION ALL
SELECT CAST(YEAR(c.index_date) AS VARCHAR(4)), 'INDEX',
       DATEDIFF(DAY, c.index_date, MAX(op.observation_period_end_date))
FROM #cohort c
INNER JOIN @cdm_database_schema.observation_period op
  ON op.person_id = c.person_id
 AND op.observation_period_end_date >= c.index_date
GROUP BY c.person_id, c.index_date, YEAR(c.index_date)
UNION ALL
SELECT 'OVERALL', 'FIRST_MET',
       DATEDIFF(DAY, ms.first_met_date, MAX(op.observation_period_end_date))
FROM #cohort c
INNER JOIN #met_summary ms ON c.person_id = ms.person_id AND ms.first_met_date IS NOT NULL
INNER JOIN @cdm_database_schema.observation_period op
  ON op.person_id = c.person_id
 AND op.observation_period_end_date >= ms.first_met_date
GROUP BY c.person_id, ms.first_met_date
UNION ALL
SELECT CAST(YEAR(ms.first_met_date) AS VARCHAR(4)), 'FIRST_MET',
       DATEDIFF(DAY, ms.first_met_date, MAX(op.observation_period_end_date))
FROM #cohort c
INNER JOIN #met_summary ms ON c.person_id = ms.person_id AND ms.first_met_date IS NOT NULL
INNER JOIN @cdm_database_schema.observation_period op
  ON op.person_id = c.person_id
 AND op.observation_period_end_date >= ms.first_met_date
GROUP BY c.person_id, ms.first_met_date, YEAR(ms.first_met_date)
;

DROP TABLE IF EXISTS #followup_quantiles;
CREATE TABLE #followup_quantiles (
    prevalence_year VARCHAR(20),
    anchor_event VARCHAR(20),
    lq_followup_days FLOAT,
    median_followup_days FLOAT,
    uq_followup_days FLOAT
);

INSERT INTO #followup_quantiles (
    prevalence_year,
    anchor_event,
    lq_followup_days,
    median_followup_days,
    uq_followup_days
)
SELECT
    prevalence_year,
    anchor_event,
    MIN(CASE WHEN 4.0 * rn >= cnt THEN CAST(followup_days AS FLOAT) END) AS lq_followup_days,
    MIN(CASE WHEN 2.0 * rn >= cnt THEN CAST(followup_days AS FLOAT) END) AS median_followup_days,
    MIN(CASE WHEN 4.0 * rn >= 3 * cnt THEN CAST(followup_days AS FLOAT) END) AS uq_followup_days
FROM (
    SELECT prevalence_year, anchor_event, followup_days,
        ROW_NUMBER() OVER (PARTITION BY prevalence_year, anchor_event ORDER BY followup_days) AS rn,
        COUNT(*)     OVER (PARTITION BY prevalence_year, anchor_event)                        AS cnt
    FROM #followup_long
) x
GROUP BY prevalence_year, anchor_event
;


------------------------------------------------------------
-- L) L01 CONSECUTIVE GAP TABLES (used by chunks 11 and 12)
------------------------------------------------------------

-- Deduplicated L01 event days per patient (one row per patient-day)
DROP TABLE IF EXISTS #l01_event_days;
CREATE TABLE #l01_event_days (
    person_id  BIGINT,
    event_day  DATE
);

INSERT INTO #l01_event_days (person_id, event_day)
SELECT DISTINCT person_id, event_date
FROM #l01_events
WHERE person_id IN (SELECT person_id FROM #cohort)
;

-- Consecutive gaps between L01 event days per patient
DROP TABLE IF EXISTS #l01_consecutive_gaps;
CREATE TABLE #l01_consecutive_gaps (
    person_id  BIGINT,
    subgroup   VARCHAR(12),
    gap_days   INT
);

WITH ranked AS (
    SELECT
        e.person_id,
        e.event_day,
        LEAD(e.event_day) OVER (PARTITION BY e.person_id ORDER BY e.event_day) AS next_day
    FROM #l01_event_days e
),
gaps AS (
    SELECT
        person_id,
        DATEDIFF(DAY, event_day, next_day) AS gap_days
    FROM ranked
    WHERE next_day IS NOT NULL
)
INSERT INTO #l01_consecutive_gaps (person_id, subgroup, gap_days)
SELECT g.person_id, 'ALL_L01', g.gap_days FROM gaps g
UNION ALL
SELECT g.person_id, 'MET_L01', g.gap_days
FROM gaps g
JOIN #met_summary ms ON g.person_id = ms.person_id AND ms.first_met_date IS NOT NULL
;

-- Max gap per patient (one row per patient; used for MAX-gap subgroups in chunks 11–12)
INSERT INTO #l01_consecutive_gaps (person_id, subgroup, gap_days)
SELECT person_id, 'ALL_L01_MAX', MAX(gap_days)
FROM #l01_consecutive_gaps
WHERE subgroup = 'ALL_L01'
GROUP BY person_id
UNION ALL
SELECT person_id, 'MET_L01_MAX', MAX(gap_days)
FROM #l01_consecutive_gaps
WHERE subgroup = 'MET_L01'
GROUP BY person_id
;


------------------------------------------------------------
-- K) FINAL SELECTS (export to CSV from SQL client)
------------------------------------------------------------

-- 0b) Cohort attrition: patients with any qualifying DX vs those with a DX
--     that falls within an observation period (the study-eligible subset).
--     The difference is the number excluded by the obs-period filter.
SELECT
    SUM(CASE WHEN stage = 'dx_any'    THEN n_patients ELSE 0 END) AS n_dx_any,
    SUM(CASE WHEN stage = 'dx_in_obs' THEN n_patients ELSE 0 END) AS n_dx_in_obs,
    SUM(CASE WHEN stage = 'dx_any'    THEN n_patients ELSE 0 END)
    - SUM(CASE WHEN stage = 'dx_in_obs' THEN n_patients ELSE 0 END)  AS n_excluded_no_obs_dx
FROM #cohort_attrition
;

-- 1) Population prevalence
WITH base AS (
    SELECT
        CASE
            WHEN GROUPING(YEAR(index_date)) = 1 THEN 'OVERALL'
            ELSE CAST(YEAR(index_date) AS VARCHAR(4))
        END AS prevalence_year,
        COUNT(*) AS n_patients,
        SUM(CASE WHEN first_other_dx_date IS NOT NULL THEN 1 ELSE 0 END) AS n_with_other_dx,
        SUM(CASE WHEN first_gen_cancer_date IS NOT NULL THEN 1 ELSE 0 END) AS n_with_gen_cancer_dx,
        SUM(CASE WHEN first_met_date IS NOT NULL THEN 1 ELSE 0 END) AS n_with_met,
        SUM(CASE WHEN first_l01_date IS NOT NULL THEN 1 ELSE 0 END) AS n_with_l01
    FROM #patient_char
    GROUP BY GROUPING SETS (
        (),
        (YEAR(index_date))
    )
)
SELECT
    prevalence_year,
    CASE WHEN n_patients <= @min_cell_count THEN -@min_cell_count ELSE n_patients END AS n_dx,
    CASE
        WHEN n_patients <= @min_cell_count THEN -@min_cell_count
        WHEN n_with_other_dx BETWEEN 1 AND @min_cell_count THEN -@min_cell_count
        ELSE n_with_other_dx
    END AS n_odx,
    CASE
        WHEN n_patients <= @min_cell_count THEN -@min_cell_count
        WHEN n_with_gen_cancer_dx BETWEEN 1 AND @min_cell_count THEN -@min_cell_count
        ELSE n_with_gen_cancer_dx
    END AS n_gdx,
    CASE
        WHEN n_patients <= @min_cell_count THEN -@min_cell_count
        WHEN n_with_met BETWEEN 1 AND @min_cell_count THEN -@min_cell_count
        ELSE n_with_met
    END AS n_met,
    CASE
        WHEN n_patients <= @min_cell_count THEN -@min_cell_count
        WHEN n_with_l01 BETWEEN 1 AND @min_cell_count THEN -@min_cell_count
        ELSE n_with_l01
    END AS n_l01
FROM base
ORDER BY
    CASE WHEN prevalence_year = 'OVERALL' THEN 0 ELSE 1 END,
    CASE WHEN prevalence_year = 'OVERALL' THEN NULL ELSE CAST(prevalence_year AS INT) END
;

-- 2) Code-count summary: all three time windows combined (small-cell sentinel)
--    time_window: all | before | after
SELECT
    x.time_window,
    x.anchor_event,
    x.event_family,
    x.concept_id,
    CASE WHEN x.n_patients <= @min_cell_count THEN -@min_cell_count ELSE x.n_records END AS n_records,
    CASE WHEN x.n_patients <= @min_cell_count THEN -@min_cell_count ELSE x.n_patients END AS n_patients,
    CASE WHEN x.n_patients <= @min_cell_count THEN -@min_cell_count ELSE COALESCE(ts.n_patients_with_code_timing, tba.n_patients_with_code_timing) END AS n_patients_with_code_timing,
    CASE WHEN x.n_patients <= @min_cell_count THEN NULL ELSE COALESCE(ts.lq_days_first,       tba.lq_days_first)       END AS lq_days_first,
    CASE WHEN x.n_patients <= @min_cell_count THEN NULL ELSE COALESCE(ts.median_days_first,   tba.median_days_first)   END AS median_days_first,
    CASE WHEN x.n_patients <= @min_cell_count THEN NULL ELSE COALESCE(ts.uq_days_first,       tba.uq_days_first)       END AS uq_days_first,
    CASE WHEN x.n_patients <= @min_cell_count THEN NULL ELSE COALESCE(ts.lq_days_closest,     tba.lq_days_closest)     END AS lq_days_closest,
    CASE WHEN x.n_patients <= @min_cell_count THEN NULL ELSE COALESCE(ts.median_days_closest, tba.median_days_closest) END AS median_days_closest,
    CASE WHEN x.n_patients <= @min_cell_count THEN NULL ELSE COALESCE(ts.uq_days_closest,     tba.uq_days_closest)     END AS uq_days_closest,
    CASE WHEN x.n_patients <= @min_cell_count THEN NULL ELSE COALESCE(ts.lq_days_first,       tba.lq_days_first)       END AS lq_days,
    CASE WHEN x.n_patients <= @min_cell_count THEN NULL ELSE COALESCE(ts.median_days_first,   tba.median_days_first)   END AS median_days,
    CASE WHEN x.n_patients <= @min_cell_count THEN NULL ELSE COALESCE(ts.uq_days_first,       tba.uq_days_first)       END AS uq_days
FROM (
    SELECT 'all'    AS time_window, anchor_event, event_family, concept_id, n_records, n_patients FROM #event_code_counts
    UNION ALL
    SELECT 'before' AS time_window, anchor_event, event_family, concept_id, n_records, n_patients FROM #event_code_counts_before_after         WHERE time_relative = 'BEFORE'
    UNION ALL
    SELECT 'after'  AS time_window, anchor_event, event_family, concept_id, n_records, n_patients FROM #event_code_counts_before_after         WHERE time_relative = 'AFTER'
    UNION ALL
    SELECT 'before' AS time_window, anchor_event, event_family, concept_id, n_records, n_patients FROM #event_code_counts_before_after_first_met WHERE time_relative = 'BEFORE'
    UNION ALL
    SELECT 'after'  AS time_window, anchor_event, event_family, concept_id, n_records, n_patients FROM #event_code_counts_before_after_first_met WHERE time_relative = 'AFTER'
) x
LEFT JOIN #event_code_timing_summary ts
  ON x.time_window = 'all'
 AND x.anchor_event = ts.anchor_event
 AND x.event_family = ts.event_family
 AND x.concept_id   = ts.concept_id
LEFT JOIN #event_code_timing_before_after_summary tba
  ON x.time_window != 'all'
 AND x.anchor_event = tba.anchor_event
 AND x.event_family = tba.event_family
 AND x.concept_id   = tba.concept_id
 AND ((x.time_window = 'before' AND tba.time_relative = 'BEFORE')
  OR  (x.time_window = 'after'  AND tba.time_relative = 'AFTER'))
ORDER BY x.time_window, x.anchor_event, x.event_family, x.n_patients DESC, x.n_records DESC, x.concept_id
;

-- 3) Temporal directionality buckets
--    Exact patient counts by direction category for key event pairs:
--      DX -> MET  (using index_date -> first_met_date from #patient_char)
--      DX -> L01  (using index_date -> first_l01_date from #patient_char)
--      MET -> L01 (using first_met_date -> first_l01_date from #patient_char)
--
--    Categories (days = TO_date - FROM_date):
--      BEFORE_GT90  : TO event > 90 days before FROM  (days < -90)
--      BEFORE_1_90  : TO event 1-90 days before FROM  (-90 <= days < 0)
--      SAME_DAY     : same calendar day                (days = 0)
--      AFTER_1_30   : 1-30 days after                  (1 <= days <= 30)
--      AFTER_31_90  : 31-90 days after                 (31 <= days <= 90)
--      AFTER_91_365 : 91-365 days after                (91 <= days <= 365)
--      AFTER_GT365  : > 365 days after                 (days > 365)
--      NO_EVENT     : FROM event present but TO event absent
--
--    Stratified by OVERALL and by anchor year:
--      DX_MET / DX_L01 use YEAR(index_date); MET_L01 uses YEAR(first_met_date).
--    Small-cell suppression: n suppressed to -@min_cell_count when <= @min_cell_count.

WITH dx_met_base AS (
    SELECT
        YEAR(index_date) AS index_year_int,
        CASE
            WHEN first_met_date IS NULL  THEN 'NO_EVENT'
            WHEN days_dx_to_met < -90    THEN 'BEFORE_GT90'
            WHEN days_dx_to_met < 0      THEN 'BEFORE_1_90'
            WHEN days_dx_to_met = 0      THEN 'SAME_DAY'
            WHEN days_dx_to_met <= 30    THEN 'AFTER_1_30'
            WHEN days_dx_to_met <= 90    THEN 'AFTER_31_90'
            WHEN days_dx_to_met <= 365   THEN 'AFTER_91_365'
            ELSE 'AFTER_GT365'
        END AS direction
    FROM #patient_char
),
dx_l01_base AS (
    SELECT
        YEAR(index_date) AS index_year_int,
        CASE
            WHEN first_l01_date IS NULL  THEN 'NO_EVENT'
            WHEN days_dx_to_l01 < -90    THEN 'BEFORE_GT90'
            WHEN days_dx_to_l01 < 0      THEN 'BEFORE_1_90'
            WHEN days_dx_to_l01 = 0      THEN 'SAME_DAY'
            WHEN days_dx_to_l01 <= 30    THEN 'AFTER_1_30'
            WHEN days_dx_to_l01 <= 90    THEN 'AFTER_31_90'
            WHEN days_dx_to_l01 <= 365   THEN 'AFTER_91_365'
            ELSE 'AFTER_GT365'
        END AS direction
    FROM #patient_char
),
met_l01_base AS (
    SELECT
        YEAR(first_met_date) AS index_year_int,
        CASE
            WHEN first_l01_date IS NULL  THEN 'NO_EVENT'
            WHEN days_met_to_l01 < -90   THEN 'BEFORE_GT90'
            WHEN days_met_to_l01 < 0     THEN 'BEFORE_1_90'
            WHEN days_met_to_l01 = 0     THEN 'SAME_DAY'
            WHEN days_met_to_l01 <= 30   THEN 'AFTER_1_30'
            WHEN days_met_to_l01 <= 90   THEN 'AFTER_31_90'
            WHEN days_met_to_l01 <= 365  THEN 'AFTER_91_365'
            ELSE 'AFTER_GT365'
        END AS direction
    FROM #patient_char
    WHERE first_met_date IS NOT NULL
)
SELECT
    x.pair,
    x.index_year,
    x.direction,
    CASE WHEN x.n_patients <= @min_cell_count THEN -@min_cell_count ELSE x.n_patients END AS n_patients
FROM (
    -- DX -> MET: OVERALL
    SELECT 'DX_MET' AS pair, 'OVERALL' AS index_year, direction, COUNT(*) AS n_patients
    FROM dx_met_base
    GROUP BY direction

    UNION ALL

    -- DX -> MET: by DX year
    SELECT 'DX_MET' AS pair, CAST(index_year_int AS VARCHAR(4)) AS index_year, direction, COUNT(*) AS n_patients
    FROM dx_met_base
    GROUP BY index_year_int, direction

    UNION ALL

    -- DX -> L01: OVERALL
    SELECT 'DX_L01' AS pair, 'OVERALL' AS index_year, direction, COUNT(*) AS n_patients
    FROM dx_l01_base
    GROUP BY direction

    UNION ALL

    -- DX -> L01: by DX year
    SELECT 'DX_L01' AS pair, CAST(index_year_int AS VARCHAR(4)) AS index_year, direction, COUNT(*) AS n_patients
    FROM dx_l01_base
    GROUP BY index_year_int, direction

    UNION ALL

    -- MET -> L01: OVERALL
    SELECT 'MET_L01' AS pair, 'OVERALL' AS index_year, direction, COUNT(*) AS n_patients
    FROM met_l01_base
    GROUP BY direction

    UNION ALL

    -- MET -> L01: by MET year
    SELECT 'MET_L01' AS pair, CAST(index_year_int AS VARCHAR(4)) AS index_year, direction, COUNT(*) AS n_patients
    FROM met_l01_base
    GROUP BY index_year_int, direction
) x
ORDER BY
    x.pair,
    CASE WHEN x.index_year = 'OVERALL' THEN 0 ELSE 1 END,
    CASE WHEN x.index_year = 'OVERALL' THEN NULL ELSE CAST(x.index_year AS INT) END,
    CASE x.direction
        WHEN 'BEFORE_GT90'  THEN 1
        WHEN 'BEFORE_1_90'  THEN 2
        WHEN 'SAME_DAY'     THEN 3
        WHEN 'AFTER_1_30'   THEN 4
        WHEN 'AFTER_31_90'  THEN 5
        WHEN 'AFTER_91_365' THEN 6
        WHEN 'AFTER_GT365'  THEN 7
        WHEN 'NO_EVENT'     THEN 8
        ELSE 9
    END
;

-- 4) Pairwise timing summary: all four timing types combined (small-cell sentinel)
--    timing_type: first_to_first | first_to_closest | first_to_closest_before | first_to_closest_after
SELECT
    x.timing_type,
    x.from_event,
    x.to_event,
    CASE WHEN x.n_patients_with_pair <= @min_cell_count THEN -@min_cell_count ELSE x.n_patients_with_pair END AS n_patients_with_pair,
    CASE WHEN x.n_patients_with_pair <= @min_cell_count THEN NULL ELSE x.p05_days END AS p05_days,
    CASE WHEN x.n_patients_with_pair <= @min_cell_count THEN NULL ELSE x.p10_days END AS p10_days,
    CASE WHEN x.n_patients_with_pair <= @min_cell_count THEN NULL ELSE x.p20_days END AS p20_days,
    CASE WHEN x.n_patients_with_pair <= @min_cell_count THEN NULL ELSE x.p25_days END AS p25_days,
    CASE WHEN x.n_patients_with_pair <= @min_cell_count THEN NULL ELSE x.p30_days END AS p30_days,
    CASE WHEN x.n_patients_with_pair <= @min_cell_count THEN NULL ELSE x.p40_days END AS p40_days,
    CASE WHEN x.n_patients_with_pair <= @min_cell_count THEN NULL ELSE x.p50_days END AS p50_days,
    CASE WHEN x.n_patients_with_pair <= @min_cell_count THEN NULL ELSE x.p60_days END AS p60_days,
    CASE WHEN x.n_patients_with_pair <= @min_cell_count THEN NULL ELSE x.p70_days END AS p70_days,
    CASE WHEN x.n_patients_with_pair <= @min_cell_count THEN NULL ELSE x.p75_days END AS p75_days,
    CASE WHEN x.n_patients_with_pair <= @min_cell_count THEN NULL ELSE x.p80_days END AS p80_days,
    CASE WHEN x.n_patients_with_pair <= @min_cell_count THEN NULL ELSE x.p90_days END AS p90_days,
    CASE WHEN x.n_patients_with_pair <= @min_cell_count THEN NULL ELSE x.p95_days END AS p95_days
FROM (
    SELECT 'first_to_first'          AS timing_type, from_event, to_event, n_patients_with_pair, p05_days, p10_days, p20_days, p25_days, p30_days, p40_days, p50_days, p60_days, p70_days, p75_days, p80_days, p90_days, p95_days FROM #timing_pair_summary
    UNION ALL
    SELECT 'first_to_closest'        AS timing_type, from_event, to_event, n_patients_with_pair, p05_days, p10_days, p20_days, p25_days, p30_days, p40_days, p50_days, p60_days, p70_days, p75_days, p80_days, p90_days, p95_days FROM #timing_pair_summary_first_to_closest
    UNION ALL
    SELECT 'first_to_closest_before' AS timing_type, from_event, to_event, n_patients_with_pair, p05_days, p10_days, p20_days, p25_days, p30_days, p40_days, p50_days, p60_days, p70_days, p75_days, p80_days, p90_days, p95_days FROM #timing_pair_summary_first_to_closest_before
    UNION ALL
    SELECT 'first_to_closest_after'  AS timing_type, from_event, to_event, n_patients_with_pair, p05_days, p10_days, p20_days, p25_days, p30_days, p40_days, p50_days, p60_days, p70_days, p75_days, p80_days, p90_days, p95_days FROM #timing_pair_summary_first_to_closest_after
) x
ORDER BY x.timing_type, x.from_event, x.to_event
;

-- 5) Pairwise timing summary stratified by anchor year
--    Same structure as chunk 04 (final_timing_pairwise.csv) but grouped by year.
--    Year is anchored on the from_event: DX-anchored pairs use YEAR(index_date),
--    MET-anchored pairs use YEAR(first_met_date).
--    Used for year-over-year plots and for the per-year columns in the §06 stability matrix.
--    Small-cell suppression applied.

SELECT
    x.timing_type,
    x.index_year,
    x.from_event,
    x.to_event,
    CASE WHEN x.n_patients_with_pair <= @min_cell_count THEN -@min_cell_count ELSE x.n_patients_with_pair END AS n_patients_with_pair,
    CASE WHEN x.n_patients_with_pair <= @min_cell_count THEN NULL ELSE x.p25_days  END AS p25_days,
    CASE WHEN x.n_patients_with_pair <= @min_cell_count THEN NULL ELSE x.p50_days  END AS p50_days,
    CASE WHEN x.n_patients_with_pair <= @min_cell_count THEN NULL ELSE x.p75_days  END AS p75_days
FROM (
    -- first_to_first by anchor year
    SELECT
        'first_to_first' AS timing_type,
        CAST(index_year_int AS VARCHAR(4)) AS index_year,
        from_event,
        to_event,
        COUNT(*) AS n_patients_with_pair,
        MIN(CASE WHEN 4.0 * rn >= cnt THEN CAST(days_diff AS FLOAT) END) AS p25_days,
        MIN(CASE WHEN 2.0 * rn >= cnt THEN CAST(days_diff AS FLOAT) END) AS p50_days,
        MIN(CASE WHEN 4.0 * rn >= 3 * cnt THEN CAST(days_diff AS FLOAT) END) AS p75_days
    FROM (
        SELECT p.from_event, p.to_event, p.days_diff,
            CASE WHEN p.from_event = 'MET' THEN YEAR(ms.first_met_date) ELSE YEAR(pc.index_date) END AS index_year_int,
            ROW_NUMBER() OVER (PARTITION BY CASE WHEN p.from_event = 'MET' THEN YEAR(ms.first_met_date) ELSE YEAR(pc.index_date) END, p.from_event, p.to_event ORDER BY p.days_diff) AS rn,
            COUNT(*)     OVER (PARTITION BY CASE WHEN p.from_event = 'MET' THEN YEAR(ms.first_met_date) ELSE YEAR(pc.index_date) END, p.from_event, p.to_event)                    AS cnt
        FROM #patient_timing_pairs p
        JOIN #patient_char pc    ON p.person_id = pc.person_id
        LEFT JOIN #met_summary ms ON p.person_id = ms.person_id
    ) y
    GROUP BY index_year_int, from_event, to_event

    UNION ALL

    -- first_to_closest_after by anchor year (MET-anchored pairs use MET year)
    SELECT
        'first_to_closest_after' AS timing_type,
        CAST(index_year_int AS VARCHAR(4)) AS index_year,
        from_event,
        to_event,
        COUNT(*) AS n_patients_with_pair,
        MIN(CASE WHEN 4.0 * rn >= cnt THEN CAST(days_diff AS FLOAT) END) AS p25_days,
        MIN(CASE WHEN 2.0 * rn >= cnt THEN CAST(days_diff AS FLOAT) END) AS p50_days,
        MIN(CASE WHEN 4.0 * rn >= 3 * cnt THEN CAST(days_diff AS FLOAT) END) AS p75_days
    FROM (
        SELECT p.from_event, p.to_event, p.days_diff,
            CASE WHEN p.from_event = 'MET' THEN YEAR(ms.first_met_date) ELSE YEAR(pc.index_date) END AS index_year_int,
            ROW_NUMBER() OVER (PARTITION BY CASE WHEN p.from_event = 'MET' THEN YEAR(ms.first_met_date) ELSE YEAR(pc.index_date) END, p.from_event, p.to_event ORDER BY p.days_diff) AS rn,
            COUNT(*)     OVER (PARTITION BY CASE WHEN p.from_event = 'MET' THEN YEAR(ms.first_met_date) ELSE YEAR(pc.index_date) END, p.from_event, p.to_event)                    AS cnt
        FROM #patient_timing_pairs_first_to_closest_after p
        JOIN #patient_char pc    ON p.person_id = pc.person_id
        LEFT JOIN #met_summary ms ON p.person_id = ms.person_id
    ) y
    GROUP BY index_year_int, from_event, to_event
) x
ORDER BY
    x.timing_type,
    x.from_event,
    x.to_event,
    CAST(x.index_year AS INT)
;

-- 6b) Directional ODX / GDX prevalence expressed CUMULATIVELY (CDF-style), so an
--     exclusion look-back (before) or follow-up (after) cutoff can be read off
--     directly. Cumulative companion to the disjoint bands in chunk 06; same
--     population, same closest-event-per-side construction, same two anchors.
--
--     For each anchor / event family / concept, the number of DISTINCT PATIENTS
--     whose closest event on a side sits WITHIN each day threshold of the anchor.
--     Because a patient counts as "within X" whenever ANY event on that side is
--     within X days of the anchor, n_within_Xd_before is exactly the number of
--     patients an X-day look-back exclusion would capture for this concept.
--     Counts are cumulative and monotonically non-decreasing across thresholds.
--
--     Anchors (both surfaced): INDEX (DX index_date, full DX cohort) and
--     FIRST_MET (first_met_date, MET subgroup only).
--     Families: ODX (other specific cancer dx), GDX (general / non-specific).
--     days = DATEDIFF(DAY, anchor_date, event_date); before = days <= -1,
--     after = days >= 1, day 0 its own category (never folded into a side).
--
--     Columns:
--       n_ever            : distinct patients with any event of the concept, any time.
--       n_before_ever     : distinct patients with any event before the anchor
--                           (the denominator for the before CDF; the tail beyond
--                           2 yr is n_before_ever - n_within_730d_before).
--       n_within_30d_before ... n_within_730d_before : cumulative before counts
--                           (patients with a before event within 30/90/180/365/730 days).
--       median_days_before: median of days-before over patients with any before
--                           event, days-before = distance of the closest-before
--                           event; framework ordered-set median convention
--                           (lower-middle for even n, as in chunks 16-17, 23, 27-28).
--       n_day0            : distinct patients with an event on the anchor day.
--       n_after_ever, n_within_30d_after ... n_within_730d_after, median_days_after:
--                           mirror of the before columns on the after side.
--
--     Covers ODX and GDX. All concepts reported; report builder limits to top N.
--
--     Small-cell suppression: each count in (0, @min_cell_count] set to
--     -@min_cell_count; a side median set to NULL when that side's denominator
--     (n_before_ever / n_after_ever) is <= @min_cell_count.

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
med_before AS (
    SELECT
        anchor_event,
        event_family,
        concept_id,
        MIN(CASE WHEN 2.0 * rn >= cnt THEN CAST(days_before AS FLOAT) END) AS median_days_before
    FROM (
        SELECT
            anchor_event,
            event_family,
            concept_id,
            days_before,
            ROW_NUMBER() OVER (PARTITION BY anchor_event, event_family, concept_id ORDER BY days_before) AS rn,
            COUNT(*)     OVER (PARTITION BY anchor_event, event_family, concept_id)                      AS cnt
        FROM dir
        WHERE days_before IS NOT NULL
    ) x
    GROUP BY anchor_event, event_family, concept_id
),
med_after AS (
    SELECT
        anchor_event,
        event_family,
        concept_id,
        MIN(CASE WHEN 2.0 * rn >= cnt THEN CAST(days_after AS FLOAT) END) AS median_days_after
    FROM (
        SELECT
            anchor_event,
            event_family,
            concept_id,
            days_after,
            ROW_NUMBER() OVER (PARTITION BY anchor_event, event_family, concept_id ORDER BY days_after) AS rn,
            COUNT(*)     OVER (PARTITION BY anchor_event, event_family, concept_id)                     AS cnt
        FROM dir
        WHERE days_after IS NOT NULL
    ) x
    GROUP BY anchor_event, event_family, concept_id
),
agg AS (
    SELECT
        anchor_event,
        event_family,
        concept_id,
        COUNT(*)                                                       AS n_ever,
        SUM(CASE WHEN days_before IS NOT NULL THEN 1 ELSE 0 END)       AS n_before_ever,
        SUM(CASE WHEN days_before <= 30  THEN 1 ELSE 0 END)            AS n_before_30,
        SUM(CASE WHEN days_before <= 90  THEN 1 ELSE 0 END)            AS n_before_90,
        SUM(CASE WHEN days_before <= 180 THEN 1 ELSE 0 END)            AS n_before_180,
        SUM(CASE WHEN days_before <= 365 THEN 1 ELSE 0 END)            AS n_before_365,
        SUM(CASE WHEN days_before <= 730 THEN 1 ELSE 0 END)            AS n_before_730,
        SUM(has_day0)                                                  AS n_day0,
        SUM(CASE WHEN days_after IS NOT NULL THEN 1 ELSE 0 END)        AS n_after_ever,
        SUM(CASE WHEN days_after <= 30  THEN 1 ELSE 0 END)             AS n_after_30,
        SUM(CASE WHEN days_after <= 90  THEN 1 ELSE 0 END)             AS n_after_90,
        SUM(CASE WHEN days_after <= 180 THEN 1 ELSE 0 END)             AS n_after_180,
        SUM(CASE WHEN days_after <= 365 THEN 1 ELSE 0 END)             AS n_after_365,
        SUM(CASE WHEN days_after <= 730 THEN 1 ELSE 0 END)             AS n_after_730
    FROM dir
    GROUP BY anchor_event, event_family, concept_id
)
SELECT
    a.anchor_event,
    a.event_family,
    a.concept_id,
    CASE WHEN a.n_ever        > 0 AND a.n_ever        <= @min_cell_count THEN -@min_cell_count ELSE a.n_ever        END AS n_ever,
    CASE WHEN a.n_before_ever > 0 AND a.n_before_ever <= @min_cell_count THEN -@min_cell_count ELSE a.n_before_ever END AS n_before_ever,
    CASE WHEN a.n_before_30   > 0 AND a.n_before_30   <= @min_cell_count THEN -@min_cell_count ELSE a.n_before_30   END AS n_within_30d_before,
    CASE WHEN a.n_before_90   > 0 AND a.n_before_90   <= @min_cell_count THEN -@min_cell_count ELSE a.n_before_90   END AS n_within_90d_before,
    CASE WHEN a.n_before_180  > 0 AND a.n_before_180  <= @min_cell_count THEN -@min_cell_count ELSE a.n_before_180  END AS n_within_180d_before,
    CASE WHEN a.n_before_365  > 0 AND a.n_before_365  <= @min_cell_count THEN -@min_cell_count ELSE a.n_before_365  END AS n_within_365d_before,
    CASE WHEN a.n_before_730  > 0 AND a.n_before_730  <= @min_cell_count THEN -@min_cell_count ELSE a.n_before_730  END AS n_within_730d_before,
    CASE WHEN a.n_before_ever <= @min_cell_count THEN NULL ELSE mb.median_days_before END AS median_days_before,
    CASE WHEN a.n_day0        > 0 AND a.n_day0        <= @min_cell_count THEN -@min_cell_count ELSE a.n_day0        END AS n_day0,
    CASE WHEN a.n_after_ever  > 0 AND a.n_after_ever  <= @min_cell_count THEN -@min_cell_count ELSE a.n_after_ever  END AS n_after_ever,
    CASE WHEN a.n_after_30    > 0 AND a.n_after_30    <= @min_cell_count THEN -@min_cell_count ELSE a.n_after_30    END AS n_within_30d_after,
    CASE WHEN a.n_after_90    > 0 AND a.n_after_90    <= @min_cell_count THEN -@min_cell_count ELSE a.n_after_90    END AS n_within_90d_after,
    CASE WHEN a.n_after_180   > 0 AND a.n_after_180   <= @min_cell_count THEN -@min_cell_count ELSE a.n_after_180   END AS n_within_180d_after,
    CASE WHEN a.n_after_365   > 0 AND a.n_after_365   <= @min_cell_count THEN -@min_cell_count ELSE a.n_after_365   END AS n_within_365d_after,
    CASE WHEN a.n_after_730   > 0 AND a.n_after_730   <= @min_cell_count THEN -@min_cell_count ELSE a.n_after_730   END AS n_within_730d_after,
    CASE WHEN a.n_after_ever  <= @min_cell_count THEN NULL ELSE ma.median_days_after END AS median_days_after
FROM agg a
LEFT JOIN med_before mb
  ON  mb.anchor_event = a.anchor_event
  AND mb.event_family = a.event_family
  AND mb.concept_id   = a.concept_id
LEFT JOIN med_after ma
  ON  ma.anchor_event = a.anchor_event
  AND ma.event_family = a.event_family
  AND ma.concept_id   = a.concept_id
ORDER BY
    CASE WHEN a.anchor_event = 'INDEX' THEN 0 ELSE 1 END,
    a.event_family,
    a.n_ever DESC,
    a.concept_id
;

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

-- 7) L01 treatment exposure in 30-day windows around anchor dates
--    For each 30-day window k (window_start = anchor + 30*k days,
--    window_end = anchor + 30*(k+1) - 1 days), counts the number of
--    distinct patients with at least one L01 drug_exposure_start_date in
--    that window, as a fraction of the eligible denominator.
--
--    Two anchors:
--      INDEX    : all DX cohort patients; windows -12 to +48 (3 yr post-DX)
--      FIRST_MET: all patients with first_met_date; windows -6 to +24 (2 yr post-MET)
--
--    The denominator for each window is the number of patients whose
--    observation period covers the window midpoint (anchor + 30*k + 15 days).
--    This avoids deflating late windows due to censoring.
--    If observation_period data is unavailable, denominator = all anchor patients
--    (conservative; may underestimate late-window rates).
--
--    Output: one row per (anchor_event, window_index).
--    window_index: integer; window covers [anchor + 30*k, anchor + 30*(k+1) - 1].
--    Small-cell suppression on n_patients_with_l01.

WITH window_bounds AS (
    -- All (anchor, patient, window_index) combinations in scope
    SELECT
        'INDEX' AS anchor_event,
        c.person_id,
        c.index_date AS anchor_date,
        w.window_index
    FROM #cohort c
    CROSS JOIN (
        SELECT -12 AS window_index UNION ALL SELECT -11 UNION ALL SELECT -10
        UNION ALL SELECT -9  UNION ALL SELECT -8  UNION ALL SELECT -7
        UNION ALL SELECT -6  UNION ALL SELECT -5  UNION ALL SELECT -4
        UNION ALL SELECT -3  UNION ALL SELECT -2  UNION ALL SELECT -1
        UNION ALL SELECT  0  UNION ALL SELECT  1  UNION ALL SELECT  2
        UNION ALL SELECT  3  UNION ALL SELECT  4  UNION ALL SELECT  5
        UNION ALL SELECT  6  UNION ALL SELECT  7  UNION ALL SELECT  8
        UNION ALL SELECT  9  UNION ALL SELECT 10  UNION ALL SELECT 11
        UNION ALL SELECT 12  UNION ALL SELECT 13  UNION ALL SELECT 14
        UNION ALL SELECT 15  UNION ALL SELECT 16  UNION ALL SELECT 17
        UNION ALL SELECT 18  UNION ALL SELECT 19  UNION ALL SELECT 20
        UNION ALL SELECT 21  UNION ALL SELECT 22  UNION ALL SELECT 23
        UNION ALL SELECT 24  UNION ALL SELECT 25  UNION ALL SELECT 26
        UNION ALL SELECT 27  UNION ALL SELECT 28  UNION ALL SELECT 29
        UNION ALL SELECT 30  UNION ALL SELECT 31  UNION ALL SELECT 32
        UNION ALL SELECT 33  UNION ALL SELECT 34  UNION ALL SELECT 35
        UNION ALL SELECT 36  UNION ALL SELECT 37  UNION ALL SELECT 38
        UNION ALL SELECT 39  UNION ALL SELECT 40  UNION ALL SELECT 41
        UNION ALL SELECT 42  UNION ALL SELECT 43  UNION ALL SELECT 44
        UNION ALL SELECT 45  UNION ALL SELECT 46  UNION ALL SELECT 47
    ) w

    UNION ALL

    SELECT
        'FIRST_MET' AS anchor_event,
        ms.person_id,
        ms.first_met_date AS anchor_date,
        w.window_index
    FROM #met_summary ms
    CROSS JOIN (
        SELECT -6  AS window_index UNION ALL SELECT -5  UNION ALL SELECT -4
        UNION ALL SELECT -3  UNION ALL SELECT -2  UNION ALL SELECT -1
        UNION ALL SELECT  0  UNION ALL SELECT  1  UNION ALL SELECT  2
        UNION ALL SELECT  3  UNION ALL SELECT  4  UNION ALL SELECT  5
        UNION ALL SELECT  6  UNION ALL SELECT  7  UNION ALL SELECT  8
        UNION ALL SELECT  9  UNION ALL SELECT 10  UNION ALL SELECT 11
        UNION ALL SELECT 12  UNION ALL SELECT 13  UNION ALL SELECT 14
        UNION ALL SELECT 15  UNION ALL SELECT 16  UNION ALL SELECT 17
        UNION ALL SELECT 18  UNION ALL SELECT 19  UNION ALL SELECT 20
        UNION ALL SELECT 21  UNION ALL SELECT 22  UNION ALL SELECT 23
    ) w
    WHERE ms.first_met_date IS NOT NULL
),
-- Mark which patients have at least one L01 exposure in each window
window_l01 AS (
    SELECT
        wb.anchor_event,
        wb.person_id,
        wb.window_index,
        wb.anchor_date,
        MAX(
            CASE
                WHEN le.event_date >= DATEADD(DAY, 30 * wb.window_index,     wb.anchor_date)
                 AND le.event_date <  DATEADD(DAY, 30 * (wb.window_index + 1), wb.anchor_date)
                THEN 1 ELSE 0
            END
        ) AS has_l01_in_window
    FROM window_bounds wb
    LEFT JOIN #l01_events le
      ON wb.person_id = le.person_id
    GROUP BY wb.anchor_event, wb.person_id, wb.window_index, wb.anchor_date
),
-- Denominator: patients observed through the window midpoint
-- (anchor + 30*k + 15 days must be within at least one observation period)
window_denom AS (
    SELECT
        wb.anchor_event,
        wb.person_id,
        wb.window_index,
        wb.anchor_date,
        MAX(
            CASE
                WHEN op.observation_period_start_date <= DATEADD(DAY, 30 * wb.window_index + 15, wb.anchor_date)
                 AND op.observation_period_end_date   >= DATEADD(DAY, 30 * wb.window_index + 15, wb.anchor_date)
                THEN 1 ELSE 0
            END
        ) AS observed_at_midpoint
    FROM window_bounds wb
    LEFT JOIN @cdm_database_schema.observation_period op
      ON op.person_id = wb.person_id
    GROUP BY wb.anchor_event, wb.person_id, wb.window_index, wb.anchor_date
),
agg AS (
    SELECT
        wl.anchor_event,
        wl.window_index,
        COUNT(*)                    AS n_eligible,
        SUM(wd.observed_at_midpoint) AS n_observed,
        SUM(wl.has_l01_in_window)   AS n_patients_with_l01
    FROM window_l01 wl
    JOIN window_denom wd
      ON wd.anchor_event = wl.anchor_event
     AND wd.person_id    = wl.person_id
     AND wd.window_index = wl.window_index
    GROUP BY wl.anchor_event, wl.window_index
)
SELECT
    a.anchor_event,
    a.window_index,
    a.n_eligible,
    CASE WHEN a.n_observed          <= @min_cell_count THEN -@min_cell_count ELSE a.n_observed          END AS n_observed,
    CASE WHEN a.n_patients_with_l01 <= @min_cell_count THEN -@min_cell_count ELSE a.n_patients_with_l01 END AS n_patients_with_l01
FROM agg a
ORDER BY a.anchor_event, a.window_index
;

-- 8) Death timing from INDEX and FIRST_MET (stratified by calendar year of index date and OVERALL)
SELECT
    s.prevalence_year,
    s.anchor_event,
    CASE WHEN s.n_patients <= @min_cell_count THEN -@min_cell_count ELSE s.n_patients END AS n_patients,
    CASE
        WHEN s.n_patients <= @min_cell_count THEN -@min_cell_count
        WHEN s.n_deaths BETWEEN 1 AND @min_cell_count THEN -@min_cell_count
        ELSE s.n_deaths
    END AS n_deaths,
    CASE WHEN s.n_patients <= @min_cell_count OR s.n_deaths <= @min_cell_count THEN NULL ELSE s.n_deaths_in_obs END AS n_deaths_in_obs,
    CASE WHEN s.n_patients <= @min_cell_count OR s.n_deaths <= @min_cell_count THEN NULL ELSE s.n_deaths_out_obs END AS n_deaths_out_obs,
    CASE WHEN s.n_patients <= @min_cell_count OR s.n_deaths <= @min_cell_count THEN NULL ELSE q.lq_days END AS lq_days,
    CASE WHEN s.n_patients <= @min_cell_count OR s.n_deaths <= @min_cell_count THEN NULL ELSE q.median_days END AS median_days,
    CASE WHEN s.n_patients <= @min_cell_count OR s.n_deaths <= @min_cell_count THEN NULL ELSE q.uq_days END AS uq_days,
    CASE WHEN s.n_patients <= @min_cell_count THEN NULL ELSE f.lq_followup_days END AS lq_followup_days,
    CASE WHEN s.n_patients <= @min_cell_count THEN NULL ELSE f.median_followup_days END AS median_followup_days,
    CASE WHEN s.n_patients <= @min_cell_count THEN NULL ELSE f.uq_followup_days END AS uq_followup_days
FROM #death_stratum_counts s
LEFT JOIN #death_timing_quantiles q
  ON s.prevalence_year = q.prevalence_year
 AND s.anchor_event = q.anchor_event
LEFT JOIN #followup_quantiles f
  ON s.prevalence_year = f.prevalence_year
 AND s.anchor_event = f.anchor_event
ORDER BY
    CASE WHEN s.prevalence_year = 'OVERALL' THEN 0 ELSE 1 END,
    CASE WHEN s.prevalence_year = 'OVERALL' THEN NULL ELSE CAST(s.prevalence_year AS INT) END,
    CASE WHEN s.anchor_event = 'INDEX' THEN 0 ELSE 1 END
;

-- 9) Demographics at anchor dates (INDEX = first DX, FIRST_MET = first MET)
-- Gender concept IDs (OMOP): 8507=Male, 8532=Female. Others treated as unknown.
WITH anchor_persons AS (
    SELECT
        'INDEX' AS anchor_event,
        c.person_id,
        c.index_date AS anchor_date
    FROM #patient_char c
    WHERE c.index_date IS NOT NULL
    UNION ALL
    SELECT
        'FIRST_MET' AS anchor_event,
        c.person_id,
        c.first_met_date AS anchor_date
    FROM #patient_char c
    WHERE c.first_met_date IS NOT NULL
),
base AS (
    SELECT
        a.anchor_event,
        a.person_id,
        a.anchor_date,
        p.gender_concept_id,
        p.birth_datetime,
        p.year_of_birth
    FROM anchor_persons a
    JOIN @cdm_database_schema.person p
      ON a.person_id = p.person_id
),
ages AS (
    SELECT
        anchor_event,
        person_id,
        gender_concept_id,
        CASE
            WHEN birth_datetime IS NOT NULL
                THEN DATEDIFF(DAY, CAST(birth_datetime AS DATE), anchor_date) / 365.25
            WHEN year_of_birth IS NOT NULL
                THEN DATEDIFF(DAY, DATEFROMPARTS(year_of_birth, 7, 1), anchor_date) / 365.25
            ELSE NULL
        END AS age_years
    FROM base
)
SELECT
    agg.anchor_event,
    agg.n_patients,
    agg.n_male,
    agg.n_female,
    agg.pct_male,
    agg.pct_female,
    p.age_lq_years,
    p.age_median_years,
    p.age_uq_years
FROM (
    SELECT
        anchor_event,
        COUNT(*) AS n_patients,
        SUM(CASE WHEN gender_concept_id = 8507 THEN 1 ELSE 0 END) AS n_male,
        SUM(CASE WHEN gender_concept_id = 8532 THEN 1 ELSE 0 END) AS n_female,
        CAST(100.0 * SUM(CASE WHEN gender_concept_id = 8507 THEN 1 ELSE 0 END) / NULLIF(COUNT(*), 0) AS FLOAT) AS pct_male,
        CAST(100.0 * SUM(CASE WHEN gender_concept_id = 8532 THEN 1 ELSE 0 END) / NULLIF(COUNT(*), 0) AS FLOAT) AS pct_female
    FROM ages
    WHERE age_years IS NOT NULL
    GROUP BY anchor_event
) agg
JOIN (
    SELECT
        anchor_event,
        MIN(CASE WHEN 4.0 * rn >= cnt THEN CAST(age_years AS FLOAT) END) AS age_lq_years,
        MIN(CASE WHEN 2.0 * rn >= cnt THEN CAST(age_years AS FLOAT) END) AS age_median_years,
        MIN(CASE WHEN 4.0 * rn >= 3 * cnt THEN CAST(age_years AS FLOAT) END) AS age_uq_years
    FROM (
        SELECT anchor_event, age_years,
            ROW_NUMBER() OVER (PARTITION BY anchor_event ORDER BY age_years) AS rn,
            COUNT(*)     OVER (PARTITION BY anchor_event)                    AS cnt
        FROM ages
        WHERE age_years IS NOT NULL
    ) y
    GROUP BY anchor_event
) p
  ON agg.anchor_event = p.anchor_event
ORDER BY CASE WHEN agg.anchor_event = 'INDEX' THEN 0 ELSE 1 END
;

-- 10) Anchor DX (main cohort) codes: distinct patients and distinct patient-days per condition_concept_id
--     Patient-day = one calendar day per person (multiple DX rows on the same day collapse to one).
WITH dx_days AS (
    SELECT DISTINCT
        person_id,
        event_date,
        concept_id
    FROM #dx_events
)
SELECT
    s.concept_id,
    CASE WHEN s.n_distinct_patients <= @min_cell_count THEN -@min_cell_count ELSE s.n_distinct_patients END AS n_distinct_patients,
    CASE WHEN s.n_distinct_patients <= @min_cell_count THEN NULL ELSE s.n_distinct_patient_days END AS n_distinct_patient_days
FROM (
    SELECT
        concept_id,
        COUNT(DISTINCT person_id) AS n_distinct_patients,
        COUNT(*) AS n_distinct_patient_days
    FROM dx_days
    GROUP BY concept_id
) s
ORDER BY s.n_distinct_patients DESC, s.concept_id
;

-- 11) L01 consecutive record gap distribution — decile summary
--     Intermediate tables #l01_event_days and #l01_consecutive_gaps are
--     built in 00_setup.sql (section L).
--
--     Two subgroups:
--       ALL_L01 : all DX cohort patients with any L01 record
--       MET_L01 : patients who also have a first_met_date
--
--     Output: one row per subgroup with gap-day deciles.

--     Small-cell suppression: n_gaps <= @min_cell_count suppresses percentiles to NULL
--     and replaces counts with -@min_cell_count.

SELECT
    subgroup,
    CASE WHEN COUNT(*) > 0 AND COUNT(*) <= @min_cell_count THEN -@min_cell_count ELSE COUNT(*) END AS n_gaps,
    CASE WHEN COUNT(*) > 0 AND COUNT(*) <= @min_cell_count THEN -@min_cell_count ELSE COUNT(DISTINCT person_id) END AS n_patients_with_gaps,
    MIN(CASE WHEN cnt > @min_cell_count AND 10.0 * rn >= cnt      THEN CAST(gap_days AS FLOAT) END) AS p10_days,
    MIN(CASE WHEN cnt > @min_cell_count AND  4.0 * rn >= cnt      THEN CAST(gap_days AS FLOAT) END) AS p25_days,
    MIN(CASE WHEN cnt > @min_cell_count AND  2.0 * rn >= cnt      THEN CAST(gap_days AS FLOAT) END) AS p50_days,
    MIN(CASE WHEN cnt > @min_cell_count AND  4.0 * rn >= 3 * cnt  THEN CAST(gap_days AS FLOAT) END) AS p75_days,
    MIN(CASE WHEN cnt > @min_cell_count AND 10.0 * rn >= 9 * cnt  THEN CAST(gap_days AS FLOAT) END) AS p90_days
FROM (
    SELECT subgroup, person_id, gap_days,
        ROW_NUMBER() OVER (PARTITION BY subgroup ORDER BY gap_days) AS rn,
        COUNT(*)     OVER (PARTITION BY subgroup)                   AS cnt
    FROM #l01_consecutive_gaps
) x
GROUP BY subgroup
ORDER BY subgroup
;

-- 12) L01 consecutive record gap distribution — bucketed histogram
--     Intermediate table #l01_consecutive_gaps is built in 00_setup.sql
--     (section L).  Same subgroups as chunk 11 (ALL_L01, MET_L01).
--
--     Output: one row per (subgroup, gap_bucket) for histogram rendering.
--     Small-cell suppression: n_gaps <= @min_cell_count suppressed to -@min_cell_count.

SELECT
    subgroup,
    CASE
        WHEN gap_days <  30  THEN 'lt30d'
        WHEN gap_days <  60  THEN '30_59d'
        WHEN gap_days <  90  THEN '60_89d'
        WHEN gap_days < 180  THEN '90_179d'
        WHEN gap_days < 365  THEN '180_364d'
        ELSE 'ge365d'
    END AS gap_bucket,
    CASE WHEN COUNT(*) > 0 AND COUNT(*) <= @min_cell_count THEN -@min_cell_count ELSE COUNT(*) END AS n_gaps
FROM #l01_consecutive_gaps
GROUP BY
    subgroup,
    CASE
        WHEN gap_days <  30  THEN 'lt30d'
        WHEN gap_days <  60  THEN '30_59d'
        WHEN gap_days <  90  THEN '60_89d'
        WHEN gap_days < 180  THEN '90_179d'
        WHEN gap_days < 365  THEN '180_364d'
        ELSE 'ge365d'
    END
ORDER BY
    subgroup,
    MIN(CASE
        WHEN gap_days <  30  THEN 1
        WHEN gap_days <  60  THEN 2
        WHEN gap_days <  90  THEN 3
        WHEN gap_days < 180  THEN 4
        WHEN gap_days < 365  THEN 5
        ELSE 6
    END)
;

-- 13) Death date vs observation period alignment — summary counts
--     For patients in the DX cohort (and the FIRST_MET subgroup), reports:
--       - n_death_before_obs : death_date < first observation_period_start
--                              (data quality error — rare but important)
--       - n_death_after_obs  : death_date > last  observation_period_end
--                              (gap distribution summarized in chunk 14)
--       - lq/median/uq/p90 percentiles of the post-obs gap (days).
--
--     Stratified by anchor (INDEX / FIRST_MET).
--     Small-cell suppression: n_death_before_obs and n_death_after_obs use -@min_cell_count
--     when suppressed; percentile columns are set to NULL when n_death_after_obs is suppressed.

WITH patient_obs AS (
    SELECT
        person_id,
        MIN(observation_period_start_date) AS first_obs_start,
        MAX(observation_period_end_date)   AS last_obs_end
    FROM @cdm_database_schema.observation_period
    WHERE person_id IN (SELECT person_id FROM #cohort)
    GROUP BY person_id
),
death_obs_gaps AS (
    SELECT
        c.person_id,
        c.index_date,
        ms.first_met_date,
        dos.death_date,
        po.first_obs_start,
        po.last_obs_end,
        CASE
            WHEN dos.death_date > po.last_obs_end
                THEN DATEDIFF(DAY, po.last_obs_end, dos.death_date)
            ELSE NULL
        END AS gap_death_after_obs,
        CASE
            WHEN dos.death_date < po.first_obs_start
                THEN 1
            ELSE 0
        END AS death_before_obs
    FROM #cohort c
    INNER JOIN #death_obs_status dos ON dos.person_id = c.person_id
    LEFT JOIN #met_summary ms ON ms.person_id = c.person_id
    LEFT JOIN patient_obs po  ON po.person_id  = c.person_id
)
SELECT
    anchor_event,
    CASE WHEN n_death_before_obs > 0 AND n_death_before_obs <= @min_cell_count THEN -@min_cell_count ELSE n_death_before_obs END AS n_death_before_obs,
    CASE WHEN n_death_after_obs  > 0 AND n_death_after_obs  <= @min_cell_count THEN -@min_cell_count ELSE n_death_after_obs  END AS n_death_after_obs,
    CASE WHEN n_death_after_obs  > 0 AND n_death_after_obs  <= @min_cell_count THEN NULL ELSE lq_gap_days     END AS lq_gap_days,
    CASE WHEN n_death_after_obs  > 0 AND n_death_after_obs  <= @min_cell_count THEN NULL ELSE median_gap_days END AS median_gap_days,
    CASE WHEN n_death_after_obs  > 0 AND n_death_after_obs  <= @min_cell_count THEN NULL ELSE uq_gap_days     END AS uq_gap_days,
    CASE WHEN n_death_after_obs  > 0 AND n_death_after_obs  <= @min_cell_count THEN NULL ELSE p90_gap_days    END AS p90_gap_days
FROM (
    SELECT
        'INDEX' AS anchor_event,
        SUM(CASE WHEN death_before_obs = 1 THEN 1 ELSE 0 END) AS n_death_before_obs,
        SUM(CASE WHEN gap_death_after_obs IS NOT NULL THEN 1 ELSE 0 END) AS n_death_after_obs,
        MIN(CASE WHEN gap_death_after_obs IS NOT NULL AND  4.0 * rn >= non_null_cnt THEN CAST(gap_death_after_obs AS FLOAT) END) AS lq_gap_days,
        MIN(CASE WHEN gap_death_after_obs IS NOT NULL AND  2.0 * rn >= non_null_cnt THEN CAST(gap_death_after_obs AS FLOAT) END) AS median_gap_days,
        MIN(CASE WHEN gap_death_after_obs IS NOT NULL AND  4.0 * rn >= 3 * non_null_cnt THEN CAST(gap_death_after_obs AS FLOAT) END) AS uq_gap_days,
        MIN(CASE WHEN gap_death_after_obs IS NOT NULL AND 10.0 * rn >= 9 * non_null_cnt THEN CAST(gap_death_after_obs AS FLOAT) END) AS p90_gap_days
    FROM (
        SELECT death_before_obs, gap_death_after_obs,
            ROW_NUMBER() OVER (ORDER BY gap_death_after_obs) AS rn,
            SUM(CASE WHEN gap_death_after_obs IS NOT NULL THEN 1 ELSE 0 END) OVER () AS non_null_cnt
        FROM death_obs_gaps
        WHERE death_date IS NOT NULL
    ) x

    UNION ALL

    SELECT
        'FIRST_MET' AS anchor_event,
        SUM(CASE WHEN death_before_obs = 1 THEN 1 ELSE 0 END) AS n_death_before_obs,
        SUM(CASE WHEN gap_death_after_obs IS NOT NULL THEN 1 ELSE 0 END) AS n_death_after_obs,
        MIN(CASE WHEN gap_death_after_obs IS NOT NULL AND  4.0 * rn >= non_null_cnt THEN CAST(gap_death_after_obs AS FLOAT) END) AS lq_gap_days,
        MIN(CASE WHEN gap_death_after_obs IS NOT NULL AND  2.0 * rn >= non_null_cnt THEN CAST(gap_death_after_obs AS FLOAT) END) AS median_gap_days,
        MIN(CASE WHEN gap_death_after_obs IS NOT NULL AND  4.0 * rn >= 3 * non_null_cnt THEN CAST(gap_death_after_obs AS FLOAT) END) AS uq_gap_days,
        MIN(CASE WHEN gap_death_after_obs IS NOT NULL AND 10.0 * rn >= 9 * non_null_cnt THEN CAST(gap_death_after_obs AS FLOAT) END) AS p90_gap_days
    FROM (
        SELECT death_before_obs, gap_death_after_obs,
            ROW_NUMBER() OVER (ORDER BY gap_death_after_obs) AS rn,
            SUM(CASE WHEN gap_death_after_obs IS NOT NULL THEN 1 ELSE 0 END) OVER () AS non_null_cnt
        FROM death_obs_gaps
        WHERE death_date IS NOT NULL
          AND first_met_date IS NOT NULL
    ) x
) agg
;

-- 14) Death date vs observation period — bucketed gap histogram
--     Restricted to patients where death_date > obs_period_end_date.
--     Exported for both INDEX (all DX cohort) and FIRST_MET (MET subgroup)
--     so that each can be shown as a separate figure in the report.

WITH patient_obs AS (
    SELECT
        person_id,
        MIN(observation_period_start_date) AS first_obs_start,
        MAX(observation_period_end_date)   AS last_obs_end
    FROM @cdm_database_schema.observation_period
    WHERE person_id IN (SELECT person_id FROM #cohort)
    GROUP BY person_id
),
death_obs_gaps AS (
    SELECT
        c.person_id,
        ms.first_met_date,
        CASE
            WHEN dos.death_date > po.last_obs_end
                THEN DATEDIFF(DAY, po.last_obs_end, dos.death_date)
            ELSE NULL
        END AS gap_death_after_obs
    FROM #cohort c
    INNER JOIN #death_obs_status dos ON dos.person_id = c.person_id
    LEFT JOIN #met_summary ms        ON ms.person_id  = c.person_id
    LEFT JOIN patient_obs po         ON po.person_id  = c.person_id
),
bucketed AS (
    SELECT
        person_id,
        first_met_date,
        CASE
            WHEN gap_death_after_obs <   30 THEN 'lt30d'
            WHEN gap_death_after_obs <   60 THEN '30_59d'
            WHEN gap_death_after_obs <   90 THEN '60_89d'
            WHEN gap_death_after_obs <  180 THEN '90_179d'
            WHEN gap_death_after_obs <  365 THEN '180_364d'
            WHEN gap_death_after_obs <  730 THEN '365_729d'
            ELSE 'ge730d'
        END AS gap_bucket,
        CASE
            WHEN gap_death_after_obs <   30 THEN 1
            WHEN gap_death_after_obs <   60 THEN 2
            WHEN gap_death_after_obs <   90 THEN 3
            WHEN gap_death_after_obs <  180 THEN 4
            WHEN gap_death_after_obs <  365 THEN 5
            WHEN gap_death_after_obs <  730 THEN 6
            ELSE 7
        END AS sort_key
    FROM death_obs_gaps
    WHERE gap_death_after_obs IS NOT NULL
)
SELECT anchor_event, gap_bucket, n_patients
FROM (
    SELECT 'INDEX' AS anchor_event, gap_bucket,
        CASE WHEN COUNT(*) > 0 AND COUNT(*) <= @min_cell_count THEN -@min_cell_count ELSE COUNT(*) END AS n_patients,
        MIN(sort_key) AS sort_key
    FROM bucketed
    GROUP BY gap_bucket

    UNION ALL

    SELECT 'FIRST_MET' AS anchor_event, gap_bucket,
        CASE WHEN COUNT(*) > 0 AND COUNT(*) <= @min_cell_count THEN -@min_cell_count ELSE COUNT(*) END AS n_patients,
        MIN(sort_key) AS sort_key
    FROM bucketed
    WHERE first_met_date IS NOT NULL
    GROUP BY gap_bucket
) x
ORDER BY
    CASE WHEN anchor_event = 'INDEX' THEN 0 ELSE 1 END,
    sort_key
;

-- 15) Distribution of distinct L01 event days per patient
--     Shows how many patients have 1, 2-6, 7-11, or 12+ distinct L01 days.
--     Patients with exactly 1 day cannot contribute to gap analyses (chunks 11-12).
--     Source: #l01_event_days (built in 00_setup.sql section L).
--
--     Two subgroups:
--       ALL_L01 : all DX cohort patients with any L01 record
--       MET_L01 : patients who also have a first_met_date
--     Small-cell suppression: n_patients <= @min_cell_count suppressed to -@min_cell_count.

SELECT
    subgroup,
    CASE
        WHEN n_days =  1 THEN '1'
        WHEN n_days <= 6 THEN '2_6'
        WHEN n_days <= 11 THEN '7_11'
        ELSE '12plus'
    END AS days_bucket,
    CASE WHEN COUNT(*) > 0 AND COUNT(*) <= @min_cell_count THEN -@min_cell_count ELSE COUNT(*) END AS n_patients
FROM (
    SELECT e.person_id, COUNT(*) AS n_days, 'ALL_L01' AS subgroup
    FROM #l01_event_days e
    GROUP BY e.person_id
    UNION ALL
    SELECT e.person_id, COUNT(*) AS n_days, 'MET_L01' AS subgroup
    FROM #l01_event_days e
    JOIN #met_summary ms ON e.person_id = ms.person_id AND ms.first_met_date IS NOT NULL
    GROUP BY e.person_id
) x
GROUP BY
    subgroup,
    CASE
        WHEN n_days =  1 THEN '1'
        WHEN n_days <= 6 THEN '2_6'
        WHEN n_days <= 11 THEN '7_11'
        ELSE '12plus'
    END
ORDER BY
    subgroup,
    MIN(n_days)
;

-- 16) E. Observation-period characterization — observability around the index
--     How much observable time each patient has BEFORE the index (look-back) and
--     AFTER the index (follow-up), reported as cumulative day-threshold counts:
--     the number of patients with fewer than 30 / 90 / 180 / 365 days of
--     observation on each side of the index. Look-back and follow-up are kept
--     strictly separate (one row per side); day 0 sits on the follow-up side
--     (follow-up = days from the index to the observation-period end, >= 0).
--
--     Observable time is measured inside the single observation period that
--     CONTAINS the anchor date, so both sides are contiguous observable time:
--       look-back_days = index_date - observation_period_start_date
--       follow-up_days = observation_period_end_date - index_date
--     A patient contributes only if the anchor date falls within one of their
--     observation periods. For INDEX this holds for every cohort patient by
--     construction (see #cohort in 00_setup.sql); for FIRST_MET it holds only
--     for patients whose first metastasis date is inside an observation period.
--
--     Two anchors: INDEX (first qualifying DX = cohort index date) and FIRST_MET
--     (first metastasis date). Source: #cohort, #met_summary (00_setup.sql) and
--     @cdm_database_schema.observation_period.
--     Small-cell suppression: threshold counts in (0, @min_cell_count] are set to
--     -@min_cell_count; median set to NULL when the group denominator is suppressed.
--     n_patients is an aggregate cohort denominator and is not suppressed, matching
--     the existing death/prevalence chunks.

WITH obs_around_anchor AS (
    -- INDEX anchor: index_date is guaranteed to fall inside an observation period.
    SELECT
        'INDEX' AS anchor_event,
        c.person_id,
        DATEDIFF(DAY, op.observation_period_start_date, c.index_date) AS lookback_days,
        DATEDIFF(DAY, c.index_date, op.observation_period_end_date)   AS followup_days
    FROM #cohort c
    INNER JOIN @cdm_database_schema.observation_period op
        ON  op.person_id = c.person_id
        AND c.index_date BETWEEN op.observation_period_start_date
                             AND op.observation_period_end_date
    UNION ALL
    -- FIRST_MET anchor: only patients whose first metastasis date is inside a period.
    SELECT
        'FIRST_MET' AS anchor_event,
        c.person_id,
        DATEDIFF(DAY, op.observation_period_start_date, ms.first_met_date) AS lookback_days,
        DATEDIFF(DAY, ms.first_met_date, op.observation_period_end_date)   AS followup_days
    FROM #cohort c
    INNER JOIN #met_summary ms
        ON ms.person_id = c.person_id AND ms.first_met_date IS NOT NULL
    INNER JOIN @cdm_database_schema.observation_period op
        ON  op.person_id = c.person_id
        AND ms.first_met_date BETWEEN op.observation_period_start_date
                                  AND op.observation_period_end_date
),
obs_sided AS (
    SELECT anchor_event, person_id, 'LOOKBACK_BEFORE_ANCHOR' AS observation_side, lookback_days AS obs_days
    FROM obs_around_anchor
    UNION ALL
    SELECT anchor_event, person_id, 'FOLLOWUP_AFTER_ANCHOR'  AS observation_side, followup_days AS obs_days
    FROM obs_around_anchor
),
ranked AS (
    SELECT
        anchor_event,
        observation_side,
        obs_days,
        ROW_NUMBER() OVER (PARTITION BY anchor_event, observation_side ORDER BY obs_days) AS rn,
        COUNT(*)     OVER (PARTITION BY anchor_event, observation_side)                    AS cnt
    FROM obs_sided
),
agg AS (
    SELECT
        anchor_event,
        observation_side,
        COUNT(*) AS n_patients,
        SUM(CASE WHEN obs_days < 30  THEN 1 ELSE 0 END) AS n_lt_30d,
        SUM(CASE WHEN obs_days < 90  THEN 1 ELSE 0 END) AS n_lt_90d,
        SUM(CASE WHEN obs_days < 180 THEN 1 ELSE 0 END) AS n_lt_180d,
        SUM(CASE WHEN obs_days < 365 THEN 1 ELSE 0 END) AS n_lt_365d,
        MIN(CASE WHEN 2.0 * rn >= cnt THEN CAST(obs_days AS FLOAT) END) AS median_days
    FROM ranked
    GROUP BY anchor_event, observation_side
)
SELECT
    anchor_event,
    observation_side,
    n_patients,
    CASE WHEN n_lt_30d  > 0 AND n_lt_30d  <= @min_cell_count THEN -@min_cell_count ELSE n_lt_30d  END AS n_lt_30d,
    CASE WHEN n_lt_90d  > 0 AND n_lt_90d  <= @min_cell_count THEN -@min_cell_count ELSE n_lt_90d  END AS n_lt_90d,
    CASE WHEN n_lt_180d > 0 AND n_lt_180d <= @min_cell_count THEN -@min_cell_count ELSE n_lt_180d END AS n_lt_180d,
    CASE WHEN n_lt_365d > 0 AND n_lt_365d <= @min_cell_count THEN -@min_cell_count ELSE n_lt_365d END AS n_lt_365d,
    CASE WHEN n_patients <= @min_cell_count THEN NULL ELSE median_days END AS median_days
FROM agg
ORDER BY
    CASE anchor_event WHEN 'INDEX' THEN 0 ELSE 1 END,
    CASE observation_side WHEN 'LOOKBACK_BEFORE_ANCHOR' THEN 0 ELSE 1 END
;

-- 17) E. Observation-period characterization — integrity checks
--     Whether the observation period behaves the way a phenotype would assume.
--     Long format: one row per (anchor_event, metric, stratum). Metrics:
--
--       PERIOD_TYPE_CONCEPT              (anchor_event = 'ALL')
--           How the period is defined at this site. One row per distinct
--           observation_period.period_type_concept_id among cohort patients.
--           n_numerator   = distinct cohort patients with a period of this type
--           n_denominator = distinct cohort patients with any period
--           (states the definition/source: claims-enrollment vs EHR-estimated
--            period types resolve to different concept ids; label upstream).
--
--       PATIENTS_WITH_MULTIPLE_OBS_PERIODS   (per anchor)
--           n_numerator   = patients with more than one observation period (a gap)
--           n_denominator = patients in this anchor's cohort
--
--       DEATHS_OUTSIDE_OBS_PERIOD            (per anchor)
--           n_numerator   = deaths on/after the anchor recorded outside any period
--           n_denominator = deaths on/after the anchor
--           (read straight from #death_stratum_counts OVERALL rows.)
--
--       DECEDENTS_PERIOD_ENDS_AFTER_DEATH    (per anchor)
--           n_numerator   = decedents whose last observation_period_end_date is
--                           AFTER the death date (period runs past death)
--           n_denominator = decedents (deaths on/after the anchor)
--
--       MEDIAN_DAYS_PERIOD_ENDS_PAST_DEATH   (per anchor)
--           median_days   = median (last_obs_end - death_date) among the decedents
--                           counted in DECEDENTS_PERIOD_ENDS_AFTER_DEATH
--           n_denominator = count of those decedents
--
--     Anchors: INDEX (cohort index date) and FIRST_MET (first metastasis date).
--     Sources: #cohort, #met_summary, #death_obs_status, #death_stratum_counts
--     (00_setup.sql) and @cdm_database_schema.observation_period.
--     Small-cell suppression: n_numerator in (0, @min_cell_count] set to
--     -@min_cell_count; median set to NULL when its decedent denominator is
--     suppressed. Aggregate cohort/death denominators are not suppressed.

WITH patient_obs AS (
    SELECT
        person_id,
        MAX(observation_period_end_date) AS last_obs_end,
        COUNT(*)                         AS n_periods
    FROM @cdm_database_schema.observation_period
    WHERE person_id IN (SELECT person_id FROM #cohort)
    GROUP BY person_id
),
period_type_patients AS (
    SELECT
        op.period_type_concept_id,
        COUNT(DISTINCT op.person_id) AS n_patients
    FROM @cdm_database_schema.observation_period op
    WHERE op.person_id IN (SELECT person_id FROM #cohort)
    GROUP BY op.period_type_concept_id
),
period_type_total AS (
    SELECT COUNT(DISTINCT person_id) AS n_patients_any_period
    FROM @cdm_database_schema.observation_period
    WHERE person_id IN (SELECT person_id FROM #cohort)
),
-- Anchor cohorts: INDEX = full DX cohort; FIRST_MET = cohort with a metastasis.
anchor_cohort AS (
    SELECT 'INDEX' AS anchor_event, c.person_id, po.n_periods
    FROM #cohort c
    LEFT JOIN patient_obs po ON po.person_id = c.person_id
    UNION ALL
    SELECT 'FIRST_MET' AS anchor_event, c.person_id, po.n_periods
    FROM #cohort c
    INNER JOIN #met_summary ms ON ms.person_id = c.person_id AND ms.first_met_date IS NOT NULL
    LEFT JOIN patient_obs po ON po.person_id = c.person_id
),
-- Decedents relative to each anchor, with whether the period runs past death.
decedent_anchor AS (
    SELECT
        'INDEX' AS anchor_event,
        dos.death_date,
        CASE WHEN po.last_obs_end > dos.death_date THEN 1 ELSE 0 END AS period_ends_after_death,
        CASE WHEN po.last_obs_end > dos.death_date
             THEN DATEDIFF(DAY, dos.death_date, po.last_obs_end) END  AS days_past_death
    FROM #cohort c
    INNER JOIN #death_obs_status dos ON dos.person_id = c.person_id
    LEFT JOIN patient_obs po ON po.person_id = c.person_id
    WHERE dos.death_date >= c.index_date
    UNION ALL
    SELECT
        'FIRST_MET' AS anchor_event,
        dos.death_date,
        CASE WHEN po.last_obs_end > dos.death_date THEN 1 ELSE 0 END,
        CASE WHEN po.last_obs_end > dos.death_date
             THEN DATEDIFF(DAY, dos.death_date, po.last_obs_end) END
    FROM #cohort c
    INNER JOIN #met_summary ms ON ms.person_id = c.person_id AND ms.first_met_date IS NOT NULL
    INNER JOIN #death_obs_status dos ON dos.person_id = c.person_id
    LEFT JOIN patient_obs po ON po.person_id = c.person_id
    WHERE dos.death_date >= ms.first_met_date
),
decedent_days_ranked AS (
    -- Rank ONLY the decedents whose period runs past death (days_past_death
    -- populated). Ranking over the full decedent set would let the NULL rows
    -- (period does not run past death) consume the lowest row numbers, since
    -- SQL Server sorts NULLs first, and the ordered-set median filter below would
    -- then pick the minimum rather than the true median. Match the non-NULL-inside
    -- pattern used by chunks 06b, 23, 27, 28, 34.
    SELECT
        anchor_event,
        days_past_death,
        ROW_NUMBER() OVER (PARTITION BY anchor_event ORDER BY days_past_death) AS rn,
        COUNT(*)     OVER (PARTITION BY anchor_event)                          AS non_null_cnt
    FROM decedent_anchor
    WHERE days_past_death IS NOT NULL
),
metrics AS (
    -- (1) period definition: period_type distribution (site-level)
    SELECT
        'ALL' AS anchor_event,
        'PERIOD_TYPE_CONCEPT' AS metric,
        CAST(ptp.period_type_concept_id AS VARCHAR(20)) AS stratum,
        ptp.n_patients AS n_numerator,
        ptt.n_patients_any_period AS n_denominator,
        CAST(NULL AS FLOAT) AS median_days
    FROM period_type_patients ptp
    CROSS JOIN period_type_total ptt

    UNION ALL
    -- (2) patients with more than one observation period (a gap)
    SELECT
        anchor_event,
        'PATIENTS_WITH_MULTIPLE_OBS_PERIODS',
        '',
        SUM(CASE WHEN n_periods > 1 THEN 1 ELSE 0 END),
        COUNT(*),
        CAST(NULL AS FLOAT)
    FROM anchor_cohort
    GROUP BY anchor_event

    UNION ALL
    -- (3) deaths recorded outside any observation period
    SELECT
        anchor_event,
        'DEATHS_OUTSIDE_OBS_PERIOD',
        '',
        n_deaths_out_obs,
        n_deaths,
        CAST(NULL AS FLOAT)
    FROM #death_stratum_counts
    WHERE prevalence_year = 'OVERALL'

    UNION ALL
    -- (4) decedents whose observation period ends after the death date
    SELECT
        anchor_event,
        'DECEDENTS_PERIOD_ENDS_AFTER_DEATH',
        '',
        SUM(period_ends_after_death),
        COUNT(*),
        CAST(NULL AS FLOAT)
    FROM decedent_anchor
    GROUP BY anchor_event

    UNION ALL
    -- (5) median days the period runs past death, among those decedents
    SELECT
        anchor_event,
        'MEDIAN_DAYS_PERIOD_ENDS_PAST_DEATH',
        '',
        CAST(NULL AS INT),
        MAX(non_null_cnt),
        MIN(CASE WHEN 2.0 * rn >= non_null_cnt
                 THEN CAST(days_past_death AS FLOAT) END)
    FROM decedent_days_ranked
    GROUP BY anchor_event
)
SELECT
    anchor_event,
    metric,
    stratum,
    CASE WHEN n_numerator IS NOT NULL AND n_numerator > 0 AND n_numerator <= @min_cell_count
         THEN -@min_cell_count ELSE n_numerator END AS n_numerator,
    n_denominator,
    CASE WHEN median_days IS NOT NULL AND n_denominator IS NOT NULL AND n_denominator <= @min_cell_count
         THEN NULL ELSE median_days END AS median_days
FROM metrics
ORDER BY
    CASE metric
        WHEN 'PERIOD_TYPE_CONCEPT'                 THEN 0
        WHEN 'PATIENTS_WITH_MULTIPLE_OBS_PERIODS'  THEN 1
        WHEN 'DEATHS_OUTSIDE_OBS_PERIOD'           THEN 2
        WHEN 'DECEDENTS_PERIOD_ENDS_AFTER_DEATH'   THEN 3
        WHEN 'MEDIAN_DAYS_PERIOD_ENDS_PAST_DEATH'  THEN 4
        ELSE 9
    END,
    CASE anchor_event WHEN 'ALL' THEN 0 WHEN 'INDEX' THEN 1 ELSE 2 END,
    stratum
;

-- 18) F. Index event record counts (part 1) — how often the code repeats
--     Distribution of the number of records per patient, for the anchor
--     Diagnosis and the anchor Metastasis. This counts RECORDS (rows in the
--     source table), not distinct days — a heavily repeated code shows up here.
--     (Part 2, chunk 19, measures the timescale between distinct Diagnosis days.)
--
--       DX  buckets: exactly 1 / 2 to 5 / 6 or more records per patient
--       MET buckets: exactly 1 / 2 or more records per patient
--
--     Denominators (n_patients_total, repeated on each row of the family):
--       DX  = cohort patients carrying the anchor Diagnosis (all of #dx_summary,
--             one row per cohort patient, every cohort patient has >= 1 DX record)
--       MET = cohort patients carrying an anchor Metastasis (all of #met_summary)
--     A patient falls in exactly one bucket per family.
--     Source: #dx_summary.n_dx_records, #met_summary.n_met_records (00_setup.sql).
--     Small-cell suppression: n_patients in (0, @min_cell_count] set to
--     -@min_cell_count. n_patients_total is an aggregate denominator, not suppressed.

WITH family_counts AS (
    SELECT 'DX'  AS event_family, person_id, n_dx_records  AS n_records FROM #dx_summary
    UNION ALL
    SELECT 'MET' AS event_family, person_id, n_met_records AS n_records FROM #met_summary
),
bucketed AS (
    SELECT
        event_family,
        person_id,
        CASE
            WHEN event_family = 'DX'  AND n_records = 1  THEN '1'
            WHEN event_family = 'DX'  AND n_records <= 5 THEN '2_5'
            WHEN event_family = 'DX'                     THEN '6plus'
            WHEN event_family = 'MET' AND n_records = 1  THEN '1'
            ELSE '2plus'
        END AS record_count_bucket,
        CASE
            WHEN event_family = 'DX'  AND n_records = 1  THEN 1
            WHEN event_family = 'DX'  AND n_records <= 5 THEN 2
            WHEN event_family = 'DX'                     THEN 3
            WHEN event_family = 'MET' AND n_records = 1  THEN 1
            ELSE 2
        END AS bucket_order
    FROM family_counts
),
totals AS (
    SELECT event_family, COUNT(*) AS n_patients_total
    FROM bucketed
    GROUP BY event_family
)
SELECT
    b.event_family,
    b.record_count_bucket,
    CASE WHEN COUNT(*) > 0 AND COUNT(*) <= @min_cell_count THEN -@min_cell_count ELSE COUNT(*) END AS n_patients,
    t.n_patients_total
FROM bucketed b
JOIN totals t ON t.event_family = b.event_family
GROUP BY b.event_family, b.record_count_bucket, t.n_patients_total
ORDER BY
    CASE b.event_family WHEN 'DX' THEN 0 ELSE 1 END,
    MIN(b.bucket_order)
;

-- 19) F. Index event record counts (part 2) — on what timescale the code repeats
--     For patients with more than one Diagnosis code, the time between
--     consecutive Diagnosis codes, for the first two transitions only:
--       DX_1_TO_2 : first Diagnosis day  -> second Diagnosis day
--       DX_2_TO_3 : second Diagnosis day -> third  Diagnosis day
--     bucketed by timeframe: within 30 days / 31 to 90 / 91 to 365 / more than a year.
--
--     JUDGMENT CALL (flag for review): "consecutive codes" is measured between
--     DISTINCT Diagnosis DAYS, not raw records. Same-day duplicate records are
--     collapsed first (SELECT DISTINCT person_id, event_date), mirroring the L01
--     gap methodology (#l01_event_days in 00_setup.sql). Counting raw records
--     instead would make almost every first-to-second gap 0 days (same-day
--     administrative duplicates) and hide the coding timescale. Consequently
--     every gap is >= 1 day and the "within 30 days" bucket is 1-30 days.
--     Part 1 (chunk 18) counts records; this part measures timing between days.
--
--     Denominators (n_transitions_total, per transition = patients, since each
--     patient contributes at most one gap per transition):
--       DX_1_TO_2 = patients with >= 2 distinct Diagnosis days
--       DX_2_TO_3 = patients with >= 3 distinct Diagnosis days
--     Source: #dx_events restricted to #cohort (00_setup.sql).
--     Small-cell suppression: n_transitions in (0, @min_cell_count] set to
--     -@min_cell_count. n_transitions_total is an aggregate denominator, not suppressed.

WITH dx_days AS (
    SELECT DISTINCT e.person_id, e.event_date AS event_day
    FROM #dx_events e
    JOIN #cohort c ON e.person_id = c.person_id
),
ranked AS (
    SELECT
        person_id,
        event_day,
        ROW_NUMBER() OVER (PARTITION BY person_id ORDER BY event_day)      AS day_rank,
        LEAD(event_day) OVER (PARTITION BY person_id ORDER BY event_day)   AS next_day
    FROM dx_days
),
transitions AS (
    SELECT
        CASE day_rank WHEN 1 THEN 'DX_1_TO_2' WHEN 2 THEN 'DX_2_TO_3' END AS transition,
        DATEDIFF(DAY, event_day, next_day) AS gap_days
    FROM ranked
    WHERE day_rank IN (1, 2)
      AND next_day IS NOT NULL
),
bucketed AS (
    SELECT
        transition,
        CASE
            WHEN gap_days <= 30  THEN 'lte30d'
            WHEN gap_days <= 90  THEN '31_90d'
            WHEN gap_days <= 365 THEN '91_365d'
            ELSE 'gt365d'
        END AS gap_bucket,
        CASE
            WHEN gap_days <= 30  THEN 1
            WHEN gap_days <= 90  THEN 2
            WHEN gap_days <= 365 THEN 3
            ELSE 4
        END AS bucket_order
    FROM transitions
),
totals AS (
    SELECT transition, COUNT(*) AS n_transitions_total
    FROM bucketed
    GROUP BY transition
)
SELECT
    b.transition,
    b.gap_bucket,
    CASE WHEN COUNT(*) > 0 AND COUNT(*) <= @min_cell_count THEN -@min_cell_count ELSE COUNT(*) END AS n_transitions,
    t.n_transitions_total
FROM bucketed b
JOIN totals t ON t.transition = b.transition
GROUP BY b.transition, b.gap_bucket, t.n_transitions_total
ORDER BY b.transition, MIN(b.bucket_order)
;

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

-- 22) D. MET-first subgroup, part 3a. Time from the first Metastasis to the first
--     specific Diagnosis, bucketed, for the MET-first patients.
--     For the MET_FIRST_THEN_DX group of chunk 20, the gap in days from the first
--     MET to the first specific DX, placed in one bucket:
--
--       LTE30D    1 to 30 days      D91_180   91 to 180 days
--       D31_60    31 to 60 days     D181_365  181 to 365 days
--       D61_90    61 to 90 days     GT365D    366 days or more
--
--     All of this time is AFTER the first MET by construction (MET-first subgroup),
--     so the gap is >= 1 day and the first bucket contains 1-30 days. Day 0 cannot
--     occur: those patients are the SAME_DAY category of chunk 20, excluded here.
--
--     Denominator (n_patients_reaching_dx_total, repeated on each row):
--       MET-first patients who reach a specific DX = the MET_FIRST_THEN_DX group of
--       chunk 20 (the two SPECIFIC_DX_* buckets of chunk 21). Under the corrected
--       DX-anchored population every MET-first patient reaches a specific DX, so this
--       denominator equals the full MET-first subgroup.
--
--     Population and observation-period notes: same as chunk 20 (DX-anchored MET
--     population from #met_events, first specific DX from #dx_events, anchored on
--     #anchor_person, no observation-period gate).
--
--     Small-cell suppression: n_patients in (0, @min_cell_count] set to
--     -@min_cell_count. n_patients_reaching_dx_total is an aggregate denominator,
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
        MIN(event_date) AS first_dx_date
    FROM #dx_events
    GROUP BY person_id
),
gap AS (
    -- MET-first-then-DX only: first MET strictly before the first specific DX.
    SELECT
        ma.person_id,
        DATEDIFF(DAY, ma.first_met_date, dx.first_dx_date) AS gap_days
    FROM met_all ma
    JOIN dx_all dx
      ON dx.person_id = ma.person_id
    WHERE ma.first_met_date < dx.first_dx_date
),
bucketed AS (
    SELECT
        person_id,
        CASE
            WHEN gap_days <= 30  THEN 'LTE30D'
            WHEN gap_days <= 60  THEN 'D31_60'
            WHEN gap_days <= 90  THEN 'D61_90'
            WHEN gap_days <= 180 THEN 'D91_180'
            WHEN gap_days <= 365 THEN 'D181_365'
            ELSE                      'GT365D'
        END AS timing_bucket,
        CASE
            WHEN gap_days <= 30  THEN 1
            WHEN gap_days <= 60  THEN 2
            WHEN gap_days <= 90  THEN 3
            WHEN gap_days <= 180 THEN 4
            WHEN gap_days <= 365 THEN 5
            ELSE                      6
        END AS bucket_order
    FROM gap
),
totals AS (
    SELECT COUNT(*) AS n_patients_reaching_dx_total FROM bucketed
)
SELECT
    b.timing_bucket,
    CASE WHEN COUNT(*) > 0 AND COUNT(*) <= @min_cell_count THEN -@min_cell_count
         ELSE COUNT(*) END AS n_patients,
    t.n_patients_reaching_dx_total
FROM bucketed b
CROSS JOIN totals t
GROUP BY b.timing_bucket, t.n_patients_reaching_dx_total
ORDER BY MIN(b.bucket_order)
;

-- 23) D. MET-first subgroup, part 3b. The same MET-to-first-specific-DX gap as
--     chunk 22, expressed cumulatively (CDF) so a linking cutoff can be read off
--     directly, plus the median gap.
--     For the MET_FIRST_THEN_DX group of chunk 20, the number of patients whose
--     first specific DX has ARRIVED BY each day threshold after the first MET.
--     Cumulative and monotonically non-decreasing across thresholds:
--
--       n_arrived_by_30d, _45d, _60d, _90d, _180d, _365d
--
--     Thresholds 30/45/60/90 are the candidate cutoffs; 180/365 give the longer
--     shape. All time is AFTER the first MET by construction, so there is no before
--     side and no day-0 mass. Patients whose specific DX arrives after 365 days are
--     the >1-year tail, derivable as n_patients_reaching_dx_total - n_arrived_by_365d.
--
--     median_days_met_to_dx: median gap (days) among the same patients, using the
--     framework's ordered-set median convention (lower-middle value for even n, as
--     in chunks 16-17 and 00_setup.sql).
--
--     Denominator (n_patients_reaching_dx_total):
--       MET-first patients who reach a specific DX (same as chunk 22). Under the
--       corrected DX-anchored population every MET-first patient reaches a specific
--       DX, so this equals the full MET-first subgroup.
--
--     Population and observation-period notes: same as chunk 20 (DX-anchored MET
--     population from #met_events, first specific DX from #dx_events, anchored on
--     #anchor_person, no observation-period gate).
--
--     Small-cell suppression: each cumulative count in (0, @min_cell_count] set to
--     -@min_cell_count; median set to NULL when its denominator is suppressed.
--     n_patients_reaching_dx_total is an aggregate denominator, not suppressed.

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
        MIN(event_date) AS first_dx_date
    FROM #dx_events
    GROUP BY person_id
),
gap AS (
    SELECT
        ma.person_id,
        DATEDIFF(DAY, ma.first_met_date, dx.first_dx_date) AS gap_days
    FROM met_all ma
    JOIN dx_all dx
      ON dx.person_id = ma.person_id
    WHERE ma.first_met_date < dx.first_dx_date
),
med AS (
    SELECT MIN(CASE WHEN 2.0 * rn >= cnt THEN CAST(gap_days AS FLOAT) END) AS median_days
    FROM (
        SELECT
            gap_days,
            ROW_NUMBER() OVER (ORDER BY gap_days) AS rn,
            COUNT(*)     OVER ()                  AS cnt
        FROM gap
    ) x
),
agg AS (
    SELECT
        COUNT(*)                                          AS n_total,
        SUM(CASE WHEN gap_days <= 30  THEN 1 ELSE 0 END)  AS n_by_30,
        SUM(CASE WHEN gap_days <= 45  THEN 1 ELSE 0 END)  AS n_by_45,
        SUM(CASE WHEN gap_days <= 60  THEN 1 ELSE 0 END)  AS n_by_60,
        SUM(CASE WHEN gap_days <= 90  THEN 1 ELSE 0 END)  AS n_by_90,
        SUM(CASE WHEN gap_days <= 180 THEN 1 ELSE 0 END)  AS n_by_180,
        SUM(CASE WHEN gap_days <= 365 THEN 1 ELSE 0 END)  AS n_by_365
    FROM gap
)
SELECT
    a.n_total AS n_patients_reaching_dx_total,
    CASE WHEN a.n_by_30  > 0 AND a.n_by_30  <= @min_cell_count THEN -@min_cell_count ELSE a.n_by_30  END AS n_arrived_by_30d,
    CASE WHEN a.n_by_45  > 0 AND a.n_by_45  <= @min_cell_count THEN -@min_cell_count ELSE a.n_by_45  END AS n_arrived_by_45d,
    CASE WHEN a.n_by_60  > 0 AND a.n_by_60  <= @min_cell_count THEN -@min_cell_count ELSE a.n_by_60  END AS n_arrived_by_60d,
    CASE WHEN a.n_by_90  > 0 AND a.n_by_90  <= @min_cell_count THEN -@min_cell_count ELSE a.n_by_90  END AS n_arrived_by_90d,
    CASE WHEN a.n_by_180 > 0 AND a.n_by_180 <= @min_cell_count THEN -@min_cell_count ELSE a.n_by_180 END AS n_arrived_by_180d,
    CASE WHEN a.n_by_365 > 0 AND a.n_by_365 <= @min_cell_count THEN -@min_cell_count ELSE a.n_by_365 END AS n_arrived_by_365d,
    CASE WHEN a.n_total <= @min_cell_count THEN NULL ELSE m.median_days END AS median_days_met_to_dx
FROM agg a
CROSS JOIN med m
;

-- 24) H. Metastasis-to-treatment timing, part 1. Where each patient's CLOSEST
--     antineoplastic treatment falls relative to the first Metastasis.
--     Each patient who carries an anchor Metastasis (MET) code (and therefore also
--     an anchor DX code) is placed in exactly one category by the side of the first
--     MET on which their single CLOSEST antineoplastic (L01) drug_exposure record
--     falls. "Closest" = the L01 record with the minimum absolute days-difference to
--     the first MET, signed:
--
--       CLOSEST_L01_BEFORE_MET   closest L01 record is before the first MET   (days_diff < 0)
--       CLOSEST_L01_ON_MET_DAY   closest L01 record is on the first MET date  (days_diff = 0, day 0)
--       CLOSEST_L01_AFTER_MET    closest L01 record is after the first MET    (days_diff > 0)
--       NO_L01_EVER              no antineoplastic drug_exposure record at all
--
--     days_diff = DATEDIFF(DAY, first_met_date, l01_event_date): negative = before,
--     0 = same calendar day as the first MET (day 0, its own explicit category,
--     never folded into "after"), positive = after. One value per patient. Ties in
--     absolute distance are broken by earlier event_date, the framework's CLOSEST
--     convention (ROW_NUMBER ... ORDER BY ABS(days_diff), event_date), so an
--     equidistant tie resolves to the before record.
--
--     Denominator (n_patients_met_total, repeated on each row):
--       all patients with >= 1 anchor MET measurement code AND >= 1 anchor DX code
--       at this site (before + day0 + after + never = this total).
--
--     POPULATION. Built from #met_events (00_setup.sql, section F):
--     @cdm_database_schema.measurement JOIN #met_concepts JOIN #anchor_person, so
--     every patient carries an anchor DX code. The cohort is DX-anchored; a MET code
--     is observed WITHIN that cohort, never as a separate entry point. There is no
--     "MET-only, no DX" patient: the MET concept set is generic across cancer types,
--     so a MET code without an anchor DX gives no evidence of the cancer of interest.
--     #anchor_person carries no observation-period-at-index gate (that is #cohort);
--     see the observation-period flag below. Identical DX-anchored population to
--     Analysis D (chunks 20-23).
--
--     L01 SOURCE. Antineoplastic records come from #l01_events (00_setup.sql,
--     section F): @cdm_database_schema.drug_exposure JOIN #l01_concepts JOIN
--     #anchor_person. #l01_events is gated to the same DX anchor cohort as the MET
--     population, so every MET patient's L01 records are present and none are missed.
--
--     JUDGMENT CALL / FLAG (observation period). Neither the MET population nor the
--     L01 records are restricted to an observation period. The population is anchored
--     on "has an anchor DX code" (#anchor_person), not "inside an observation period"
--     (#cohort). Observation-period coverage is characterized separately in Analysis
--     E (chunks 16-17). See the accompanying report for the reasoned recommendation.
--
--     Small-cell suppression: n_patients in (0, @min_cell_count] set to
--     -@min_cell_count. n_patients_met_total is an aggregate denominator, not
--     suppressed. A category with zero patients is absent (as in chunks 18-23).

WITH met_all AS (
    -- DX-anchored MET population: earliest MET date per patient (#met_events is
    -- gated to #anchor_person and carries no observation-period gate).
    SELECT
        person_id,
        MIN(event_date) AS first_met_date
    FROM #met_events
    GROUP BY person_id
),
l01_all AS (
    -- Antineoplastic drug_exposure records for the DX anchor cohort (#l01_events is
    -- gated to #anchor_person, the same cohort as the MET population).
    SELECT
        person_id,
        event_date
    FROM #l01_events
),
pair AS (
    -- Signed L01-to-first-MET distance for every L01 record of a MET patient.
    SELECT
        ma.person_id,
        DATEDIFF(DAY, ma.first_met_date, la.event_date) AS days_diff,
        la.event_date
    FROM met_all ma
    JOIN l01_all la
      ON la.person_id = ma.person_id
),
closest AS (
    -- Single closest L01 record per patient (framework CLOSEST convention).
    SELECT
        person_id,
        days_diff,
        ROW_NUMBER() OVER (
            PARTITION BY person_id
            ORDER BY ABS(days_diff), event_date
        ) AS rn
    FROM pair
),
classified AS (
    SELECT
        ma.person_id,
        CASE
            WHEN c.days_diff IS NULL THEN 'NO_L01_EVER'
            WHEN c.days_diff < 0     THEN 'CLOSEST_L01_BEFORE_MET'
            WHEN c.days_diff = 0     THEN 'CLOSEST_L01_ON_MET_DAY'
            ELSE                          'CLOSEST_L01_AFTER_MET'
        END AS placement_category
    FROM met_all ma
    LEFT JOIN (SELECT person_id, days_diff FROM closest WHERE rn = 1) c
      ON c.person_id = ma.person_id
),
totals AS (
    SELECT COUNT(*) AS n_patients_met_total FROM met_all
)
SELECT
    c.placement_category,
    CASE WHEN COUNT(*) > 0 AND COUNT(*) <= @min_cell_count THEN -@min_cell_count
         ELSE COUNT(*) END AS n_patients,
    t.n_patients_met_total
FROM classified c
CROSS JOIN totals t
GROUP BY c.placement_category, t.n_patients_met_total
ORDER BY
    CASE c.placement_category
        WHEN 'CLOSEST_L01_BEFORE_MET' THEN 0
        WHEN 'CLOSEST_L01_ON_MET_DAY' THEN 1
        WHEN 'CLOSEST_L01_AFTER_MET'  THEN 2
        WHEN 'NO_L01_EVER'            THEN 3
        ELSE 9
    END
;

-- 25) H. Metastasis-to-treatment timing (Part 1 support) — reconciliation of the
--     two treated-patient populations Part 2 uses, and the bilateral-treatment
--     count referenced in the Part 1 caption.
--     Part 2 deliberately reads its two cumulative curves over DIFFERENT
--     denominators (AA's decision, 13 Jul 2026): the before-curve and the signed
--     histogram are CLOSEST-based, while the after-curve is over EVERY patient with
--     any antineoplastic (L01) record strictly after the first Metastasis. This
--     chunk quantifies exactly how those populations relate, so the after-curve's
--     superset construction is auditable rather than asserted. One row.
--
--     Over the treated MET patients (>= 1 L01 record), per-patient side flags are
--     built from the signed L01-to-first-MET distances:
--       has_before = any L01 record strictly before the first MET (days_diff < 0)
--       has_day0   = any L01 record on the first MET date        (days_diff = 0)
--       has_after  = any L01 record strictly after the first MET (days_diff > 0)
--     and each treated patient's CLOSEST side (BEFORE / DAY0 / AFTER) is taken from
--     the single closest record (same convention as chunk 24).
--
--     Columns (each a patient count over the treated subgroup):
--       n_treated                   before + day0 + after treated patients
--                                   (= chunk 24 before + day0 + after)
--       n_closest_after             treated patients whose CLOSEST record is after
--                                   the first MET (the histogram's after bars, and
--                                   the old closest-after after-curve population)
--       n_after_any                 treated patients with ANY strictly-after L01
--                                   record (the Part 2 after-curve denominator);
--                                   a SUPERSET of n_closest_after
--       n_after_any_added           n_after_any - n_closest_after: patients added to
--                                   the after-curve by re-basing it on any-after
--                                   rather than closest-after (their closest record
--                                   is before or on the MET day, but they also have
--                                   a real after-MET record)
--       n_bilateral                 treated patients with a record on BOTH sides
--                                   (has_before = 1 AND has_after = 1)
--       n_bilateral_closest_before  bilateral patients whose CLOSEST record is
--                                   before the MET (collapsed to the before side by
--                                   the closest-only view; these are the core of
--                                   n_after_any_added)
--       n_bilateral_closest_after   bilateral patients whose CLOSEST record is after
--                                   the MET (already inside n_closest_after)
--
--     JUDGMENT CALL / FLAG (after = strictly after, day 0 excluded). The after-curve
--     population is patients with any record with days_diff > 0. Day 0 is its own
--     explicit category and belongs to NEITHER curve, per the locked design
--     principle and the approved mock. The task prose phrased this as "on or after,"
--     but the mock (source of truth) and the day-0-explicit rule make it strictly
--     after; day-0 treatment is not counted toward the after-curve. Flagged rather
--     than silently decided.
--
--     JUDGMENT CALL / FLAG (superset arithmetic). n_after_any_added collects
--     every treated patient with an after-MET record whose closest record is NOT
--     after: closest-before-with-after (= n_bilateral_closest_before) plus the
--     residual closest-on-day-0-with-after. The mock modelled the added group as
--     40 closest-before patients only and assumed no day-0-closest patient also has
--     a later after-MET record; in real data that day-0 residual may be non-zero,
--     so n_after_any is computed directly as "any strictly-after record" and will
--     be >= the mock's 392 + 40 decomposition. n_after_any_added minus
--     n_bilateral_closest_before is that day-0 residual.
--
--     Population, observation-period and L01-source notes: same as chunk 24
--     (DX-anchored MET population from #met_events; L01 from #l01_events, gated to the
--     same #anchor_person cohort; no observation-period gate). No change to 00_setup.sql.
--
--     Small-cell suppression: each count in (0, @min_cell_count] set to
--     -@min_cell_count.

WITH met_all AS (
    SELECT
        person_id,
        MIN(event_date) AS first_met_date
    FROM #met_events
    GROUP BY person_id
),
l01_all AS (
    SELECT
        person_id,
        event_date
    FROM #l01_events
),
pair AS (
    SELECT
        ma.person_id,
        DATEDIFF(DAY, ma.first_met_date, la.event_date) AS days_diff,
        la.event_date
    FROM met_all ma
    JOIN l01_all la
      ON la.person_id = ma.person_id
),
flags AS (
    -- Per treated patient: which sides of the first MET carry any L01 record.
    SELECT
        person_id,
        MAX(CASE WHEN days_diff < 0 THEN 1 ELSE 0 END) AS has_before,
        MAX(CASE WHEN days_diff = 0 THEN 1 ELSE 0 END) AS has_day0,
        MAX(CASE WHEN days_diff > 0 THEN 1 ELSE 0 END) AS has_after
    FROM pair
    GROUP BY person_id
),
closest AS (
    SELECT
        person_id,
        days_diff,
        ROW_NUMBER() OVER (
            PARTITION BY person_id
            ORDER BY ABS(days_diff), event_date
        ) AS rn
    FROM pair
),
closest_side AS (
    SELECT
        person_id,
        CASE WHEN days_diff < 0 THEN 'BEFORE'
             WHEN days_diff = 0 THEN 'DAY0'
             ELSE                    'AFTER' END AS cside
    FROM closest
    WHERE rn = 1
),
combined AS (
    SELECT
        f.person_id,
        f.has_before,
        f.has_after,
        cs.cside
    FROM flags f
    JOIN closest_side cs
      ON cs.person_id = f.person_id
),
agg AS (
    SELECT
        COUNT(*)                                                                       AS n_treated,
        SUM(CASE WHEN cside = 'AFTER' THEN 1 ELSE 0 END)                               AS n_closest_after,
        SUM(has_after)                                                                 AS n_after_any,
        SUM(CASE WHEN has_before = 1 AND has_after = 1 THEN 1 ELSE 0 END)              AS n_bilateral,
        SUM(CASE WHEN has_before = 1 AND has_after = 1 AND cside = 'BEFORE' THEN 1 ELSE 0 END) AS n_bilateral_closest_before,
        SUM(CASE WHEN has_before = 1 AND has_after = 1 AND cside = 'AFTER'  THEN 1 ELSE 0 END) AS n_bilateral_closest_after
    FROM combined
)
SELECT
    CASE WHEN n_treated                  > 0 AND n_treated                  <= @min_cell_count THEN -@min_cell_count ELSE n_treated                  END AS n_treated,
    CASE WHEN n_closest_after            > 0 AND n_closest_after            <= @min_cell_count THEN -@min_cell_count ELSE n_closest_after            END AS n_closest_after,
    CASE WHEN n_after_any                > 0 AND n_after_any                <= @min_cell_count THEN -@min_cell_count ELSE n_after_any                END AS n_after_any,
    CASE WHEN (n_after_any - n_closest_after) > 0 AND (n_after_any - n_closest_after) <= @min_cell_count THEN -@min_cell_count ELSE (n_after_any - n_closest_after) END AS n_after_any_added,
    CASE WHEN n_bilateral                > 0 AND n_bilateral                <= @min_cell_count THEN -@min_cell_count ELSE n_bilateral                END AS n_bilateral,
    CASE WHEN n_bilateral_closest_before > 0 AND n_bilateral_closest_before <= @min_cell_count THEN -@min_cell_count ELSE n_bilateral_closest_before END AS n_bilateral_closest_before,
    CASE WHEN n_bilateral_closest_after  > 0 AND n_bilateral_closest_after  <= @min_cell_count THEN -@min_cell_count ELSE n_bilateral_closest_after  END AS n_bilateral_closest_after
FROM agg
;

-- 26) H. Metastasis-to-treatment timing (Part 2, histogram) — the signed
--     distribution of each treated patient's CLOSEST antineoplastic treatment
--     relative to the first Metastasis.
--     Over the treated MET patients (>= 1 L01 record), each patient is reduced to
--     the single signed days_diff of their CLOSEST L01 record (same value and
--     convention as chunk 24) and placed in one signed-day bin. Before and after
--     are separate; day 0 is its own central bin. bin_order runs left to right
--     along the signed axis (farthest before -> day 0 -> farthest after) so the
--     report renders the bars directly.
--
--       bin_order  side    day_range_label   contents (signed days_diff)
--          1       BEFORE   366+              days_diff <= -366
--          2       BEFORE   181-365           -365 .. -181
--          3       BEFORE   91-180            -180 .. -91
--          4       BEFORE   61-90             -90 .. -61
--          5       BEFORE   31-60             -60 .. -31
--          6       BEFORE   1-30              -30 .. -1
--          7       DAY0     Day 0             days_diff = 0
--          8       AFTER    1-30              1 .. 30
--          9       AFTER    31-60             31 .. 60
--         10       AFTER    61-90             61 .. 90
--         11       AFTER    91-180            91 .. 180
--         12       AFTER    181-365           181 .. 365
--         13       AFTER    366+              days_diff >= 366
--
--     The 366+ terminal bins carry everything beyond one year on each side. The bin
--     share (n_patients / n_treated_total) is what the report plots.
--
--     NOTE (relationship to the after-curve, chunk 28). This histogram is entirely
--     CLOSEST-based: the after bins (order 8-13) sum to the closest-after patients
--     (chunk 25 n_closest_after), NOT to the after-curve population (n_after_any).
--     The after-curve is intentionally over a broader population and is therefore
--     NOT the cumulative of these after bars. The before bins (order 1-6) sum to the
--     closest-before patients and DO agree with the before-curve (chunk 27).
--
--     Denominator (n_treated_total, repeated on each row):
--       treated MET patients = before + day0 + after (= chunk 24 sum of the three
--       treated categories; = chunk 25 n_treated).
--
--     Population, observation-period and L01-source notes: same as chunk 24
--     (DX-anchored MET population from #met_events; L01 from #l01_events, gated to the
--     same #anchor_person cohort; no observation-period gate). No change to 00_setup.sql.
--
--     Small-cell suppression: n_patients in (0, @min_cell_count] set to
--     -@min_cell_count. n_treated_total is an aggregate denominator, not
--     suppressed. A bin with zero patients is absent (as in chunks 18-25).

WITH met_all AS (
    SELECT
        person_id,
        MIN(event_date) AS first_met_date
    FROM #met_events
    GROUP BY person_id
),
l01_all AS (
    SELECT
        person_id,
        event_date
    FROM #l01_events
),
pair AS (
    SELECT
        ma.person_id,
        DATEDIFF(DAY, ma.first_met_date, la.event_date) AS days_diff,
        la.event_date
    FROM met_all ma
    JOIN l01_all la
      ON la.person_id = ma.person_id
),
closest AS (
    SELECT
        person_id,
        days_diff,
        ROW_NUMBER() OVER (
            PARTITION BY person_id
            ORDER BY ABS(days_diff), event_date
        ) AS rn
    FROM pair
),
c1 AS (
    SELECT person_id, days_diff FROM closest WHERE rn = 1
),
binned AS (
    SELECT
        person_id,
        CASE
            WHEN days_diff = 0                          THEN 7
            WHEN days_diff <= -366                       THEN 1
            WHEN days_diff <= -181                       THEN 2
            WHEN days_diff <= -91                        THEN 3
            WHEN days_diff <= -61                        THEN 4
            WHEN days_diff <= -31                        THEN 5
            WHEN days_diff <= -1                         THEN 6
            WHEN days_diff <= 30                         THEN 8
            WHEN days_diff <= 60                         THEN 9
            WHEN days_diff <= 90                         THEN 10
            WHEN days_diff <= 180                        THEN 11
            WHEN days_diff <= 365                        THEN 12
            ELSE                                             13
        END AS bin_order
    FROM c1
),
labelled AS (
    SELECT
        person_id,
        bin_order,
        CASE WHEN bin_order <= 6 THEN 'BEFORE'
             WHEN bin_order = 7  THEN 'DAY0'
             ELSE                     'AFTER' END AS side,
        CASE bin_order
            WHEN 1  THEN '366+'
            WHEN 2  THEN '181-365'
            WHEN 3  THEN '91-180'
            WHEN 4  THEN '61-90'
            WHEN 5  THEN '31-60'
            WHEN 6  THEN '1-30'
            WHEN 7  THEN 'Day 0'
            WHEN 8  THEN '1-30'
            WHEN 9  THEN '31-60'
            WHEN 10 THEN '61-90'
            WHEN 11 THEN '91-180'
            WHEN 12 THEN '181-365'
            ELSE         '366+'
        END AS day_range_label
    FROM binned
),
totals AS (
    SELECT COUNT(*) AS n_treated_total FROM c1
)
SELECT
    b.bin_order,
    b.side,
    b.day_range_label,
    CASE WHEN COUNT(*) > 0 AND COUNT(*) <= @min_cell_count THEN -@min_cell_count
         ELSE COUNT(*) END AS n_patients,
    t.n_treated_total
FROM labelled b
CROSS JOIN totals t
GROUP BY b.bin_order, b.side, b.day_range_label, t.n_treated_total
ORDER BY b.bin_order
;

-- 27) H. Metastasis-to-treatment timing (Part 2, before-curve) — cumulative reach
--     of the CLOSEST-before treatment, over the closest-before patients.
--     Over the patients whose CLOSEST antineoplastic (L01) record is strictly
--     before the first Metastasis (chunk 24 CLOSEST_L01_BEFORE_MET), the number
--     whose closest-before record sits WITHIN each day threshold before the first
--     MET. Cumulative and monotonically non-decreasing across thresholds. Reads
--     "how far back the nearest before-MET treatment sits":
--
--       n_within_30d_before, _60d, _90d, _180d, _365d
--
--     days_before = ABS(days_diff) of the closest record (all values >= 1 by
--     construction; day 0 is a separate central category, not on this curve). The
--     curve is CLOSEST-based, so it agrees with the histogram's before bars
--     (chunk 26, bin_order 1-6). Patients whose closest-before treatment is more
--     than 365 days before the MET are the earlier-than-one-year tail, derivable as
--     n_before_total - n_within_365d_before.
--
--     median_days_before_closest: median days_before among the same patients, using
--     the framework's ordered-set median convention (lower-middle value for even n,
--     as in chunks 16-17, 23 and 00_setup.sql).
--
--     Denominator (n_before_total):
--       closest-before patients (= chunk 24 CLOSEST_L01_BEFORE_MET n_patients).
--
--     NOTE (direction). This is the BEFORE curve. It reads leftward (backward in
--     time) from the first MET and uses its own directional denominator; it is
--     never combined with the after-curve into a symmetric window.
--
--     Population, observation-period and L01-source notes: same as chunk 24
--     (DX-anchored MET population from #met_events; L01 from #l01_events, gated to the
--     same #anchor_person cohort; no observation-period gate). No change to 00_setup.sql.
--
--     Small-cell suppression: each cumulative count in (0, @min_cell_count] set to
--     -@min_cell_count; median set to NULL when its denominator is suppressed.
--     n_before_total is an aggregate denominator, not suppressed.

WITH met_all AS (
    SELECT
        person_id,
        MIN(event_date) AS first_met_date
    FROM #met_events
    GROUP BY person_id
),
l01_all AS (
    SELECT
        person_id,
        event_date
    FROM #l01_events
),
pair AS (
    SELECT
        ma.person_id,
        DATEDIFF(DAY, ma.first_met_date, la.event_date) AS days_diff,
        la.event_date
    FROM met_all ma
    JOIN l01_all la
      ON la.person_id = ma.person_id
),
closest AS (
    SELECT
        person_id,
        days_diff,
        ROW_NUMBER() OVER (
            PARTITION BY person_id
            ORDER BY ABS(days_diff), event_date
        ) AS rn
    FROM pair
),
before_closest AS (
    -- Closest record is strictly before the first MET.
    SELECT
        person_id,
        ABS(days_diff) AS days_before
    FROM closest
    WHERE rn = 1
      AND days_diff < 0
),
med AS (
    SELECT MIN(CASE WHEN 2.0 * rn >= cnt THEN CAST(days_before AS FLOAT) END) AS median_days
    FROM (
        SELECT
            days_before,
            ROW_NUMBER() OVER (ORDER BY days_before) AS rn,
            COUNT(*)     OVER ()                     AS cnt
        FROM before_closest
    ) x
),
agg AS (
    SELECT
        COUNT(*)                                           AS n_total,
        SUM(CASE WHEN days_before <= 30  THEN 1 ELSE 0 END) AS n_30,
        SUM(CASE WHEN days_before <= 60  THEN 1 ELSE 0 END) AS n_60,
        SUM(CASE WHEN days_before <= 90  THEN 1 ELSE 0 END) AS n_90,
        SUM(CASE WHEN days_before <= 180 THEN 1 ELSE 0 END) AS n_180,
        SUM(CASE WHEN days_before <= 365 THEN 1 ELSE 0 END) AS n_365
    FROM before_closest
)
SELECT
    a.n_total AS n_before_total,
    CASE WHEN a.n_30  > 0 AND a.n_30  <= @min_cell_count THEN -@min_cell_count ELSE a.n_30  END AS n_within_30d_before,
    CASE WHEN a.n_60  > 0 AND a.n_60  <= @min_cell_count THEN -@min_cell_count ELSE a.n_60  END AS n_within_60d_before,
    CASE WHEN a.n_90  > 0 AND a.n_90  <= @min_cell_count THEN -@min_cell_count ELSE a.n_90  END AS n_within_90d_before,
    CASE WHEN a.n_180 > 0 AND a.n_180 <= @min_cell_count THEN -@min_cell_count ELSE a.n_180 END AS n_within_180d_before,
    CASE WHEN a.n_365 > 0 AND a.n_365 <= @min_cell_count THEN -@min_cell_count ELSE a.n_365 END AS n_within_365d_before,
    CASE WHEN a.n_total <= @min_cell_count THEN NULL ELSE m.median_days END AS median_days_before_closest
FROM agg a
CROSS JOIN med m
;

-- 28) H. Metastasis-to-treatment timing (Part 2, after-curve) — cumulative reach
--     of the FIRST after-Metastasis treatment, over EVERY patient with any
--     after-Metastasis treatment (the re-based after population, AA's decision
--     13 Jul 2026).
--     Over the patients who have ANY antineoplastic (L01) record strictly after the
--     first Metastasis (days_diff > 0), timed by that patient's FIRST such record
--     (the minimum positive days_diff), the number whose first after-MET treatment
--     has arrived WITHIN each day threshold after the first MET. Cumulative and
--     monotonically non-decreasing:
--
--       n_within_30d_after, _60d, _90d, _180d, _365d
--
--     This is the forward attribution window: for any forward window it reads the
--     share of everyone eventually treated after the MET who is captured by that
--     window. Patients whose first after-MET treatment is more than 365 days out
--     are the later-than-one-year tail, derivable as
--     n_after_any_total - n_within_365d_after.
--
--     median_days_after_first: median first-after-MET days among the same patients,
--     framework ordered-set median convention (lower-middle for even n, as in
--     chunks 16-17, 23, 27 and 00_setup.sql).
--
--     Denominator (n_after_any_total):
--       patients with any strictly-after L01 record (= chunk 25 n_after_any). This
--       is a SUPERSET of the closest-after patients (chunk 25 n_closest_after and
--       the histogram after bars, chunk 26): it adds patients whose closest record
--       is before or on the MET day but who also have a genuine after-MET record.
--       Consequently this curve is NOT the cumulative of the histogram's after bars,
--       by design.
--
--     JUDGMENT CALL / FLAG (population definition, differs from before-curve and
--     histogram). Unlike the CLOSEST-based before-curve (chunk 27) and histogram
--     (chunk 26), this after-curve is over the ANY-strictly-after population and is
--     timed by each patient's FIRST after-MET record, not their closest record.
--       - Day 0 is excluded (strictly after, days_diff > 0), consistent with the
--         locked day-0-explicit principle; day-0 treatment is on neither curve. The
--         task prose said "on or after," reconciled here to strictly after per the
--         mock (source of truth) and the day-0 rule.
--       - A patient with treatment ONLY before the MET and none strictly after
--         correctly falls OUT of this curve (no positive days_diff, so absent from
--         the WHERE days_diff > 0 set).
--       - A closest-before patient who ALSO has an after-MET record is INCLUDED
--         here (via their after record) while remaining on the before side of the
--         histogram and before-curve; this is the intended superset behaviour.
--
--     Population, observation-period and L01-source notes: same as chunk 24
--     (DX-anchored MET population from #met_events; L01 from #l01_events, gated to the
--     same #anchor_person cohort; no observation-period gate). No change to 00_setup.sql.
--
--     Small-cell suppression: each cumulative count in (0, @min_cell_count] set to
--     -@min_cell_count; median set to NULL when its denominator is suppressed.
--     n_after_any_total is an aggregate denominator, not suppressed.

WITH met_all AS (
    SELECT
        person_id,
        MIN(event_date) AS first_met_date
    FROM #met_events
    GROUP BY person_id
),
l01_all AS (
    SELECT
        person_id,
        event_date
    FROM #l01_events
),
pair AS (
    SELECT
        ma.person_id,
        DATEDIFF(DAY, ma.first_met_date, la.event_date) AS days_diff
    FROM met_all ma
    JOIN l01_all la
      ON la.person_id = ma.person_id
),
after_first AS (
    -- One row per patient with any strictly-after record: their first after-MET day.
    SELECT
        person_id,
        MIN(days_diff) AS first_after_days
    FROM pair
    WHERE days_diff > 0
    GROUP BY person_id
),
med AS (
    SELECT MIN(CASE WHEN 2.0 * rn >= cnt THEN CAST(first_after_days AS FLOAT) END) AS median_days
    FROM (
        SELECT
            first_after_days,
            ROW_NUMBER() OVER (ORDER BY first_after_days) AS rn,
            COUNT(*)     OVER ()                          AS cnt
        FROM after_first
    ) x
),
agg AS (
    SELECT
        COUNT(*)                                                AS n_total,
        SUM(CASE WHEN first_after_days <= 30  THEN 1 ELSE 0 END) AS n_30,
        SUM(CASE WHEN first_after_days <= 60  THEN 1 ELSE 0 END) AS n_60,
        SUM(CASE WHEN first_after_days <= 90  THEN 1 ELSE 0 END) AS n_90,
        SUM(CASE WHEN first_after_days <= 180 THEN 1 ELSE 0 END) AS n_180,
        SUM(CASE WHEN first_after_days <= 365 THEN 1 ELSE 0 END) AS n_365
    FROM after_first
)
SELECT
    a.n_total AS n_after_any_total,
    CASE WHEN a.n_30  > 0 AND a.n_30  <= @min_cell_count THEN -@min_cell_count ELSE a.n_30  END AS n_within_30d_after,
    CASE WHEN a.n_60  > 0 AND a.n_60  <= @min_cell_count THEN -@min_cell_count ELSE a.n_60  END AS n_within_60d_after,
    CASE WHEN a.n_90  > 0 AND a.n_90  <= @min_cell_count THEN -@min_cell_count ELSE a.n_90  END AS n_within_90d_after,
    CASE WHEN a.n_180 > 0 AND a.n_180 <= @min_cell_count THEN -@min_cell_count ELSE a.n_180 END AS n_within_180d_after,
    CASE WHEN a.n_365 > 0 AND a.n_365 <= @min_cell_count THEN -@min_cell_count ELSE a.n_365 END AS n_within_365d_after,
    CASE WHEN a.n_total <= @min_cell_count THEN NULL ELSE m.median_days END AS median_days_after_first
FROM agg a
CROSS JOIN med m
;

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

-- 34) B. General cancer diagnosis (GDX) coding trajectory — part 2, timing of the
--     FIRST general cancer diagnosis code relative to the first specific Diagnosis
--     (INDEX = #cohort.index_date), directional and CDF-style, with day 0 explicit.
--     Over the anchor-cohort patients who carry at least one general cancer
--     diagnosis code, each patient contributes one signed gap:
--
--       signed_days = first_general_code_date - first_specific_diagnosis_date
--
--     negative = the first general code precedes the first specific Diagnosis
--     (pre-diagnostic / workup coding); zero = same calendar day; positive = the
--     first general code follows the first specific Diagnosis.
--
--     Three directional masses (mutually exclusive, sum to n_with_general_code):
--       n_first_general_before   signed_days < 0
--       n_first_general_day0     signed_days = 0   (explicit central category)
--       n_first_general_after    signed_days > 0
--
--     Cumulative (CDF) reach on each side, counted outward from day 0 and
--     monotonically non-decreasing across thresholds:
--       before side (subset of n_first_general_before):
--         n_first_general_within_30d_before   -30 <= signed_days <= -1
--         _90d, _180d, _365d                  wider look-back windows
--         tail earlier than 1 year before = n_first_general_before - within_365d_before
--       after side (subset of n_first_general_after):
--         n_first_general_within_30d_after     1 <= signed_days <= 30
--         _90d, _180d, _365d                   wider follow-up windows
--         tail later than 1 year after = n_first_general_after - within_365d_after
--
--     median_signed_days_first_general: median of signed_days over all patients with
--     a general code (single value; positive means the first general code typically
--     follows the first specific Diagnosis). Framework ordered-set median convention
--     (lower-middle value for even n, as in chunks 16-17, 23, 27 and 00_setup.sql).
--     Validation reference: the approved V3 mock reports a first-general-to-first-
--     Diagnosis median of +11 days at HUS with a long pre-diagnostic (before) tail.
--
--     NOTE (direction). Before and after use their own outward-cumulative counts and
--     are never combined into a symmetric window; day 0 is its own mass, not folded
--     into the after side.
--
--     Denominator (n_with_general_code, repeated on the single row):
--       anchor-cohort patients with >= 1 general cancer diagnosis code (the union of
--       the three trajectory categories in chunk 33; validated HUS total = 618).
--
--     Population note. Uses #gen_cancer_summary.first_gen_cancer_date, the earliest
--     general-code date per cohort patient (built in 00_setup.sql over
--     #gen_cancer_events joined to #cohort). General-code dates are not restricted to
--     an observation period, matching the mock.
--
--     Small-cell suppression: each directional/cumulative count in (0, @min_cell_count]
--     set to -@min_cell_count; median set to NULL when its denominator
--     (n_with_general_code) is suppressed. n_with_general_code is an aggregate
--     denominator, not suppressed.

WITH first_general AS (
    -- Signed gap from the first specific Diagnosis to the patient's first general
    -- cancer diagnosis code, one row per cohort patient who carries a general code.
    SELECT
        gs.person_id,
        DATEDIFF(DAY, c.index_date, gs.first_gen_cancer_date) AS signed_days
    FROM #gen_cancer_summary gs
    JOIN #cohort c
      ON gs.person_id = c.person_id
    WHERE gs.first_gen_cancer_date IS NOT NULL
),
med AS (
    SELECT MIN(CASE WHEN 2.0 * rn >= cnt THEN CAST(signed_days AS FLOAT) END) AS median_days
    FROM (
        SELECT
            signed_days,
            ROW_NUMBER() OVER (ORDER BY signed_days) AS rn,
            COUNT(*)     OVER ()                     AS cnt
        FROM first_general
    ) x
),
agg AS (
    SELECT
        COUNT(*) AS n_total,
        SUM(CASE WHEN signed_days <  0 THEN 1 ELSE 0 END) AS n_before,
        SUM(CASE WHEN signed_days =  0 THEN 1 ELSE 0 END) AS n_day0,
        SUM(CASE WHEN signed_days >  0 THEN 1 ELSE 0 END) AS n_after,
        SUM(CASE WHEN signed_days >= -30  AND signed_days <= -1 THEN 1 ELSE 0 END) AS n_b30,
        SUM(CASE WHEN signed_days >= -90  AND signed_days <= -1 THEN 1 ELSE 0 END) AS n_b90,
        SUM(CASE WHEN signed_days >= -180 AND signed_days <= -1 THEN 1 ELSE 0 END) AS n_b180,
        SUM(CASE WHEN signed_days >= -365 AND signed_days <= -1 THEN 1 ELSE 0 END) AS n_b365,
        SUM(CASE WHEN signed_days >= 1   AND signed_days <= 30  THEN 1 ELSE 0 END) AS n_a30,
        SUM(CASE WHEN signed_days >= 1   AND signed_days <= 90  THEN 1 ELSE 0 END) AS n_a90,
        SUM(CASE WHEN signed_days >= 1   AND signed_days <= 180 THEN 1 ELSE 0 END) AS n_a180,
        SUM(CASE WHEN signed_days >= 1   AND signed_days <= 365 THEN 1 ELSE 0 END) AS n_a365
    FROM first_general
)
SELECT
    a.n_total AS n_with_general_code,
    CASE WHEN a.n_before > 0 AND a.n_before <= @min_cell_count THEN -@min_cell_count ELSE a.n_before END AS n_first_general_before,
    CASE WHEN a.n_b30    > 0 AND a.n_b30    <= @min_cell_count THEN -@min_cell_count ELSE a.n_b30    END AS n_first_general_within_30d_before,
    CASE WHEN a.n_b90    > 0 AND a.n_b90    <= @min_cell_count THEN -@min_cell_count ELSE a.n_b90    END AS n_first_general_within_90d_before,
    CASE WHEN a.n_b180   > 0 AND a.n_b180   <= @min_cell_count THEN -@min_cell_count ELSE a.n_b180   END AS n_first_general_within_180d_before,
    CASE WHEN a.n_b365   > 0 AND a.n_b365   <= @min_cell_count THEN -@min_cell_count ELSE a.n_b365   END AS n_first_general_within_365d_before,
    CASE WHEN a.n_day0   > 0 AND a.n_day0   <= @min_cell_count THEN -@min_cell_count ELSE a.n_day0   END AS n_first_general_day0,
    CASE WHEN a.n_after  > 0 AND a.n_after  <= @min_cell_count THEN -@min_cell_count ELSE a.n_after  END AS n_first_general_after,
    CASE WHEN a.n_a30    > 0 AND a.n_a30    <= @min_cell_count THEN -@min_cell_count ELSE a.n_a30    END AS n_first_general_within_30d_after,
    CASE WHEN a.n_a90    > 0 AND a.n_a90    <= @min_cell_count THEN -@min_cell_count ELSE a.n_a90    END AS n_first_general_within_90d_after,
    CASE WHEN a.n_a180   > 0 AND a.n_a180   <= @min_cell_count THEN -@min_cell_count ELSE a.n_a180   END AS n_first_general_within_180d_after,
    CASE WHEN a.n_a365   > 0 AND a.n_a365   <= @min_cell_count THEN -@min_cell_count ELSE a.n_a365   END AS n_first_general_within_365d_after,
    CASE WHEN a.n_total <= @min_cell_count THEN NULL ELSE m.median_days END AS median_signed_days_first_general
FROM agg a
CROSS JOIN med m
;

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
