# FACLON-Bladder Diagnostics and Feasibility 

Eligibility stage for the **Metastatic bladder cancer guidelines** study.

---

## Study layout

A full run has two main steps, in order:

1. **Diagnostics** (`results/diagnostics/`) — pre-study characterization
   queries against the OMOP CDM. This functionality is ported from the external
   [`onco-pre-study`](https://github.com/Nemesis-Health/onco-pre-study/tree/fb30995fa0c776e4681e92a9e640812a9e4e88df)
   repo (pinned at commit `fb30995`): its query assets and SQL Server templates
   are mirrored into this repository (`sql/prestudy/`, `results/prestudy_queries/`)
   so the study can run standalone, without a separate checkout of that project.
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

> [!IMPORTANT]
> **ARTEMIS must be the version this study was built against.** It is a
> GitHub-only package (not on CRAN); use **`OHDSI/Artemis` at v1.6.0** (commit
> `242b5a24864b85a44c62d95a98cbaa2d16c55539`), the version pinned in `renv.lock`.
> ARTEMIS also needs **Python ≥ 3.12** on the machine — the ARTEMIS README has
> good guidance for resolving the Python dependency:
> <https://github.com/OHDSI/Artemis#installation>.

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
            "dplyr", "tibble", "readr", "cli", "rlang", "stringr", "ARTEMIS"))
  cat(sprintf("%-18s %s\n", p,
      tryCatch(as.character(packageVersion(p)), error = function(e) "MISSING")))
```

`run.R` checks all eleven are present and stops with a clear message if any is
missing. (ARTEMIS is the exception to "newer is fine": use the commit above,
which is the tested one — see the ARTEMIS note.)

Either way, install a database driver (above) and set up Python ≥ 3.12 for
ARTEMIS.

---

## What it does — the pipeline stages

| Stage | Script | Produces |
|---|---|---|
| **(a)** ARTEMIS regimen alignment | `R/01_artemis.R` | `bc_artemis_episodes`, `bc_regimen_classifications` |
| **(b)** eligibility labs **+** cohorts → one table | `R/02_eligibility_inputs.R` | `bc_lab_cohort` (labs **+** ECOG **+** conditions), `bc_raw_lab_results` |
| **(c)** main cohort tree | `R/03_main_cohorts.R` | `bc_cohort`, `results/eligibility/cohort_counts.csv` |
| **(d)** lab test ranges on (c) | `R/04_lab_ranges.R` | `lab_value_distribution.csv`, `lab_results_summary.csv`, `lab_results_rollup.csv` |
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

- **`diagnostics.zip`** — CSVs staged into `results/diagnostics/` from an
  external onco-pre-study checkout's output folder, if one is configured
  (`settings$preStudyProjectRoot`, unset by default); mirrored as-is,
  unfiltered.
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
| `helpers.R` | Cohort-generation + SQL helpers (thin wrappers over CirceR/CohortGenerator/SqlRender). |
| `artemis.R` | The ARTEMIS pipeline wrapper: `runArtemis()`, `buildEpisodeTable()`, `writeArtemisEpisodes()`. (Coverage/uncaptured analytics are computed in `06_artemis_assessment.R`.) |
| `vendor_utils.R` | `.getDbms()` + `%||%` (helpers used by the ARTEMIS code). |
| `setup.R` | **Do not edit.** Validates the `run.R` CONFIG block and builds the derived paths + `executionSettings` object the steps read. |

### `sql/` — SqlRender templates
| File | Role |
|---|---|
| `lab_cohorts.sql` | Scores OMOP measurements → `bc_raw_lab_results` (all normalised rows) + `bc_lab_cohort` (pass rows, `cohort_definition_id = test_id`, 1–23/44–48). |
| `insert_eligibility_cohorts.sql` | Copies a generated cohort's members into `bc_lab_cohort` under a test-id slot (ECOG/conditions). |
| `eligibility_2{a,b,c,d,e}.sql` | The eligibility leaves — read `bc_lab_cohort` uniformly (labs + ECOG + conditions). |
| `Target_1A_initiated_template.sql` | Treatment-initiation base cohort (earliest classifiable regimen). |
| `lab_value_distribution_portable.sql` | Per cohort × lab (cat) summary of `std_value` (mean/SD/median/IQR), censored. Used by step (d); `lab_value_distribution.sql` is the PERCENTILE_CONT original, kept for comparison. |
| `lab_results_summary_portable.sql` | Per (cat, concept, unit) QC summary of `bc_raw_lab_results` (unit-resolution sanity check). Used by step (d); `lab_results_summary.sql` is the PERCENTILE_CONT original, kept for comparison. |
| `lab_results_rollup_portable.sql` | Per-category headline of `bc_raw_lab_results`: one row per (cat, is_ambiguous) in the standard unit, with unit-resolution health as QC columns. Used by step (d); `lab_results_rollup.sql` is the PERCENTILE_CONT original, kept for comparison. |
| `lab_cohort_counts.sql` | Whole-population counts of `bc_lab_cohort` per test-id. |
| `eligibility_input_coverage.sql` | Each input × Target 1A: `n_tested` (measured) + `n_passed` (criterion met). |
| `n_target1a.sql` | Target 1A denominator. |

### `cohorts/` — cohort artefacts
`00_ARTEMIS/` scan cohort · `01_Target/` Target 1A + the L01 comparison cohort · `02_Covariate/`
the ECOG cohorts (`ECOG_0`, `ECOG_1`, `ECOG_2`, `ECOG_3plus`) and condition cohorts
(`Peripheral_Neuropathy`, `Significant_Skin_Disorders`, `Audiometric_Hearing_Loss`,
`Polyuria`, `Polydipsia`, `Anticoagulant_Therapy`, `Liver_Metastasis`,
`Gilberts_Syndrome`) · `extras/` `regimen_reference.csv`, `trial_reference.yaml`.

Only the eligibility-input covariates are kept here; the pure comorbidity /
characterisation covariates (e.g. hypertension, diabetes, smoking, metastasis
sites) were removed — characterisation is a downstream stage this project does
not run.

### `results/` — outputs (`diagnostics/`, `eligibility/`, git-ignored)

---

## Outputs (`results/eligibility/`)

A full run writes **fourteen CSVs** to `results/eligibility/` (created on first
write; the folder is git-ignored). These aggregate tables are the only
artefacts the main pipeline exports — no row-level data is written. Every file
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
| `cohort_counts.csv` | `03_main_cohorts.R` | Each cohort (the tree) | generated cohort |
| `lab_cohort_counts.csv` | `05_eligibility_coverage.R` | **Whole population** | eligibility test-id |
| `eligibility_input_coverage.csv` | `05_eligibility_coverage.R` | Target 1A | eligibility test-id × Target 1A |
| `lab_value_distribution.csv` | `04_lab_ranges.R` | Per main cohort | cohort × lab (cat) |
| `lab_results_summary.csv` | `04_lab_ranges.R` | **Whole population** | cat × measurement concept × unit × status × ambiguity |
| `lab_results_rollup.csv` | `04_lab_ranges.R` | **Whole population** | cat × ambiguity (standard unit; QC columns) |
| `artemis_summary.csv` | `06_artemis_assessment.R` | Scan cohort + Target 1A | cohort × ARTEMIS pipeline stage |
| `artemis_coverage.csv` | `06_artemis_assessment.R` | Scan cohort + Target 1A | cohort × coverage level (patient / exposure) |
| `artemis_drug_exposures.csv` | `06_artemis_assessment.R` | Scan cohort + Target 1A | cohort × anticancer ingredient |
| `artemis_regimens_aligned.csv` | `06_artemis_assessment.R` | Scan cohort + Target 1A | cohort × aligned regimen |
| `artemis_episodes_per_patient.csv` | `06_artemis_assessment.R` | Scan cohort + Target 1A | cohort × episode-count value |
| `artemis_uncaptured_drugs.csv` | `06_artemis_assessment.R` | Scan cohort + Target 1A | cohort × anticancer ingredient (uncaptured) |
| `demographics.csv` | `07_demographics.R` | Per cohort | cohort × characteristic × stratum |
| `covariate_overlap.csv` | `08_covariates.R` | Target 1A | covariate (comorbidity / PS stratum) × cohort 1A |

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

---

### `cohort_counts.csv`
Row per generated cohort — the whole main tree plus covariates (Target 1A / T1
mBC, the treatment-initiation arms 4/5/6, eligibility leaves 2a–2e, the
intersections 3a–3e, and the ECOG + condition covariates).

| Column | Meaning |
|---|---|
| `cohortId` | Numeric id assigned in dependency order in `03_main_cohorts.R`. |
| `cohortName` | Human-readable cohort name (e.g. `T1 Metastatic bladder cancer`). |
| `cohortEntries` | Number of qualifying cohort episodes (entries). |
| `cohortSubjects` | Number of distinct subjects (censored). |

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
Row per eligibility test-id **crossed with Target 1A** — how many mBC patients
had each input measured vs. passed it, within the index window
(`labWindowBeforeDays` before / `labWindowAfterDays` after, default 14 / 7)
of the Target 1A index date. ECOG/condition slots have no `n_tested` (blank —
they are not lab measurements).

| Column | Meaning |
|---|---|
| `test_id` | Eligibility test-id. |
| `label` | Human label for the test-id. |
| `n_target1a` | Target 1A denominator (same value on every row). |
| `n_tested` | Target 1A members who had the measurement at all (labs only; censored). |
| `n_passed` | Target 1A members who met the criterion / have the cohort (censored). |

### `lab_value_distribution.csv`
Row per **cohort × lab (cat)** — the distribution of the normalised lab
value (`std_value`) among each main cohort's subjects, using the one
measurement closest to index within the index window (`labWindowBeforeDays`
before / `labWindowAfterDays` after). One row per lab:
`std_value` does not depend on the eligibility threshold, so the raw table's
per-criterion (`test_id`) fan-out is collapsed to distinct measurements first.

| Column | Meaning |
|---|---|
| `cohort_definition_id` | Cohort id (matches `cohort_counts.csv` `cohortId`). |
| `cat` | Lab category / analyte code. |
| `n_with_lab` | Subjects with a value near index (censored). |
| `mean_value`, `sd_value` | Mean and standard deviation of `std_value` (blanked when censored). |
| `median_value`, `lq_value`, `uq_value` | Median, lower (25th) and upper (75th) quartile (blanked when censored). |

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
| `n_subjects` | Subjects in that cohort × stratum (censored). % is not emitted — derive it against the cohort N (`cohort_counts.csv`, or sum the strata). |

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
| `code` | Short code: PS strata (`PS1`, `PS2`, `PS2+`, `PS 0-2`, `PS 0-1`) or comorbidity (`T2DM`, `HTN`, `CVD`, `Stroke`, `VTE`, `LiverDx`, `RenalDx`, `Dementia`). |
| `label` | Human-readable description. |
| `n_1a` | Subjects in cohort 1A (the denominator). |
| `n_overlap` | 1A subjects meeting the covariate (censored). % is not emitted — it is `n_overlap / n_1a`. |

---

## Known gaps / assumptions

- **NYHA, PD-L1, comorbidity-grade** are *ignored* for now (assume-pass / `1 = 1`);
  templates kept in `eligibility_2*.sql` with notes. 2d passes without a real
  PD-L1 check.
- **Conditions are exclusions** — the "present" concept sets act as the
  "significant / grade ≥2" proxy (`NOT EXISTS`).
- **Combo coag limb is `(INR OR PT) AND aPTT`** (per the guideline logic; INR is
  the normalised form of PT, so either satisfies the extrinsic limb). aPTT is
  still separately required — confirm it exists in your CDM (absent at HUS), else
  2a–2c stay ~0.
- **Composite panels** (Cr, TBil, AST, ALT, INR/PT) appear in the coverage only
  as their atomic components, not as combined rows.
- **Gilbert's (test 29)** not encoded → the `TBil ≤3× ULN` branch is currently
  ungated (slightly *over*-permissive). Left deliberately — it excludes no-one.
- *Wired since:* liver-mets (28), anticoagulant exception (31), and the carbo
  neuropathy≥2/hearing≥2 inclusions.

The `sql/` templates and `R/` steps carry inline documentation of the cohort
logic, test-id allocation, and generation order; start from `run.R` and the
per-step headers.
