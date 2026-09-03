# ===========================================================================
# setup.R  —  derived config objects (do not edit)
# ===========================================================================
# Validates the CONFIG block in run.R and builds the paths + executionSettings
# object the numbered steps rely on. Sourced by run.R at global scope.
# ===========================================================================

if (is.null(connectionDetails))
  stop("Define `connectionDetails` in run.R's CONFIG block before running.",
       call. = FALSE)
stopifnot(nzchar(settings$databaseId),
          nzchar(settings$cdmDatabaseSchema), nzchar(settings$workDatabaseSchema))

if (!nzchar(settings$vocabDatabaseSchema))
  settings$vocabDatabaseSchema <- settings$cdmDatabaseSchema

# default the endocrine-therapy strip ON for site configs predating the option
if (is.null(settings$stripEndocrineTherapy))
  settings$stripEndocrineTherapy <- TRUE

# default the validDrugs restriction for configs predating the options:
# regimen-component filter ON, ATC filter OFF (see run.R for why)
if (is.null(settings$validDrugsRegimenComponents))
  settings$validDrugsRegimenComponents <- TRUE
if (is.null(settings$validDrugsAtcClasses))
  settings$validDrugsAtcClasses <- character(0)

# default the age/sex strata columns ON (all three) for configs predating
# the option -- character(0) (all strata off) is a deliberate site choice,
# not a missing setting, so only NULL (the field doesn't exist at all) gets
# defaulted here.
if (is.null(settings$strataColumns))
  settings$strataColumns <- c("age_group", "sex", "age_sex")

projectRoot <- normalizePath(".", mustWork = FALSE)
sqlDir      <- file.path(projectRoot, "sql")
cohortsDir  <- file.path(projectRoot, "cohorts")
extrasDir   <- file.path(cohortsDir, "extras")
dir.create(settings$outputFolder, recursive = TRUE, showWarnings = FALSE)

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
