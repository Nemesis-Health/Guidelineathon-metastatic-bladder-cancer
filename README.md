# FACLON-Bladder Diagnostics and Feasibility 

Eligibility stage for the **FALCON-Bladder/Guidelinathon** study.

---

## Study layout

A full run has two main steps, in order:

1. **Diagnostics** (`results/diagnostics/`) — pre-study characterization
   queries against the OMOP CDM. This functionality is ported from the external
   [`onco-pre-study`](https://github.com/Nemesis-Health/onco-pre-study/tree/fb30995fa0c776e4681e92a9e640812a9e4e88df)
   repo (pinned at commit `fb30995`): its query assets and SQL Server templates
   are mirrored into this repository (`sql/prestudy/`) so the study can run
   standalone, without a separate checkout of that project.
   See [What it does — the diagnostics stage](#what-it-does--the-diagnostics-stage)
   and [Pre-study queries & result packaging](#pre-study-queries--result-packaging).
2. **Eligibility** (`results/eligibility/`) — the main cohort-creation
   pipeline: ARTEMIS regimen alignment, eligibility / lab test normalization, cohort creation,
   cohort lab ranges and demographics.
   See [What it does — the pipeline stages](#what-it-does--the-pipeline-stages).

At the end of a run, each step's outputs are packaged into their own zip —
`diagnostics.zip` and `eligibility_results.zip` respectively.

---

## Quick start

1. Open `bladder-eligibility.Rproj` in RStudio (or set the project dir as the
   working directory).
2. Edit the **CONFIG block at the top of `run.R`** — define `connectionDetails`
   (however your site connects) and fill in the schema names.
3. Run: step through `run.R`, or

   ```r
   source("run.R")
   ```

> [!TIP]
> `run.R` splits into two independent, complementary scripts if you don't want
> to run both stages in one go — together they do exactly what `run.R` does:
> - **`run_diagnostics_only.R`** — just the pre-study diagnostics stage
>   (`R/00_prestudy_queries.R`). No ARTEMIS, CohortGenerator, or CirceR
>   required. Use this if you're stuck on the ARTEMIS/Python setup but want
>   diagnostics results now. Writes `results/diagnostics/` + `diagnostics.zip`.
> - **`run_feasibility_only.R`** — just the eligibility/feasibility pipeline
>   (steps a–h: ARTEMIS alignment through covariates). Use this once ARTEMIS
>   is sorted, whether or not you've already run diagnostics separately.
>   Writes `results/eligibility/` + `eligibility_results.zip`.
>
> Each has its own CONFIG block (same fields as `run.R`) — edit and
> `source()` the one you need.

`run.R` holds the **CONFIG block** (the only thing to edit — `connectionDetails`,
schemas, table names, run settings; it builds the `executionSettings` object the
ARTEMIS code reads), then sources the numbered steps in order and writes
CSVs under `results/eligibility/`.

### Requirements

**R 4.5.1** (the version the lockfile pins) and the eleven direct R packages below. Everything else in `renv.lock` is a transitive dependency of these.

| Package | Version | Source |
|---|---|---|
| `ARTEMIS` | **1.6.0** (`242b5a2`) | GitHub `OHDSI/Artemis` — **see the ARTEMIS note below** |
| `DatabaseConnector` | 6.4.0 | CRAN |
| `CirceR` | 1.3.3 | CRAN |
| `CohortGenerator` | 0.11.2 | CRAN |
| `SqlRender` | 1.19.4 | CRAN |
| `dplyr` | 1.1.4 | CRAN |
| `tibble` | 3.3.0 | CRAN |
| `readr` | 2.1.6 | CRAN |
| `cli` | 3.6.5 | CRAN |
| `rlang` | 1.1.6 | CRAN |
| `stringr` | 1.6.0 | CRAN |

Everything except ARTEMIS comes from CRAN.

You also need a driver for your database: a **JDBC driver** if you connect with
`createConnectionDetails()` (download once with
`DatabaseConnector::downloadJdbcDrivers("<dbms>", "~/.jdbc_drivers")`), or the
relevant **ODBC/DBI driver** if you use `createDbiConnectionDetails()`. Which one
is up to you — `connectionDetails` is defined by you in `run.R` (see step 2 in
[Quick start](#quick-start)).

> [!WARNING]
> **PostgreSQL: use a JDBC connection, not DBI/RPostgres.** DatabaseConnector's
> DBI code path calls `getTableNames()` to verify cohort tables after creating
> them, but `RPostgres::Postgres()`'s `dbListTables()` ignores the schema
> argument and only lists tables on the current session's `search_path`
> ([OHDSI/DatabaseConnector#339](https://github.com/OHDSI/DatabaseConnector/issues/339)).
> This makes `CohortGenerator::generateCohortSet()` fail with "The following
> tables have not been created" even though they were. The pipeline detects
> this combination right after connecting and stops with a pointer to this
> note; other DBMSes/drivers (e.g. DBI via `odbc::odbc()` for SQL Server) are
> unaffected.

> [!IMPORTANT]
> **ARTEMIS must be the version this study was built against.** It is a
> GitHub-only package (not on CRAN); use **`OHDSI/Artemis` at v1.6.0** (commit
> `242b5a24864b85a44c62d95a98cbaa2d16c55539`), the version pinned in `renv.lock`.
> ARTEMIS also needs **Python ≥ 3.12** on the machine — the ARTEMIS README has
> good guidance for resolving the Python dependency:
> <https://github.com/OHDSI/Artemis#installation>.

> [!WARNING]
> **Pin `pandas` to the 2.x line (e.g. `2.2.3`) in ARTEMIS's Python environment —
> `pandas 3.x` silently breaks regimen alignment.** Confirmed 2026-07-31: with
> `pandas==3.0.3` installed in the reticulate venv ARTEMIS builds (usually
> `<Rlib>/ARTEMIS/.r-reticulate`), `ARTEMIS::generateRawAlignments()` /
> `runArtemis()` fails with `Error in if (nrow(output) == 0) { : argument is of
> length zero` — **after** "Generating raw alignments" reports 100% complete, so
> it looks like an alignment/data problem, not an environment one. It is not:
> the Cython alignment engine's return value silently fails to convert to a
> proper R data.frame under pandas 3.x, for **any** input data (verified with
> correctly-tokenized, correctly-matched regimen strings — reproduces even in a
> direct, standalone call to `ARTEMIS::generateRawAlignments()`). Fix:
> ```bash
> <path-to-ARTEMIS-venv>/bin/python3 -m pip install "pandas==2.2.3"
> ```
> After downgrading, the exact same call returns a proper populated data.frame
> (132,920 correct alignments in testing, vs. a hard crash before). Check the
> installed version with `<venv>/bin/python3 -m pip list | grep -i pandas`. If
> a future ARTEMIS release is confirmed pandas-3-compatible, this note (and the
> pin) can be dropped.

### Installing the dependencies

Two ways — renv first (reproducible), or a plain install if you prefer.

**Option 1 — renv (exact versions, reproducible, isolated).** Restores the exact
pinned versions from `renv.lock` into a project-local library, leaving your system
library untouched. renv is **not** auto-activated — nothing happens unless you opt
in:

```r
install.packages("renv")   # if not already installed
renv::activate()           # create a project-local library (writes .Rprofile + renv/)
renv::restore()            # install every pinned package from renv.lock into it
```

`renv::activate()` is what makes the restore project-local; skip it and
`renv::restore()` installs into your normal library instead. Every entry in
`renv.lock` is required to run the study (the recursive dependency closure of the
eleven packages — no dev/report extras); renv does not resolve unrecorded
dependencies, which is why it lists ~110 packages rather than eleven.

**Option 2 — just make sure they're installed.** You don't strictly need renv or
the exact pinned versions — the study only needs each package at **≥ the version
in the table above**. If you already run OHDSI studies you likely have most of
these; update anything older, and install ARTEMIS from GitHub:

```r
install.packages(c("DatabaseConnector", "CirceR", "CohortGenerator",
                   "SqlRender", "dplyr", "tibble", "readr",
                   "cli", "rlang", "stringr", "remotes"))
remotes::install_github("OHDSI/Artemis@242b5a24864b85a44c62d95a98cbaa2d16c55539")
```

To see what you already have first:

```r
for (p in c("DatabaseConnector", "CirceR", "CohortGenerator", "SqlRender",
            "dplyr", "tibble", "readr", "cli", "rlang", "stringr", "ARTEMIS",
            "jsonlite", "ggplot2", "scales"))
  cat(sprintf("%-18s %s\n", p,
      tryCatch(as.character(packageVersion(p)), error = function(e) "MISSING")))
```

`run.R` checks all fourteen are present and stops with a clear message if any
is missing. (ARTEMIS is the exception to "newer is fine": use the commit
above, which is the tested one — see the ARTEMIS note.)

Either way, install a database driver (above) and set up Python ≥ 3.12 for
ARTEMIS.

---

## What it does — the pipeline stages

| Stage | Script | Produces |
|---|---|---|
| **(a)** ARTEMIS regimen alignment | `R/01_artemis.R` | `bc_artemis_episodes`, `bc_regimen_classifications` |
| **(b)** eligibility labs **+** cohorts → one table | `R/02_eligibility_inputs.R` | `bc_lab_cohort` (labs **+** ECOG **+** conditions), `bc_raw_lab_results` |
| **(c)** main cohort tree | `R/03_main_cohorts.R` | `bc_cohort`, `results/eligibility/cohort_counts.csv` |
| **(d)** lab test ranges on (c) | `R/04_lab_ranges.R` | `lab_value_distribution.csv`, `lab_timing_to_index.csv`, `lab_results_summary.csv`, `lab_results_rollup.csv` |
| — eligibility-input counts + coverage | `R/05_eligibility_coverage.R` | `lab_cohort_counts.csv`, `eligibility_input_coverage.csv` |
| — ARTEMIS alignment assessment | `R/06_artemis_assessment.R` | `artemis_summary.csv`, `artemis_coverage.csv`, `artemis_drug_exposures.csv`, `artemis_regimens_aligned.csv`, `artemis_episodes_per_patient.csv`, `artemis_uncaptured_drugs.csv` |
| — per-cohort demographics | `R/07_demographics.R` | `demographics.csv` |
| — covariate overlap with 1A | `R/08_covariates.R` | `covariate_overlap.csv`, `bc_covariate_cohort` |

**Approach A** — every eligibility input lives in one table (`bc_lab_cohort`):
first the labs (`sql/lab_cohorts.sql`), then the ECOG + condition cohorts, whose
membership is *inserted* into the same table under reserved test-id slots. So
`sql/eligibility_2*.sql` reads a single table uniformly.

---

## What it does — the diagnostics stage

Runs a fixed battery of pre-study characterization queries against the CDM,
anchored on the bladder-cancer diagnosis cohort (`sql/prestudy/chunks/00_setup.sql`,
section A — aligned with the main study's `[GDE] Bladder Cancer` concept set from
`cohorts/01_Target/Target_1A.json`). All queries live in `sql/prestudy/`
(`00_setup.sql` builds shared temp tables; `chunks/01`–`35` each export one CSV).
This is a high-level orientation only — for the exact query logic and output
schemas, see [onco-pre-study at `fb30995`](https://github.com/Nemesis-Health/onco-pre-study/tree/fb30995fa0c776e4681e92a9e640812a9e4e88df),
the source this was mirrored from.

| Group | Chunk(s) | Covers |
|---|---|---|
| Attrition & prevalence | `00b`, `01` | Cohort attrition (any qualifying DX → the obs-period-eligible subset), population prevalence. |
| Code counts & timing | `02`–`05` | Code-count summaries and pairwise event timing (DX / MET / L01), overall and by year. |
| ODX / GDX prevalence | `06`, `06b`, `33`–`35` | Directional other-cancer-dx and general-cancer-dx concept prevalence around the anchor, banded and cumulative. |
| L01 (antineoplastic) treatment | `07`, `11`–`15` | Treatment-exposure windows and consecutive-record gap distributions. |
| Death timing | `08`, `13`–`14` | Death date vs. index/first-MET and vs. observation-period end. |
| Demographics | `09` | Age/sex at anchor dates. |
| Anchor code detail | `10`, `18`–`19` | Per-concept anchor-code counts, record-repeat and intercode timing. |
| Observation-period QC | `16`–`17` | Look-back/follow-up observability, period-definition integrity. |
| MET-first subgroup | `20`–`23` | Ordering, support, and timing of first Metastasis vs. first specific diagnosis. |
| MET → treatment timing | `24`–`28` | Where/when the closest antineoplastic treatment falls relative to first Metastasis. |
| Drug-therapy procedures | `29`–`32` | Procedure-vs-drug-exposure signal source, timing, and co-occurrence. |

---

## Pre-study queries & result packaging

`sql/prestudy/` is already committed (mirrored from
[onco-pre-study at `fb30995`](https://github.com/Nemesis-Health/onco-pre-study/tree/fb30995fa0c776e4681e92a9e640812a9e4e88df))
— no external checkout needed to run the study.

At the end of a run, results are packaged into two archives:

- **`diagnostics.zip`** — `run.R` executes `sql/prestudy/chunks/00_setup.sql`
  then every other chunk against the live connection (`R/00_prestudy_queries.R::runPreStudyDiagnostics()`),
  writing one CSV per chunk to `results/diagnostics/`; mirrored as-is,
  unfiltered (any cell-count suppression happens inside the SQL itself via
  `@min_cell_count`, same as the external project).
- **`eligibility_results.zip`** — every CSV under `results/eligibility/`,
  already censored at write time (subjects < `settings$minCellCount`) by
  each `R/0N_*.R` step — no additional filtering happens at packaging time.

## File map

### `R/` — driver + logic
| File | Role |
|---|---|
| `01_artemis.R` | (a) generate the ARTEMIS scan cohort, run regimen alignment, write episodes, load `regimen_reference.csv`. |
| `02_eligibility_inputs.R` | (b) run `lab_cohorts.sql`; generate ECOG + condition cohorts; insert them into `bc_lab_cohort` under test-id slots. |
| `03_main_cohorts.R` | (c) build the full manifest (Target 1A, covariates, ARTEMIS + SQL templates: initiated base, 4/5/6, 2a–2e, 3a–3e) and generate it. |
| `04_lab_ranges.R` | (d) lab-value distribution + per-unit QC summary on the main cohorts. |
| `05_eligibility_coverage.R` | eligibility-table counts and each input crossed with Target 1A (tested / passed). |
| `06_artemis_assessment.R` | ARTEMIS assessment: alignment stats, patient/exposure coverage, per-drug and per-regimen frequencies, uncaptured exposures — all from the in-memory `artemisResult`. |
| `07_demographics.R` | Per-cohort demographic strata (age group / sex / index year, with `pct`) + continuous age summary. |
| `08_covariates.R` | Comorbidity + performance-status overlap with Target 1A; also generates the comorbidity cohorts step (k) scores as Charlson CCI components. |
| `09_outcomes.R` | Outcomes: DTI (Target 1A), OS (every cohort), TTNT/TTD/TTD-LoT2/TFI (treatment-initiated cohorts) — KM + 1/2/3-yr milestones, stratified by age group / sex / index year. |
| `10_adherence.R` | Guideline relevance (per-cohort % of Cohort 1) + adherence roll-up (per eligibility leaf: adherent / alt-guideline / indicated-other / non-indicated / no-treatment). |
| `11_baseline_characterization.R` | Weight/height/BMI (per cohort) + Charlson Comorbidity Index (Cohort 1). |
| `12_treatment_patterns.R` | Regimen + classification-category distribution by line of therapy, % untreated, Sankey-ready LoT1→LoT2→LoT3 pathway counts. |
| `helpers.R` | Cohort-generation + SQL helpers (thin wrappers over CirceR/CohortGenerator/SqlRender). |
| `artemis.R` | The ARTEMIS pipeline wrapper: `runArtemis()`, `buildEpisodeTable()`, `writeArtemisEpisodes()`. (Coverage/uncaptured analytics are computed in `06_artemis_assessment.R`.) |
| `timeToEvent.R` | Generic time-to-event engine (ported from `onco-study-modules`): `computeTimeToEvent()` (KM via `survival`/`broom`) + `computeTimeDiffStats()` (non-censored descriptive stats). Used by step 09. |
| `survivalMilestones.R` | `extractSurvivalMilestones()` — reads KM survival probabilities at fixed day milestones (365/730/1095). Used by step 09. |
| `eventBuilders.R` | Per-outcome event tibbles for step 09/12: `fetchDeathEvents()` (OS), `buildLineOfTherapyEvents()` (TTNT/TTD/TTD-LoT2, from ARTEMIS episodes), `buildDtiEvents()` (DTI), `anchorEpisodes()` (restricts episode ranking to on/after each subject's own index — see Known gaps), `combineEarliestEvent()` (death-aware TTNT/TTD/TFI). |
| `guidelineAdherence.R` | `computeGuidelineRelevance()` / `computeAdherenceRollup()` — pure set-math for step 10; see that file's header for why the set logic differs from `onco-study-modules`' original. |
| `charlsonScore.R` | `computeCharlsonScore()` / `charlsonComponents()`, ported from `onco-study-modules` (pure math, no DB dependency). Used by step 11. |
| `vendor_utils.R` | `.getDbms()` + `%||%` (helpers used by the ARTEMIS code). |
| `setup.R` | **Do not edit.** Validates the `run.R` CONFIG block and builds the derived paths + `executionSettings` object the steps read. |

### `sql/` — SqlRender templates
| File | Role |
|---|---|
| `lab_cohorts.sql` | Scores OMOP measurements → `bc_raw_lab_results` (all normalised rows) + `bc_lab_cohort` (pass rows, `cohort_definition_id = test_id`, 1–23/44–48). |
| `insert_eligibility_cohorts.sql` | Copies a generated cohort's members into `bc_lab_cohort` under a test-id slot (ECOG/conditions). |
| `eligibility_2{a,b,c,d,e}.sql` | The eligibility leaves — read `bc_lab_cohort` uniformly (labs + ECOG + conditions). |
| `Target_1A_initiated_template.sql` | Treatment-initiation base cohort (earliest classifiable regimen). |
| `lab_value_distribution_portable.sql` | Per cohort × lab (cat) × stratum summary of `std_value` (mean/SD/median/IQR), censored. Used by step (d); `lab_value_distribution.sql` is the PERCENTILE_CONT original, kept for comparison. |
| `lab_results_summary_portable.sql` | Per (cat, concept, unit) QC summary of `bc_raw_lab_results` (unit-resolution sanity check). Used by step (d); `lab_results_summary.sql` is the PERCENTILE_CONT original, kept for comparison. |
| `lab_results_rollup_portable.sql` | Per-category headline of `bc_raw_lab_results`: one row per (cat, is_ambiguous) in the standard unit, with unit-resolution health as QC columns. Used by step (d); `lab_results_rollup.sql` is the PERCENTILE_CONT original, kept for comparison. |
| `lab_cohort_counts.sql` | Whole-population counts of `bc_lab_cohort` per test-id. |
| `eligibility_input_coverage.sql` | Each input × cohort × stratum (every cohort in the main tree): `n_tested` (measured) + `n_passed` (criterion met). |
| `n_target1a.sql` | Target 1A denominator. Used by step (h) (`covariate_overlap.csv`); `eligibility_input_coverage.csv`'s per-cohort/stratum denominators come from `subject_strata.sql` directly instead. |
| `cohort_counts_stratified.sql` | Per cohort × stratum (`age_group`/`sex`/`age_sex`) distinct-subject counts; the `overall` view comes from `CohortGenerator::getCohortCounts()` instead, reshaped in R. Used by step (c). |
| `outcome_target_data.sql` | Cohort membership + index/end dates for a given cohort-id list. Used by steps 09/10/11/12 (generic — the `@target_cohort_ids` list is whatever the caller needs). |
| `subject_strata.sql` | Per-subject age group / sex / age × sex / index year — single source of truth for this bucketing. See that file's own header for the full list of consumers. |
| `fetch_death_events.sql` | Death dates for subjects in a set of cohorts. Used by `fetchDeathEvents()` (step 09, OS outcome). |
| `demographics_continuous.sql` | Per-cohort continuous age summary (mean/SD/median/IQR/min/max), portable percentile technique (no `PERCENTILE_CONT`, same as `lab_value_distribution_portable.sql`). Used by step 07. |
| `baseline_vitals.sql` | Weight (kg) / height (cm) / BMI, closest measurement to each cohort's index within `settings$vitalsWindowDays`. Used by step 11. |
| `metastasis_marker.sql` | Subjects with a metastasis measurement among a given concept-id list (used with `Target_1A.json`'s own metastasis ConceptSet, not a hardcoded list). Used by step 11 for Charlson's `metastatic_solid_tumor`. |

### `cohorts/` — cohort artefacts
`00_ARTEMIS/` scan cohort · `01_Target/` Target 1A + the L01 comparison cohort ·
`02_Covariate/` two groups of JSONs, both read by `08_covariates.R`:
- **Eligibility-input covariates** (feed `bc_lab_cohort` test-id slots, step (b)):
  the ECOG cohorts (`ECOG_0`, `ECOG_1`, `ECOG_2`, `ECOG_3plus`) and condition
  cohorts (`Peripheral_Neuropathy`, `Significant_Skin_Disorders`,
  `Audiometric_Hearing_Loss`, `Polyuria`, `Polydipsia`, `Anticoagulant_Therapy`,
  `Liver_Metastasis`, `Gilberts_Syndrome`).
- **Comorbidity covariates** (feed `covariate_overlap.csv` +, for a subset,
  Charlson CCI scoring in step (k) — see `08_covariates.R`'s `comorbMap`):
  `Type_2_Diabetes`, `Hypertension`, `Cardiovascular_Disease`, `Stroke`,
  `Venous_Thrombotic_Events`, `Renal_Disease`, `Dementia`, and — added for
  Charlson CCI, sourced from Fortin/Reps/Ryan 2022/2023 (see Known gaps) —
  `Myocardial_Infarction`, `Congestive_Heart_Failure`,
  `Peripheral_Vascular_Disease`, `Chronic_Pulmonary_Disease`,
  `Rheumatic_Disease`, `Peptic_Ulcer_Disease`, `Diabetes_With_Complications`,
  `Hemiplegia_Paraplegia`, `AIDS_HIV`,
  `Liver_Disease` (mild tier) and `Liver_Disease_Severe` (moderate/severe
  tier — `Liver_Disease.json`'s concept set was corrected against the same
  source; it previously used an ad hoc 3-concept list that didn't match the
  standard Charlson mild-liver-disease definition). `Metastatic_Solid_Tumor`
  also exists (feeds `covariate_overlap.csv`) but is **not** used for CCI's
  `metastatic_solid_tumor` — see Known gaps for why step (k) derives that
  one from `Target_1A.json`'s own metastasis marker instead.

`extras/` `regimen_reference.csv`, `trial_reference.yaml` (unused — see Known
gaps, generalizability).

### `results/` — outputs (`diagnostics/`, `eligibility/`, git-ignored)

### `.cache/` — resumable-state checkpoints, git-ignored, NOT an output
`saveState()`/`loadState()` (`R/helpers.R`) checkpoint expensive in-memory
objects (`mainManifest`, `episodes`, `artemis_result.rds`, ...) to
`.cache/<outputFolder name>/` so a crashed/restarted session can resume a
later step without recomputing earlier ones. Unlike everything under
`results*/`, these are **patient-level** (ARTEMIS episodes/alignments,
drug exposures by `person_id`) — never zip or share this folder alongside
`diagnostics.zip`/`eligibility_results.zip`. Keyed by the output folder's
own name, so pointing `settings$outputFolder` at a fresh folder (e.g. for a
clean re-run) also starts from a fresh cache — nothing carries over silently.

---

## Outputs (`results/eligibility/`)

A full run writes several dozen CSVs to `results/eligibility/` (created on first
write; the folder is git-ignored). These aggregate tables are the only
artefacts the main pipeline exports — no row-level data is written (the
patient-level `.cache/` checkpoints above are a separate, unshared folder).
Every file
is UTF-8, comma-separated,
with a header row; missing/censored cells are written as **empty strings**
(`readr::write_csv(..., na = "")`).

**Which population each table describes matters** and varies by file. Some are
*whole-population* — every person in the CDM with the relevant data, **not** the
bladder-cancer study cohort — and exist purely as unit-resolution / data-quality
checks (`lab_results_summary`, `lab_results_rollup`, `lab_cohort_counts`). Others
are restricted to a study cohort: **Target 1A** (overall mBC), the **ARTEMIS scan
cohort**, or reported **per generated cohort**. The **Population** column says
which; read it before comparing counts across files (e.g. a whole-population lab
count is not comparable to a Target 1A coverage count).

Quick index (detailed schema for each below):

| File | Written by | Population | Grain (one row per…) |
|---|---|---|---|
| `cohort_counts.csv` | `03_main_cohorts.R` | Each cohort (the tree) | generated cohort × stratum type × stratum value |
| `lab_cohort_counts.csv` | `05_eligibility_coverage.R` | **Whole population** | eligibility test-id |
| `eligibility_input_coverage.csv` | `05_eligibility_coverage.R` | Per main cohort | cohort × stratum type × stratum value × eligibility test-id |
| `lab_value_distribution.csv` | `04_lab_ranges.R` | Per main cohort | cohort × lab (cat) × stratum type × stratum value |
| `lab_timing_to_index.csv` | `04_lab_ranges.R` | Target 1A + Target 1A PC allowed | cohort × lab (cat) × direction (before/after/any) |
| `lab_results_summary.csv` | `04_lab_ranges.R` | **Whole population** | cat × measurement concept × unit × status × ambiguity |
| `lab_results_rollup.csv` | `04_lab_ranges.R` | **Whole population** | cat × ambiguity (standard unit; QC columns) |
| `artemis_summary.csv` | `06_artemis_assessment.R` | Scan cohort + Target 1A | cohort × ARTEMIS pipeline stage |
| `artemis_coverage.csv` | `06_artemis_assessment.R` | Scan cohort + Target 1A | cohort × coverage level (patient / exposure) |
| `artemis_drug_exposures.csv` | `06_artemis_assessment.R` | Scan cohort + Target 1A | cohort × anticancer ingredient |
| `artemis_regimens_aligned.csv` | `06_artemis_assessment.R` | Scan cohort + Target 1A | cohort × aligned regimen |
| `artemis_episodes_per_patient.csv` | `06_artemis_assessment.R` | Scan cohort + Target 1A | cohort × episode-count value |
| `artemis_uncaptured_drugs.csv` | `06_artemis_assessment.R` | Scan cohort + Target 1A | cohort × anticancer ingredient (uncaptured) |
| `demographics.csv` | `07_demographics.R` | Per cohort | cohort × characteristic × stratum |
| `demographics_age_continuous.csv` | `07_demographics.R` | Per cohort | cohort (n/mean/SD/median/IQR/min/max of age) |
| `covariate_overlap.csv` | `08_covariates.R` | Target 1A | covariate (comorbidity / PS stratum) × cohort 1A |
| `outcome_dti_summary.csv` / `_histogram.csv` | `09_outcomes.R` | Target 1A | stratum type × stratum value (+ time bin for histogram) |
| `outcome_{os,ttnt,ttd,ttd_lot2,tfi}_summary.csv` / `_histogram.csv` | `09_outcomes.R` | os: every cohort (T1/T2a-e/T3a-e/T4-6a-f); ttnt/ttd/ttd_lot2/tfi: treatment-initiated cohorts only (T3a-e/T4-6a-f) | cohort × stratum type × stratum value (+ time bin for histogram) |
| `outcome_{os,ttnt,ttd,ttd_lot2,tfi}_km.csv` | `09_outcomes.R` | same as above | cohort × stratum type × stratum value × KM step |
| `outcome_{os,ttnt,ttd,ttd_lot2,tfi}_median_survival.csv` | `09_outcomes.R` | same as above | cohort × stratum type × stratum value |
| `outcome_{os,ttnt,ttd,ttd_lot2,tfi}_milestones.csv` | `09_outcomes.R` | same as above | cohort × stratum type × stratum value × milestone (365/730/1095d) |
| `guideline_relevance.csv` | `10_adherence.R` | T1/T2a-e/T3a-e/T4-6a-f | stratum type × stratum value × cohort |
| `guideline_adherence.csv` | `10_adherence.R` | Eligible (T2) subjects per leaf | stratum type × stratum value × leaf × category (adherent/alt-guideline/indicated-other/non-indicated/no-treatment) |
| `baseline_vitals.csv` | `11_baseline_characterization.R` | Per cohort | cohort × variable (weight_kg/height_cm/bmi) × stratum type × stratum value |
| `charlson_cci.csv` | `11_baseline_characterization.R` | Target 1A | CCI category (0 / 1-2 / 3-4 / >=5) |
| `treatment_pattern_untreated.csv` | `12_treatment_patterns.R` | Target 1A | stratum (overall/age_group/sex/age_sex) |
| `treatment_pattern_regimen.csv` | `12_treatment_patterns.R` | Treated (Target 1A-anchored) | stratum × line of therapy × regimen name |
| `treatment_pattern_category.csv` | `12_treatment_patterns.R` | Treated (Target 1A-anchored) | stratum × classification lens × line of therapy × category (a-f) |
| `treatment_pathways.csv` | `12_treatment_patterns.R` | Treated (Target 1A-anchored) | stratum × LoT1 × LoT2 × LoT3 category combination (`class_eau`, capped at 3 lines) |
| `treatment_pattern_by_year.csv` | `12_treatment_patterns.R` | Per treated cohort ("mBC initiated base", T3a-e, T4-6a-f) | cohort × lot × index year × lens category × stratum (overall/age_group/sex/age_sex) |

### Privacy censoring (applies to every file)

All small-cell counts are censored before write, so no aggregate reveals a
group of fewer than `minCellCount` (default **5**) subjects:

- A patient/subject count `n` with `0 < n < minCellCount` is written as
  **`−minCellCount`** (e.g. `−5`), never the true small value.
- When a count is censored, its **paired record/measurement/episode count and
  any distribution statistics** (mean, SD, quantiles, percentages) on that row
  are **blanked** (empty cell).
- A genuine zero stays `0`; a censored small count is the negative sentinel — so
  the two are distinguishable downstream.

### Age/sex stratification (applies to every stratified file)

Most per-cohort outputs below break down age (`age_group`: `<=65`/`>65`,
relative to that cohort's own index date), `sex`, and the age × sex cross
(`age_sex`) alongside the pooled `overall` row, via one shared query,
`sql/subject_strata.sql`.

Which of these views actually get computed and written is controlled by a
single setting, **`settings$strataColumns`** in `run.R`'s CONFIG block
(default `c("age_group", "sex", "age_sex")`). A site that wants no
stratification at all sets it to `character(0)`; a site that only wants,
say, sex breakdowns sets it to `c("sex")`. `overall` is always produced
regardless. This is the one place to change it — no per-file toggles.

---

### `cohort_counts.csv`
Row per generated cohort × stratum — the whole main tree plus covariates
(Target 1A / T1 mBC, the treatment-initiation arms 4/5/6, eligibility leaves
2a–2e, the intersections 3a–3e, and the ECOG + condition covariates), each
reported once overall and once per `subject_strata.sql` stratum (`age_group`,
`sex`, `age_sex`). The `overall` rows are `CohortGenerator::getCohortCounts()`'s
own result reshaped into this long format, not re-derived, so they can't
drift from the trusted library count; `age_group`/`sex`/`age_sex` come from a
companion query (`cohort_counts_stratified.sql`).

| Column | Meaning |
|---|---|
| `cohort_definition_id` | Numeric id assigned in dependency order in `03_main_cohorts.R`. |
| `cohort_name` | Human-readable cohort name (e.g. `T1 Metastatic bladder cancer`). |
| `stratum_type` | `overall`, `age_group`, `sex`, or `age_sex`. |
| `stratum_value` | `overall`; `<=65`/`>65`; `Male`/`Female`/`Other-Unknown`; or the `age_sex` combination. |
| `n_entries` | Number of qualifying cohort episodes (entries; blanked when `n_subjects` is censored). |
| `n_subjects` | Number of distinct subjects (censored). |

### `lab_cohort_counts.csv`
Row per eligibility **test-id slot** in the unified `bc_lab_cohort` table, over
the **whole population** (not restricted to Target 1A). Ids 1–23 / 44–48 are
labs; 24–27 ECOG; 28–40 conditions (test-id reference in the header of `sql/eligibility_2a.sql`).

| Column | Meaning |
|---|---|
| `test_id` | Eligibility test-id (`cohort_definition_id` in `bc_lab_cohort`). |
| `label` | Human label for the test-id (e.g. `ALT<=2.5xULN`, `ECOG 1`, `Liver metastasis`). |
| `n_subjects` | Distinct subjects meeting that criterion / in that cohort (censored). |
| `n_records` | Underlying row count (blanked when `n_subjects` is censored). |

### `eligibility_input_coverage.csv`
Row per eligibility test-id **crossed with every cohort in the main tree**
(same scope as `lab_value_distribution.csv` — not just Target 1A), once
overall and once per `subject_strata.sql` stratum (`age_group`, `sex`,
`age_sex`) — how many members of that cohort had each input measured vs.
passed it, within the index window (`labWindowBeforeDays` before /
`labWindowAfterDays` after, default 14 / 7) of *that cohort's own* index
date. ECOG/condition slots have no `n_tested` (blank — they are not lab
measurements). `n_cohort` is the denominator **for that cohort × stratum**
(e.g. a `cohort_definition_id=T2a, age_group=">65"` row's `n_cohort` is >65
T2a members only, not all of T2a or all of T1).

Note the overlap with `lab_value_distribution.csv`: for labs specifically,
`n_tested` is the same fact as that file's `n_with_lab` for the matching
cat, just duplicated at test-id (threshold) granularity instead of
cat (lab) granularity — every test-id sharing a cat has an identical
`n_tested`. Kept as two files deliberately: they answer different
questions (eligibility coverage vs. value distribution), even though one
column overlaps.

| Column | Meaning |
|---|---|
| `cohort_definition_id`, `cohort_name` | As elsewhere. |
| `stratum_type` | `overall`, `age_group`, `sex`, or `age_sex`. |
| `stratum_value` | `overall`; `<=65`/`>65`; `Male`/`Female`/`Other-Unknown`; or the `age_sex` combination. |
| `test_id` | Eligibility test-id. |
| `label` | Human label for the test-id. |
| `n_cohort` | This cohort's denominator, restricted to this row's stratum. |
| `n_tested` | Members (in this cohort × stratum) who had the measurement at all (labs only; censored). |
| `n_passed` | Members (in this cohort × stratum) who met the criterion / have the cohort (censored). |

### `lab_value_distribution.csv`
Row per **cohort × lab (cat) × stratum** — the distribution of the
normalised lab value (`std_value`) among each main cohort's subjects, using
the one measurement closest to index within the index window
(`labWindowBeforeDays` before / `labWindowAfterDays` after). One row per lab
per stratum: `std_value` does not depend on the eligibility threshold, so
the raw table's per-criterion (`test_id`) fan-out is collapsed to distinct
measurements first. Every (cohort, cat) combination is reported once
overall and once per `subject_strata.sql` stratum (`age_group`, `sex`,
`age_sex`).

| Column | Meaning |
|---|---|
| `stratum_type` | `overall`, `age_group`, `sex`, or `age_sex`. |
| `stratum_value` | `overall`; `<=65`/`>65`; `Male`/`Female`/`Other-Unknown`; or the `age_sex` combination. |
| `cohort_definition_id` | Cohort id (matches `cohort_counts.csv` `cohort_definition_id`). |
| `cat` | Lab category / analyte code. |
| `n_with_lab` | Subjects with a value near index (censored). |
| `mean_value`, `sd_value` | Mean and standard deviation of `std_value` (blanked when censored). |
| `median_value`, `lq_value`, `uq_value` | Median, lower (25th) and upper (75th) quartile (blanked when censored). |

### `lab_timing_to_index.csv`
Row per **Target 1A / Target 1A PC allowed × lab (cat) × direction × stratum**
— how far from the cohort index (the metastasis-marker date) subjects'
recorded measurements of each of the 14 labs fall, searching a subject's
**entire** measurement history (not the `labWindowBeforeDays`/`labWindowAfterDays`
eligibility window `lab_value_distribution.csv` restricts to). `direction` is
one of `before` (closest on/before index), `after` (closest on/after index),
or `any` (closest in either direction); a same-day measurement (0 days)
counts as the closest for all three. Restricted to Target 1A and its
PC-allowed variant — the metastasis index isn't meaningful for the
treatment-initiated cohorts (T3-6, L01-anchored), which index on treatment
start instead.

Every (cohort, cat, direction) combination is reported once overall and
once per `subject_strata.sql` stratum (`age_group`, `sex`, `age_sex`) —
`stratum_type`/`stratum_value` identify which. The stratum views always
sum back to the `overall` row's `n_ever` (e.g. `age_group`'s `<=65` + `>65`
== `overall`'s `n_ever`).

Two kinds of columns: **coverage buckets** (`n_0_14` … `n_ever`), cumulative
counts of subjects whose closest measurement in that direction falls within
N days of index (not disjoint bins — `n_0_30` includes everyone already
counted in `n_0_14`); and **percentiles** of days-to-closest among subjects
counted in `n_ever` (i.e. conditional on having a measurement at all in that
direction).

| Column | Meaning |
|---|---|
| `stratum_type` | `overall`, `age_group`, `sex`, or `age_sex`. |
| `stratum_value` | `overall`; `<=65`/`>65`; `Male`/`Female`/`Other-Unknown`; or the `age_sex` combination (`'<=65\|Male'`, ...). |
| `cohort_definition_id` | Cohort id (Target 1A or Target 1A PC allowed). |
| `cat` | Lab category / analyte code (one of the 14 in `sql/lab_cohorts.sql`). |
| `direction` | `before`, `after`, or `any`. |
| `n_0_14`, `n_0_30`, `n_0_60`, `n_0_90`, `n_0_180` | Subjects whose closest measurement in that direction is within 14/30/60/90/180 days of index (each censored independently). |
| `n_ever` | Subjects with a measurement in that direction at all, no day cap (censored). |
| `p5_days` … `p95_days` | 5th/10th/25th/50th/75th/90th/95th percentile of days-to-closest, among `n_ever` subjects (blanked when `n_ever` is censored). |

### `lab_results_summary.csv`
QC / unit-resolution sanity check on the raw normalised table
(`bc_raw_lab_results`), collapsed to one physical measurement before counting.
**Whole population** — every person in the CDM with these measurements, not the
bladder-cancer cohort.
Row per (cat × measurement concept × unit × status × ambiguity). Every unit for
a given lab should land in the same `std_value` range.

| Column | Meaning |
|---|---|
| `cat` | Lab category / analyte code. |
| `measurement_concept_id` | OMOP measurement concept id. |
| `measurement_concept_name` | Concept name (from vocabulary; blank if unresolved). |
| `unit_concept_id` | OMOP unit concept id. |
| `unit_concept_name` | Unit name (from vocabulary; blank if unresolved). |
| `status` | Normalisation status for the (concept, unit). |
| `is_ambiguous` | Flag: unit resolution was ambiguous. |
| `n_patients` | Distinct patients (censored). |
| `n_measurements` | Measurement count (blanked when censored). |
| `mean_value`, `sd_value` | Mean and SD of `std_value` (blanked when censored). |
| `min_value`, `lq_value`, `median_value`, `uq_value`, `max_value` | Min, quartiles, median, max of `std_value` (blanked when censored). |

### `lab_results_rollup.csv`
Per-category headline of the same normalised table, the companion to
`lab_results_summary.csv` (likewise **whole population**, not the study cohort).
Because `std_value` is already in each category's
standard unit, the distribution is pooled across every source concept/unit into
one row per (cat × ambiguity). Ambiguous streams (`is_ambiguous = 1`) — where
more than one scale cleared the resolver, so `std_value` may be mis-scaled — get
their own row so they never contaminate the clean distribution. Unit-resolution
health is carried as QC columns instead of extra rows.

| Column | Meaning |
|---|---|
| `cat` | Lab category / analyte code. |
| `std_unit_name` | The category's standard unit — the unit every value in the row is reported in (from `bc_lab_normals`). |
| `is_ambiguous` | 0 = single scale won (trustworthy); 1 = >1 scale cleared 0.7 decades (value may be mis-scaled), reported separately. |
| `n_patients` | Distinct patients pooled across the category's streams (censored) — a true patient count, not the sum of `lab_results_summary` rows. |
| `n_measurements` | Measurement count (blanked when censored). |
| `n_concepts`, `n_units` | Distinct source measurement concepts / units feeding the category (unit-resolution spread). |
| `pct_overridden` | Share of measurements whose recorded unit was overridden by the resolver (blanked when censored). |
| `pct_unverified` | Share whose unit could not be verified but was trusted as recorded (blanked when censored). |
| `mean_value`, `sd_value` | Mean and SD of `std_value` (blanked when censored). |
| `min_value`, `lq_value`, `median_value`, `uq_value`, `max_value` | Min, quartiles, median, max of `std_value` (blanked when censored). |

**Cohort strata (all six `artemis_*` files).** Each carries a leading `cohort`
column and is emitted once per stratum, stacked: `scan_cohort` = the full ARTEMIS
scan cohort; `target_1a` = restricted to the "T1 Metastatic bladder cancer"
cohort (`cohort1Id`, step 05's Target-1A denominator). Every metric below is
computed within the stratum. Counts are censored per stratum, so a small
`target_1a` cell can be masked while its `scan_cohort` counterpart is not.

### `artemis_summary.csv`
Row per cohort × ARTEMIS pipeline stage — the funnel from scan cohort to aligned
episodes. Written only if the ARTEMIS step (a) ran this session.

| Column | Meaning |
|---|---|
| `cohort` | Stratum: `scan_cohort` or `target_1a` (see note above). |
| `metric` | Stage name: `ARTEMIS scan cohort (subjects)` → `Ingredient-level drug exposures` → `Valid anticancer drug exposures` → `Raw alignments (pre-processing)` → `Regimen episodes aligned`. For `target_1a` the first stage counts 1A subjects present in the scan cohort. |
| `n_patients` | Distinct patients at that stage (censored; scan-cohort record count is N/A). |
| `n_records` | Records at that stage (blanked when the patient count is censored). |

### `artemis_coverage.csv`
Two rows — patient-level and exposure-level alignment coverage. An exposure is
"captured" if its start date falls inside any aligned episode window for the
same patient (start-date containment; no exposure end date is available).

| Column | Meaning |
|---|---|
| `level` | `patient` or `exposure`. |
| `n_covered` | Covered patients / exposures (censored). |
| `n_total` | Total valid patients / exposures (censored). % is not emitted — it is `n_covered / n_total`. |

### `artemis_drug_exposures.csv`
Valid anticancer exposures per ingredient, most frequent first.

| Column | Meaning |
|---|---|
| `drug_concept_id` | Ingredient (ancestor) concept id. |
| `drug_name` | Ingredient name. |
| `n_records` | Exposure records (blanked when `n_patients` censored). |
| `n_patients` | Distinct patients (censored). |

### `artemis_regimens_aligned.csv`
Aligned regimen episodes per regimen, most frequent first.

| Column | Meaning |
|---|---|
| `regimen` | Regimen name (`episode_source_value`). |
| `n_episodes` | Aligned episodes (blanked when `n_patients` censored). |
| `n_patients` | Distinct patients (censored). |

### `artemis_episodes_per_patient.csv`
Distribution of how many aligned episodes each patient has.

| Column | Meaning |
|---|---|
| `n_episodes` | Episode count value. |
| `n_patients` | Patients with exactly that many episodes (censored). |

### `artemis_uncaptured_drugs.csv`
Valid anticancer exposures that overlap **no** aligned episode, per ingredient,
most frequent first — the complement of the coverage analysis. Same columns as
`artemis_drug_exposures.csv`.

| Column | Meaning |
|---|---|
| `drug_concept_id` | Ingredient (ancestor) concept id. |
| `drug_name` | Ingredient name. |
| `n_records` | Uncaptured exposure records (blanked when `n_patients` censored). |
| `n_patients` | Distinct patients (censored). |

### `demographics.csv`
Per-cohort demographic strata: age group at index (`>65` / `<=65`), sex
(`Male` / `Female` / `Other-Unknown`), and index year. One row per
cohort × characteristic × stratum (long/tidy). Age is at `cohort_start_date`
(`YEAR(index) − year_of_birth`).

| Column | Meaning |
|---|---|
| `cohort_definition_id` | Cohort id (matches `cohort_counts.csv` `cohortId`). |
| `cohort_name` | Cohort name from the run manifest. |
| `characteristic` | `age_group`, `sex`, or `index_year`. |
| `stratum` | Category within the characteristic (e.g. `>65`, `Female`, `2019`). |
| `n_subjects` | Subjects in that cohort × stratum (censored). |
| `pct` | % of that cohort's total N within `characteristic` (e.g. sex's three strata sum to ~100%), computed on the raw pre-censoring count so one censored row doesn't distort the others' denominator; blanked whenever `n_subjects` is censored. |

### `demographics_age_continuous.csv`
Companion to `demographics.csv`'s categorical `age_group`: age at index as a
continuous variable per cohort, per the protocol's "mean (SD), minimum,
maximum, median and IQR."

| Column | Meaning |
|---|---|
| `cohort_definition_id`, `cohort_name` | As above. |
| `n` | Subjects in that cohort (censored). |
| `mean_age`, `sd_age` | Mean and SD of age at index (blanked when `n` censored). |
| `min_age`, `lq_age`, `median_age`, `uq_age`, `max_age` | Min, quartiles, median, max (blanked when `n` censored). |

### `covariate_overlap.csv`
Descriptive covariates **not** used by the main cohort tree, reported as an
overlap with cohort 1A (overall mBC). Comorbidities count 1A subjects with ≥1
qualifying record **on/before their 1A index** (prevalent baseline comorbidity);
performance-status strata count 1A subjects with an ECOG record (KPS folded in)
in the stratum within the index window (`labWindowBeforeDays` before /
`labWindowAfterDays` after). PS strata **overlap** by
design (`PS 0-2` includes `PS1`/`PS2`). Comorbidity cohorts are generated into
`bc_covariate_cohort` (never `bc_cohort`); to add one, drop its JSON into
`cohorts/02_Covariate/` (see `R/08_covariates.R` `comorbMap`).

| Column | Meaning |
|---|---|
| `code` | Short code: PS strata (`PS1`, `PS2`, `PS2+`, `PS 0-2`, `PS 0-1`) or comorbidity — see `08_covariates.R`'s `comorbMap` for the full list (`T2DM`, `HTN`, `CVD`, `Stroke`, `VTE`, `LiverDx`, `RenalDx`, `Dementia`, plus the Charlson-only additions `MI`, `CHF`, `PVD`, `COPD`, `RheumDx`, `PUD`, `DMComplic`, `Hemiplegia`, `AIDS`, `LiverDxSevere`, `MetSolidTumor`). |
| `label` | Human-readable description. |
| `n_1a` | Subjects in cohort 1A (the denominator). |
| `n_overlap` | 1A subjects meeting the covariate (censored). % is not emitted — it is `n_overlap / n_1a`. |

**Outcome files (all `outcome_*` files, step 09).** DTI runs on Target 1A
only; OS runs on every main-tree cohort; TTNT/TTD/TTD-LoT2/TFI run only on
the treatment-initiated cohorts (T3a–e, T4–6a–f), since they are defined
relative to a line-of-therapy start or discontinuation. Every outcome is run
once "overall" and once per protocol stratum (age group / sex / index year),
plus the age × sex crossed view (`subject_strata.sql`'s `age_sex` column) —
one dimension at a time, matching the protocol's stratification list, with
age × sex the one crossed exception. Every file carries
`cohort_definition_id`, `cohort_name` (Target 1A only for the DTI files), and
`stratum_type` (`overall`/`age_group`/`sex`/`age_sex`/`index_year`) plus the
grouping column itself when `stratum_type` isn't `overall` (e.g. an
`age_group` column holding `>65`/`<=65`). Time units are days throughout.

Episode ranking for every line-of-therapy-based event (DTI, TTNT, TTD,
TTD-LoT2, TFI) is anchored to the relevant index date before ranking
(`anchorEpisodes()`, `R/eventBuilders.R`) — see Known gaps for why. TTNT, TTD,
TTD-LoT2, and TFI are all death-aware (`combineEarliestEvent()`): the
protocol defines each as "... or death, whichever occurs first."

### `outcome_dti_summary.csv`, `outcome_{os,ttnt,ttd,ttd_lot2,tfi}_summary.csv`
Descriptive statistics of time-to-event, among those with the event (DTI: time
to first LoT; the rest: censored survival time from `computeTimeToEvent()`).

| Column | Meaning |
|---|---|
| `count` | Subjects in that cohort × stratum (censored). |
| `n_event` | Subjects with the event observed (DTI has none — every DTI row already requires a first LoT). |
| `min_time`, `c10_time`, `q25_time`/`lq_time`, `median_time`, `q75_time`/`uq_time`, `c90_time`, `max_time` | Time-to-event distribution among events, in days (blanked when `count`/`n_event` is censored). |

### `outcome_dti_histogram.csv`, `outcome_{os,ttnt,ttd,ttd_lot2,tfi}_histogram.csv`
Binned time-to-event counts (breaks: ⩽−365, −180, −90, −60, −30, 0, 30, 60,
90, 180, 365, ⩾365 days).

| Column | Meaning |
|---|---|
| `time_bin` | Day-range bucket. |
| `count` | Subjects in that bucket (censored). |

### `outcome_{os,ttnt,ttd,ttd_lot2,tfi}_km.csv`
Tidy Kaplan-Meier step curve (one row per event/censoring time), from
`survival::survfit()` via `broom::tidy()`.

| Column | Meaning |
|---|---|
| `time` | Days since index. |
| `estimate`, `conf.low`, `conf.high` | KM survival probability + 95% CI at that step. |
| `n.risk`, `n.event`, `n.censor` | At-risk / event / censoring counts at that step (censored). |
| `strata` | `survival`'s own stratum label for the fit (e.g. `age_group=>65`, or `All` when unstratified). |

### `outcome_{os,ttnt,ttd,ttd_lot2,tfi}_median_survival.csv`
Median survival time with 95% CI, from `summary(survfit(...))$table`.

| Column | Meaning |
|---|---|
| `strata` | `survival`'s own stratum label (or `All`). |
| `n` | Subjects in the fit (censored). |
| `median`, `lower`, `upper` | Median survival time + 95% CI, in days (blanked when `n` is censored or the median is unreached). |

### `outcome_{os,ttnt,ttd,ttd_lot2,tfi}_milestones.csv`
KM survival probability read off the step curve at fixed day milestones
(365/730/1095 — the protocol's 1/2/3-year estimates).

| Column | Meaning |
|---|---|
| `strata` | KM stratum label (or `All`). |
| `milestone` | `365`, `730`, or `1095` (days). |
| `surv_prob`, `lower`, `upper` | Survival probability + 95% CI at that milestone (blanked when `n_at_risk` is censored). |
| `n_at_risk` | Subjects still at risk at that milestone (censored). |

### `guideline_relevance.csv`
Per-cohort population size as a fraction of Cohort 1 — the protocol's
"relevance" statistic. Reported once overall and once per
`subject_strata.sql` stratum (`age_group`, `sex`, `age_sex`); membership is
filtered to the stratum before computing, so `pct_of_base` is that
stratum's share of Cohort 1's own same-stratum members, not of all of
Cohort 1.

| Column | Meaning |
|---|---|
| `cohort_definition_id`, `cohort_name` | As elsewhere. |
| `stratum_type` | `overall`, `age_group`, `sex`, or `age_sex`. |
| `stratum_value` | `overall`; `<=65`/`>65`; `Male`/`Female`/`Other-Unknown`; or the `age_sex` combination. |
| `n` | Subjects in that cohort, restricted to this stratum (censored). |
| `pct_of_base` | % of Cohort 1's same-stratum members (blanked when `n` censored). |

### `guideline_adherence.csv`
Per eligibility leaf (a–e), the eligible population partitioned into five
disjoint categories via explicit set-differences (`computeAdherenceRollup()`,
`R/guidelineAdherence.R` — see that file's header for why this repo can't use
`onco-study-modules`' original set logic as-is). Reported once overall and
once per `subject_strata.sql` stratum (`age_group`, `sex`, `age_sex`) —
`eligible_n` is that stratum's eligible population, not the leaf's whole
eligible count.

| Column | Meaning |
|---|---|
| `stratum_type` | `overall`, `age_group`, `sex`, or `age_sex`. |
| `stratum_value` | `overall`; `<=65`/`>65`; `Male`/`Female`/`Other-Unknown`; or the `age_sex` combination. |
| `leaf` | `a`–`e`. |
| `category` | `adherent` (received the recommended regimen), `alt_guideline` (a different EAU-recommended regimen), `indicated_other` (a HemOnc mBC-indicated regimen), `non_indicated` (any other regimen), or `no_treatment`. |
| `n` | Subjects in that leaf × category × stratum (censored). |
| `eligible_n` | Total eligible for that leaf, restricted to this stratum (censored; the denominator — the five categories' `n` sum to this). |
| `pct_of_eligible` | % of `eligible_n` (blanked when `n` censored). |

### `baseline_vitals.csv`
Per-cohort weight/height/BMI, closest measurement to index within
`settings$vitalsWindowDays` (default ±90 days). Every (cohort, variable)
combination is reported once overall and once per `subject_strata.sql`
stratum (`age_group`, `sex`, `age_sex`).

| Column | Meaning |
|---|---|
| `cohort_definition_id`, `cohort_name` | As elsewhere. |
| `variable` | `weight_kg`, `height_cm`, or `bmi`. |
| `stratum_type` | `overall`, `age_group`, `sex`, or `age_sex`. |
| `stratum_value` | `overall`; `<=65`/`>65`; `Male`/`Female`/`Other-Unknown`; or the `age_sex` combination. |
| `n` | Subjects with that measurement near index, restricted to this stratum (censored). |
| `mean`, `sd`, `median`, `lq`, `uq`, `min`, `max` | Distribution (blanked when `n` censored). |

### `charlson_cci.csv`
Charlson Comorbidity Index category distribution, Cohort 1 only. 16 of 19
canonical components are wired (see Known gaps for which three aren't, and
why the score is still a slight understatement for a small subset of
patients).

| Column | Meaning |
|---|---|
| `cohort_definition_id`, `cohort_name` | Cohort 1 only. |
| `cci_category` | `0`, `1-2`, `3-4`, or `>=5`. |
| `n` | Subjects in that category (censored). |

All four of these are stratified one dimension at a time (overall /
age_group / sex), plus the age × sex crossed view, via
`sql/subject_strata.sql` anchored to each subject's Cohort 1 index — same
marginal convention as `treatment_pattern_by_year.csv` and the outcome files.
Which stratum views are populated is controlled centrally by
`settings$strataColumns` (see "Age/sex stratification" above) — a partner
can disable stratification for these (and every other stratified output)
in one place rather than per-file.

### `treatment_pattern_untreated.csv`
Per stratum: how many of Cohort 1 never initiated any systemic regimen.

| Column | Meaning |
|---|---|
| `stratum_type` | `overall`, `age_group`, `sex`, or `age_sex`. |
| `stratum_value` | The specific bucket (`overall` for the `overall` row). |
| `n_t1` | Cohort 1 denominator, within that stratum. |
| `n_treated`, `n_untreated` | Censored counts. |
| `pct_untreated` | % of `n_t1` (blanked if either count above is censored). |

### `treatment_pattern_regimen.csv`
Regimen distribution by line of therapy, among Cohort 1 members who
initiated treatment (episodes anchored to each subject's own index — see
Known gaps).

| Column | Meaning |
|---|---|
| `stratum_type`, `stratum_value` | As `treatment_pattern_untreated.csv`. |
| `lot_number` | 1, 2, 3, ... (chronological ARTEMIS episode rank, no cap). |
| `regName` | Regimen name (`episode_source_value`). |
| `n_patients` | Subjects on that regimen at that LoT, within that stratum (censored). |
| `lot_n` | Total subjects reaching that LoT within that stratum (denominator). |
| `pct_of_lot` | % of `lot_n` (blanked when `n_patients` censored). |

### `treatment_pattern_category.csv`
Same as above, but grouped by classification-lens category instead of raw
regimen name — one block per lens.

| Column | Meaning |
|---|---|
| `stratum_type`, `stratum_value` | As `treatment_pattern_untreated.csv`. |
| `lens` | `eau`, `hemonc_mbc`, or `any` (`cohorts/extras/regimen_reference.csv`'s three independent lenses — see Known gaps re: cohorts 4/5/6). |
| `lot_number`, `category` (a–f), `n_patients`, `lot_n`, `pct_of_lot` | As `treatment_pattern_regimen.csv`. |

### `treatment_pathways.csv`
Sankey-**ready** LoT1→LoT2→LoT3 flow data (`class_eau` category per line) —
data only, not itself a rendered plot.

| Column | Meaning |
|---|---|
| `stratum_type`, `stratum_value` | As `treatment_pattern_untreated.csv`. |
| `lot1`, `lot2`, `lot3` | `class_eau` category at that line (`NA` if the subject didn't reach it). |
| `n_patients` | Subjects following that exact pathway, within that stratum (censored). |

### `treatment_pattern_by_year.csv`
Regimen-category share by calendar year, **per treated cohort** (not pooled
like the tables above) — the protocol's ask to track "the shift in treatment
patterns... with the introduction of enfortumab" over time. Includes
`"mBC initiated base"` itself (the whole unsplit treated population — the
only slice here that can show a real regimen *mix*, since every single-arm
T4/T5/T6 cohort is 100% one category by construction and T3a-e are further
restricted to eligible-and-adherent), plus T3a-e and T4-6a-f individually.
Stratified one dimension at a time (overall / age_group / sex), plus the
age × sex crossed view, same marginal convention as the outcome files, via
`sql/subject_strata.sql` (the same per-subject lookup `R/09_outcomes.R`
uses) — not crossed with `treatment_year`, which is always its own axis
regardless of `stratum_type`.
`treatment_share_by_year_plot()` (`R/12_treatment_patterns.R`) renders any
one cohort/LoT/lens/stratum slice of this as a stacked bar chart (ggplot2) —
callable interactively, not run automatically for every combination.

| Column | Meaning |
|---|---|
| `stratum_type` | `overall`, `age_group`, `sex`, or `age_sex`. |
| `lens` | `eau`, `hemonc_mbc`, or `any`. |
| `cohort_definition_id`, `cohort_name` | The specific treated cohort. |
| `lot_number` | Line of therapy (no cap). |
| `treatment_year` | Calendar year of that line's `episode_start_date`. |
| `age_group`, `sex`, `age_sex` | Present only on the matching `stratum_type`'s rows (`NA` otherwise). |
| `category` | Lens category (a–f). |
| `n_patients` | Subjects on that category, in that cohort × lot × year × stratum level (censored). |
| `year_lot_n` | Denominator — total subjects in that cohort × lot × year × stratum level. |
| `pct_of_year_lot` | % of `year_lot_n` (blanked when `n_patients` censored). |

---

## Known limitations

- **Universal eligibility criteria are only partially enforced.** Prior
  observation (≥365 days), the 6-month follow-up buffer before each
  database's latest date, and a 2010-01-01 study-period floor are not
  currently applied. Treat absolute cohort sizes and cross-site comparisons
  with that in mind.
- **No formal data-quality assessment** (Achilles / DQD / CohortDiagnostics)
  runs as part of this pipeline; `03_main_cohorts.R`'s Circe inclusion-rule
  stats stand in as a lighter-weight attrition report.
- **TFI and second-line TTD are implemented; third-line-and-beyond outcomes
  are out of scope**, matching the protocol's stated first/second-line
  focus. TTNT/TTD/TFI/DTI events are anchored to the relevant cohort's own
  index before ranking, and are death-aware.
- **Guideline adherence buckets are computed as non-overlapping residuals**,
  since cohorts 4/5/6 are independent regimen-classification lenses rather
  than mutually exclusive tiers (see below) — a patient can appear in more
  than one.
- **Generalizability vs. trial populations (SMD) is not implemented** —
  `cohorts/extras/trial_reference.yaml` has no reference data yet.
- **Charlson CCI covers 16 of 19 components** (Fortin/Reps/Ryan SNOMED
  coding algorithm, *BMC Med Inform Decis Mak* 22:225 (2022), correction
  23:110 (2023)). `leukemia`/`lymphoma` aren't separable under this coding
  scheme, so CCI is slightly understated for hematologic malignancies.
- **NYHA, PD-L1, and comorbidity-grade criteria are not evaluated**
  (assume-pass).
- **Condition-based criteria use "present" concept sets** as a proxy for
  significant/grade≥2 disease.
- **Combination anticoagulation is defined as `(INR OR PT) AND aPTT`**;
  confirm aPTT exists in your CDM (absent at HUS).
- **Composite lab panels** (Cr, TBil, AST, ALT, INR/PT) appear only as
  atomic components, not combined rows.
- **Gilbert's syndrome (test 29) is not encoded**, so the TBil ≤3× ULN
  branch is left ungated (over-permissive; excludes no one).
- **Eligibility window is ±14/7 days around the Cohort 1 index** for lab
  criteria — an intentional PI decision, not the protocol's literal 90-day
  window. Non-lab condition criteria inherit the same window by
  construction.
- **The treatment-initiated cohort's regimen-start window is
  `[index − 30, index + 90]`**, an author-chosen window rather than a
  literal transcription of the protocol text.
- **Cohorts 4/5/6(a–f) are three independent, non-exclusive regimen
  classifications** (`class_eau` / `class_hemonc_mbc` / `class_any`), not
  the protocol's exclusive tiers.

See `DEVELOPMENT.md` (gitignored, local) for the full reasoning behind each
of these and other in-progress notes.

The `sql/` templates and `R/` steps carry inline documentation of the cohort
logic, test-id allocation, and generation order; start from `run.R` and the
per-step headers.
