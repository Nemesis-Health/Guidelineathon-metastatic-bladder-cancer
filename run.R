# ===========================================================================
# run.R  —  FALCON-Bladder study (standalone; no OncoStudyModules dep)
# ===========================================================================
# Runs two parts, chosen with `runParts` in the CONFIG block:
#   diagnostics  pre-study characterization queries on the CDM
#                -> results/diagnostics/, diagnostics.zip
#                Needs no ARTEMIS, CohortGenerator or CirceR.
#   study        the study pipeline: cohorts, then characterization, labs,
#                ARTEMIS assessment, outcomes, guideline adherence and
#                treatment patterns -> results/eligibility/, study_results.zip
#
# The steps are the scripts in R/steps/; R/pipeline.R lists them by stage.
#
# Usage: edit the CONFIG block below, then  source("run.R")
# Requires: the packages in R/packages.R (checked and loaded at start; NOT
#           OncoStudyModules).
# ===========================================================================

# ===========================================================================
# CONFIG  [EDIT HERE]
# ===========================================================================

# --- Database connection ----------------------------------------------------
# Define however your site connects -- see README.md's Requirements section for examples.
connectionDetails <- NULL   # <-- REPLACE with your connection

# --- Bulk load ----------------------------------------------------------------
# Faster table writes on Redshift; needs extra setup -- see README.md "Optional: bulk load".
Sys.setenv(DATABASE_CONNECTOR_BULK_UPLOAD = FALSE)

# --- Site + OMOP CDM schemas ------------------------------------------------
# Work table names, time windows, ARTEMIS filters and strata are fixed for
# every site and live in R/study_settings.R; don't change them unless the
# study team asks (see that file for how).
settings <- list(
  databaseId          = "",   # short site id, e.g. "HUS"
  cdmDatabaseSchema   = "",
  vocabDatabaseSchema = "",    # defaults to cdmDatabaseSchema if blank
  workDatabaseSchema  = "",    # where cohort + lab + episode tables are written
  minCellCount        = 5L,    # counts below this are censored in every output
  outputFolder        = file.path("results")
)

# --- What to run --------------------------------------------------------------
# Both by default. c("diagnostics") alone if ARTEMIS isn't set up yet;
# c("study") alone to skip diagnostics you have already run.
runParts <- c("diagnostics", "study")

# ===========================================================================
# Run  —  do not edit below
# ===========================================================================
source("R/setup.R")   # packages, functions, config checks, derived settings

connection <- DatabaseConnector::connect(connectionDetails)
checkConnection(connection, writesTables = runStudy)

if ("diagnostics" %in% runParts) {
  runStage("diagnostics")
  zipResults("diagnostics")
}

if (runStudy) {
  for (stage in studyStages) runStage(stage)
  zipResults("study")
}

DatabaseConnector::disconnect(connection)
message("\n=== Done. Results under ", settings$outputFolder, " ===")
