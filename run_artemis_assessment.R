# ===========================================================================
# run_artemis_assessment.R — regenerate ONLY the stratified ARTEMIS assessment
# ===========================================================================
# Produces the six artemis_*.csv with both cohort strata (scan_cohort +
# target_1a) from R/06_artemis_assessment.R.
#
# TWO MODES, chosen automatically by whether the saved RDS exists:
#
#   FAST (RDS present) — load a saved artemisResult and run ONLY step 06.
#     No re-alignment, no 02/03. Requires that the bc_cohort table from your
#     earlier run still holds the "T1 Metastatic bladder cancer" cohort (it is
#     queried live for the target_1a subject set), and that you set
#     target1aCohortId below to that cohort's id.
#
#   FULL (no RDS) — run 01 -> 02 -> 03 -> 06 (re-aligns; the slow path).
#
# Usage: fill the CONFIG block (connection + schemas identical to run.R), point
#        artemisResultPath at your saved RDS, then source this file.
# ===========================================================================

for (p in c("DatabaseConnector", "SqlRender", "CohortGenerator", "CirceR",
            "ARTEMIS", "dplyr", "tibble", "readr")) {
  if (!requireNamespace(p, quietly = TRUE))
    stop("Required package not installed: ", p, call. = FALSE)
}

# ===========================================================================
# CONFIG  [EDIT HERE — connection + schemas identical to your run.R]
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

# --- FAST-mode inputs ------------------------------------------------------
# Path to your saved full artemisResult (the object returned by runArtemis()).
# If this file exists, FAST mode is used; otherwise the script falls back to
# the FULL re-alignment pipeline.
artemisResultPath <- file.path(settings$outputFolder, "artemis_result.rds")

# cohort_definition_id of "T1 Metastatic bladder cancer" in your bc_cohort
# table (the target_1a stratum). Read it off your cohort_counts.csv — it was 2
# in the bladder6 run. FAST mode queries bc_cohort for this id.
target1aCohortId <- 2L

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

if (file.exists(artemisResultPath)) {
  message("== FAST mode: loading ", artemisResultPath, " (step 06 only) ==")
  artemisResult <- readRDS(artemisResultPath)
  # Minimal manifest so 06 can resolve the target_1a cohort id by name; the
  # subject set itself is queried live from the existing bc_cohort table.
  mainManifest <- tibble::tibble(cohortId = as.integer(target1aCohortId),
                                 cohortName = "T1 Metastatic bladder cancer")
  # artemisCounts / artemisCohortId are intentionally absent here: 06 guards on
  # exists() and simply reports the scan_cohort subject count as NA and derives
  # target_1a's scan count from the T1 subject set. Everything else is exact.
} else {
  message("== FULL mode: no ", artemisResultPath, " — running 01->02->03 ==")
  source("R/01_artemis.R")            # (a) ARTEMIS alignment
  source("R/02_eligibility_inputs.R") # (b) populate bc_lab_cohort
  source("R/03_main_cohorts.R")       # (c) main tree incl. T1 -> mainManifest
}

source("R/06_artemis_assessment.R")   # (f) stratified ARTEMIS assessment

message("\n=== Done. artemis_*.csv (scan_cohort + target_1a) under ",
        settings$outputFolder, "/csv/ ===")
