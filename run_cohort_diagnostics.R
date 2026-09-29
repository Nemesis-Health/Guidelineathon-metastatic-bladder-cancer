# ===========================================================================
# run_cohort_diagnostics.R  —  OHDSI CohortDiagnostics on the main cohorts
# ===========================================================================
# Generates the 01_Target JSON cohorts (cohorts/01_Target/) into their own work table, then runs CohortDiagnostics::
# executeDiagnostics() over them: inclusion statistics, included source
# concepts, orphan concepts, visit context, index-event breakdown, and cohort
# relationship.
#
# Usage: edit the CONFIG block below
# Requires: DatabaseConnector, SqlRender, CohortGenerator, CirceR,
#           CohortDiagnostics, dplyr, tibble, readr  (installed).
# ===========================================================================

for (p in c("DatabaseConnector", "SqlRender", "CohortGenerator", "CirceR",
            "CohortDiagnostics", "dplyr", "tibble", "readr")) {
  if (!requireNamespace(p, quietly = TRUE))
    stop("Required package not installed: ", p, call. = FALSE)
}

# ===========================================================================
# CONFIG  [EDIT HERE]
# ===========================================================================

# --- Database connection ----------------------------------------------------
# Same as run.R — see that file's CONFIG block for JDBC / DBI examples.
connectionDetails <- NULL   # <-- REPLACE with your connection

# --- Site + OMOP CDM schemas ------------------------------------------------
settings <- list(
  databaseId          = "",   # short site id, e.g. "HUS"
  cdmDatabaseSchema   = "",
  vocabDatabaseSchema = "",    # defaults to cdmDatabaseSchema if blank
  workDatabaseSchema  = "",    # where the diagnostics cohort table is written

  cohortTable  = "bc_cohort_diagnostics",
  minCellCount = 5L,
  outputFolder = file.path("results"),
  regenerateCohorts = TRUE
)

# ===========================================================================
# Run  —  do not edit below
# ===========================================================================

if (is.null(connectionDetails))
  stop("Define `connectionDetails` in the CONFIG block before running.", call. = FALSE)
stopifnot(nzchar(settings$databaseId), nzchar(settings$cdmDatabaseSchema),
          nzchar(settings$workDatabaseSchema))
if (!nzchar(settings$vocabDatabaseSchema))
  settings$vocabDatabaseSchema <- settings$cdmDatabaseSchema

projectRoot <- normalizePath(".", mustWork = FALSE)
cohortsDir  <- file.path(projectRoot, "cohorts")
dir.create(settings$outputFolder, recursive = TRUE, showWarnings = FALSE)

source("R/vendor_utils.R")   # .getDbms, %||%, upstream-bug patches
source("R/helpers.R")        # readJsonCohorts(), buildCohortSet(), generateCohorts(), runCohortDiagnostics()

connection <- DatabaseConnector::connect(connectionDetails)
.checkDbiPostgresBug(connection)

message("\n=== Cohort diagnostics: generating 01_Target ===")

jsonCohorts <- dplyr::bind_rows(
  readJsonCohorts(file.path(cohortsDir, "01_Target")))
cohortDefinitionSet <- buildCohortSet(jsonCohorts = jsonCohorts, startId = 1L,
                                       generateStats = TRUE)

if (settings$regenerateCohorts) {
  generateCohorts(connection, cohortDefinitionSet, dropTables = TRUE,
                  cohortTable = settings$cohortTable)
} else {
  message("Skipping generation (settings$regenerateCohorts = FALSE) -- using ",
          "subjects already in ", settings$workDatabaseSchema, ".",
          settings$cohortTable)
}

message("\n=== Cohort diagnostics: running CohortDiagnostics::executeDiagnostics() ===")

exportFolder <- file.path(settings$outputFolder, "cohort_diagnostics")
dir.create(exportFolder, recursive = TRUE, showWarnings = FALSE)

runCohortDiagnostics(
  connection               = connection,
  cohortDefinitionSet      = cohortDefinitionSet,
  exportFolder             = exportFolder,
  databaseId               = settings$databaseId,
  cohortDatabaseSchema     = settings$workDatabaseSchema,
  cdmDatabaseSchema        = settings$cdmDatabaseSchema,
  vocabularyDatabaseSchema = settings$vocabDatabaseSchema,
  cohortTable              = settings$cohortTable,
  minCellCount             = settings$minCellCount,
  runIncidenceRate                  = FALSE,
  runTemporalCohortCharacterization = FALSE)

utils::zip(zipfile = file.path(settings$outputFolder, "cohort_diagnostics.zip"),
           files = list.files(exportFolder, recursive = TRUE, full.names = TRUE,
                              include.dirs = TRUE, all.files = TRUE),
           flags = "-q")

message("\n=== Done. Results under ", exportFolder, " ===")
message("Wrote cohort_diagnostics.zip to ", settings$outputFolder)
message("To browse interactively: CohortDiagnostics::createMergedResultsFile(dataFolder = \"",
        exportFolder, "\", sqliteDbPath = \"MergedCohortDiagnosticsData.sqlite\") ",
        "then CohortDiagnostics::launchDiagnosticsExplorer(sqliteDbPath = \"MergedCohortDiagnosticsData.sqlite\")")

DatabaseConnector::disconnect(connection)
