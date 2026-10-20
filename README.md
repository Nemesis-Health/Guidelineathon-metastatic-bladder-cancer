   # FALCON-Bladder Study

## Quick start

1. Open `bladder-eligibility.Rproj` (or set the repo as the working directory).
2. Edit the **CONFIG block at the top of `run.R`**: `connectionDetails`, the
   bulk-load switch, `databaseId`, the schemas, `minCellCount` and
   `outputFolder`. The work table names there (`bc_cohort`, ...) need
   changing only if they clash with tables already in the work schema.
3. `source("run.R")`.

`runParts` in the CONFIG block picks what runs. The default runs the study
only. Add `"diagnostics"` if the study team asks for the pre-study queries;
`c("diagnostics")` alone needs no ARTEMIS, CohortGenerator or CirceR.

**Optional:** `run_cohort_diagnostics.R` runs OHDSI CohortDiagnostics on the
`cohorts/01_Target/` cohorts (own CONFIG block, own cohort table). It needs
`CohortDiagnostics` installed, which is not in `renv.lock`.

### Study settings

Fixed study settings live in `R/study_settings.R` and are the same at every
site. Don't change them unless the study team asks; if it does, add the field
to the `settings` list in `run.R` (a field set there wins).

| Setting | Default | What it does |
|---|---|---|
| `labWindowBeforeDays`, `labWindowAfterDays` | `30`, `30` | Window around the metastasis index for labs and ECOG in eligibility (2a-2d, T1-CE), coverage, lab distributions, the PS overlap and the lab-coverage cross. |
| `treatedLabWindowBeforeDays`, `treatedLabWindowAfterDays` | `30`, `0` | The same for cohorts indexed on treatment start, so results after treatment began don't count. |
| `labValueSelection` | `"closest"` | `"closest"`: per lab, the one result closest to index decides every test of that lab (ties: before index wins; same day, the worst value). `"any"`: a test passes if any result in the window passes. |
| `conditionFlagWindowBeforeDays`, `conditionFlagWindowAfterDays` | `30`, `30` | Window for the condition flags (liver metastasis, Gilbert's, neuropathy, skin disorders, hearing loss). A flag counts when its cohort era overlaps the window; these cohorts last to the end of observation, so any earlier record counts. |
| `maintenanceMerge`, `maintenanceMaxGapDays` | `TRUE`, `180` | Fold maintenance (e.g. avelumab after platinum) into the line it maintains before lines are numbered. Rules: `maintenanceRules` in `R/treatment_lines.R`. |
| `bodyMeasurementsWindowDays` | `90` | ± days around index for weight/height/BMI. |
| `stripEndocrineTherapy` | `TRUE` | Drop endocrine regimens (`is_endocrine` in `regimen_reference.csv`) from the ARTEMIS reference. |
| `validDrugsRegimenComponents` | `TRUE` | Encode only drugs that appear in a kept regimen in the ARTEMIS alignment string; supportive drugs otherwise add gaps and lower alignment scores. |
| `validDrugsAtcClasses` | `c("L01","L02","L03","L04")` | ATC classes kept in the alignment string. Also drops anticancer drugs whose formulation isn't ATC-mapped (nab-paclitaxel, ADCs, ...); `character(0)` turns it off. |
| `assessmentAtcClasses` | `NULL` | ATC classes counted in the ARTEMIS assessment. `NULL`: L01/L03/L04, plus L02 when `stripEndocrineTherapy` is `FALSE`; `character(0)`: every ingredient (for debugging). |
| `strataColumns` | all six | Which strata are reported on top of `overall` (see [Censoring and strata](#censoring-and-strata)). `character(0)` reports `overall` only. |

---

## Requirements

R ≥ 4.4.0 (tested on 4.5.1) and these packages (`requiredPackages` in `R/packages.R`; the run
stops at startup listing any that are missing or fail to load). Any version at
or above these works, except ARTEMIS:

`ARTEMIS` 1.6.0 (GitHub), `DatabaseConnector` 6.4.0, `CirceR` 1.3.3,
`CohortGenerator` 0.11.2, `SqlRender` 1.19.4, `DBI` 1.2.3, `dplyr` 1.1.4,
`tibble` 3.3.0, `readr` 2.1.6, `cli` 3.6.5, `rlang` 1.1.6, `stringr` 1.6.0,
`jsonlite` 2.0.0, `ggplot2` 4.0.1, `scales` 1.4.0, `survival` 3.8-3,
`broom` 1.0.7.

Install with renv (exact versions, project-local library):

```r
install.packages("renv")
renv::activate()
renv::restore()
```

or into your own library:

```r
install.packages(c("DatabaseConnector", "CirceR", "CohortGenerator", "SqlRender",
                   "DBI", "dplyr", "tibble", "readr", "cli", "rlang", "stringr",
                   "jsonlite", "ggplot2", "scales", "survival", "broom", "remotes"))
remotes::install_github("OHDSI/Artemis@242b5a24864b85a44c62d95a98cbaa2d16c55539")
```

> [!IMPORTANT]
> **ARTEMIS: use v1.6.0** (`OHDSI/Artemis@242b5a2`), the tested version. It
> needs **Python ≥ 3.12**; see the
> [ARTEMIS install notes](https://github.com/OHDSI/Artemis#installation).
> **Pin `pandas` to 2.x** in its Python environment (usually
> `<Rlib>/ARTEMIS/.r-reticulate`). With pandas 3.x, alignment fails after
> reporting 100% with `argument is of length zero`:
> ```bash
> <path-to-ARTEMIS-venv>/bin/python3 -m pip install "pandas==2.2.3"
> ```

### Database connection

Any `DatabaseConnector` `connectionDetails` works; the SQL dialect is read from
the connection. Get a JDBC driver with
`DatabaseConnector::downloadJdbcDrivers("<dbms>", "~/.jdbc_drivers")`, or use
`createDbiConnectionDetails()` with an ODBC/DBI driver. For example:

```r
# SQL Server, JDBC: put the database in extraSettings, not server = "host/db"
connectionDetails <- DatabaseConnector::createConnectionDetails(
  dbms = "sql server", server = "host", user = "...", password = "...",
  extraSettings = "databaseName=db", pathToDriver = path.expand("~/.jdbc_drivers"))

# Snowflake, RSA key-pair
connectionDetails <- DatabaseConnector::createConnectionDetails(
  dbms = "snowflake", user = Sys.getenv("SNOWFLAKE_USER"),
  connectionString = paste0(
    "jdbc:snowflake://<account>.snowflakecomputing.com/",
    "?warehouse=<WAREHOUSE>&db=<DATABASE>&schema=<CDM_SCHEMA>&role=<ROLE>",
    "&private_key_file=", Sys.getenv("PRIV_KEY_FILE")))
```

**PostgreSQL: connect with JDBC, not DBI/RPostgres.** RPostgres lists tables
only on the session's `search_path`, so cohort generation fails with "tables
have not been created". The run stops at startup on this combination.

### Optional: bulk load

`Sys.setenv(DATABASE_CONNECTOR_BULK_UPLOAD = TRUE)` in the CONFIG block makes
DatabaseConnector bulk-load the tables the pipeline writes. It matters on
**Redshift**, where each write can otherwise take minutes (the run warns when
it is off). It needs, set before running:

- **Redshift:** S3 staging credentials: `AWS_ACCESS_KEY_ID`,
  `AWS_SECRET_ACCESS_KEY`, `AWS_DEFAULT_REGION`, `AWS_BUCKET_NAME`,
  `AWS_OBJECT_KEY` (key prefix) and `AWS_SSE_TYPE = "AES256"`.
- **PostgreSQL:** `psql`, with `Sys.setenv(POSTGRES_PATH = "<folder with psql>")`.

Other backends ignore it. If it is on but its prerequisite is missing, the run
stops at startup. Without the prerequisites, leave it `FALSE`.

---

## Pipeline

`run.R` runs the scripts in `R/steps/` stage by stage (`pipelineStages` in
`R/pipeline.R`). After the cohorts stage there is one stage per
`results/eligibility/` folder, and a step's first digit is its stage. Steps
pass objects through `saveState()`/`loadState()`.

| Step | Does | Writes |
|---|---|---|
| `00_diagnostics.R` | Pre-study queries (`sql/prestudy/`) | `results/diagnostics/*.csv` |
| `10_artemis.R` | Generate the ARTEMIS scan cohort, align regimens | `bc_artemis_episodes`, `bc_regimen_classifications` |
| `11_eligibility_inputs.R` | Score labs (`lab_cohorts.sql`), generate the ECOG and condition cohorts, put all eligibility inputs in one table under test ids | `bc_lab_cohort`, `bc_raw_lab_results` |
| `12_main_cohorts.R` | Generate the `cohorts/01_Target/` cohorts and the SQL-built tree (initiated bases, 2a-2e, T1-PT/NPT/CE, reached-node cohorts, 3a-3e, 4-6a-f); check they nest | `bc_cohort`, `cohort_counts`, `attrition_target_1a` |
| `20_demographics.R` | | `demographics`, `demographics_age_continuous` |
| `21_covariates.R` | Generate the comorbidity cohorts, overlap with the tree | `covariate_overlap`, `bc_covariate_cohort` |
| `22_baseline_characterization.R` | | `baseline_body_measurements`, `charlson_cci` |
| `23_rollups.R` | | `condition_rollup`, `drug_rollup`, `other_cancer_rollup` |
| `30_lab_ranges.R` | | `lab_value_distribution`, `lab_timing_to_index`, `lab_results_summary`, `lab_unit_resolution`, `lab_results_rollup` |
| `31_eligibility_coverage.R` | | `lab_cohort_counts`, `eligibility_input_coverage`, `eligibility_test_kappa`, `eligibility_lab_coverage_kappa` |
| `32_covariate_lab_coverage.R` | | `covariate_lab_coverage` |
| `40_artemis_assessment.R` | | `artemis_*` |
| `50_outcomes.R` | DTI, OS, TTNT, TTD, TTD-LoT2, TFI | `outcome_*` |
| `60_adherence.R` | | `guideline_*` |
| `70_treatment_patterns.R` | | `treatment_pattern_*`, `treatment_pathways` |

Every eligibility input (labs, ECOG, conditions) lives in `bc_lab_cohort`
under a test id declared in `cohorts/extras/eligibility_test_ids.csv`; the
eligibility SQL (`sql/eligibility_2*.sql`) refers to each as `@t_<key>`.

`.cache/<outputFolder name>/` holds the `saveState()` checkpoints so a
restarted session can resume. **It is patient-level: never share it.**

### Diagnostics

`sql/prestudy/chunks/00_setup.sql` builds the anchor (the `[GDE] Bladder
Cancer` concept set from `Target_1A.json`); each other chunk writes one CSV.
Cell suppression is inside the SQL (`@min_cell_count`). For query logic and
schemas, see onco-pre-study at `fb30995`.

| Group | Chunks | Covers |
|---|---|---|
| Attrition & prevalence | `00b`, `01` | Attrition to the observation-eligible subset; prevalence |
| Code counts & timing | `02`–`05`, `42` | Code counts and DX / MET / L01 timing, overall and by year |
| Other-cancer prevalence | `06`, `06b`, `33`–`35`, `41` | Other-cancer and general-cancer codes around the anchor |
| L01 treatment | `07`, `11`–`15` | Exposure windows and gaps between records |
| Death timing | `08`, `13`–`14` | Death vs index, first MET and observation end |
| Demographics | `09` | Age/sex at anchor dates |
| Anchor codes | `10`, `18`–`19`, `36`–`38` | Per-concept counts, repeats, timing between codes |
| Observation-period QC | `16`–`17`, `39` | Look-back, follow-up, period integrity |
| MET-first subgroup | `20`–`23`, `37` | First metastasis vs first diagnosis |
| MET → treatment | `24`–`28` | Closest treatment to first metastasis |
| Drug-therapy procedures | `29`–`32`, `40` | Procedure vs drug-exposure signal |

---

## Files

- `run.R`: CONFIG and run. `run_cohort_diagnostics.R`: optional CohortDiagnostics.
- `R/setup.R`, `R/pipeline.R`, `R/study_settings.R`, `R/packages.R`: setup,
  stages, fixed settings, packages. Don't edit.
- `R/` function files: `sql.R` (render and run `sql/`), `cohorts.R` (cohort
  generation and id lookups, test ids, `labRowsSql()`), `outputs.R` (strata,
  `writeResultCsv()`, folder READMEs), `db_compat.R` (connection checks,
  upstream patches), `artemis.R`, `artemis_uncaptured.R` (capture rule; also
  interactive drill-down helpers), `treatment_lines.R` (lines of therapy,
  outcome events), `time_to_event.R` (KM engine), `guideline_adherence.R`,
  `charlson.R`.
- `sql/`: SqlRender templates, one per query; each file's header says what it
  does and which step uses it.
- `cohorts/`:
  - `00_ARTEMIS/`: the ARTEMIS scan cohort.
  - `01_Target/`: Target 1A (Cohort 1) and its PC-allowed, mixed-bag and
    all-mBC (`Target_1mBC`) variants, and the L01-initiated cohorts
    (drug-only and drug-or-procedure, each with a PC-allowed variant).
  - `02_Comorbidity/`: the protocol's comorbidity covariates (T2DM,
    hypertension, CVD, stroke, VTE, liver disease, renal disease, dementia).
  - `03_Charlson/`: Charlson components not reported as comorbidities
    (Fortin/Reps/Ryan concept sets, except MI: PhenotypeLibrary cohort 510).
  - `04_Eligibility/`: ECOG and condition cohorts for eligibility.
  - `05_Lab_coverage/`: Heme disorders, a lab-coverage subgroup.
  - `extras/`: `regimen_reference.csv` (built by `build_regimen_reference.R`),
    `eligibility_test_ids.csv`, `trial_reference.yaml` (unused).

---

## Outputs (`results/eligibility/`)

Aggregate CSVs only, in six folders. UTF-8, comma-separated, header row;
missing and censored cells are empty. Each folder gets a `README.md` with its
section below plus [Censoring and strata](#censoring-and-strata).

Check each file's **population** before comparing counts: a few files are
lab QC over the **whole CDM population**, not the study cohorts.

**Cohort codes** used below: T1 = Cohort 1 (Target 1A, mBC); T1pc =
prostate cancer allowed; mixed bag = mBC with another primary; T1all =
`Target_1mBC` (T1 + mixed bag); 2a-2e = eligibility leaves (EV-pembro,
cisplatin, carboplatin, PD-L1, none); T1-PT / T1-NPT / T1-CE = previously
treated / not previously treated / combination eligible; T2b-R / T2c-R /
T2d-R = patients who reach the 2b / 2c / 2d checks; Base = "mBC initiated
base" (first classified regimen −30 to +90 days from index, no regimen in the
year before); BaseL01 (and variants) = L01-initiated; 3a-3d = eligible for
leaf a-d and started that arm's EAU regimen, 3e = 2e and started a non-EAU
regimen; 4-6a-f = first-line category under the EAU / HemOnc
mBC / any-regimen lens.

<!-- shared -->
### Censoring and strata

**Censoring.** A subject count `n` with `0 < n < minCellCount` (default 5) is
written as `−minCellCount` (e.g. `-5`); a true zero stays `0`. Record counts,
percentages and statistics that go with a censored count are blank.
Statistics that would let a censored cell be worked out are blank too.

**Strata.** Most per-cohort files have an `overall` row plus one set of rows
per stratum column, one column at a time (`stratum_type`, `stratum_value`):

| `stratum_type` | Values |
|---|---|
| `age_group` | `<=65`, `>65` |
| `sex` | `Male`, `Female`, `Other-Unknown` |
| `age_sex` | `age_group` × `sex`, e.g. `>65\|Female` |
| `age_band` | `<=65`, `66-80`, `>80` |
| `index_period` | `2015-2020`, `2021-2023`, `2024+` (`<2015` for cohorts that can index earlier) |
| `index_period_2021` | `2015-2020`, `2021+` |

Age is index year minus birth year. Periods use the index year; a boundary
year goes to the later band. Each cohort uses **its own index**: first
metastasis for T1 and its leaves, treatment start for treatment-initiated
cohorts, so a patient can fall in different bands in different cohorts.
Overlapping strata can reveal a censored cell by subtraction (e.g. `>80` =
`>65` − `66-80`); a site can narrow `strataColumns` to avoid that.
<!-- /shared -->

---

<!-- category:characterization -->
## `characterization/`

Who is in each cohort. "The tree" means every cohort in `bc_cohort` except
the reached-node cohorts, which appear only in `cohort_counts.csv` and
`eligibility_input_coverage.csv`.

### `cohort_counts.csv`
Every cohort, including the reached-node cohorts, overall and per stratum.
T2b-R = T1-CE minus 2a; T2c-R = T1-CE minus 2a and 2b; T2d-R = T1-NPT minus
T1-CE. With them, every eligibility check has reached, passed and failed
counts.

Columns: `stratum_type`, `stratum_value`, `cohort_definition_id`,
`cohort_name`, `n_entries` (cohort entries), `n_subjects`.

### `attrition_target_1a.csv`
Circe inclusion-rule attrition for the eight `cohorts/01_Target/` cohorts.
One row per cohort × rule, plus `ruleSequence = -1` (qualifying event, before
any rule).

| Column | Meaning |
|---|---|
| `cohortId`, `cohortName`, `ruleSequence`, `ruleName` | Cohort and rule (0-based order). |
| `personCount` | Subjects meeting this rule, regardless of the others. |
| `gainCount` | Subjects failing only this rule (gained if it were dropped). Blank on the `-1` row. |
| `personTotal` | Subjects before any rule. |
| `remaining` | Subjects meeting rules `0..ruleSequence` together; the last rule's value is the cohort count. |

### `demographics.csv`
Every cohort in the tree. Columns: `cohort_definition_id`, `cohort_name`,
`characteristic` (`age_group`, `sex`, `age_band`, `index_period`,
`index_period_2021`, `index_year`), `stratum` (the value), `n_subjects`,
`pct` (% of the cohort). Every characteristic is always written, whatever
`strataColumns` says.

### `demographics_age_continuous.csv`
Age at index, every cohort in the tree, overall and per stratum. Columns:
`cohort_definition_id`, `cohort_name`, `stratum_type`, `stratum_value`, `n`,
`mean_age`, `sd_age`, `min_age`, `lq_age`, `median_age`, `uq_age`, `max_age`.

### `covariate_overlap.csv`
Comorbidities and performance status, every cohort in the tree, overall and
per stratum, with a row even when the overlap is 0.

- Comorbidities (`T2DM`, `HTN`, `CVD`, `Stroke`, `VTE`, `LiverDx`, `RenalDx`,
  `Dementia`): any record on or before the cohort's index.
- PS (`PS1`, `PS2`, `PS2+`, `PS 0-2`, `PS 0-1`): an ECOG record (KPS mapped)
  in the lab window. The strata overlap by design, and a patient with two
  records in the window can be in more than one.

Columns: `cohort_definition_id`, `cohort_name`, `stratum_type`,
`stratum_value`, `code`, `label`, `n_cohort`, `n_overlap`.

### `baseline_body_measurements.csv`
Weight, height and BMI closest to index within ±`bodyMeasurementsWindowDays`
(90), every cohort in the tree, overall and per stratum. Columns:
`cohort_definition_id`, `cohort_name`, `variable` (`weight_kg`, `height_cm`,
`bmi`), `stratum_type`, `stratum_value`, `n`, `mean`, `sd`, `median`, `lq`,
`uq`, `min`, `max`.

### `charlson_cci.csv`
Charlson Comorbidity Index category, every cohort in the tree, overall and
per stratum. Components count any record on or before the cohort's own index,
so a patient can score higher in a later-indexed cohort.

`cci_version`:
- `calculated`: 15 of 19 components, every member. Metastatic solid tumour
  and any malignancy are left out (every patient has mBC, so everyone would
  score ≥ 5); leukaemia and lymphoma can't be separated in this coding.
- `reported`: a recorded index (concept 42538860, measurement or
  observation) closest to index within ±30 days; only members with one.
- `max`: the higher of the two per member.

Columns: `cohort_definition_id`, `cohort_name`, `stratum_type`,
`stratum_value`, `cci_version`, `cci_category` (`0`, `1-2`, `3-4`, `>=5`),
`n`.

### `condition_rollup.csv`, `drug_rollup.csv`
Members of each cohort in the tree with a condition in each disease
category, or a drug in each ATC 1st-level group, on or before their index.
Overall and per stratum; categories with no members have no row.

- **Conditions**: disease categories built from SNOMED parents, close to
  ICD-10 chapters; one category per concept, and a member counts in every
  category they have a condition in. Bladder cancer is taken out first.
  Other neoplasms are **not reported**: metastases recorded as conditions map
  to the primary-site cancer, so the category can't tell another primary from
  the patient's own metastases (see `other_cancer_rollup.csv`). `Other
  condition` = outside every category.
- **Drugs**: from `drug_era` (`source_table` = `drug_exposure` where a site's
  `drug_era` is empty). A drug counts in every ATC group it belongs to, so
  groups overlap.

Columns: `cohort_definition_id`, `cohort_name`, `stratum_type`,
`stratum_value`, [`atc_code`], `category`, `n_cohort`, `n_subjects`,
[`source_table`] (bracketed: drugs only).

### `other_cancer_rollup.csv`
For T1, the mixed bag and T1all: members with a code from the cohorts'
*Excluded primaries* set within [index − 180, index + 30] days, by cancer
site (SNOMED parents following the ICD-10 C-blocks; `Other cancer` for the
rest). T1 has none by construction. Read lung, liver, bone and brain with
care: a metastasis recorded as a cancer of that organ lands here.

Columns as `condition_rollup.csv`, plus `n_subjects_2plus` (members with ≥ 2
records in the site) and `n_records`.
<!-- /category:characterization -->

---

<!-- category:labs -->
## `labs/`

Eligibility inputs and lab values for the study cohorts, plus unit-resolution
QC over the **whole population**. Lab results are converted to each lab's
standard unit (`std_value`) before scoring.

### `lab_cohort_counts.csv`
**Whole population.** Subjects and records per eligibility test id: labs
(1-23, 44-49), ECOG (24-27), conditions, anticoagulant therapy and symptoms
(28-40), as in `cohorts/extras/eligibility_test_ids.csv`. Columns: `test_id`,
`label`, `n_subjects`, `n_records`.

### `eligibility_input_coverage.csv`
Each eligibility input × every cohort in the tree and the reached-node
cohorts, overall and per stratum: members tested and members passing, around
the cohort's own index. Labs and ECOG use the lab window (`lab_window`: e.g.
`-30..30` for metastasis-indexed, `-30..0` for treatment-indexed cohorts);
conditions use the condition window. A lab passes on the same result
eligibility uses. Treatment-indexed cohorts (T3a-e included) show whether
members still met each criterion just before treatment start.

Columns: `cohort_definition_id`, `cohort_name`, `stratum_type`,
`stratum_value`, `lab_window`, `test_id`, `label`, `n_cohort`, `n_tested`
(labs only), `n_passed`.

### `eligibility_test_kappa.csv`
T1, overall and per stratum: for each pair of lab tests, among members with
a result for both, the 2×2 pass/fail counts, % agreement and Cohen's kappa.
Pass/fail follows `labValueSelection`. `same_lab` marks two bands of one lab
(e.g. Hb ≥ 9 and Hb < 9); under `"closest"`, `n_pass_both` must be 0 for
mutually exclusive bands.

Columns: `cohort_definition_id`, `cohort_name`, `stratum_type`,
`stratum_value`, `test_id_1`, `label_1`, `test_id_2`, `label_2`, `same_lab`,
`n_both`, `n_pass_both`, `n_pass_1_only`, `n_pass_2_only`, `n_fail_both`,
`pct_agree`, `kappa`.

### `eligibility_lab_coverage_kappa.csv`
T1, overall and per stratum: for each pair of labs, whether each was tested
in the lab window, among all members. ECOG counts as one item and is always
listed. Columns: `cohort_definition_id`, `cohort_name`, `stratum_type`,
`stratum_value`, `lab_1`, `lab_2`, `n_cohort`, `n_tested_both`,
`n_tested_1_only`, `n_tested_2_only`, `n_tested_neither`, `pct_agree`,
`kappa`.

### `lab_value_distribution.csv`
`std_value` per cohort in the tree × lab, overall and per stratum, on the
result closest to index in the lab window. Columns: `stratum_type`,
`stratum_value`, `cohort_definition_id`, `lab_window`, `cat` (lab),
`n_with_lab`, `mean_value`, `sd_value`, `median_value`, `lq_value`,
`uq_value`, `min_value`, `max_value`.

### `lab_timing_to_index.csv`
T1 and T1pc, overall and per stratum: how far the closest measurement of each
lab falls from index, searching the whole history. `direction` = `before`,
`after` or `any` (same day counts for all three).

Columns: `stratum_type`, `stratum_value`, `cohort_definition_id`, `cat`,
`direction`, `n_0_14`, `n_0_30`, `n_0_60`, `n_0_90`, `n_0_180` (cumulative:
closest within N days), `n_ever` (any measurement), `p5_days` … `p95_days`
(percentiles of days to closest, among `n_ever`).

### `lab_results_summary.csv`
**Whole population.** Unit-resolution check: one row per lab × concept ×
unit × factor × status × ambiguity. Every unit of a lab should land in the
same `std_value` range.

Columns: `cat`, `measurement_concept_id`, `measurement_concept_name`,
`unit_concept_id`, `unit_concept_name`, `factor` (`std_value = value ×
factor`, plus an offset for HbA1c), `status`, `is_ambiguous`, `n_patients`,
`n_measurements`, `mean_value`, `sd_value`, `min_value`, `lq_value`,
`median_value`, `uq_value`, `max_value`.

`status`: `verified` (recorded unit), `concept` (unit stated by the concept
name), `overridden` (best-scoring scale), `unverified` (recorded unit, no
evidence either way), `unresolved` (not converted; only in
`lab_unit_resolution.csv`). `is_ambiguous` = more than one scale fit.

### `lab_unit_resolution.csv`
**Whole population.** Why each group (concept × unit × recorded reference
range) got its factor, including unresolved groups. Scores are distances in
decades from the lab's normal range, from the recorded range when it matches
the normal's bounds, otherwise from the value percentiles (groups over 20
records). Range, factor and status are not censored.

Columns: `cat`, `measurement_concept_id`, `measurement_concept_name`,
`unit_concept_id`, `unit_concept_name`, `range_low`, `range_high`,
`n_patients`, `n_records`, `p03_value`, `p25_value`, `p75_value`,
`p97_value` (recorded values, before conversion), `factor`, `val_offset`,
`status`, `is_ambiguous`, `recorded_unit_score`, `concept_unit_score`,
`best_score`.

### `lab_results_rollup.csv`
**Whole population.** One row per lab × `is_ambiguous`, pooled in the
standard unit; ambiguous streams get their own row. `n_patients` is a true
patient count, not a sum of summary rows. Columns: `cat`, `std_unit_name`,
`is_ambiguous`, `n_patients`, `n_measurements`, `n_concepts`, `n_units`,
`pct_overridden` (`overridden` or `concept`), `pct_unverified`, then the
`std_value` distribution as in `lab_results_summary.csv`.

### `covariate_lab_coverage.csv`
T1 only: members with and without each of heme disorders, liver disease and
renal disease (any record on or before index), and how many on each side had
each lab in the lab window. Columns: `cohort_definition_id`, `subgroup`
(e.g. `heme_disorder`, `no_heme_disorder`), `subgroup_count`, `test` (lab),
`n_with_test`.
<!-- /category:labs -->

---

<!-- category:artemis -->
## `artemis/`

How well ARTEMIS regimen alignment covers the drug exposures. Every file has
a leading `cohort` column with three blocks, each censored separately:

- `scan_cohort`: the ARTEMIS scan cohort, whole history.
- `target_1a`: T1 members, whole history.
- `target_1a_post_met`: T1 members, only exposures, episodes and alignments
  on or after the metastasis index. Regimens that started before metastasis
  are not in its regimen list, but still count for capture.

**Valid anticancer exposures** are ingredients in ATC L01, L03 and L04 (plus
L02 if `stripEndocrineTherapy` is off; see `assessmentAtcClasses`). An
exposure is **captured** when it starts within 30 days of an aligned episode
of a regimen that contains that ingredient.

| File | Columns |
|---|---|
| `artemis_summary.csv` | `cohort`, `metric` (stage: scan cohort → ingredient-level exposures → valid anticancer exposures → raw alignments → regimen episodes), `n_patients`, `n_records` |
| `artemis_coverage.csv` | `cohort`, `level`, `n_covered`, `n_total` |
| `artemis_drug_exposures.csv` | `cohort`, `drug_concept_id`, `drug_name`, `n_records`, `n_patients`: valid exposures per ingredient |
| `artemis_regimens_aligned.csv` | `cohort`, `regimen`, `n_episodes`, `n_patients` |
| `artemis_episodes_per_patient.csv` | `cohort`, `n_episodes`, `n_patients` |
| `artemis_uncaptured_drugs.csv` | As `artemis_drug_exposures.csv`, for exposures not captured |

`artemis_coverage.csv` levels (`n_covered` / `n_total`):
- `cohort_subject`: patients with an aligned episode / every member of the
  block's cohort.
- `scanned_subject`: the same / members ARTEMIS scanned.
- `patient`: patients with an aligned episode / patients with a valid
  exposure.
- `exposure`: captured / valid exposures (the complement of
  `artemis_uncaptured_drugs.csv`).

If step 10 did not run in the same session, the scan-cohort subject counts are
blank and `scanned_subject` equals `cohort_subject` for the T1 blocks.
<!-- /category:artemis -->

---

<!-- category:outcomes -->
## `outcomes/`

Time is in days. Populations:

- **DTI** (diagnosis to treatment): T1.
- **OS**: T1, 2a-2e, 3a-3e, 4-6a-f, BaseL01, BaseL01 PC allowed.
- **TTNT, TTD, TTD-LoT2, TFI**: 3a-3e and 4-6a-f.

**Definitions.** Lines of therapy are the base cohort's: line 1 is the
regimen Base was indexed on, maintenance is folded into the line it maintains
(`maintenanceMerge`), every episode ends at death at the latest, and episodes
before treatment start are dropped. Follow-up ends at the cohort end date:
end of observation, death or another primary cancer.

| Outcome | From | Event |
|---|---|---|
| OS | cohort index | death |
| TTNT | line 1 start | line 2 start or death |
| TTD | line 1 start | line 1 end (last administration, or death) |
| TTD-LoT2 | line 2 start (patients who started line 2) | line 2 end |
| TFI | line 1 end | line 2 start or death; patients who died on line 1 are left out |
| DTI | T1 index | line 1 start; descriptive only, no KM |

DTI has two definitions: `treated` (Base: start −30 to +90 days) and
`unbound` (from −30 days on, adding regimens started after day 90; the
washout still applies). Negative times are kept.

**Strata.** Every file has `cohort_definition_id`, `cohort_name` and
`stratum_type` (`overall`, each stratum column, or `index_year`). Summary,
histogram and DTI files put the stratum value in its own column at the end
(`age_group`, `sex`, ..., `index_year`; empty on other rows). KM, median and
milestone files carry it in `strata` instead (e.g. `age_group=>65`, or `All`).

### `outcome_{os,ttnt,ttd,ttd_lot2,tfi}_summary.csv`
Columns: …, `count` (subjects), `n_event`, then time among those with the
event: `min_time`, `c10_time`, `q25_time`, `median_time`, `q75_time`,
`c90_time`, `max_time`.

### `outcome_{os,ttnt,ttd,ttd_lot2,tfi}_histogram.csv`
Every subject by observed time (event or censoring), in half-open bins
`[0,30)`, `[30,60)`, `[60,90)`, `[90,180)`, `[180,365)`, `[365, Inf)`; empty
bins have no row. Columns: …, `time_bin`, `count`.

### `outcome_{os,ttnt,ttd,ttd_lot2,tfi}_km.csv`
Kaplan-Meier steps, from the first event on. Columns: …, `time`, `n.risk`,
`n.event`, `n.censor`, `estimate`, `std.error`, `conf.high`, `conf.low`,
`strata`.

### `outcome_{os,ttnt,ttd,ttd_lot2,tfi}_median_survival.csv`
Columns: …, `strata`, `n`, `median`, `lower`, `upper` (95% CI; blank when the
median isn't reached).

### `outcome_{os,ttnt,ttd,ttd_lot2,tfi}_milestones.csv`
KM survival at 365, 730 and 1095 days, read from the last step at or before
the milestone (so carried forward past the end of follow-up; 1 with blank CI
and `n_at_risk` before the first event). Columns: …, `strata`, `milestone`,
`surv_prob`, `lower`, `upper`, `n_at_risk`.

### `outcome_dti_summary.csv`
Columns: …, `definition`, `count`, `min_time`, `c10_time`, `lq_time`,
`median_time`, `uq_time`, `c90_time`, `max_time`, `mean_time`,
`mean_time_min0` (negative times as 0), `n_before`, `pct_before` (started
before index).

### `outcome_dti_buckets.csv`
Every T1 member in one `bucket`: started `-30 to -1`, `0-30`, `31-60`,
`61-90` (these four are Base), `91-180`, `181-360`, `>360`, or
`not started: prior treatment` (regimen in the year before index), or
`not started: none recorded`.
Columns: …, `bucket`, `n`, `n_total`, `pct`.

### `outcome_dti_by_category_summary.csv`, `_buckets.csv`
As above, for patients who started, split by `lens` (`eau`, `hemonc_mbc`,
`any`) and the first regimen's `category` (`ev_pembro`, `cisplatin`,
`carboplatin`, `pdl1_mono`, `other_recommended`, `other`). In the buckets
file `n_total` is the patients in that lens × category.
<!-- /category:outcomes -->

---

<!-- category:guideline -->
## `guideline/`

What the guideline recommended for each eligibility leaf (2a-2e) against the
first-line treatment its patients started. First-line treatment is the
regimen Base was indexed on; anyone not in Base is `untreated` (this includes
treatment more than 90 days after index and every previously treated
patient).

### `guideline_relevance.csv`
Each cohort's size as a share of T1, overall and per stratum (a stratum's
share is of T1's members in the same stratum). Cohorts: T1, 2a-2e, 3a-3e,
4-6a-f, Base. Strata use each cohort's own index. Columns:
`cohort_definition_id`, `cohort_name`, `stratum_type`, `stratum_value`, `n`,
`pct_of_base`.

### `guideline_adherence_crosstab.csv`
Leaf × lens × first-line category, overall and per stratum. Counts only:
every protocol adherence statistic is a sum or ratio of these rows. Within a
leaf × lens the seven categories add up to `eligible_n` (before censoring).

| `lens` (cohorts) | `ev_pembro` … `pdl1_mono` | `other_recommended` | `other` |
|---|---|---|---|
| `eau` (T4) | EAU guideline regimens for that arm | always 0 | not an EAU regimen |
| `hemonc_mbc` (T5) | HemOnc mBC-indicated regimens containing the arm's drug | mBC-indicated, none of the arms' drugs | not indicated for mBC |
| `any` (T6) | any regimen containing the arm's drug | always 0 | none of the arms' drugs |

The protocol's categories, for leaf x in a-d:

| Protocol | From this file |
|---|---|
| Adherent (Cohort 3x) | `eau`, `category` = `recommended` |
| Other guideline treatment | `eau`, the other three arms |
| mBC-indicated, not guideline (Cohort 5) | `hemonc_mbc` arms + `other_recommended`, minus the `eau` arms |
| Not indicated (Cohort 6) | `hemonc_mbc`, `other` |
| No treatment | `untreated` |

The Cohort 5 subtraction holds because every EAU regimen has the same
category under `hemonc_mbc`. Leaf e has no recommendation; the protocol's 3e
(any treatment) is `eligible_n` minus `untreated`.

Columns: `stratum_type`, `stratum_value`, `leaf`, `lens`, `recommended`
(blank for e), `category` (the six above or `untreated`), `n`, `eligible_n`.

### `guideline_adherence.csv`
A per-leaf roll-up; use the crosstab for the protocol's categories. Each leaf is compared only with its own arm's
cohorts, so `alt_guideline` is always 0 and a patient started on another
arm's regimen counts as `no_treatment`. Columns: `stratum_type`,
`stratum_value`, `leaf`, `category` (`adherent`, `alt_guideline`,
`indicated_other`, `non_indicated`, `no_treatment`), `n`, `eligible_n`,
`pct_of_eligible`.
<!-- /category:guideline -->

---

<!-- category:treatment_patterns -->
## `treatment_patterns/`

Lines of therapy among Base, as in the outcomes: maintenance folded into its
line (`maintenanceMerge`), lines end at death, line 1 is Base's index regimen.
Strata use the T1 index, except `treatment_pattern_by_year.csv`.

| File | Columns |
|---|---|
| `treatment_pattern_untreated.csv` | `stratum_type`, `stratum_value`, `n_t1`, `n_treated` (in Base), `n_untreated`, `pct_untreated`. Why the rest aren't treated: `outcome_dti_buckets.csv`. |
| `treatment_pattern_regimen.csv` | `pct_of_lot`, `stratum_type`, `stratum_value`, `lot_number`, `regName`, `n_patients`, `lot_n` (patients reaching that line) |
| `treatment_pattern_category.csv` | `pct_of_lot`, `stratum_type`, `stratum_value`, `lens`, `lot_number`, `category`, `n_patients`, `lot_n` |
| `treatment_pathways.csv` | `stratum_type`, `stratum_value`, `lot1`, `lot2`, `lot3` (EAU-lens category; empty if not reached), `n_patients` |
| `treatment_pattern_maintenance.csv` | `stratum_type`, `stratum_value`, `lot_number`, `regName` (induction), `maintenance_regimen` and `maintenance_rule` (or `none`), `n_patients`, `median_gap_days` (induction end to maintenance start; negative if they overlap), `median_maintenance_days` |
| `treatment_pattern_by_year.csv` | `pct_of_year_lot`, `stratum_type`, `lens`, `cohort_definition_id`, `cohort_name`, `lot_number`, `treatment_year`, `category`, `n_patients`, `year_lot_n`, then the stratum value columns (`age_group`, `sex`, ...) |

Categories are `ev_pembro`, `cisplatin`, `carboplatin`, `pdl1_mono`,
`other_recommended` and `other`, per lens (`eau`, `hemonc_mbc`, `any`).

`treatment_pattern_by_year.csv` is per treated cohort (Base, 3a-3e, 4-6a-f),
by the calendar year each line started, with strata on the cohort's own
(treatment-start) index. Only Base shows a regimen mix: each 4-6 cohort is
one category by definition. The maintenance file is written only when
`maintenanceMerge` is on.
<!-- /category:treatment_patterns -->

---
