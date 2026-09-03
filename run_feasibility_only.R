# ===========================================================================
# run_feasibility_only.R  —  feasibility/eligibility pipeline only
# ===========================================================================
# Complement of run_diagnostics_only.R: runs everything in run.R EXCEPT the
# pre-study diagnostics stage (0). Together, run_diagnostics_only.R +
# run_feasibility_only.R cover exactly what run.R does.
#   (a) ARTEMIS regimen alignment            -> R/01_artemis.R
#   (b) eligibility labs + cohorts -> 1 table -> R/02_eligibility_inputs.R
#   (c) main cohort tree                      -> R/03_main_cohorts.R
#   (d) lab test ranges on main cohorts       -> R/04_lab_ranges.R
#   (e) eligibility-input coverage            -> R/05_eligibility_coverage.R
#   (f) ARTEMIS alignment assessment          -> R/06_artemis_assessment.R
#   (g) per-cohort demographics               -> R/07_demographics.R
#   (h) covariate overlap with 1A             -> R/08_covariates.R
#
# Use this once ARTEMIS is sorted (see README.md) if you already have
# diagnostics results from run_diagnostics_only.R and just need the
# eligibility/feasibility cohorts now — no need to re-run diagnostics.
#
# Usage: edit the CONFIG block below, then  source("run_feasibility_only.R")
# Requires: DatabaseConnector, SqlRender, CohortGenerator, CirceR, ARTEMIS,
#           dplyr, tibble, readr  (installed; NOT OncoStudyModules).
# ===========================================================================

# JAVA: Snowflake's JDBC driver bundles Apache Arrow, which fails on Java 17+
# ("Failed to initialize MemoryUtil") unless java.nio is opened to it. This must
# be set BEFORE the JVM starts — i.e. before DatabaseConnector loads — so it has
# to be the first statement in a FRESH R session. Harmless on other dialects and
# on older Java versions.
options(java.parameters = "--add-opens=java.base/java.nio=ALL-UNNAMED")

for (p in c("DatabaseConnector", "SqlRender", "CohortGenerator", "CirceR",
            "ARTEMIS", "dplyr", "tibble", "readr", "cli", "rlang", "stringr")) {
  if (!requireNamespace(p, quietly = TRUE))
    stop("Required package not installed: ", p, call. = FALSE)
}

# ARTEMIS must be ATTACHED (not just loaded via `::`): loadRegimens() does
# data("regimens", package = "ARTEMIS", envir = regimens_env) internally, but
# then checks exists("regimens") without envir = regimens_env, so the check
# only succeeds when package:ARTEMIS is already on the search path.
suppressMessages(library(ARTEMIS))

# ===========================================================================
# CONFIG  [EDIT HERE]  — same as run.R
# ===========================================================================

# --- OPTION A: fill the whole CONFIG block from a .env file -----------------
# If you keep credentials in a .env file (see README "Running it yourself"),
# uncomment these three lines and SKIP the rest of this block — configureFromEnv()
# returns exactly the `connectionDetails` and `settings` built by hand below.
#   source("R/env_config.R")
#   cfg <- configureFromEnv()            # reads ./.env
#   connectionDetails <- cfg$connectionDetails; settings <- cfg$settings
#
# --- OPTION B: fill it in by hand ------------------------------------------
# --- Database connection ----------------------------------------------------
# Same as run.R — see that file's CONFIG block for JDBC / DBI examples.
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
  outputFolder        = file.path("results")
)

# ===========================================================================
# Run  —  do not edit below
# ===========================================================================
source("R/vendor_utils.R")   # .getDbms, %||%
source("R/artemis.R")        # vendored: runArtemis(), writeArtemisEpisodes(), ...
source("R/artemis_uncaptured.R")  # uncapturedExposures(), plotUncapturedAlignment()
source("R/helpers.R")        # cohort generation + SQL utilities
source("R/setup.R")          # config checks + derived paths + executionSettings

connection <- DatabaseConnector::connect(connectionDetails)
.checkDbiPostgresBug(connection)

source("R/01_artemis.R")            # (a)
source("R/02_eligibility_inputs.R") # (b)
source("R/03_main_cohorts.R")       # (c)
source("R/04_lab_ranges.R")         # (d) lab test ranges on main cohorts
source("R/05_eligibility_coverage.R") # eligibility-input counts + Target 1A coverage
source("R/06_artemis_assessment.R") # ARTEMIS alignment assessment (uses artemisResult)
source("R/07_demographics.R")       # per-cohort demographics (age / sex / index year)
source("R/08_covariates.R")         # covariate overlap with 1A (comorbidities + PS)

message("\n=== Done. Results under ", settings$outputFolder, "/eligibility/ ===")

utils::zip(zipfile = file.path(settings$outputFolder, "eligibility_results.zip"), files = list.files(file.path(settings$outputFolder, "eligibility"), recursive = TRUE, full.names = TRUE, include.dirs = TRUE, all.files = TRUE), flags = "-q")

message("Wrote eligibility_results.zip to ", settings$outputFolder)

DatabaseConnector::disconnect(connection)
