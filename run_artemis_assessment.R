# ===========================================================================
# run_artemis_assessment.R — regenerate ONLY the stratified ARTEMIS assessment
# ===========================================================================
# Produces the six artemis_*.csv with both cohort strata (scan_cohort +
# target_1a) by running just the steps that feed R/06_artemis_assessment.R:
#
#   (a) R/01_artemis.R          -> artemisResult, artemisCounts, artemisCohortId
#   (b) R/02_eligibility_inputs.R  populates bc_lab_cohort (so (c) can generate)
#   (c) R/03_main_cohorts.R     -> mainManifest + bc_cohort (incl. T1 = target_1a)
#   (f) R/06_artemis_assessment.R  writes the six artemis_*.csv, both strata
#
# Skips 04/05/07/08 (lab ranges, eligibility coverage, demographics, covariate
# overlap) — none of them feed step 06.
#
# Step (a) re-runs the ARTEMIS alignment (the slow part) UNLESS a saved
# results/artemis_result.rds is present AND you set useSavedArtemis <- TRUE
# below — see the note there for the prerequisites before trusting that path.
#
# Usage: fill the CONFIG block (identical to run.R — copy your run.R values),
#        then  source("run_artemis_assessment.R")
# ===========================================================================

for (p in c("DatabaseConnector", "SqlRender", "CohortGenerator", "CirceR",
            "ARTEMIS", "dplyr", "tibble", "readr")) {
  if (!requireNamespace(p, quietly = TRUE))
    stop("Required package not installed: ", p, call. = FALSE)
}

# ===========================================================================
# CONFIG  [EDIT HERE — keep identical to your run.R]
# ===========================================================================

connectionDetails <- NULL   # <-- REPLACE with your connection (see run.R)

settings <- list(
  databaseId          = "",
  cdmDatabaseSchema   = "",
  vocabDatabaseSchema = "",
  workDatabaseSchema  = "",

  cohortTable          = "bc_cohort",
  labCohortTable       = "bc_lab_cohort",
  rawLabResultsTable   = "bc_raw_lab_results",
  covariateCohortTable = "bc_covariate_cohort",
  artemisCohortName    = "ARTEMIS bladder cohort",
  episodeTable         = "bc_artemis_episodes",
  regimenClassTable    = "bc_regimen_classifications",

  minCellCount        = 5L,
  labIndexWindowDays  = 14L,
  stripEndocrineTherapy = TRUE,
  validDrugsRegimenComponents = TRUE,
  validDrugsAtcClasses = character(0),
  assessmentAtcClasses = NULL,
  outputFolder        = file.path("results")
)

# Fast path: skip the ARTEMIS re-alignment and load a previously saved
# results/artemis_result.rds instead. Only works if that file exists AND the
# work schema still holds this study's bc_regimen_classifications table (needed
# by step (c)'s 4/5/6 splits). With no RDS present, this run must re-align, so
# leave this FALSE. When TRUE the scan_cohort summary's "scan cohort subjects"
# count is unavailable (artemisCounts is not saved) and shows as blank/NA.
useSavedArtemis <- FALSE

# ===========================================================================
# Run  —  do not edit below
# ===========================================================================
source("R/vendor_utils.R")
source("R/artemis.R")
source("R/artemis_uncaptured.R")
source("R/helpers.R")
source("R/setup.R")

connection <- DatabaseConnector::connect(connectionDetails)
on.exit(try(DatabaseConnector::disconnect(connection), silent = TRUE), add = TRUE)

rdsPath <- file.path(settings$outputFolder, "artemis_result.rds")
if (isTRUE(useSavedArtemis) && file.exists(rdsPath)) {
  message("== (a) loading saved ARTEMIS result (skipping re-alignment) ==")
  artemisResult <- readRDS(rdsPath)
} else {
  if (isTRUE(useSavedArtemis))
    message("useSavedArtemis=TRUE but ", rdsPath, " not found — re-aligning.")
  source("R/01_artemis.R")            # (a) ARTEMIS alignment
}

source("R/02_eligibility_inputs.R")   # (b) populate bc_lab_cohort
source("R/03_main_cohorts.R")         # (c) main tree incl. T1 -> mainManifest
source("R/06_artemis_assessment.R")   # (f) stratified ARTEMIS assessment

message("\n=== Done. artemis_*.csv (scan_cohort + target_1a) under ",
        settings$outputFolder, "/csv/ ===")
