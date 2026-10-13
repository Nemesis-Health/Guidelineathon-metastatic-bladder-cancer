# FALCON-Bladder Study

Diagnostics + full study pipeline (eligibility through outcomes, guideline
adherence, and treatment patterns) for the **FALCON-Bladder/Guidelinathon** study.

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
2. **Study** (`results/eligibility/`) — the main cohort-creation pipeline:
   ARTEMIS regimen alignment, eligibility / lab test normalization,
   cohort creation, characterization (demographics, comorbidities, baseline
   body measurements, Charlson CCI), outcomes (survival + time-to-event), guideline
   adherence, and treatment patterns.
   See [What it does — the pipeline stages](#what-it-does--the-pipeline-stages).

At the end of a run, each step's outputs are packaged into their own zip —
`diagnostics.zip` and `study_results.zip` respectively.

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
> - **`run_study_only.R`** — just the study pipeline
>   (steps a–m: ARTEMIS alignment through lab coverage by comorbidity
>   subgroup). Use this once ARTEMIS is sorted, whether or not you've
>   already run diagnostics separately.
>   Writes `results/eligibility/` + `study_results.zip`.
>
> Each has its own CONFIG block (same fields as `run.R`) — edit and
> `source()` the one you need.

`run.R` holds the **CONFIG block** (the only thing to edit — `connectionDetails`,
schemas, table names, run settings; it builds the `executionSettings` object the
ARTEMIS code reads), then sources the numbered steps in order and writes
CSVs under `results/eligibility/`.

### CONFIG settings reference

The comments in `run.R`/`run_study_only.R` are deliberately terse — full detail on the
less-obvious run settings lives here instead.

| Setting | Default | What it does |
|---|---|---|
| `labWindowBeforeDays`, `labWindowAfterDays` | `30`, `30` | Days before/after index a record may fall for near-index eligibility inputs: labs, ECOG/PS in Target 2a-2d, the covariate PS overlap (step (h)), eligibility-input coverage (step (e)), lab value distributions (step (d)). |
| `treatedLabWindowBeforeDays`, `treatedLabWindowAfterDays` | `30`, `0` | The same window for cohorts indexed on treatment start (the initiated bases, T3-T6) in eligibility-input coverage and lab value distributions: 30 days before up to and including the start date, so results taken after treatment began don't count. Condition flags use it too for these cohorts. |
| `labValueSelection` | `"closest"` | How labs and ECOG decide eligibility in Target 2a-2d and T1-CE. `"closest"`: per lab, the one result closest to index within the lab window decides every test of that lab (ties: before index wins; on the same day the worst value counts). `"any"`: a test passes if any passing result falls in the window. |
| `conditionFlagWindowBeforeDays`, `conditionFlagWindowAfterDays` | `30`, `30` | Window for the CONDITION flags in Target 2a-2d and eligibility-input coverage (step (e)): liver metastasis, Gilbert's syndrome, neuropathy, skin disorders, hearing loss. A flag counts when its cohort era overlaps the window, and these cohorts stay live to the end of observation, so any earlier record counts; how long a condition lasts is set by its cohort's end strategy, not here. |
| `maintenanceMerge`, `maintenanceMaxGapDays` | `TRUE`, `180` | Fold maintenance therapy into the line of therapy it maintains before lines are numbered (outcomes and treatment patterns), e.g. avelumab after platinum-based chemotherapy is part of line 1, not line 2. A maintenance episode must start within `maintenanceMaxGapDays` of the earlier regimen's end. The rules are `maintenanceRules` in `R/eventBuilders.R`. `FALSE` numbers every ARTEMIS episode as its own line. |
| `bodyMeasurementsWindowDays` | `90` | Index window for baseline weight/height/BMI (step (k)) — wider than the lab window, matching onco-study-modules' own convention for body measurements. |
| `stripEndocrineTherapy` | `TRUE` | Excludes endocrine-therapy regimens (tamoxifen, abiraterone, GnRH agonists, ...) from the ARTEMIS reference, via `is_endocrine` in `cohorts/extras/regimen_reference.csv`. `FALSE` counts endocrine therapy as anticancer treatment. |
| `validDrugsRegimenComponents` | `TRUE` | Controls which drugs ARTEMIS encodes into each patient's alignment string — non-regimen/supportive drugs are gap noise that lowers alignment scores and shrinks eras (DEVELOPMENT.md §10.4). `TRUE` keeps only drugs that appear in a kept regimen (keeps `validDrugs` and the regimen file consistent — every kept regimen's components stay encodable); `FALSE` keeps all. Composes with `validDrugsAtcClasses` below (both apply when both active); regimens whose components get filtered out can no longer align and are dropped from the reference (logged). |
| `validDrugsAtcClasses` | `c("L01","L02","L03","L04")` | ATC 2nd-level classes to keep in the alignment string. `character(0)` (off) also keeps steroids/rescue agents — the classes further drop those for a cleaner string, but ALSO false-drop anticancer drugs whose special-formulation/fixed-dose-combo RxNorm concept isn't ATC-mapped in the vocab (nab-paclitaxel, liposomal doxorubicin, ADCs, ...) and their regimens — opt-in for that reason. |
| `assessmentAtcClasses` | `NULL` | ATC 2nd-level classes kept in the ARTEMIS exposure assessment (`drug_exposures`/`uncaptured`/`coverage` in step (f)) — a diagnostic escape hatch, separate from the alignment-string filter above. `NULL` mirrors the regimen anticancer filter (`L01`/`L03`/`L04`, plus `L02` when `stripEndocrineTherapy` is `FALSE`). Set an explicit vector to override, or `character(0)` to keep every recognized ingredient (useful for one-off debugging of confusing coverage numbers — shows the *unfiltered* exposure counts, supportive drugs included). |
| `strataColumns` | `c("age_group","sex","age_sex","age_band","index_period","index_period_2021")` | Which `subject_strata.sql` breakdowns (see "Stratification") get reported, on top of `"overall"`, across every stratified output (`lab_value_distribution`, `lab_timing_to_index`, `eligibility_input_coverage`, `cohort_counts`, `demographics`, `outcomes`, `guideline_relevance`/`adherence`, `baseline_body_measurements`, `treatment_pattern_*`). Read by `activeStrataTypes()`/`activeStrataSpecs()` (`R/helpers.R`) — no per-step code needed to change it. A partner whose subgroups censor too heavily to be useful can narrow this (e.g. `c("sex")`), or set `character(0)` to turn stratification off everywhere and only get `"overall"` rows. |

### Requirements

**R 4.5.1** (the version the lockfile pins) and the seventeen direct R packages below (`requiredPackages` in `R/packages.R`, which every run script loads at startup). Everything else in `renv.lock` is a transitive dependency of these.

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
| `DBI` | 1.2.3 | CRAN |
| `jsonlite` | 2.0.0 | CRAN |
| `ggplot2` | 4.0.1 | CRAN |
| `scales` | 1.4.0 | CRAN |
| `survival` | 3.8-3 | CRAN (ships with R as a recommended package) |
| `broom` | 1.0.7 | CRAN |

Everything except ARTEMIS comes from CRAN.

`survival` and `broom` are used by the outcomes step's Kaplan-Meier engine
(`R/09_outcomes.R`, via `R/timeToEvent.R`). The run stops if either is
missing rather than producing outcomes without the KM, median-survival and
milestone files.

You also need a driver for your database: a **JDBC driver** if you connect with
`createConnectionDetails()` (download once with
`DatabaseConnector::downloadJdbcDrivers("<dbms>", "~/.jdbc_drivers")`), or the
relevant **ODBC/DBI driver** if you use `createDbiConnectionDetails()`. Which one
is up to you — `connectionDetails` is defined by you in `run.R` (see step 2 in
[Quick start](#quick-start)). Any `DatabaseConnector` `connectionDetails` works;
the SQL dialect is read from the live connection, so nothing else depends on
how it's built. A few examples:

```r
# JDBC (SQL Server) -- NB: this driver has no "host/db" path-style syntax;
# server = "host/db" gets sent verbatim as jdbc:sqlserver://host/db, which it
# treats as ONE hostname to resolve (fails with a "TCP/IP connection... has
# failed" error that looks like a network/instance problem but isn't). Use
# extraSettings = "databaseName=..." instead.
connectionDetails <- DatabaseConnector::createConnectionDetails(
  dbms = "sql server", server = "host", user = "...", password = "...",
  extraSettings = "databaseName=db", pathToDriver = path.expand("~/.jdbc_drivers"))

# DBI / Azure AD token
connectionDetails <- DatabaseConnector::createDbiConnectionDetails(
  dbms = "sql server", drv = odbc::odbc(),
  Driver = "ODBC Driver 18 for SQL Server",
  Server = "...", Database = "...", Encrypt = "yes",
  TrustServerCertificate = "No",
  attributes = list("azure_token" = token$credentials$access_token))

# Snowflake, RSA key-pair auth (e.g. IQVIA Posit Workbench)
connectionDetails <- DatabaseConnector::createConnectionDetails(
  dbms = "snowflake",
  user = Sys.getenv("SNOWFLAKE_USER"),          # e.g. "u12345678"
  connectionString = paste0(
    "jdbc:snowflake://<account>.snowflakecomputing.com/",
    "?warehouse=<WAREHOUSE>&db=<DATABASE>&schema=<CDM_SCHEMA>",
    "&role=<ROLE>",
    "&private_key_file=", Sys.getenv("PRIV_KEY_FILE")))
```

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
> `pandas 3.x` silently breaks regimen alignment. This includes `pandas 3.1`,
> not just `3.0` — pinning to `2.x` specifically, not just "not 3.0", matters.**
> With `pandas 3.x` installed in the reticulate venv ARTEMIS builds (usually
> `<Rlib>/ARTEMIS/.r-reticulate`),
> `ARTEMIS::generateRawAlignments()`/`runArtemis()` fails with `Error in if
> (nrow(output) == 0) { : argument is of length zero` — **after** "Generating raw
> alignments" reports 100% complete, so it looks like an alignment/data problem,
> not an environment one. It is not: the Cython alignment engine's return value
> fails to convert to a proper R data.frame under pandas 3.x. Fix:
> ```bash
> <path-to-ARTEMIS-venv>/bin/python3 -m pip install "pandas==2.2.3"
> ```
> Check the installed version with `<venv>/bin/python3 -m pip list | grep -i
> pandas`. If a future ARTEMIS release is confirmed pandas-3-compatible, this
> note (and the pin) can be dropped.

> [!TIP]
> **Optional: bulk load for faster writes on some backends.**
> This pipeline writes a couple of reference tables while it runs. On some
> database backends, `DatabaseConnector` can write them considerably faster
> using its own built-in bulk-load mechanism instead of its default path. It
> is off by default; to turn it on, change the CONFIG block line in `run.R`,
> `run_study_only.R` and `run_cohort_diagnostics.R` to
> `Sys.setenv(DATABASE_CONNECTOR_BULK_UPLOAD = TRUE)`. `insertTable()` reads
> this variable, so CohortGenerator's and CohortDiagnostics' own writes
> follow it too.
>
> `DatabaseConnector` applies it only to the backends its bulk-load path
> supports (Redshift, PostgreSQL, PDW, Hive, Spark) and ignores it everywhere
> else. On a supported backend, though, it needs its prerequisite in place, or
> the first table write fails. Depending on your backend, that is one of:
> - **a local database client tool** installed on this machine — on
>   PostgreSQL, `psql`, with its folder set before running as
>   `Sys.setenv(POSTGRES_PATH = "/path/to/folder/containing/psql")`, or
> - **object-storage credentials**, set before running:
>   ```r
>   Sys.setenv(
>     AWS_ACCESS_KEY_ID     = "...",
>     AWS_SECRET_ACCESS_KEY = "...",
>     AWS_DEFAULT_REGION    = "...",   # region of the staging bucket
>     AWS_BUCKET_NAME       = "...",   # bucket to stage data in before loading
>     AWS_OBJECT_KEY        = "...",   # key prefix within that bucket
>     AWS_SSE_TYPE          = "AES256"
>   )
>   ```
> Neither available to you? Leave it `FALSE` — the pipeline runs
> correctly either way, just slower on those couple of writes.
>
> **On Redshift this matters most:** without bulk load each of those writes
> can take several minutes, so the run scripts warn at startup when it is off.
> Redshift's bulk load stages data through S3, so it needs the
> object-storage credentials above (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
> `AWS_DEFAULT_REGION`, `AWS_BUCKET_NAME`). On PostgreSQL the default writes
> are already fast, so there is no warning when it is off. On either
> backend, if it is `TRUE` but its prerequisite is missing, the run stops
> at startup rather than partway through.

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
seventeen packages — no dev/report extras); renv does not resolve unrecorded
dependencies, which is why it lists ~110 packages rather than seventeen.

**Option 2 — just make sure they're installed.** You don't strictly need renv or
the exact pinned versions — the study only needs each package at **≥ the version
in the table above**. If you already run OHDSI studies you likely have most of
these; update anything older, and install ARTEMIS from GitHub:

```r
install.packages(c("DatabaseConnector", "CirceR", "CohortGenerator",
                   "SqlRender", "dplyr", "tibble", "readr",
                   "cli", "rlang", "stringr", "jsonlite", "ggplot2",
                   "scales", "survival", "broom", "remotes"))
remotes::install_github("OHDSI/Artemis@242b5a24864b85a44c62d95a98cbaa2d16c55539")
```

To see what you already have first:

```r
for (p in c("DatabaseConnector", "CirceR", "CohortGenerator", "SqlRender",
            "dplyr", "tibble", "readr", "cli", "rlang", "stringr", "ARTEMIS",
            "jsonlite", "ggplot2", "scales", "survival", "broom"))
  cat(sprintf("%-18s %s\n", p,
      tryCatch(as.character(packageVersion(p)), error = function(e) "MISSING")))
```

Every run script loads all seventeen before doing anything else and stops,
listing each one, if any is missing or fails to load. (ARTEMIS is the exception to "newer is fine": use the commit
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
| **(d)** lab test ranges on (c) | `R/04_lab_ranges.R` | `lab_value_distribution.csv`, `lab_timing_to_index.csv`, `lab_results_summary.csv`, `lab_unit_resolution.csv`, `lab_results_rollup.csv` |
| — eligibility-input counts + coverage | `R/05_eligibility_coverage.R` | `lab_cohort_counts.csv`, `eligibility_input_coverage.csv`, `eligibility_test_kappa.csv`, `eligibility_lab_coverage_kappa.csv` |
| — ARTEMIS alignment assessment | `R/06_artemis_assessment.R` | `artemis_summary.csv`, `artemis_coverage.csv`, `artemis_drug_exposures.csv`, `artemis_regimens_aligned.csv`, `artemis_episodes_per_patient.csv`, `artemis_uncaptured_drugs.csv` |
| — per-cohort demographics | `R/07_demographics.R` | `demographics.csv`, `demographics_age_continuous.csv` |
| — covariate overlap with the main tree | `R/08_covariates.R` | `covariate_overlap.csv`, `bc_covariate_cohort` |
| — outcomes: DTI / OS / TTNT / TTD / TTD-LoT2 / TFI | `R/09_outcomes.R` | `outcomes/outcome_*_summary.csv`, `_histogram.csv`, `_km.csv`, `_median_survival.csv`, `_milestones.csv` |
| — guideline relevance + adherence roll-up | `R/10_adherence.R` | `guideline/guideline_relevance.csv`, `guideline_adherence.csv` |
| — baseline body measurements + Charlson CCI | `R/11_baseline_characterization.R` | `characterization/baseline_body_measurements.csv`, `charlson_cci.csv` |
| — treatment patterns by line of therapy | `R/12_treatment_patterns.R` | `treatment_patterns/treatment_pattern_untreated.csv`, `_regimen.csv`, `_category.csv`, `treatment_pathways.csv`, `treatment_pattern_by_year.csv`, `treatment_pattern_maintenance.csv` |
| — lab coverage by comorbidity subgroup | `R/13_covariate_lab_coverage.R` | `labs/covariate_lab_coverage.csv` |
| — record provenance of bladder cancer / other-malignancy codes | `R/14_provenance.R` | `characterization/bladder_cancer_provenance.csv`, `other_malignancy_provenance.csv` |
| — condition, drug and other-cancer roll-ups | `R/15_rollups.R` | `characterization/condition_rollup.csv`, `drug_rollup.csv`, `other_cancer_rollup.csv` |

**Approach A** — every eligibility input lives in one table (`bc_lab_cohort`):
first the labs (`sql/lab_cohorts.sql`), then the ECOG + condition cohorts, whose
membership is *inserted* into the same table under reserved test-id slots. So
`sql/eligibility_2*.sql` reads a single table uniformly. Every slot is declared
once, in `cohorts/extras/eligibility_test_ids.csv` (id, key, kind, source
cohort, label); the SQL refers to a slot by its key as `@t_<key>`
(e.g. `@t_gfr_ge30`), filled in by `testIdParams()` (`R/helpers.R`).

---

## What it does — the diagnostics stage

Runs a fixed battery of pre-study characterization queries against the CDM,
anchored on the bladder-cancer diagnosis cohort (`sql/prestudy/chunks/00_setup.sql`,
section A — aligned with the main study's `[GDE] Bladder Cancer` concept set from
`cohorts/01_Target/Target_1A.json`). All queries live in `sql/prestudy/`
(`00_setup.sql` builds shared temp tables; `chunks/01`–`42` each export one CSV).
This is a high-level orientation only — for the exact query logic and output
schemas, see [onco-pre-study at `fb30995`](https://github.com/Nemesis-Health/onco-pre-study/tree/fb30995fa0c776e4681e92a9e640812a9e4e88df),
the source this was mirrored from.

| Group | Chunk(s) | Covers |
|---|---|---|
| Attrition & prevalence | `00b`, `01` | Cohort attrition (any qualifying DX → the obs-period-eligible subset), population prevalence. |
| Code counts & timing | `02`–`05`, `42` | Code-count summaries and pairwise event timing (DX / MET / L01), overall and by year; `42` is a densified-percentile twin of `04`. |
| ODX / GDX prevalence | `06`, `06b`, `33`–`35`, `41` | Directional other-cancer-dx and general-cancer-dx concept prevalence around the anchor, banded and cumulative; `41` re-anchors `35`'s split to the first Metastasis. |
| L01 (antineoplastic) treatment | `07`, `11`–`15` | Treatment-exposure windows and consecutive-record gap distributions. |
| Death timing | `08`, `13`–`14` | Death date vs. index/first-MET and vs. observation-period end. |
| Demographics | `09` | Age/sex at anchor dates. |
| Anchor code detail | `10`, `18`–`19`, `36`–`38` | Per-concept anchor-code counts, record-repeat and intercode timing; `36`–`38` add dense per-patient/gap percentile grids as companions to `18`/`19`. |
| Observation-period QC | `16`–`17`, `39` | Look-back/follow-up observability, period-definition integrity; `39` adds the percentile spread behind `17`'s past-death median. |
| MET-first subgroup | `20`–`23`, `37` | Ordering, support, and timing of first Metastasis vs. first specific diagnosis; `37` is a dense-percentile companion to this timing. |
| MET → treatment timing | `24`–`28` | Where/when the closest antineoplastic treatment falls relative to first Metastasis. |
| Drug-therapy procedures | `29`–`32`, `40` | Procedure-vs-drug-exposure signal source, timing, and co-occurrence; `40` adds the ungated, both-windows companion to `29`. |

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
- **`study_results.zip`** — every CSV under `results/eligibility/`,
  already censored at write time (subjects < `settings$minCellCount`) by
  each `R/0N_*.R` step — no additional filtering happens at packaging time.

## File map

### `R/` — driver + logic
| File | Role |
|---|---|
| `01_artemis.R` | (a) generate the ARTEMIS scan cohort, run regimen alignment, write episodes, load `regimen_reference.csv`. |
| `02_eligibility_inputs.R` | (b) run `lab_cohorts.sql`; generate ECOG + condition cohorts; insert them into `bc_lab_cohort` under test-id slots. |
| `03_main_cohorts.R` | (c) build the full manifest (Target 1A, covariates, ARTEMIS + SQL templates: initiated base, 4/5/6, 2a–2e, the attrition cohorts T1-PT/T1-NPT/T1-CE, 3a–3e) and generate it; checks the attrition cohorts nest with 2a–2d. |
| `04_lab_ranges.R` | (d) lab-value distribution + per-unit QC summary on the main cohorts. |
| `05_eligibility_coverage.R` | eligibility-table counts, each input crossed with every main cohort (tested / passed), and Target 1A agreement between lab tests (pass/fail) and between labs (tested or not). |
| `06_artemis_assessment.R` | ARTEMIS assessment: alignment stats, patient/exposure coverage, per-drug and per-regimen frequencies, uncaptured exposures — all from the in-memory `artemisResult`. |
| `07_demographics.R` | Per-cohort demographic strata (age group / sex / index year, with `pct`) + continuous age summary. |
| `08_covariates.R` | Comorbidity + performance-status overlap with every cohort in the main tree; also generates the comorbidity cohorts step (k) scores as Charlson CCI components. |
| `09_outcomes.R` | Outcomes: DTI (Target 1A), OS (every cohort), TTNT/TTD/TTD-LoT2/TFI (treatment-initiated cohorts) — KM + 1/2/3-yr milestones, stratified by age group / sex / index year. |
| `10_adherence.R` | Guideline relevance (per-cohort % of Cohort 1) + adherence roll-up (per eligibility leaf: adherent / alt-guideline / indicated-other / non-indicated / no-treatment). |
| `11_baseline_characterization.R` | Weight/height/BMI + Charlson Comorbidity Index, per cohort in the main tree. |
| `12_treatment_patterns.R` | Regimen + classification-category distribution by line of therapy, % untreated, Sankey-ready LoT1→LoT2→LoT3 pathway counts, maintenance use (lines numbered after folding maintenance into its line). |
| `13_covariate_lab_coverage.R` | (m) lab test coverage by comorbidity subgroup (Heme Disorders / Liver Disease / Renal Disease, with/without), Target 1A only. |
| `14_provenance.R` | (n) record provenance (`condition_type_concept_id`) of bladder cancer and other-malignancy condition records, in a metastatic bladder cancer population the queries build themselves. |
| `15_rollups.R` | (o) condition and drug roll-ups: conditions in disease categories and drugs in ATC 1st-level groups, on/before each cohort's index, every cohort in the main tree. |
| `helpers.R` | Cohort-generation + SQL helpers (thin wrappers over CirceR/CohortGenerator/SqlRender). |
| `artemis.R` | The ARTEMIS pipeline wrapper: `runArtemis()`, `buildEpisodeTable()`, `writeArtemisEpisodes()`. (Coverage/uncaptured analytics are computed in `06_artemis_assessment.R`.) |
| `artemis_uncaptured.R` | `uncapturedExposures()`/`plotUncapturedAlignment()` — per-ingredient, patient-level drill-down into `artemis_uncaptured_drugs.csv` (step 06) plus the ARTEMIS per-patient alignment viewer; interactive helpers, not run automatically. |
| `timeToEvent.R` | Generic time-to-event engine (ported from `onco-study-modules`): `computeTimeToEvent()` (KM via `survival`/`broom`) + `computeTimeDiffStats()` (non-censored descriptive stats). Used by step 09. |
| `survivalMilestones.R` | `extractSurvivalMilestones()` — reads KM survival probabilities at fixed day milestones (365/730/1095). Used by step 09. |
| `eventBuilders.R` | Per-outcome event tibbles for step 09/12: `fetchDeathEvents()` (OS), `treatedLines()` (lines of therapy of the base treated cohort, numbered once for steps 09 and 12), `firstLineStatus()` (DTI), `buildLineOfTherapyEvents()` (TTNT/TTD/TTD-LoT2 events from those lines), `anchorEpisodes()` (restricts episode ranking to on/after each subject's own index — see Known gaps), `combineEarliestEvent()` (death-aware TTNT/TTD/TFI). |
| `guidelineAdherence.R` | `computeGuidelineRelevance()` / `computeAdherenceRollup()` — pure set-math for step 10; see that file's header for why the set logic differs from `onco-study-modules`' original. |
| `charlsonScore.R` | `computeCharlsonScore()` / `charlsonComponents()`, ported from `onco-study-modules` (pure math, no DB dependency). Used by step 11. |
| `vendor_utils.R` | `.getDbms()` + `%||%` (helpers used by the ARTEMIS code). |
| `setup.R` | **Do not edit.** Validates the `run.R` CONFIG block and builds the derived paths + `executionSettings` object the steps read. |

### `sql/` — SqlRender templates
| File | Role |
|---|---|
| `lab_cohorts.sql` | Scores OMOP measurements → `bc_raw_lab_results` (all normalised rows) + `bc_lab_cohort` (pass rows, `cohort_definition_id = test_id`). |
| `insert_eligibility_cohorts.sql` | Copies a generated cohort's members into `bc_lab_cohort` under a test-id slot (ECOG/conditions). |
| `eligibility_2{a,b,c,d,e}.sql` | The eligibility leaves — read `bc_lab_cohort` uniformly (labs + ECOG + conditions). |
| `eligibility_previously_treated.sql`, `eligibility_not_previously_treated.sql`, `eligibility_combination.sql` | The attrition cohorts T1-PT / T1-NPT / T1-CE: Cohort 1 failing / passing the washout, and passing the washout plus the combination panel (2a's logic without the enfortumab criteria). |
| `Target_1A_initiated_template.sql` | Treatment-initiation base cohort (earliest classifiable regimen). |
| `lab_value_distribution_portable.sql` | Per cohort × lab (cat) × stratum summary of `std_value` (mean/SD/median/IQR/min/max), censored, on the result eligibility uses (`eligibility_lab_rows.sql`). Used by step (d); `lab_value_distribution.sql` is the PERCENTILE_CONT original, kept for comparison. |
| `lab_timing_to_index_portable.sql` | Per Target 1A (+ PC allowed) × lab (cat) × direction (before/after/any) × stratum, distance in days from index to the closest measurement in a subject's entire history. Used by step (d). |
| `lab_results_summary_portable.sql` | Per (cat, concept, unit) QC summary of `bc_raw_lab_results` (unit-resolution sanity check). Used by step (d); `lab_results_summary.sql` is the PERCENTILE_CONT original, kept for comparison. |
| `lab_unit_resolution.sql` | Per unit-resolution group of `bc_lab_resolved` (concept × unit × recorded reference range): the range, the recorded values' spread, the factor chosen and its scores. Used by step (d). |
| `lab_results_rollup_portable.sql` | Per-category headline of `bc_raw_lab_results`: one row per (cat, is_ambiguous) in the standard unit, with unit-resolution health as QC columns. Used by step (d); `lab_results_rollup.sql` is the PERCENTILE_CONT original, kept for comparison. |
| `lab_cohort_counts.sql` | Whole-population counts of `bc_lab_cohort` per test-id. |
| `eligibility_input_coverage.sql` | Each input × cohort × stratum (every cohort in the main tree): `n_tested` (measured) + `n_passed` (criterion met), from the rows eligibility uses (`eligibility_lab_rows.sql`). |
| `cohort_counts_stratified.sql` | Per cohort × stratum (see "Stratification") distinct-subject counts; the `overall` view comes from `CohortGenerator::getCohortCounts()` instead, reshaped in R. Used by step (c). |
| `outcome_target_data.sql` | Cohort membership + index/end dates for a given cohort-id list. Used by steps 09/10/11/12 (generic — the `@target_cohort_ids` list is whatever the caller needs). |
| `subject_strata.sql` | Per-subject age group / sex / age × sex / index year — single source of truth for this bucketing. See that file's own header for the full list of consumers. |
| `fetch_death_events.sql` | Death dates for subjects in a set of cohorts. Used by `fetchDeathEvents()` (step 09, OS outcome). |
| `demographics.sql` | Per-cohort demographic strata counts (age group / sex / index year), long/tidy. Used by step 07. |
| `demographics_continuous.sql` | Per-cohort × stratum continuous age summary, portable percentile technique + stratification same as `lab_value_distribution_portable.sql`. Used by step 07. |
| `baseline_body_measurements.sql` | Weight (kg) / height (cm) / BMI, closest measurement to each cohort's index within `settings$bodyMeasurementsWindowDays`; distribution stats computed in SQL, portable-percentile technique + stratification same as `lab_value_distribution_portable.sql`. Used by step 11. |
| `covariate_overlap.sql` | Comorbidity overlap counts, every cohort in the main tree × stratum, each anchored to that cohort's own index (unbounded look-back). Used by step (h). |
| `ps_overlap.sql` | Performance-status (ECOG) overlap counts, same scope as `covariate_overlap.sql` but a near-index window instead of a look-back. Used by step (h). |
| `charlson_components.sql` | Same look-back as `covariate_overlap.sql` but pivoted into one 0/1 flag column per Charlson component (conditional aggregation, columns built dynamically in R) plus `subject_strata.sql`'s columns, all in one row per (cohort, subject) — feeds `computeCharlsonScore()` directly, no per-subject join/pivot in R. Used by step 11. |
| `covariate_lab_coverage.sql` | Target 1A split into with/without each of three comorbidities (Heme Disorders / Liver Disease / Renal Disease, same unbounded look-back as `covariate_overlap.sql`), crossed with every lab (cat) in the eligibility lab window. Used by step (m). |
| `provenance/bladder_cancer_provenance.sql`, `provenance/other_malignancy_provenance.sql` Condition records for Target 1A's bladder cancer / excluded-primaries concept sets, counted by `condition_type_concept_id`, in a population built in the query (first metastasis record, measurement or condition, with a bladder cancer code from 180 days before to 30 days after it). Used by step (n). `provenance/translated/` holds per-dialect copies for running by hand, regenerated by `provenance/translate.R`. |
| `condition_rollup.sql`, `drug_rollup.sql` | Subjects per cohort × stratum × condition category (SNOMED parents + descendants, one category per concept by precedence) or ATC 1st-level group (every group a drug belongs to), from records on/before each cohort's index, plus each cohort × stratum's denominator. Used by step (o). `condition_rollup.sql` with `cancer = TRUE` gives `other_cancer_rollup.csv`. |

### `cohorts/` — cohort artefacts
`00_ARTEMIS/` scan cohort · `01_Target/` Target 1A + the L01 comparison cohorts
(drug-only and drug-or-procedure, each with a PC-allowed variant) ·
`02_Comorbidity/` the protocol's comorbidity covariates, reported in
`covariate_overlap.csv` (`08_covariates.R`, `comorbMap` with `show = TRUE`):
`Type_2_Diabetes`, `Hypertension`, `Cardiovascular_Disease`, `Stroke`,
`Venous_Thrombotic_Events`, `Liver_Disease`, `Renal_Disease`, `Dementia`. Five
of them also feed Charlson CCI scoring (step (k)); `Liver_Disease` and
`Renal_Disease` are also lab-coverage subgroups (step (m)). ·
`03_Charlson/` Charlson components that are not reported as comorbidities
(`show = FALSE`), sourced from Fortin/Reps/Ryan 2022/2023 (see Known gaps):
`Myocardial_Infarction` (the exception: OHDSI PhenotypeLibrary cohort 510,
acute MI only — see Known gaps), `Congestive_Heart_Failure`,
`Peripheral_Vascular_Disease`, `Chronic_Pulmonary_Disease`,
`Rheumatic_Disease`, `Peptic_Ulcer_Disease`, `Diabetes_With_Complications`,
`Hemiplegia_Paraplegia`, `AIDS_HIV` and `Liver_Disease_Severe` (moderate/severe
tier; `Liver_Disease` in `02_Comorbidity/` is the mild tier, its concept set
corrected against the same source). ·
`04_Eligibility/` eligibility inputs, generated by `02_eligibility_inputs.R`
into `bc_lab_cohort` test-id slots (step (b)): the ECOG cohorts (`ECOG_0`,
`ECOG_1`, `ECOG_2`, `ECOG_3plus`) and condition cohorts
(`Peripheral_Neuropathy`, `Significant_Skin_Disorders`,
`Audiometric_Hearing_Loss`, `Polyuria`, `Polydipsia`, `Anticoagulant_Therapy`,
`Liver_Metastasis`, `Gilberts_Syndrome`). ·
`05_Lab_coverage/` `Heme_Disorders`, used only as a subgroup in the
lab-coverage cross (step (m)).

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
`diagnostics.zip`/`study_results.zip`. Keyed by the output folder's
own name, so pointing `settings$outputFolder` at a fresh folder (e.g. for a
clean re-run) also starts from a fresh cache — nothing carries over silently.

---

## Outputs (`results/eligibility/`)

A full run writes several dozen CSVs to `results/eligibility/` (created on first
write; the folder is git-ignored), grouped into subfolders by category:
`characterization/`, `labs/`, `artemis/`, `outcomes/`, `guideline/`,
`treatment_patterns/`. These aggregate tables are the only artefacts the main
pipeline exports — no row-level data is written (the patient-level `.cache/`
checkpoints above are a separate, unshared folder). Every file is UTF-8,
comma-separated, with a header row; missing/censored cells are written as
**empty strings** (`readr::write_csv(..., na = "")`).

**Which population each table describes matters** and varies by file. Some are
*whole-population* — every person in the CDM with the relevant data, **not** the
bladder-cancer study cohort — and exist purely as unit-resolution / data-quality
checks (`lab_results_summary`, `lab_results_rollup`, `lab_cohort_counts`). Others
are restricted to a study cohort: **Target 1A** (overall mBC), the **ARTEMIS scan
cohort**, or reported **per generated cohort**. Each category's own quick-index
table below has a **Population** column that says which; read it before
comparing counts across files (e.g. a whole-population lab count is not
comparable to a Target 1A coverage count).

Each category subfolder gets its own small `README.md`, written once per run by
`writeCategoryReadmes()` (`R/helpers.R`) — not hand-duplicated text, but a
**verbatim excerpt** of that category's own section below, taken between a pair
of `<!-- category:... -->` markers. The two can't drift out of sync with each
other: the folder copy *is* this file's content at run time, so editing a
category's section here is the only thing you ever need to do. The two
conventions below apply to every file in every category, so — to keep each
per-category excerpt small — they're documented once here rather than repeated
in each one:

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

### Stratification (applies to every stratified file)

Most per-cohort outputs below are broken down by the strata below alongside
the pooled `overall` row, via one shared query, `sql/subject_strata.sql`. Age
and period are relative to that cohort's own index date. Each `stratum_type`
is one column, and each patient has one value in it.

| `stratum_type` | `stratum_value`s |
|---|---|
| `age_group` | `<=65`, `>65` (the protocol's age groups) |
| `sex` | `Male`, `Female`, `Other-Unknown` |
| `age_sex` | `age_group` × `sex`, e.g. `>65\|Female` |
| `age_band` | `<=65`, `66-80`, `>80` |
| `index_period` | `2015-2020`, `2021-2023`, `2024+` (`<2015` only for cohorts that can index earlier) |
| `index_period_2021` | `2015-2020`, `2021+` (separate from `index_period` because `2021+` overlaps two of its bands) |

Exact definitions:

- **Age** is the calendar year of the cohort's index date minus the year of
  birth, so it can be up to a year above the exact age. `>65` means 66 or older;
  `66-80` is 66 to 80 inclusive; `>80` is 81 or older.
- **Periods** use the calendar year of the index date. Each band includes its
  start year: `2015-2020` is 1 Jan 2015 to 31 Dec 2020, `2021-2023` is 2021 to
  2023, `2024+` is 2024 onwards, `2021+` is 2021 onwards. The study's requested
  cut-offs ("2015-2021, 2021-2024, 2024+, 2021+") share their boundary years;
  each boundary year goes to the later band, so 2021 is in `2021-2023` and
  `2024` is in `2024+`.
- **Each cohort uses its own index date**: the first metastasis record for
  Cohort 1 and its eligibility leaves, the treatment start for the
  treatment-initiated cohorts. The same patient can fall in different age or
  period bands in different cohorts.
- **Censoring** applies to every stratum row in the same way (see "Privacy
  censoring" above). Because strata overlap, a censored cell can sometimes be
  recovered by subtraction, e.g. `>80` = `>65` − `66-80`, or `2024+` = `2021+` −
  `2021-2023` (as `overall` minus one `age_group` already allows). Narrow
  `strataColumns` if a site needs to avoid that.

Which of these views actually get computed and written is controlled by a
single setting, **`settings$strataColumns`** in `run.R`'s CONFIG block
(default: all six). A site that wants no
stratification at all sets it to `character(0)`; a site that only wants,
say, sex breakdowns sets it to `c("sex")`. `overall` is always produced
regardless. This is the one place to change it — no per-file toggles.

---

<!-- category:characterization -->
## `characterization/`
Cohort sizes, attrition, demographics, comorbidity/performance-status overlap,
baseline body measurements, Charlson CCI, and the record provenance of the
bladder cancer / other-malignancy condition codes — everything describing *who* is in each
cohort, as opposed to labs/ARTEMIS/outcomes/treatment content. "Privacy
censoring" and "Stratification" above apply here too.

| File | Written by | Population | Grain (one row per…) |
|---|---|---|---|
| `cohort_counts.csv` | `03_main_cohorts.R` | Each cohort (the tree) | generated cohort × stratum type × stratum value |
| `attrition_target_1a.csv` | `03_main_cohorts.R` | Target 1A tree JSON cohorts | cohort × inclusion-rule sequence |
| `demographics.csv` | `07_demographics.R` | Per cohort | cohort × characteristic × stratum |
| `demographics_age_continuous.csv` | `07_demographics.R` | Per cohort | cohort × stratum type × stratum value |
| `covariate_overlap.csv` | `08_covariates.R` | Per cohort | cohort × stratum type × stratum value × covariate (comorbidity / PS) |
| `baseline_body_measurements.csv` | `11_baseline_characterization.R` | Per cohort | cohort × variable (weight_kg/height_cm/bmi) × stratum type × stratum value |
| `charlson_cci.csv` | `11_baseline_characterization.R` | Per cohort | cohort × CCI version (calculated / reported / max) × stratum type × stratum value × CCI category (0 / 1-2 / 3-4 / >=5) |
| `bladder_cancer_provenance.csv` | `14_provenance.R` | Metastasis + bladder cancer code (built in SQL, broader than Target 1A) | record type (`condition_type_concept_id`), plus an `ALL` row |
| `other_malignancy_provenance.csv` | `14_provenance.R` | Metastasis + bladder cancer code (built in SQL, broader than Target 1A) | record type (`condition_type_concept_id`), plus an `ALL` row |
| `condition_rollup.csv` | `15_rollups.R` | Each cohort (the tree) | cohort × stratum type × stratum value × condition category |
| `drug_rollup.csv` | `15_rollups.R` | Each cohort (the tree) | cohort × stratum type × stratum value × ATC 1st-level group |
| `other_cancer_rollup.csv` | `15_rollups.R` | Target 1A, mixed bag, all mBC (`Target_1mBC`) | cohort × stratum type × stratum value × cancer site |

### `cohort_counts.csv`
Row per generated cohort × stratum — the whole main tree plus covariates
(Target 1A / T1 mBC, the treatment-initiation arms 4/5/6, eligibility leaves
2a–2e, the intersections 3a–3e, and the ECOG + condition covariates), each
reported once overall and once per `subject_strata.sql` stratum (see "Stratification"). The `overall` rows are `CohortGenerator::getCohortCounts()`'s
own result reshaped into this long format, not re-derived, so they can't
drift from the trusted library count; `age_group`/`sex`/`age_sex` come from a
companion query (`cohort_counts_stratified.sql`).

| Column | Meaning |
|---|---|
| `cohort_definition_id` | Numeric id assigned in dependency order in `03_main_cohorts.R`. |
| `cohort_name` | Human-readable cohort name (e.g. `T1 Metastatic bladder cancer`). |
| `stratum_type` | `overall`, or a stratum (see "Stratification" above). |
| `stratum_value` | `overall`, or the stratum's value. |
| `n_entries` | Number of qualifying cohort episodes (entries; blanked when `n_subjects` is censored). |
| `n_subjects` | Number of distinct subjects (censored). |

### `attrition_target_1a.csv`
Standard OHDSI inclusion-rule attrition for the Target 1A tree's Circe JSON
cohorts (`cohorts/01_Target/`), read back from `CohortGenerator::getCohortStats()`
after generation (`generateStats = TRUE`). One row per cohort × inclusion
rule, in rule order, plus a `ruleSequence = -1` baseline row (the qualifying
event, before any inclusion rule is applied). `remaining` reconstructs the
classic waterfall — cumulative subjects surviving rules `0..i` together —
from Circe's per-rule bitmask result table; the last rule's `remaining`
always equals `personTotal`. `personCount`/`gainCount` are marginal, not
sequential: a rule's `personCount` is subjects satisfying that rule alone
regardless of the others, and `gainCount` is subjects who'd be gained back
if only that rule were dropped (fail this rule, pass every other one) —
rule order doesn't affect either, since Circe rules are an unordered AND.

| Column | Meaning |
|---|---|
| `cohortId`, `cohortName` | The Target 1A tree cohort (`T1 Metastatic bladder cancer` / `T1 Metastatic bladder cancer (PC allowed)`). |
| `ruleSequence` | `-1` (qualifying event, before any inclusion rule) or the rule's 0-based order. |
| `ruleName` | Inclusion rule text, or `(qualifying event, before inclusion rules)` for `-1`. |
| `personCount` | Subjects satisfying this rule alone (censored). |
| `gainCount` | Subjects who'd be gained back if only this rule were dropped (censored independently; also blanked when `personCount` is censored). |
| `personTotal` | Total subjects considered for this rule (censored). |
| `remaining` | Cumulative subjects surviving rules `0..ruleSequence` together (waterfall; censored). |

### `demographics.csv`
Per-cohort demographic strata: age group at index (`>65` / `<=65`), sex
(`Male` / `Female` / `Other-Unknown`), and index year. One row per
cohort × characteristic × stratum (long/tidy). Age is at `cohort_start_date`
(`YEAR(index) − year_of_birth`).

| Column | Meaning |
|---|---|
| `cohort_definition_id` | Cohort id (matches `cohort_counts.csv` `cohortId`). |
| `cohort_name` | Cohort name from the run manifest. |
| `characteristic` | `age_group`, `sex`, `age_band`, `index_period`, `index_period_2021`, or `index_year`. |
| `stratum` | Category within the characteristic (e.g. `>65`, `Female`, `2019`). |
| `n_subjects` | Subjects in that cohort × stratum (censored). |
| `pct` | % of that cohort's total N within `characteristic` (e.g. sex's three strata sum to ~100%), computed on the raw pre-censoring count so one censored row doesn't distort the others' denominator; blanked whenever `n_subjects` is censored. |

### `demographics_age_continuous.csv`
Companion to `demographics.csv`'s categorical `age_group`: age at index as a
continuous variable, per the protocol's "mean (SD), minimum, maximum, median
and IQR." Every cohort in the main tree, reported once overall and once per
`subject_strata.sql` stratum (see "Stratification") — same
convention as `baseline_body_measurements.csv` (`age_group`-stratified continuous age is
a bit tautological, since each bucket's mean is bounded by construction, but
kept anyway for uniformity rather than special-casing this one file).

| Column | Meaning |
|---|---|
| `cohort_definition_id`, `cohort_name` | As above. |
| `stratum_type` | `overall`, or a stratum (see "Stratification" above). |
| `stratum_value` | `overall`, or the stratum's value. |
| `n` | Subjects in that cohort, restricted to this stratum (censored). |
| `mean_age`, `sd_age` | Mean and SD of age at index (blanked when `n` censored). |
| `min_age`, `lq_age`, `median_age`, `uq_age`, `max_age` | Min, quartiles, median, max (blanked when `n` censored). |

### `covariate_overlap.csv`
Descriptive covariates **not** used by the main cohort tree, reported as an
overlap with every cohort in the main tree (same scope as
`eligibility_input_coverage.csv`/`lab_value_distribution.csv`), each anchored
to **that cohort's own index date**. Comorbidities count members with ≥1
qualifying record **on/before their own index** — an unbounded look-back
(prevalent baseline comorbidity), not a windowed one; performance-status
strata count members with an ECOG record (KPS folded in) in the stratum
within the index window (`labWindowBeforeDays` before / `labWindowAfterDays`
after) of their own index — deliberately a near-index window, not the
comorbidities' unbounded look-back: PS is a point-in-time functional
assessment, not a chronic condition flag. PS strata **overlap** by design
(`PS 0-2` includes `PS1`/`PS2`). Comorbidity cohorts are generated into
`bc_covariate_cohort` (never `bc_cohort`); to add one, drop its JSON into
`cohorts/02_Comorbidity/` (or `03_Charlson/` / `05_Lab_coverage/` for one used
only by those analyses) and list it in `R/08_covariates.R` `comorbMap`.

Every (cohort, covariate) pair is reported once overall and once per
`subject_strata.sql` stratum (see "Stratification"), with an
explicit row even where there's no overlap at all (`n_overlap = 0`, not a
silently missing combination).

| Column | Meaning |
|---|---|
| `cohort_definition_id`, `cohort_name` | As elsewhere. |
| `stratum_type` | `overall`, or a stratum (see "Stratification" above). |
| `stratum_value` | `overall`, or the stratum's value. |
| `code` | Short code: PS strata (`PS1`, `PS2`, `PS2+`, `PS 0-2`, `PS 0-1`) or comorbidity — see `08_covariates.R`'s `comorbMap` (`T2DM`, `HTN`, `CVD`, `Stroke`, `VTE`, `LiverDx`, `RenalDx`, `Dementia`): the protocol's covariate list. The other `comorbMap` cohorts (Charlson-only components, Heme Disorders for the lab-coverage cross) are generated with `show = FALSE` and not reported here. |
| `label` | Human-readable description. |
| `n_cohort` | This cohort's denominator, restricted to this row's stratum (censored). |
| `n_overlap` | Members (in this cohort × stratum) meeting the covariate (censored). % is not emitted — it is `n_overlap / n_cohort`. |

### `baseline_body_measurements.csv`
Per-cohort weight/height/BMI, closest measurement to index within
`settings$bodyMeasurementsWindowDays` (default ±90 days). Every (cohort, variable)
combination is reported once overall and once per `subject_strata.sql`
stratum (see "Stratification").

| Column | Meaning |
|---|---|
| `cohort_definition_id`, `cohort_name` | As elsewhere. |
| `variable` | `weight_kg`, `height_cm`, or `bmi`. |
| `stratum_type` | `overall`, or a stratum (see "Stratification" above). |
| `stratum_value` | `overall`, or the stratum's value. |
| `n` | Subjects with that measurement near index, restricted to this stratum (censored). |
| `mean`, `sd`, `median`, `lq`, `uq`, `min`, `max` | Distribution (blanked when `n` censored). |

### `charlson_cci.csv`
Charlson Comorbidity Index category distribution, every cohort in the main
tree x `subject_strata.sql` stratum (see "Stratification") — same
scope and convention as `covariate_overlap.csv`. Each cohort's components
are anchored to **that cohort's own index date** (`sql/charlson_components.sql`,
same unbounded on/before-index look-back as `covariate_overlap.csv`, computed
entirely in SQL via conditional aggregation, not pulled per-subject and
joined/pivoted in R), so the
same subject can carry a different score in different cohorts if they have
more comorbidities on record by a later cohort's index (e.g. a
treatment-initiation index, which falls on/after the mBC index).

15 of 19 canonical components are wired. `metastatic_solid_tumor` (weight 6)
and `any_malignancy` (weight 2) are **deliberately excluded**, unlike a
standard Charlson score: every subject in every cohort here has metastatic
bladder cancer by cohort definition, so counting it would drive every
subject into the `>=5` category regardless of anything else — degenerate,
not informative for this study population. See Known gaps for the other two
components that aren't wired, and why the score is a slight understatement
for a small subset of patients as a result.

Three versions are reported (`cci_version`): `calculated` (the score above,
every member), `reported` (a recorded Charlson Comorbidity Index, concept
42538860 in `measurement` or `observation`, closest to index within ±30 days;
only members with one, so `n` adds up to those members) and `max` (the higher
of the two per member; the calculated score where none is recorded). The
age-adjusted index is not used, as it isn't comparable
(`sql/charlson_recorded.sql`).

| Column | Meaning |
|---|---|
| `cohort_definition_id`, `cohort_name` | As elsewhere. |
| `stratum_type` | `overall`, or a stratum (see "Stratification" above). |
| `stratum_value` | `overall`, or the stratum's value. |
| `cci_version` | `calculated`, `reported` or `max`. |
| `cci_category` | `0`, `1-2`, `3-4`, or `>=5`. |
| `n` | Subjects in that cohort × stratum × category (censored). |

### `bladder_cancer_provenance.csv`, `other_malignancy_provenance.csv`
Where the bladder cancer and other-malignancy condition codes come from:
every `condition_occurrence` record a population patient has for the concept
set, counted by `condition_type_concept_id` (EHR, claims, registry, ...). All
of a patient's records count, not only those near index.
`bladder_cancer_provenance` uses the `[GDE] Bladder Cancer` concept set (the
prior-bladder-cancer rule); `other_malignancy_provenance` uses `[GDE] Excluded
primaries`, the set the "no other cancer" rule excludes on. Not stratified by
age/sex.

The population is built in the queries themselves, not read from `bc_cohort`:
each patient's first metastasis record, measurement or condition (`[GDE]
metastasis (measurement)`, the concept sets generated from `Target_1A.json`),
limited to patients with a bladder cancer code from 180 days before to 30 days
after it. Target 1A's age and other-cancer rules are **not** applied, so the
counts cover a broader group than Target 1A and aren't comparable to Target 1A
counts in other files.

| Column | Meaning |
|---|---|
| `type_concept_id` | The record's `condition_type_concept_id` (`0` where missing). Empty on the `ALL` row. |
| `type_concept_name` | Vocabulary name of that type; `ALL` for the pooled row, `Not in vocabulary` if the id has no `concept` row. |
| `n_patients` | Population patients with ≥1 such record of this type (censored). A patient can have records of several types, so type rows don't sum to `ALL`. |
| `n_records` | Records of this type (blanked when `n_patients` is censored). |

### `condition_rollup.csv`, `drug_rollup.csv`
The protocol's concept-based baseline comorbidities ("condition groups" and
"drug era groups"): how many members of each cohort in the main tree had a
condition in each disease category, or a drug in each ATC group, **on or
before their own index** (no lower bound, as `covariate_overlap.csv`). Every
(cohort, category) is reported once overall and once per stratum (see
"Stratification"); a category with no members has no row.

- **Conditions** (`condition_occurrence`) are rolled up into disease
  categories, each the descendants of a few SNOMED parent concepts (listed in
  `sql/condition_rollup.sql`), similar to ICD-10 chapters. A concept under
  several parents goes to the first category in that list, so categories are
  exclusive per concept; a member is counted in every category any of their
  conditions falls in. `Bladder cancer` is taken out first. **Other
  neoplasms are not reported:** the vocabulary maps metastases recorded as
  conditions to the primary-site malignancy (e.g. a liver metastasis to
  *Malignant neoplasm of liver*), so a neoplasm category can't tell another
  primary cancer from this cohort's own metastases. Neoplasm codes are still
  assigned to that hidden category, so they don't fall into the organ
  categories. Other primary cancers are for the separate other-cancer
  roll-up. `Other condition` is a concept outside every category; unmapped
  records (concept 0) aren't counted.
- **Drugs** come from `drug_era`, as the protocol specifies (`source_table`
  says `drug_exposure` where a site's `drug_era` is empty and the step fell
  back to drug exposure start dates). Each drug counts in **every** ATC
  1st-level group it belongs to (e.g. aspirin in both B and N), so groups
  overlap and don't add up to the cohort. `No ATC group` is a drug with no
  ATC classification.

| Column | Meaning |
|---|---|
| `cohort_definition_id`, `cohort_name` | As elsewhere. |
| `stratum_type` | `overall`, or a stratum (see "Stratification" above). |
| `stratum_value` | `overall`, or the stratum's value. |
| `atc_code` | (`drug_rollup.csv` only) ATC 1st-level code (`A`–`V`); empty for `No ATC group`. |
| `category` | Condition category, or ATC group name. |
| `n_cohort` | This cohort's denominator, restricted to this row's stratum (censored). |
| `n_subjects` | Members (in this cohort × stratum) with ≥1 record in the category (censored). |
| `source_table` | (`drug_rollup.csv` only) `drug_era`, or `drug_exposure` if the site's `drug_era` was empty. |

### `other_cancer_rollup.csv`
Other cancers in the Target 1A cohort rule's window, for Target 1A, the mixed
bag and `Target_1mBC` (Target 1A plus the mixed bag): members with a code in
the cohorts' own *Excluded primaries* concept set within `[index − 180d,
index + 30d]`, by cancer site. Built by `sql/condition_rollup.sql` with
`cancer = TRUE`: sites are SNOMED parents following the ICD-10 C-blocks
(e.g. Lung ≈ C34, Prostate ≈ C61; listed in the SQL), one site per concept by
precedence, `Other cancer` for the rest. Target 1A has none by construction,
so its rows are a check. Read lung, liver, bone and brain with care: where a
site records a metastasis as a cancer of that organ, it lands here.

Columns as `condition_rollup.csv`, plus:

| Column | Meaning |
|---|---|
| `n_subjects_2plus` | Members with ≥2 records in the site in the window (censored), i.e. not resting on a single code. |
| `n_records` | Records in the site in the window (blanked when `n_subjects` is censored). |
<!-- /category:characterization -->

---

<!-- category:labs -->
## `labs/`
Lab test coverage, value distributions, and timing-to-index for the study
cohorts, plus unit-resolution QC on the raw normalised measurement table
(whole-population, not the study cohort — see each row's Population below).
"Privacy censoring" and "Stratification" above apply here too.

| File | Written by | Population | Grain (one row per…) |
|---|---|---|---|
| `lab_cohort_counts.csv` | `05_eligibility_coverage.R` | **Whole population** | eligibility test-id |
| `eligibility_input_coverage.csv` | `05_eligibility_coverage.R` | Per main cohort | cohort × stratum type × stratum value × eligibility test-id |
| `eligibility_test_kappa.csv` | `05_eligibility_coverage.R` | Target 1A | stratum type × stratum value × pair of lab tests |
| `eligibility_lab_coverage_kappa.csv` | `05_eligibility_coverage.R` | Target 1A | stratum type × stratum value × pair of labs (ECOG as one) |
| `lab_value_distribution.csv` | `04_lab_ranges.R` | Per main cohort | cohort × lab (cat) × stratum type × stratum value |
| `lab_timing_to_index.csv` | `04_lab_ranges.R` | Target 1A + Target 1A PC allowed | cohort × lab (cat) × direction (before/after/any) |
| `lab_results_summary.csv` | `04_lab_ranges.R` | **Whole population** | cat × measurement concept × unit × factor × status × ambiguity |
| `lab_unit_resolution.csv` | `04_lab_ranges.R` | **Whole population** | cat × measurement concept × unit × recorded reference range |
| `lab_results_rollup.csv` | `04_lab_ranges.R` | **Whole population** | cat × ambiguity (standard unit; QC columns) |
| `covariate_lab_coverage.csv` | `13_covariate_lab_coverage.R` | Target 1A only | comorbidity subgroup (with/without) × lab (cat) |

### `lab_cohort_counts.csv`
Row per eligibility **test-id slot** in the unified `bc_lab_cohort` table, over
the **whole population** (not restricted to Target 1A). Ids 1–23 / 44–49 are
labs; 24–27 ECOG; 28–40 conditions (all declared in `cohorts/extras/eligibility_test_ids.csv`).

| Column | Meaning |
|---|---|
| `test_id` | Eligibility test-id (`cohort_definition_id` in `bc_lab_cohort`). |
| `label` | Human label for the test-id (e.g. `ALT<=2.5xULN`, `ECOG 1`, `Liver metastasis`). |
| `n_subjects` | Distinct subjects meeting that criterion / in that cohort (censored). |
| `n_records` | Underlying row count (blanked when `n_subjects` is censored). |

### `eligibility_input_coverage.csv`
Row per eligibility test-id **crossed with every cohort in the main tree**
(same scope as `lab_value_distribution.csv` — not just Target 1A), once
overall and once per `subject_strata.sql` stratum (see "Stratification") — how many members of that cohort had each input measured vs.
passed it, within the window (`lab_window`) around *that cohort's own* index
date: `labWindowBeforeDays` / `labWindowAfterDays` (default 30 / 30) for
cohorts indexed on metastasis, `treatedLabWindowBeforeDays` /
`treatedLabWindowAfterDays` (default 30 / 0) for those indexed on treatment
start. Both counts read the rows eligibility uses (`eligibility_lab_rows.sql`),
so under `labValueSelection = "closest"` a lab passes on the closest result,
as in Target 2a-2d. Treatment-indexed cohorts are the ones `cohortIndex`
(`R/03_main_cohorts.R`) marks `"treatment"`. That includes T3a-e: their rows
show whether members still met each criterion before treatment start, so
they can fail a criterion they passed at the metastasis index, which is what
put them in T2 and so in T3. ECOG/condition slots have no `n_tested` (blank — they are not lab
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
| `stratum_type` | `overall`, or a stratum (see "Stratification" above). |
| `stratum_value` | `overall`, or the stratum's value. |
| `lab_window` | Days around this cohort's index the inputs were read from, e.g. `-30..30` or `-30..0`. |
| `test_id` | Eligibility test-id. |
| `label` | Human label for the test-id. |
| `n_cohort` | This cohort's denominator, restricted to this row's stratum (censored). |
| `n_tested` | Members (in this cohort × stratum) with a scorable result in the window (labs only; censored). |
| `n_passed` | Members (in this cohort × stratum) who met the criterion / have the cohort (censored). |

### `eligibility_test_kappa.csv`
Agreement between every pair of lab tests in Target 1A, overall and per
stratum. Each member's pass/fail per test is the one eligibility uses (the
closest result, `eligibility_lab_rows.sql`); for each pair, among members with
a result for both, the 2×2 counts, % agreement and Cohen's kappa. ECOG and
condition inputs are not included. `same_lab` marks pairs on the same lab
(e.g. Hb ≥ 9 and Hb < 9), which agree or disagree by construction; on these
pairs `n_pass_both` must be 0 for mutually exclusive bands, which checks that
each patient is scored on one result per lab.

| Column | Meaning |
|---|---|
| `test_id_1`, `label_1`, `test_id_2`, `label_2` | The two tests (eligibility test ids). |
| `same_lab` | Both tests are on the same lab. |
| `n_both` | Members with a result for both tests (censored). |
| `n_pass_both`, `n_pass_1_only`, `n_pass_2_only`, `n_fail_both` | The 2×2 counts (censored). |
| `pct_agree`, `kappa` | % agreement and Cohen's kappa (blanked when `n_both` or any of the four cells is censored, since either would let the censored cell be worked out). |

### `eligibility_lab_coverage_kappa.csv`
Agreement on *whether* labs were tested, between every pair of labs in
Target 1A, overall and per stratum: among all members, was each lab tested
in the lab window (a scorable result, as counted in
`eligibility_input_coverage.csv`'s `n_tested`). Testing is per lab, so all
tests on one lab (e.g. the GFR bands) count once. ECOG counts as one item
(any grade recorded in the window) and is always listed, so a site without
ECOG records shows it as never tested.

| Column | Meaning |
|---|---|
| `lab_1`, `lab_2` | The two labs (`cat`, or `ECOG`). |
| `n_cohort` | Target 1A members in this stratum (censored). |
| `n_tested_both`, `n_tested_1_only`, `n_tested_2_only`, `n_tested_neither` | The 2×2 counts (censored). |
| `pct_agree`, `kappa` | % agreement and Cohen's kappa (blanked when `n_cohort` or any of the four cells is censored). |

### `lab_value_distribution.csv`
Row per **cohort × lab (cat) × stratum** — the distribution of the
normalised lab value (`std_value`) among each main cohort's subjects, using
the one result eligibility uses: the closest to index within the window
(`lab_window`, as in `eligibility_input_coverage.csv`), with the same
tie-breaks (`eligibility_lab_rows.sql`). One row per lab per stratum. Every (cohort, cat) combination is reported once
overall and once per `subject_strata.sql` stratum (see "Stratification").

| Column | Meaning |
|---|---|
| `stratum_type` | `overall`, or a stratum (see "Stratification" above). |
| `stratum_value` | `overall`, or the stratum's value. |
| `cohort_definition_id` | Cohort id (matches `cohort_counts.csv` `cohort_definition_id`). |
| `lab_window` | Days around this cohort's index the value was read from, e.g. `-30..30` or `-30..0`. |
| `cat` | Lab category / analyte code. |
| `n_with_lab` | Subjects with a value near index (censored). |
| `mean_value`, `sd_value` | Mean and standard deviation of `std_value` (blanked when censored). |
| `median_value`, `lq_value`, `uq_value` | Median, lower (25th) and upper (75th) quartile (blanked when censored). |
| `min_value`, `max_value` | Range (blanked when censored). |

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
once per `subject_strata.sql` stratum (see "Stratification") —
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
| `stratum_type` | `overall`, or a stratum (see "Stratification" above). |
| `stratum_value` | `overall`, or the stratum's value (e.g. `'<=65\|Male'` for `age_sex`). |
| `cohort_definition_id` | Cohort id (`T1 Metastatic bladder cancer` or `T1 Metastatic bladder cancer (PC allowed)`). |
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
Row per (cat × measurement concept × unit × factor × status × ambiguity). Every
unit for a given lab should land in the same `std_value` range.

| Column | Meaning |
|---|---|
| `cat` | Lab category / analyte code. |
| `measurement_concept_id` | OMOP measurement concept id. |
| `measurement_concept_name` | Concept name (from vocabulary; blank if unresolved). |
| `unit_concept_id` | OMOP unit concept id. |
| `unit_concept_name` | Unit name (from vocabulary; blank if unresolved). |
| `factor` | Conversion factor applied to the recorded value (`std_value = value_as_number × factor`, plus an offset for HbA1c). |
| `status` | How the (concept, unit) scale was chosen: `verified` (recorded unit), `concept` (unit stated by the concept name), `overridden` (best-scoring scale), `unverified` (recorded unit, no evidence to check it), `unresolved` (none; not converted). |
| `is_ambiguous` | Flag: unit resolution was ambiguous. |
| `n_patients` | Distinct patients (censored). |
| `n_measurements` | Measurement count (blanked when censored). |
| `mean_value`, `sd_value` | Mean and SD of `std_value` (blanked when censored). |
| `min_value`, `lq_value`, `median_value`, `uq_value`, `max_value` | Min, quartiles, median, max of `std_value` (blanked when censored). |

### `lab_unit_resolution.csv`
Why each lab group got its conversion factor. Unit resolution
(`lab_cohorts.sql` step 3) works per group of (concept × unit × recorded
reference range), so a concept and unit with several reference ranges has
several rows. **Whole population**, including groups that could not be
resolved (`status = unresolved`, not converted), which `lab_results_summary.csv`
omits. Every score can be recomputed from the range and percentiles.

| Column | Meaning |
|---|---|
| `cat` | Lab category / analyte code. |
| `measurement_concept_id`, `measurement_concept_name` | OMOP measurement concept. |
| `unit_concept_id`, `unit_concept_name` | Recorded unit (0 = none). |
| `range_low`, `range_high` | Reference range recorded in the measurement table (blank if not recorded or not > 0). |
| `n_patients` | Distinct patients (censored). |
| `n_records` | Measurement count (blanked when censored). |
| `p03_value`, `p25_value`, `p75_value`, `p97_value` | Percentiles of the recorded value, before conversion (blanked when censored). |
| `factor`, `val_offset` | Conversion applied (blank if unresolved). |
| `status` | As in `lab_results_summary.csv`. |
| `is_ambiguous` | Flag: more than one scale passed the 0.7-decade check. |
| `recorded_unit_score` | Score of the recorded unit's scale, in decades from the normal range (blank if the unit is unknown or could not be scored; blanked when censored). |
| `concept_unit_score` | Best score among the scales the concept name allows (blank for concepts that state no unit; blanked when censored). |
| `best_score` | Best score over all scales (blanked when censored). |

A score uses the recorded range when the category's normal has the matching
bound(s), otherwise the value percentiles (groups over 20 records only). The
range, factor and status are not censored: they describe the lab's reference
range and the resolver's choice, not patient values.

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
| `pct_overridden` | Share of measurements whose recorded unit was set aside by the resolver (`overridden` or `concept`; blanked when censored). |
| `pct_unverified` | Share whose unit could not be verified but was trusted as recorded (blanked when censored). |
| `mean_value`, `sd_value` | Mean and SD of `std_value` (blanked when censored). |
| `min_value`, `lq_value`, `median_value`, `uq_value`, `max_value` | Min, quartiles, median, max of `std_value` (blanked when censored). |

### `covariate_lab_coverage.csv`
Row per **comorbidity subgroup (with/without) × lab (cat)**, **Target 1A
only** (not the full main tree). Target 1A members are split into with/without
each of three comorbidities -- Heme Disorders, Liver Disease, Renal Disease --
using the same unbounded on/before-index lookback as `covariate_overlap.csv`
("ever before index": a qualifying record any time on or before the subject's
own Target 1A index date). Each subgroup side is then crossed with every lab
(cat), counting members with >=1 measurement in the eligibility lab window
(`labWindowBeforeDays` before / `labWindowAfterDays` after index, default
30/30) -- same window `lab_value_distribution.csv` uses. Every (subgroup,
test) combination gets an explicit row, zero-filled where a subgroup has no
coverage at all for that test.

| Column | Meaning |
|---|---|
| `cohort_definition_id` | Target 1A's cohort id. |
| `subgroup` | `heme_disorder`/`no_heme_disorder`, `liver_disorder`/`no_liver_disorder`, or `renal_disorder`/`no_renal_disorder`. |
| `subgroup_count` | Target 1A members on that side of that subgroup (denominator; not censored). |
| `test` | Lab category / analyte code. |
| `n_with_test` | Subgroup members with a measurement in the lab window (censored). |
<!-- /category:labs -->

---

<!-- category:artemis -->
## `artemis/`
ARTEMIS regimen-alignment diagnostics — the funnel from raw drug exposures to
aligned regimen episodes, and how well alignment covers the underlying
exposures. Written only if ARTEMIS step (a)/(f) ran this session. "Privacy
censoring" above applies here too (not age/sex stratification — these use a
different cohort-strata convention, described next).

| File | Written by | Population | Grain (one row per…) |
|---|---|---|---|
| `artemis_summary.csv` | `06_artemis_assessment.R` | Scan cohort + Target 1A | cohort × ARTEMIS pipeline stage |
| `artemis_coverage.csv` | `06_artemis_assessment.R` | Scan cohort + Target 1A | cohort × coverage level (patient / exposure) |
| `artemis_drug_exposures.csv` | `06_artemis_assessment.R` | Scan cohort + Target 1A | cohort × anticancer ingredient |
| `artemis_regimens_aligned.csv` | `06_artemis_assessment.R` | Scan cohort + Target 1A | cohort × aligned regimen |
| `artemis_episodes_per_patient.csv` | `06_artemis_assessment.R` | Scan cohort + Target 1A | cohort × episode-count value |
| `artemis_uncaptured_drugs.csv` | `06_artemis_assessment.R` | Scan cohort + Target 1A | cohort × anticancer ingredient (uncaptured) |

**Cohort strata (all six files above).** Each carries a leading `cohort`
column and is emitted once per stratum, stacked: `scan_cohort` = the full ARTEMIS
scan cohort; `target_1a` = restricted to the "T1 Metastatic bladder cancer"
cohort (`cohort1Id`, step 05's Target-1A denominator) over each patient's whole
recorded history; `target_1a_post_met` = the same subset restricted to the
**study period of interest** — only exposures/episodes dated on or after the
patient's metastasis date (Target 1A indexes on the first metastasis
measurement, so `cohort_start_date` *is* that date; day 0 counts as
post-metastasis). Every metric below is computed within the stratum. Counts are
censored per stratum, so a small `target_1a` cell can be masked while its
`scan_cohort` counterpart is not.

The date floor applies to exposures, episodes, and raw alignments (the latter
are re-dated from their stored day offset before flooring). The **capture
test is not date-floored**: a post-metastasis exposure is checked against all
of that patient's episodes, including one that started before metastasis —
otherwise a dose just after metastasis, covered by a regimen that began just
before it, would wrongly show as uncaptured. This keeps the `exposure` coverage
row and `artemis_uncaptured_drugs.csv` exact complements in every stratum. One
consequence: the `target_1a_post_met` regimen list contains regimens *started*
on or after metastasis, so a regimen that began before metastasis and ran into
the window is absent from it.

### `artemis_summary.csv`
Row per cohort × ARTEMIS pipeline stage — the funnel from scan cohort to aligned
episodes. Written only if the ARTEMIS step (a) ran this session.

| Column | Meaning |
|---|---|
| `cohort` | Stratum: `scan_cohort`, `target_1a`, or `target_1a_post_met` (see note above). |
| `metric` | Stage name: `ARTEMIS scan cohort (subjects)` → `Ingredient-level drug exposures` → `Valid anticancer drug exposures` → `Raw alignments (pre-processing)` → `Regimen episodes aligned`. For the Target-1A strata the first stage counts 1A subjects present in the scan cohort. |
| `n_patients` | Distinct patients at that stage (censored; scan-cohort record count is N/A). |
| `n_records` | Records at that stage (blanked when the patient count is censored). |

### `artemis_coverage.csv`
Four rows per stratum — two cohort-level coverage rates plus the existing
patient- and exposure-level alignment coverage. An exposure is "captured" if
its start date falls inside any aligned episode window for the same patient
(start-date containment; no exposure end date is available).

| Column | Meaning |
|---|---|
| `level` | `cohort_subject`, `scanned_subject`, `patient`, or `exposure`. |
| `n_covered` | Covered patients / exposures (censored). |
| `n_total` | Total valid patients / exposures (censored). % is not emitted — it is `n_covered / n_total`. |

`cohort_subject` and `scanned_subject` both count subjects with ≥1 aligned
regimen episode; they differ only in denominator. `cohort_subject` divides by
**every** subject of the stratum's defining cohort, scanned by ARTEMIS or not —
on `target_1a` this is "% of the metastatic subset with at least one regimen at
all"; on `target_1a_post_met`, "% with one *started* after metastasis".
`scanned_subject` divides by only the subjects ARTEMIS actually scanned. The
two coincide when the defining cohort is a subset of the ARTEMIS scan cohort.
`patient`/`exposure` are unchanged from before: share of patients with a valid
anticancer exposure, and share of valid exposures that are captured.

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
<!-- /category:artemis -->

---

<!-- category:outcomes -->
## `outcomes/`
DTI / OS / TTNT / TTD / TTD-LoT2 / TFI — descriptive stats, histograms,
Kaplan-Meier curves, median survival, and 1/2/3-year milestones. "Privacy
censoring" and "Stratification" above apply here too.

| File | Written by | Population | Grain (one row per…) |
|---|---|---|---|
| `outcome_dti_summary.csv` | `09_outcomes.R` | Target 1A | definition (treated / unbound) × stratum type × stratum value |
| `outcome_dti_buckets.csv` | `09_outcomes.R` | Target 1A (every member) | stratum type × stratum value × bucket |
| `outcome_dti_by_category_summary.csv` / `_buckets.csv` | `09_outcomes.R` | Target 1A, started | (definition ×) lens × first-line treatment category × stratum type × stratum value (× bucket) |
| `outcome_{os,ttnt,ttd,ttd_lot2,tfi}_summary.csv` / `_histogram.csv` | `09_outcomes.R` | os: every cohort (T1/T2a-e/T3a-e/T4-6a-f); ttnt/ttd/ttd_lot2/tfi: treatment-initiated cohorts only (T3a-e/T4-6a-f) | cohort × stratum type × stratum value (+ time bin for histogram) |
| `outcome_{os,ttnt,ttd,ttd_lot2,tfi}_km.csv` | `09_outcomes.R` | same as above | cohort × stratum type × stratum value × KM step |
| `outcome_{os,ttnt,ttd,ttd_lot2,tfi}_median_survival.csv` | `09_outcomes.R` | same as above | cohort × stratum type × stratum value |
| `outcome_{os,ttnt,ttd,ttd_lot2,tfi}_milestones.csv` | `09_outcomes.R` | same as above | cohort × stratum type × stratum value × milestone (365/730/1095d) |

**Outcome files (all files in this category, step 09).** DTI runs on Target 1A
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
(`anchorEpisodes()`, `R/eventBuilders.R`) — see Known gaps for why. DTI and
the treatment-pattern outputs use the base treated cohort's own rules
(`treatedLines()`, `R/eventBuilders.R`; `sql/Target_1A_initiated_template.sql`):
treated means a member of "mBC initiated base", whose first line is a
classified regimen starting from 30 days before to 90 days after the Target 1A
index, with no regimen in the year before; that regimen is line 1. DTI (time from
the Target 1A index to the first line) is descriptive, no Kaplan-Meier, and
reported two ways: the summary for two definitions, each with its own `count`
— `treated` (base cohort, −30 to 90 days) and `unbound` (from −30 days on,
adding patients whose first classified regimen started after day 90; the
washout still applies) — and buckets covering every Target 1A member,
including those who did not start and why. Negative times are kept as they
are (a median or percentile floored at 0 is the raw one floored at 0). TTNT, TTD,
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
| `definition` | DTI only: `treated` (−30 to 90 days, the base cohort) or `unbound` (−30 days on). |
| `mean_time`, `mean_time_min0` | DTI only: mean time, raw and with negative times counted as 0 (blanked when `count` is censored). |
| `n_before`, `pct_before` | DTI only: subjects whose first line started before index, and their share of `count` (censored; `pct_before` blanked when `n_before` is). |

### `outcome_dti_buckets.csv`
Every Target 1A member in one bucket, by when their first classified regimen
started relative to the index: `-30 to -1`, `0-30`, `31-60`, `61-90` (these
four are the base treated cohort), `91-180`, `181-360`, `>360` (started after
the cohort's window), or not started: `prior treatment` (a regimen in the year
before index — the washout), `other treatment only` (episodes, none
qualifying), `none recorded`. Columns: `bucket`, `n`, `n_total` (Target 1A in
that stratum), `pct` (of `n_total`); counts censored, `pct` blanked when
either is.

### `outcome_dti_by_category_summary.csv` / `_buckets.csv`
The DTI summary and the started buckets split by the first regimen's
treatment category under each classification lens: `lens` (`eau`,
`hemonc_mbc`, `any` — the T4/T5/T6 lenses) and `category` (`ev_pembro`,
`cisplatin`, `carboplatin`, `pdl1_mono`, `other_recommended`, `other`).
In the buckets file `n_total` is the started patients in that lens ×
category.

### `outcome_{os,ttnt,ttd,ttd_lot2,tfi}_histogram.csv`
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
<!-- /category:outcomes -->

---

<!-- category:guideline -->
## `guideline/`
Guideline relevance (per-cohort share of Cohort 1) and adherence roll-up
(per eligibility leaf, partitioned into adherent / alt-guideline /
indicated-other / non-indicated / no-treatment). "Privacy censoring" and
"Stratification" above apply here too.

| File | Written by | Population | Grain (one row per…) |
|---|---|---|---|
| `guideline_relevance.csv` | `10_adherence.R` | T1/T2a-e/T3a-e/T4-6a-f | stratum type × stratum value × cohort |
| `guideline_adherence.csv` | `10_adherence.R` | Eligible (T2) subjects per leaf | stratum type × stratum value × leaf × category (adherent/alt-guideline/indicated-other/non-indicated/no-treatment) |

### `guideline_relevance.csv`
Per-cohort population size as a fraction of Cohort 1 — the protocol's
"relevance" statistic. Reported once overall and once per
`subject_strata.sql` stratum (see "Stratification"); membership is
filtered to the stratum before computing, so `pct_of_base` is that
stratum's share of Cohort 1's own same-stratum members, not of all of
Cohort 1.

| Column | Meaning |
|---|---|
| `cohort_definition_id`, `cohort_name` | As elsewhere. |
| `stratum_type` | `overall`, or a stratum (see "Stratification" above). |
| `stratum_value` | `overall`, or the stratum's value. |
| `n` | Subjects in that cohort, restricted to this stratum (censored). |
| `pct_of_base` | % of Cohort 1's same-stratum members (blanked when `n` censored). |

### `guideline_adherence.csv`
Per eligibility leaf (a–e), the eligible population partitioned into five
disjoint categories via explicit set-differences (`computeAdherenceRollup()`,
`R/guidelineAdherence.R` — see that file's header for why this repo can't use
`onco-study-modules`' original set logic as-is). Reported once overall and
once per `subject_strata.sql` stratum (see "Stratification") —
`eligible_n` is that stratum's eligible population, not the leaf's whole
eligible count.

| Column | Meaning |
|---|---|
| `stratum_type` | `overall`, or a stratum (see "Stratification" above). |
| `stratum_value` | `overall`, or the stratum's value. |
| `leaf` | `a`–`e`. |
| `category` | `adherent` (received the recommended regimen), `alt_guideline` (a different EAU-recommended regimen), `indicated_other` (a HemOnc mBC-indicated regimen), `non_indicated` (any other regimen), or `no_treatment`. |
| `n` | Subjects in that leaf × category × stratum (censored). |
| `eligible_n` | Total eligible for that leaf, restricted to this stratum (censored; the denominator — the five categories' `n` sum to this). |
| `pct_of_eligible` | % of `eligible_n` (blanked when `n` censored). |
<!-- /category:guideline -->

---

<!-- category:treatment_patterns -->
## `treatment_patterns/`
Regimen + classification-category distribution by line of therapy, %
untreated, Sankey-ready LoT pathway counts, and regimen-category share by
calendar year, and maintenance use. Lines of therapy are numbered after
maintenance is folded into the line it maintains (`maintenanceMerge`, see the
settings table), so e.g. avelumab after platinum-based chemotherapy is part of
line 1. All six files are stratified one dimension at a time
(overall / age_group / sex), plus the age × sex crossed view, via
`sql/subject_strata.sql` anchored to each subject's Cohort 1 index — same
marginal convention as the outcome files. Which stratum views are populated
is controlled centrally by `settings$strataColumns` (see "Stratification"
above) — a partner can disable stratification for these
(and every other stratified output) in one place rather than per-file.

| File | Written by | Population | Grain (one row per…) |
|---|---|---|---|
| `treatment_pattern_untreated.csv` | `12_treatment_patterns.R` | Target 1A | stratum (overall/age_group/sex/age_sex) |
| `treatment_pattern_regimen.csv` | `12_treatment_patterns.R` | Treated ("mBC initiated base") | stratum × line of therapy × regimen name |
| `treatment_pattern_category.csv` | `12_treatment_patterns.R` | Treated ("mBC initiated base") | stratum × classification lens × line of therapy × category (a-f) |
| `treatment_pathways.csv` | `12_treatment_patterns.R` | Treated ("mBC initiated base") | stratum × LoT1 × LoT2 × LoT3 category combination (`class_eau`, capped at 3 lines) |
| `treatment_pattern_maintenance.csv` | `12_treatment_patterns.R` | Treated ("mBC initiated base") | stratum × line of therapy × line regimen × maintenance regimen |
| `treatment_pattern_by_year.csv` | `12_treatment_patterns.R` | Per treated cohort ("mBC initiated base", T3a-e, T4-6a-f) | cohort × lot × index year × lens category × stratum (overall/age_group/sex/age_sex) |

### `treatment_pattern_untreated.csv`
Per stratum: how many of Cohort 1 are in the base treated cohort ("mBC
initiated base"). Why the rest are not, and when late starters started, is in
`outcome_dti_buckets.csv`.

| Column | Meaning |
|---|---|
| `stratum_type` | `overall`, or a stratum (see "Stratification" above). |
| `stratum_value` | The specific bucket (`overall` for the `overall` row). |
| `n_t1` | Cohort 1 denominator, within that stratum (censored). |
| `n_treated`, `n_untreated` | Censored counts. |
| `pct_untreated` | % of `n_t1` (blanked if either count above is censored). |

### `treatment_pattern_regimen.csv`
Regimen distribution by line of therapy, among the base treated cohort's
members. Line 1 is the regimen the cohort was indexed on, so line-1 counts
by category reproduce the T4/T5/T6 arms.

| Column | Meaning |
|---|---|
| `stratum_type`, `stratum_value` | As `treatment_pattern_untreated.csv`. |
| `lot_number` | 1, 2, 3, ... (chronological ARTEMIS episode rank, no cap). |
| `regName` | Regimen name (`episode_source_value`). |
| `n_patients` | Subjects on that regimen at that LoT, within that stratum (censored). |
| `lot_n` | Total subjects reaching that LoT within that stratum (denominator; censored). |
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

### `treatment_pattern_maintenance.csv`
How often each line's regimen was followed by maintenance that was folded into
it, and which maintenance. Written only when `maintenanceMerge` is on.

| Column | Meaning |
|---|---|
| `stratum_type`, `stratum_value` | As `treatment_pattern_untreated.csv`. |
| `lot_number` | Line of therapy (after merging maintenance). |
| `regName` | The line's regimen (the induction regimen). |
| `maintenance_regimen` | The maintenance regimen folded into the line, or `none`. |
| `maintenance_rule` | The rule that matched (e.g. `switch: avelumab after platinum`), or `none`. |
| `n_patients` | Subjects with that line, regimen and maintenance, within that stratum (censored). |
| `median_gap_days` | Median days from the induction regimen's end to the maintenance start (negative if they overlap); blank for `none` or when `n_patients` is censored. |
| `median_maintenance_days` | Median days from the maintenance start to the line's end; blank for `none` or when censored. |

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
| `stratum_type` | `overall`, or a stratum (see "Stratification" above). |
| `lens` | `eau`, `hemonc_mbc`, or `any`. |
| `cohort_definition_id`, `cohort_name` | The specific treated cohort. |
| `lot_number` | Line of therapy (no cap). |
| `treatment_year` | Calendar year of that line's `episode_start_date`. |
| `age_group`, `sex`, `age_sex` | Present only on the matching `stratum_type`'s rows (`NA` otherwise). |
| `category` | Lens category (a–f). |
| `n_patients` | Subjects on that category, in that cohort × lot × year × stratum level (censored). |
| `year_lot_n` | Denominator — total subjects in that cohort × lot × year × stratum level (censored). |
| `pct_of_year_lot` | % of `year_lot_n` (blanked when `n_patients` censored). |
<!-- /category:treatment_patterns -->

---

## Known limitations

- **Universal eligibility criteria are only partially enforced.** The Target
  cohorts require 30 days of prior observation and an index on or after
  2015-01-01, but no 6-month follow-up buffer before each database's latest
  date is applied. Treat absolute cohort sizes and cross-site comparisons
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
- **Charlson CCI covers 15 of 19 components** (Fortin/Reps/Ryan SNOMED
  coding algorithm, *BMC Med Inform Decis Mak* 22:261 (2022), correction
  23:109 (2023)). `leukemia`/`lymphoma` aren't separable under this coding
  scheme, so CCI is slightly understated for hematologic malignancies.
  `metastatic_solid_tumor`/`any_malignancy` are deliberately excluded (not
  a data gap): every subject in every cohort here has metastatic bladder
  cancer by cohort definition, so counting it would put everyone in the
  `>=5` category regardless of anything else.
- **Charlson MI component counts acute MI only.** `Myocardial_Infarction.json`
  is OHDSI PhenotypeLibrary cohort 510 ("[P][R] Acute myocardial
  infarction": 312327 and descendants), not the Fortin/Reps/Ryan concept set
  used for the other components. Standard Charlson MI (Quan I21/I22/I25.2)
  also includes old/healed MI, so patients with only an old-MI record are
  missed and CCI is slightly understated for them.
- **NYHA, PD-L1, and comorbidity-grade criteria are not evaluated**
  (assume-pass).
- **Condition-based criteria use "present" concept sets** as a proxy for
  significant/grade≥2 disease.
- **Combination anticoagulation is defined as `(INR OR PT) AND aPTT`**;
  confirm aPTT exists in your CDM.
- **Composite lab panels** (Cr, TBil, AST, ALT, INR/PT) appear only as
  atomic components, not combined rows.
- **Eligibility window is ±30 days around the Cohort 1 index** for lab/ECOG
  criteria — an intentional PI decision, not the protocol's literal 90-day
  window. CONDITION criteria (liver-mets, Gilbert's syndrome, neuropathy,
  skin, hearing) also use ±30 days (`settings$conditionFlagWindowBeforeDays`/
  `conditionFlagWindowAfterDays`), but their cohorts stay live to the end of
  observation, so any record before index counts.
- **The treatment-initiated cohort's regimen-start window is
  `[index − 30, index + 90]`**, an author-chosen window rather than a
  literal transcription of the protocol text.
- **The washout stops 30 days before index.** The spec says no treatment
  "within a year prior"; the SQL looks for regimens overlapping
  `[index − 365, index − 30)`. This is intentional: treatment from 30 days
  before index counts as first-line initiation, so the washout ends where that
  window starts.
- **2c (carboplatin) also excludes 2b (cisplatin) patients.** The spec only
  excludes EV-eligible patients. The extra exclusion is intentional, so that
  2a–2e are mutually exclusive.
- **2e is a residual, not the spec's best supportive care group.** The spec's
  BSC is treatment-naive, not combination-eligible and not PD-L1-eligible. 2e
  is every Cohort 1 patient not in 2a–2d, so it also holds previously treated
  patients and combination-eligible patients who fit no arm. Whether to split
  those out into their own groups is not decided yet.
- **4e and 6e are always empty.** No regimen carries `other_recommended` in
  the EAU or the any-regimen lens, so these cohorts have no members by
  construction. They are kept so that all three lenses report the same
  categories (a–f).
- **"No other cancer" looks back 180 days, not "at any time prior".** The
  Target 1A cohorts exclude other primaries recorded from 180 days before to
  30 days after index, an intentional choice rather than the protocol's
  unbounded look-back.
- **Study start is anchored on the first-ever metastasis record.** A person
  whose first metastasis record predates 2015-01-01 is excluded rather than
  entering on a later record. The L01-initiated cohorts apply the date to
  that same metastasis record, while their 30-day prior-observation
  requirement is measured from treatment start.
- **Eligibility uses the lab/ECOG value closest to index; the coverage and
  overlap outputs still count any record in the window.** With the default
  `labValueSelection = "closest"`, Target 2a-2d and T1-CE score each lab
  (and ECOG) on the single result closest to index, so their bands are
  mutually exclusive per patient.
  `eligibility_input_coverage.sql`'s `n_passed` and `ps_overlap.sql`'s
  PS-strata counts still treat any row in the window as a pass, so a subject
  with two draws can fall in mutually exclusive bands at once (e.g. GFR >60
  and GFR <30; ECOG 0 and ECOG 2). The excess grows with how often a
  subject is drawn, so bands can sum to well over 100% of `n_tested`.
  Ever-in-window remains the right reading for toxicity/safety.
  The closest-value rule still needs PI sign-off.
- **Lab unit resolution can still pick the wrong scale for Hb and GFR.**
  `lab_cohorts.sql` step 3 keeps a recorded unit that scores under 0.7
  decades; failing that it uses the unit the concept name states
  (`@concept_unit_table`: GFR "/1.73 sq M" means ×1, Hb [Mass/volume] or
  [Moles/volume]), then the best-scoring scale, with equal scores going to
  the factor closest to 1. Open gaps: a recorded unit that contradicts the
  concept still wins (e.g. GFR recorded as mL/min/m² on a "/1.73 sq M"
  concept gets ×1.73); a reference range recorded in a different unit from
  its values decides the scale, because the range is scored before the
  values; GFR's one-sided normal (≥ 90) favours ×1.73 for concepts that
  state no unit; and `std_value` has no plausibility bound beyond
  `value_as_number > 0`, so sentinel values survive into `bc_lab_cohort`.
  Check `lab_results_summary.csv` (`status`, per concept and unit) before
  using Hb or GFR strata.
- **Cohorts 4/5/6(a–f) are three independent, non-exclusive regimen
  classifications** (`class_eau` / `class_hemonc_mbc` / `class_any`), not
  the protocol's exclusive tiers.

See `DEVELOPMENT.md` (gitignored, local) for the full reasoning behind each
of these and other in-progress notes.

The `sql/` templates and `R/` steps carry inline documentation of the cohort
logic, test-id allocation, and generation order; start from `run.R` and the
per-step headers.
