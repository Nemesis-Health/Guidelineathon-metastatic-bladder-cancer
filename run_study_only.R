# ===========================================================================
# run_study_only.R  —  study pipeline only
# ===========================================================================
# Complement of run_diagnostics_only.R: runs everything in run.R EXCEPT the
# pre-study diagnostics stage (0). Together, run_diagnostics_only.R +
# run_study_only.R cover exactly what run.R does.
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
# Use this once ARTEMIS is sorted (see README.md) if you already have
# diagnostics results from run_diagnostics_only.R and just need the
# study results now — no need to re-run diagnostics.
#
# Usage: edit the CONFIG block below, then  source("run_study_only.R")
# Requires: the packages in R/packages.R (checked and loaded at start; NOT
#           OncoStudyModules).
# ===========================================================================

source("R/packages.R")
loadRequiredPackages()

suppressMessages(library(ARTEMIS))

# ===========================================================================
# CONFIG  [EDIT HERE]  — same as run.R
# ===========================================================================

# --- Database connection ----------------------------------------------------
# Same as run.R — see README.md's Requirements section for examples.
connectionDetails <- NULL   # <-- REPLACE with your connection

# --- Bulk load ----------------------------------------------------------------
# Faster table writes on Redshift; needs extra setup -- see README.md "Optional: bulk load".
Sys.setenv(DATABASE_CONNECTOR_BULK_UPLOAD = FALSE)

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

  # --- Run settings -- full detail on all of these in README.md's CONFIG settings reference ---
  minCellCount        = 5L,
  labWindowBeforeDays = 30L,   # near-index eligibility inputs (labs, ECOG/PS): days before index
  labWindowAfterDays  = 30L,   # same, days after index
  labValueSelection   = "closest",   # eligibility labs/ECOG: "closest" result to index decides; "any" passing result in the window
  treatedLabWindowBeforeDays = 30L,   # same inputs for cohorts indexed on treatment start (initiated bases, T3-T6): days before
  treatedLabWindowAfterDays  = 0L,    # same, days after (0 = up to and including the start date)
  conditionFlagWindowBeforeDays = 30L,    # condition flags (liver mets, neuropathy, ...): days before index a live record may end
  conditionFlagWindowAfterDays  = 30L,    # same, days after index
  bodyMeasurementsWindowDays = 90L,   # baseline weight/height/BMI: days before/after index
  stripEndocrineTherapy = TRUE,   # drop endocrine-therapy regimens from the ARTEMIS reference
  validDrugsRegimenComponents = TRUE,   # keep only drugs that appear in a kept regimen
  validDrugsAtcClasses = c("L01", "L02", "L03", "L04"),   # ATC classes kept in the alignment string
  assessmentAtcClasses = NULL,   # ATC classes kept in exposure assessment (step f); NULL mirrors the regimen filter above
  maintenanceMerge      = TRUE,  # fold maintenance (e.g. avelumab after platinum) into the line it maintains
  maintenanceMaxGapDays = 180L,  # max days from the earlier regimen's end to the maintenance start
  strataColumns = c("age_group", "sex", "age_sex",   # breakdowns reported on every stratified output
                    "age_band", "index_period", "index_period_2021"),
  outputFolder        = file.path("results")
)

# ===========================================================================
# Run  —  do not edit below
# ===========================================================================
source("R/vendor_utils.R")   # .getDbms, %||%
source("R/artemis.R")        # vendored: runArtemis(), writeArtemisEpisodes(), ...
source("R/artemis_uncaptured.R")  # uncapturedExposures(), plotUncapturedAlignment()
source("R/helpers.R")        # cohort generation + SQL utilities
source("R/timeToEvent.R")    # computeTimeToEvent(), computeTimeDiffStats()
source("R/survivalMilestones.R") # extractSurvivalMilestones()
source("R/eventBuilders.R")  # fetchDeathEvents(), treatedLines(), buildLineOfTherapyEvents(), anchorEpisodes(), combineEarliestEvent()
source("R/guidelineAdherence.R") # computeGuidelineRelevance(), computeAdherenceRollup()
source("R/charlsonScore.R")  # computeCharlsonScore(), charlsonComponents()
source("R/setup.R")          # config checks + derived paths + executionSettings

connection <- DatabaseConnector::connect(connectionDetails)
checkConnection(connection)

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

utils::zip(zipfile = file.path(settings$outputFolder, "study_results.zip"), files = list.files(file.path(settings$outputFolder, "eligibility"), recursive = TRUE, full.names = TRUE, include.dirs = TRUE, all.files = TRUE), flags = "-q")

message("Wrote study_results.zip to ", settings$outputFolder)

DatabaseConnector::disconnect(connection)
