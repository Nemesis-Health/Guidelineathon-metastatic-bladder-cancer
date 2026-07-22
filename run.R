# ===========================================================================
# run.R  —  Bladder eligibility study (standalone; no OncoStudyModules dep)
# ===========================================================================
# Stage: cohort creation.
#   (a) ARTEMIS regimen alignment            -> R/01_artemis.R
#   (b) eligibility labs + cohorts -> 1 table -> R/02_eligibility_inputs.R
#   (c) main cohort tree                      -> R/03_main_cohorts.R
#   (d) lab test ranges on main cohorts       -> R/04_lab_ranges.R
#   (e) eligibility-input coverage            -> R/05_eligibility_coverage.R
#   (f) ARTEMIS alignment assessment          -> R/06_artemis_assessment.R
#   (g) per-cohort demographics               -> R/07_demographics.R
#   (h) covariate overlap with 1A             -> R/08_covariates.R
#
# Usage: edit the CONFIG block below, then  source("run.R")
# Requires: DatabaseConnector, SqlRender, CohortGenerator, CirceR, ARTEMIS,
#           dplyr, tibble, readr  (installed; NOT OncoStudyModules).
# ===========================================================================

for (p in c("DatabaseConnector", "SqlRender", "CohortGenerator", "CirceR",
            "ARTEMIS", "dplyr", "tibble", "readr")) {
  if (!requireNamespace(p, quietly = TRUE))
    stop("Required package not installed: ", p, call. = FALSE)
}

# ===========================================================================
# CONFIG  [EDIT HERE]
# ===========================================================================

# --- Database connection ----------------------------------------------------
# Define `connectionDetails` however your site connects — this is left open on
# purpose. Most JDBC setups use DatabaseConnector::createConnectionDetails(),
# but some sites need a different constructor (e.g. createDbiConnectionDetails()
# for Azure AD token auth). Any DatabaseConnector connectionDetails works; the
# SQL dialect is read from the live connection, so nothing else depends on how
# it is built.
#
# Example (JDBC):
#   connectionDetails <- DatabaseConnector::createConnectionDetails(
#     dbms = "sql server", server = "host/db", user = "...", password = "...",
#     pathToDriver = path.expand("~/.jdbc_drivers"))
#
# Example (DBI / Azure token):
#   connectionDetails <- DatabaseConnector::createDbiConnectionDetails(
#     dbms = "sql server", drv = odbc::odbc(),
#     Driver = "ODBC Driver 18 for SQL Server",
#     Server = "...", Database = "...", Encrypt = "yes",
#     TrustServerCertificate = "No",
#     attributes = list("azure_token" = token$credentials$access_token))

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
  validDrugsAtcClasses = character(0),
  # ATC 2nd-level classes whose descendant ingredients are kept in the ARTEMIS
  # exposure assessment (drug_exposures / uncaptured / coverage in step (f)).
  # NULL (default) mirrors the regimen anticancer filter: L01/L03/L04, plus L02
  # when stripEndocrineTherapy is FALSE. Set an explicit vector (e.g. c("L01"))
  # to override, or character(0) to keep every recognised ingredient.
  assessmentAtcClasses = NULL,
  outputFolder        = file.path("results")
)

# --- Optional pre-study export settings ------------------------------------
# If set, `preStudyProjectRoot` may point to a local onco-pre-study checkout.
settings$preStudyProjectRoot <- settings$preStudyProjectRoot %||% file.path("~", "onco-pre-study")
settings$preStudyArchiveName <- settings$preStudyArchiveName %||% "prestudy_queries.zip"

# ===========================================================================
# Run  —  do not edit below
# ===========================================================================
source("R/vendor_utils.R")   # .getDbms, %||%
source("R/artemis.R")        # vendored: runArtemis(), writeArtemisEpisodes(), ...
source("R/artemis_uncaptured.R")  # uncapturedExposures(), plotUncapturedAlignment()
source("R/helpers.R")        # cohort generation + SQL utilities
source("R/setup.R")          # config checks + derived paths + executionSettings

# Export pre-study queries before any DB connections or heavy steps run.
# This is intentionally resilient: failures won't stop the main pipeline.
tryCatch({
  source("R/00_prestudy_queries.R")
  exportPreStudyQueries(projectRoot = settings$preStudyProjectRoot,
                        outputFolder = settings$outputFolder,
                        archiveName = settings$preStudyArchiveName)
  message("Pre-study queries exported to ", file.path(settings$outputFolder, "prestudy_queries"))
}, error = function(e) {
  message("Pre-study export skipped: ", e$message)
})

connection <- DatabaseConnector::connect(connectionDetails)
on.exit(try(DatabaseConnector::disconnect(connection), silent = TRUE), add = TRUE)

source("R/01_artemis.R")            # (a)
source("R/02_eligibility_inputs.R") # (b)
source("R/03_main_cohorts.R")       # (c)
source("R/04_lab_ranges.R")         # (d) lab test ranges on main cohorts
source("R/05_eligibility_coverage.R") # eligibility-input counts + Target 1A coverage
source("R/06_artemis_assessment.R") # ARTEMIS alignment assessment (uses artemisResult)
source("R/07_demographics.R")       # per-cohort demographics (age / sex / index year)
source("R/08_covariates.R")         # covariate overlap with 1A (comorbidities + PS)

message("\n=== Done. Results under ", settings$outputFolder, "/csv/ ===")
