# ===========================================================================
# setup.R  —  derived config objects (do not edit)
# ===========================================================================
# Validates the CONFIG block in run.R, adds the fixed study settings
# (R/study_settings.R) and builds the paths + executionSettings object the
# numbered steps rely on. Sourced by run.R at global scope.
# ===========================================================================

if (is.null(connectionDetails))
  stop("Define `connectionDetails` in run.R's CONFIG block before running.",
       call. = FALSE)
stopifnot(nzchar(settings$databaseId),
          nzchar(settings$cdmDatabaseSchema), nzchar(settings$workDatabaseSchema))

if (!nzchar(settings$vocabDatabaseSchema))
  settings$vocabDatabaseSchema <- settings$cdmDatabaseSchema

# fixed study settings; a field the site set in its own settings list wins
source("R/study_settings.R")
settings <- utils::modifyList(studySettings, settings)

stopifnot(settings$labValueSelection %in% c("closest", "any"))

projectRoot <- normalizePath(".", mustWork = FALSE)
sqlDir      <- file.path(projectRoot, "sql")
cohortsDir  <- file.path(projectRoot, "cohorts")
extrasDir   <- file.path(cohortsDir, "extras")
dir.create(settings$outputFolder, recursive = TRUE, showWarnings = FALSE)

# Resumable-state checkpoints (saveState()/loadState(), R/helpers.R) hold
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
# verbatim from this repo's own README.md (writeCategoryReadmes(), R/helpers.R)
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
