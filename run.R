# ===========================================================================
# run.R  —  Bladder eligibility study (standalone; no OncoStudyModules dep)
# ===========================================================================
# Runs diagnostics + the eligibility/feasibility pipeline in one go. To run
# either half on its own (e.g. diagnostics now, eligibility once ARTEMIS is
# sorted), use run_diagnostics_only.R and run_feasibility_only.R instead —
# together they do exactly what this file does.
#
# Stage: cohort creation.
#   (0) pre-study diagnostics                -> R/00_prestudy_queries.R
#   (a) ARTEMIS regimen alignment            -> R/01_artemis.R
#   (b) eligibility labs + cohorts -> 1 table -> R/02_eligibility_inputs.R
#   (c) main cohort tree                      -> R/03_main_cohorts.R
#   (d) lab test ranges on main cohorts       -> R/04_lab_ranges.R
#   (e) eligibility-input coverage            -> R/05_eligibility_coverage.R
#   (f) ARTEMIS alignment assessment          -> R/06_artemis_assessment.R
#   (g) per-cohort demographics               -> R/07_demographics.R
#   (h) covariate overlap with 1A             -> R/08_covariates.R
#   (i) outcomes: DTI / OS / TTNT / TTD / TFI -> R/09_outcomes.R
#   (j) guideline relevance + adherence       -> R/10_adherence.R
#   (k) baseline vitals + Charlson CCI        -> R/11_baseline_characterization.R
#   (l) treatment patterns by LoT             -> R/12_treatment_patterns.R
#
# Usage: edit the CONFIG block below, then  source("run.R")
# Requires: DatabaseConnector, SqlRender, CohortGenerator, CirceR, ARTEMIS,
#           dplyr, tibble, readr  (installed; NOT OncoStudyModules).
# ===========================================================================

for (p in c("DatabaseConnector", "SqlRender", "CohortGenerator", "CirceR",
            "ARTEMIS", "dplyr", "tibble", "readr", "cli", "rlang", "stringr",
            "jsonlite", "ggplot2", "scales")) {
  if (!requireNamespace(p, quietly = TRUE))
    stop("Required package not installed: ", p, call. = FALSE)
}

# ARTEMIS must be ATTACHED (not just loaded via `::`): loadRegimens() does
# data("regimens", package = "ARTEMIS", envir = regimens_env) internally, but
# then checks exists("regimens") without envir = regimens_env, so the check
# only succeeds when package:ARTEMIS is already on the search path.
suppressMessages(library(ARTEMIS))

# ===========================================================================
# CONFIG  [EDIT HERE]
# ===========================================================================

# --- Database connection ----------------------------------------------------
# OPTIONAL, ONE-TIME SETUP: this pipeline writes a couple of reference tables
# while it runs. On some database backends, DatabaseConnector can write them
# a lot faster if you turn on its own built-in bulk-load mechanism first:
#
#   Sys.setenv(DATABASE_CONNECTOR_BULK_UPLOAD = TRUE)
#
# This is always safe to set -- DatabaseConnector applies it only to the
# backends it supports, and does nothing on any other backend. Depending on
# which backend you're connecting to, its bulk-load path may need one of two
# kinds of one-time setup of its own:
#   - a local database client tool installed on this machine, or
#   - object-storage credentials, set the same way:
#       Sys.setenv(AWS_ACCESS_KEY_ID = "...", AWS_SECRET_ACCESS_KEY = "...",
#                  AWS_DEFAULT_REGION = "...", AWS_BUCKET_NAME = "...",
#                  AWS_OBJECT_KEY = "...", AWS_SSE_TYPE = "AES256")
# If neither is available to you, simply don't set
# DATABASE_CONNECTOR_BULK_UPLOAD -- the pipeline runs correctly either way,
# just slower on those couple of writes.
#
# Define `connectionDetails` however your site connects — this is left open on
# purpose. Most JDBC setups use DatabaseConnector::createConnectionDetails(),
# but some sites need a different constructor (e.g. createDbiConnectionDetails()
# for Azure AD token auth). Any DatabaseConnector connectionDetails works; the
# SQL dialect is read from the live connection, so nothing else depends on how
# it is built.
#
# Example (JDBC):
#   connectionDetails <- DatabaseConnector::createConnectionDetails(
#     dbms = "sql server", server = "host", user = "...", password = "...",
#     extraSettings = "databaseName=db", pathToDriver = path.expand("~/.jdbc_drivers"))
#   # NB: this driver has no "host/db" path-style syntax -- `server = "host/db"`
#   # gets sent to it verbatim as `jdbc:sqlserver://host/db`, which it treats
#   # as ONE hostname to resolve (fails with a "TCP/IP connection... has
#   # failed" error that looks like a network/instance problem but isn't). Use
#   # `extraSettings = "databaseName=..."` instead; see docs/SQL_SERVER.md.
#
# Example (DBI / Azure token):
#   connectionDetails <- DatabaseConnector::createDbiConnectionDetails(
#     dbms = "sql server", drv = odbc::odbc(),
#     Driver = "ODBC Driver 18 for SQL Server",
#     Server = "...", Database = "...", Encrypt = "yes",
#     TrustServerCertificate = "No",
#     attributes = list("azure_token" = token$credentials$access_token))
#
# Example (Snowflake / RSA key-pair auth, e.g. IQVIA Posit Workbench):
#   connectionDetails <- DatabaseConnector::createConnectionDetails(
#     dbms = "snowflake",
#     user = Sys.getenv("SNOWFLAKE_USER"),          # e.g. "u12345678"
#     connectionString = paste0(
#       "jdbc:snowflake://<account>.snowflakecomputing.com/",
#       "?warehouse=<WAREHOUSE>&db=<DATABASE>&schema=<CDM_SCHEMA>",
#       "&role=<ROLE>",
#       "&private_key_file=", Sys.getenv("PRIV_KEY_FILE")))

connectionDetails <- NULL   # <-- REPLACE with your connection

# --- Site + OMOP CDM schemas ------------------------------------------------
settings <- list(
  databaseId          = "",   # short site id, e.g. "HUS"
  cdmDatabaseSchema   = "",
  vocabDatabaseSchema = "",    # defaults to cdmDatabaseSchema if blank
  workDatabaseSchema  = "",    # where cohort + lab + episode tables are written

  # --- Work tables ----------------------------------------------------------
  cohortTable          = "bc_cohort",
  labCohortTable       = "bc_lab_cohort",       # unified eligibility table (labs + cohorts)
  rawLabResultsTable   = "bc_raw_lab_results",
  covariateCohortTable = "bc_covariate_cohort", # descriptive covariates (comorbidities); NOT part of the main tree
  artemisCohortName    = "ARTEMIS bladder cohort",
  episodeTable         = "bc_artemis_episodes",
  regimenClassTable    = "bc_regimen_classifications",

  # --- Run settings ---------------------------------------------------------
  minCellCount        = 5L,
  # Index window for near-index inputs (labs, ECOG, condition/diagnosis limbs):
  # how many days BEFORE and AFTER the index date a record may fall. Asymmetric.
  labWindowBeforeDays = 14L,
  labWindowAfterDays  = 7L,
  # Index window for baseline weight/height/BMI (step (k)) — wider than the
  # lab window above; matches onco-study-modules' own +/-90-day convention
  # for vitals.
  vitalsWindowDays    = 90L,
  # Exclude endocrine-therapy regimens (tamoxifen, abiraterone, GnRH agonists,
  # ...) from the ARTEMIS reference. Applied via the is_endocrine column of
  # cohorts/extras/regimen_reference.csv. TRUE = drop hormone therapy (default);
  # FALSE = count endocrine therapy as anticancer treatment.
  stripEndocrineTherapy = TRUE,
  # --- Which drugs ARTEMIS encodes into each patient's alignment string ------
  # Non-regimen / supportive drugs in the string are gap noise that lowers
  # alignment scores and shrinks eras (DEVELOPMENT.md §10.4). Two composable
  # filters (both applied when both active). Regimens whose components are
  # filtered out can no longer align and are dropped from the reference (logged).
  #   validDrugsRegimenComponents  TRUE (default) = keep only drugs that appear
  #                                in a kept regimen; FALSE = keep all. This keeps
  #                                validDrugs and the regimen file consistent —
  #                                every kept regimen's components stay encodable,
  #                                so every regimen stays alignable.
  #   validDrugsAtcClasses         ATC 2nd-level classes to keep. DEFAULT
  #                                character(0) (off): setting c("L01".."L04")
  #                                further drops steroids/rescue agents for a
  #                                cleaner string, but ALSO false-drops anticancer
  #                                drugs whose special-formulation / fixed-dose-
  #                                combo RxNorm concept isn't ATC-mapped in the
  #                                vocab (nab-paclitaxel, liposomal doxorubicin,
  #                                ADCs, ...) and their regimens — so it is opt-in.
  validDrugsRegimenComponents = TRUE,
  validDrugsAtcClasses = c("L01", "L02", "L03", "L04"),
  # ATC 2nd-level classes whose descendant ingredients are kept in the ARTEMIS
  # exposure assessment (drug_exposures / uncaptured / coverage in step (f)).
  # NULL (default) mirrors the regimen anticancer filter: L01/L03/L04, plus L02
  # when stripEndocrineTherapy is FALSE. Set an explicit vector (e.g. c("L01"))
  # to override, or character(0) to keep every recognised ingredient.
  assessmentAtcClasses = NULL,
  # Which subject_strata.sql (age/sex) breakdowns get reported, on top of
  # "overall", across every stratified output (lab_value_distribution,
  # lab_timing_to_index, eligibility_input_coverage, cohort_counts,
  # demographics, outcomes, guideline_relevance/adherence, baseline_vitals,
  # treatment_pattern_*). One setting, read by activeStrataTypes()/
  # activeStrataSpecs() (R/helpers.R) -- no per-step code needed to change
  # it. DEFAULT c("age_group", "sex", "age_sex") (all three); a smaller
  # partner whose subgroups censor too heavily to be useful can narrow this
  # (e.g. c("sex")) or set character(0) to turn stratification off
  # everywhere and only get "overall" rows.
  strataColumns = c("age_group", "sex", "age_sex"),
  outputFolder        = file.path("results")
)

# ===========================================================================
# Run  —  do not edit below
# ===========================================================================
source("R/vendor_utils.R")   # .getDbms, %||%
source("R/00_prestudy_queries.R")
source("R/artemis.R")        # vendored: runArtemis(), writeArtemisEpisodes(), ...
source("R/artemis_uncaptured.R")  # uncapturedExposures(), plotUncapturedAlignment()
source("R/helpers.R")        # cohort generation + SQL utilities
source("R/timeToEvent.R")    # computeTimeToEvent(), computeTimeDiffStats()
source("R/survivalMilestones.R") # extractSurvivalMilestones()
source("R/eventBuilders.R")  # fetchDeathEvents(), buildLineOfTherapyEvents(), buildDtiEvents(), anchorEpisodes(), combineEarliestEvent()
source("R/guidelineAdherence.R") # computeGuidelineRelevance(), computeAdherenceRollup()
source("R/charlsonScore.R")  # computeCharlsonScore(), charlsonComponents()
source("R/setup.R")          # config checks + derived paths + executionSettings

connection <- DatabaseConnector::connect(connectionDetails)
.checkDbiPostgresBug(connection)

message("\n=== Diagnostics: pre-study characterization queries ===")
runPreStudyDiagnostics(connection, settings)      # (0)

source("R/01_artemis.R")            # (a)
source("R/02_eligibility_inputs.R") # (b)
source("R/03_main_cohorts.R")       # (c)
source("R/04_lab_ranges.R")         # (d) lab test ranges on main cohorts
source("R/05_eligibility_coverage.R") # eligibility-input counts + Target 1A coverage
source("R/06_artemis_assessment.R") # ARTEMIS alignment assessment (uses artemisResult)
source("R/07_demographics.R")       # per-cohort demographics (age / sex / index year)
source("R/08_covariates.R")         # covariate overlap with 1A (comorbidities + PS)
source("R/09_outcomes.R")           # outcomes: DTI / OS / TTNT / TTD / TFI
source("R/10_adherence.R")          # guideline relevance + adherence roll-up
source("R/11_baseline_characterization.R") # weight/height/BMI + Charlson CCI
source("R/12_treatment_patterns.R") # treatment patterns by line of therapy

message("\n=== Done. Results under ", settings$outputFolder, "/eligibility/ ===")

utils::zip(zipfile = file.path(settings$outputFolder, "diagnostics.zip"), files = list.files(file.path(settings$outputFolder, "diagnostics"), recursive = TRUE, full.names = TRUE, include.dirs = TRUE, all.files = TRUE), flags = "-q")
utils::zip(zipfile = file.path(settings$outputFolder, "eligibility_results.zip"), files = list.files(file.path(settings$outputFolder, "eligibility"), recursive = TRUE, full.names = TRUE, include.dirs = TRUE, all.files = TRUE), flags = "-q")

message("Wrote diagnostics.zip and eligibility_results.zip to ", settings$outputFolder)

DatabaseConnector::disconnect(connection)
