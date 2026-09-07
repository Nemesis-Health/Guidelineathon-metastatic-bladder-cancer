# ===========================================================================
# run_cohort_diagnostics.R  —  OHDSI CohortDiagnostics on the main cohorts
# ===========================================================================
# Generates the 00_ARTEMIS + 01_Target JSON cohorts (cohorts/00_ARTEMIS/,
# cohorts/01_Target/ — same cohorts 03_main_cohorts.R draws its JSON half
# from) into their own work table, then runs CohortDiagnostics::
# executeDiagnostics() over them: inclusion statistics, included source
# concepts, orphan concepts, visit context, index-event breakdown, incidence
# rates, cohort relationship, and temporal characterization.
#
# Independent of run.R / run_feasibility_only.R — it does not touch
# ARTEMIS regimen alignment, the SQL-templated cohorts (initiated base,
# eligibility 2a-2e/3a-3e, ...), or any of the numbered outcome/adherence
# steps, and writes to its own cohort table (settings$cohortTable below,
# default "bc_cohort_diagnostics") so it can't clobber a cohort table
# already populated by a full run.R pass in the same work schema.
#
# Usage: edit the CONFIG block below, then  source("run_cohort_diagnostics.R")
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

  # FALSE skips (re)generating the cohort table and assumes cohortTable
  # already holds subjects for cohortId 1..7 matching cohortDefinitionSet
  # below (00_ARTEMIS then 01_Target, in that order) -- e.g. a table this
  # same script generated on an earlier run. It is NOT safe to point this at
  # run.R's own bc_cohort: step (c) (R/03_main_cohorts.R) regenerates that
  # table with dropTables = TRUE for the Target tree alone, which drops the
  # 00_ARTEMIS scan cohort step (a) had generated into it -- so a post-run.R
  # bc_cohort never holds both cohort sets at once.
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

source("R/vendor_utils.R")   # .getDbms, %||%
source("R/helpers.R")        # readJsonCohorts(), buildCohortSet(), generateCohorts()

connection <- DatabaseConnector::connect(connectionDetails)
.checkDbiPostgresBug(connection)

message("\n=== Cohort diagnostics: generating 00_ARTEMIS + 01_Target ===")

# Same two JSON directories 03_main_cohorts.R draws its JSON half from; read
# together (ARTEMIS first) so cohortId assignment stays deterministic.
jsonCohorts <- dplyr::bind_rows(
  readJsonCohorts(file.path(cohortsDir, "00_ARTEMIS")),
  readJsonCohorts(file.path(cohortsDir, "01_Target")))

# generateStats = TRUE: bakes Circe's inclusion-rule-statistics SQL into
# generation (harmless for ARTEMIS's cohort, which has no InclusionRules),
# which is what populates the cohort_inclusion* tables CohortDiagnostics'
# runInclusionStatistics reads back.
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

# All runXxx flags left at executeDiagnostics()'s own defaults (every check
# except runTimeSeries) -- pass e.g. runOrphanConcepts = FALSE here if a run
# is taking too long on a large CDM.
CohortDiagnostics::executeDiagnostics(
  cohortDefinitionSet      = cohortDefinitionSet,
  exportFolder             = exportFolder,
  databaseId               = settings$databaseId,
  cohortDatabaseSchema     = settings$workDatabaseSchema,
  connection               = connection,
  cdmDatabaseSchema        = settings$cdmDatabaseSchema,
  vocabularyDatabaseSchema = settings$vocabDatabaseSchema,
  cohortTable              = settings$cohortTable,
  minCellCount             = settings$minCellCount)

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
