# ===========================================================================
# run.R  —  Bladder study (standalone; no OncoStudyModules dep)
# ===========================================================================
# Runs diagnostics + the study pipeline in one go. To run either half
# on its own (e.g. diagnostics now, the study pipeline once ARTEMIS is sorted), use
# run_diagnostics_only.R and run_study_only.R instead — together they do
# exactly what this file does.
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
#   (k) baseline body measurements + Charlson CCI -> R/11_baseline_characterization.R
#   (l) treatment patterns by LoT             -> R/12_treatment_patterns.R
#   (m) lab coverage by comorbidity subgroup  -> R/13_covariate_lab_coverage.R
#   (n) condition-code record provenance     -> R/14_provenance.R
#   (o) condition + drug roll-ups            -> R/15_rollups.R
#
# Usage: edit the CONFIG block below, then  source("run.R")
# Requires: the packages in R/packages.R (checked and loaded at start; NOT
#           OncoStudyModules).
# ===========================================================================

source("R/packages.R")
loadRequiredPackages()

# ARTEMIS must be ATTACHED (not just loaded via `::`): loadRegimens() does
# data("regimens", package = "ARTEMIS", envir = regimens_env) internally, but
# then checks exists("regimens") without envir = regimens_env, so the check
# only succeeds when package:ARTEMIS is already on the search path.
suppressMessages(library(ARTEMIS))

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
source("R/eventBuilders.R")  # fetchDeathEvents(), treatedLines(), buildLineOfTherapyEvents(), anchorEpisodes(), combineEarliestEvent()
source("R/guidelineAdherence.R") # computeGuidelineRelevance(), computeAdherenceCrosstab(), computeAdherenceRollup()
source("R/charlsonScore.R")  # computeCharlsonScore(), charlsonComponents()
source("R/setup.R")          # config checks + derived paths + executionSettings

connection <- DatabaseConnector::connect(connectionDetails)
checkConnection(connection)

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
source("R/13_covariate_lab_coverage.R") # lab coverage by comorbidity subgroup (Target 1A)
source("R/14_provenance.R")         # record provenance of Target 1A condition codes
source("R/15_rollups.R")            # condition + drug roll-ups (concept-based baseline comorbidities)

message("\n=== Done. Results under ", settings$outputFolder, "/eligibility/ ===")

utils::zip(zipfile = file.path(settings$outputFolder, "diagnostics.zip"), files = list.files(file.path(settings$outputFolder, "diagnostics"), recursive = TRUE, full.names = TRUE, include.dirs = TRUE, all.files = TRUE), flags = "-q")
utils::zip(zipfile = file.path(settings$outputFolder, "study_results.zip"), files = list.files(file.path(settings$outputFolder, "eligibility"), recursive = TRUE, full.names = TRUE, include.dirs = TRUE, all.files = TRUE), flags = "-q")

message("Wrote diagnostics.zip and study_results.zip to ", settings$outputFolder)

DatabaseConnector::disconnect(connection)
