# ===========================================================================
# setup.R  —  packages, functions and derived config (do not edit)
# ===========================================================================
# Sourced by run.R after its CONFIG block. Loads the packages and function
# files the chosen runParts need, validates the CONFIG block, adds the fixed
# study settings (R/study_settings.R) and builds the paths + executionSettings
# object the steps rely on.
# ===========================================================================

runStudy <- "study" %in% runParts
stopifnot(length(runParts) > 0, all(runParts %in% c("diagnostics", "study")))

source("R/packages.R")
loadRequiredPackages(if (runStudy) requiredPackages else diagnosticsPackages)

# ARTEMIS must be ATTACHED (not just loaded via `::`): loadRegimens() does
# data("regimens", package = "ARTEMIS", envir = regimens_env) internally, but
# then checks exists("regimens") without envir = regimens_env, so the check
# only succeeds when package:ARTEMIS is already on the search path.
if (runStudy) suppressMessages(library(ARTEMIS))

source("R/db_compat.R")    # .getDbms(), %||%, checkConnection()
source("R/sql.R")          # runSqlFile(), querySqlFile(), renderSqlFile()
source("R/pipeline.R")     # pipelineStages, runStage(), saveState()/loadState(), zipResults()
if (runStudy) {
  source("R/cohorts.R")             # cohort generation, cohort ids, eligibility test ids
  source("R/outputs.R")             # strata, writeResultCsv(), folder READMEs
  source("R/artemis.R")             # vendored: runArtemis(), writeArtemisEpisodes(), ...
  source("R/artemis_uncaptured.R")  # uncapturedExposures(), plotUncapturedAlignment()
  source("R/time_to_event.R")       # computeTimeToEvent(), computeTimeDiffStats(), extractSurvivalMilestones()
  source("R/treatment_lines.R")     # fetchDeathEvents(), treatedLines(), buildLineOfTherapyEvents(), ...
  source("R/guideline_adherence.R") # computeGuidelineRelevance(), computeAdherenceCrosstab(), computeAdherenceRollup()
  source("R/charlson.R")            # computeCharlsonScore(), charlsonComponents()
}

# --- CONFIG checks ------------------------------------------------------------
if (is.null(connectionDetails))
  stop("Define `connectionDetails` in run.R's CONFIG block before running.",
       call. = FALSE)
stopifnot(nzchar(settings$cdmDatabaseSchema))
if (runStudy)
  stopifnot(nzchar(settings$databaseId), nzchar(settings$workDatabaseSchema))

if (!nzchar(settings$vocabDatabaseSchema))
  settings$vocabDatabaseSchema <- settings$cdmDatabaseSchema

projectRoot <- normalizePath(".", mustWork = FALSE)
sqlDir      <- file.path(projectRoot, "sql")
dir.create(settings$outputFolder, recursive = TRUE, showWarnings = FALSE)

if (runStudy) {
  # fixed study settings; a field the site set in its own settings list wins
  source("R/study_settings.R")
  settings <- utils::modifyList(studySettings, settings)

  # work table names come from the run script's own settings list
  workTables <- c("cohortTable", "labCohortTable", "rawLabResultsTable",
                  "covariateCohortTable", "artemisCohortName", "episodeTable",
                  "regimenClassTable")
  missingTables <- workTables[!vapply(workTables, function(f)
    is.character(settings[[f]]) && nzchar(settings[[f]]), logical(1))]
  if (length(missingTables))
    stop("Set these work table names in the settings list in run.R: ",
         paste(missingTables, collapse = ", "), call. = FALSE)

  stopifnot(settings$labValueSelection %in% c("closest", "any"))

  cohortsDir <- file.path(projectRoot, "cohorts")
  extrasDir  <- file.path(cohortsDir, "extras")

  # Resumable-state checkpoints (saveState()/loadState(), R/pipeline.R) hold
  # patient-level intermediates (ARTEMIS episodes/alignments, drug exposures) --
  # unlike outputFolder's CSVs/zips, which are aggregate and privacy-censored,
  # these are never meant to be shared, so they live in a separate .cache/
  # folder rather than inside the output folder a site would zip up. Keyed by
  # outputFolder's own name so a fresh outputFolder (e.g. a "clean" re-run)
  # never silently resumes from a previous run's cached state.
  if (is.null(settings$stateFolder))
    settings$stateFolder <- file.path(".cache", basename(settings$outputFolder))
  dir.create(settings$stateFolder, recursive = TRUE, showWarnings = FALSE)

  # One README.md per results/eligibility/<category>/ subfolder, excerpted
  # verbatim from this repo's own README.md (writeCategoryReadmes(), R/outputs.R)
  # -- written once up front so the folders are self-documenting even before
  # any step writes a CSV into them.
  writeCategoryReadmes()

  # executionSettings object compatible with the vendored runArtemis()
  # (it reads cdm/vocab/work schema, cohortTable, connectionDetails, artemisSettings
  #  and checks class "OsmExecutionSettings").
  artemisSettings <- structure(
    list(cohortTable = settings$cohortTable, episodeTable = settings$episodeTable),
    class = "OsmArtemisSettings"
  )
  executionSettings <- structure(
    list(
      connectionDetails   = connectionDetails,
      cdmDatabaseSchema   = settings$cdmDatabaseSchema,
      vocabDatabaseSchema = settings$vocabDatabaseSchema,
      workDatabaseSchema  = settings$workDatabaseSchema,
      cohortTable         = settings$cohortTable,
      databaseId          = settings$databaseId,
      minCellCount        = settings$minCellCount,
      artemisSettings     = artemisSettings
    ),
    class = "OsmExecutionSettings"
  )
}
