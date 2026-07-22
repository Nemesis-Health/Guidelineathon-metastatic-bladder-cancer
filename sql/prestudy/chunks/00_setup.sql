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
