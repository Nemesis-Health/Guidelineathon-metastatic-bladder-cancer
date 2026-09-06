# ===========================================================================
# run_diagnostics_only.R  —  pre-study diagnostics only (no ARTEMIS needed)
# ===========================================================================
# Runs just the diagnostics stage (R/00_prestudy_queries.R) against the OMOP
# CDM and stops there — it does NOT touch ARTEMIS, CohortGenerator, or CirceR,
# and does not run any of the numbered eligibility steps (01-08).
#
# Use this if you're stuck on the ARTEMIS/Python setup (see README.md) but
# want the pre-study diagnostics results now; run the full `run.R` later once
# ARTEMIS is sorted.
#
# Usage: edit the CONFIG block below, then  source("run_diagnostics_only.R")
# Requires: DatabaseConnector, SqlRender, dplyr, readr  (installed).
# ===========================================================================

for (p in c("DatabaseConnector", "SqlRender", "dplyr", "readr")) {
  if (!requireNamespace(p, quietly = TRUE))
    stop("Required package not installed: ", p, call. = FALSE)
}

# ===========================================================================
# CONFIG  [EDIT HERE]
# ===========================================================================

# --- Database connection ----------------------------------------------------
# Same as run.R — see that file's CONFIG block for JDBC / DBI examples.
connectionDetails <- DatabaseConnector::createConnectionDetails(
  dbms             = "bigquery",
  connectionString = paste0(
    "jdbc:bigquery://https://www.googleapis.com/bigquery/v2:443;",
    "ProjectId=omop-test-data;OAuthType=0;",
    "OAuthServiceAcctEmail=omop-bigquery@omop-test-data.iam.gserviceaccount.com;",
    "OAuthPvtKeyPath=", path.expand("~/.bigquery_service_account.json"), ";",
    "EnableSession=1;Location=EU;"),
  user         = "",
  password     = "",
  pathToDriver = path.expand("~/.jdbc_drivers"))
options(sqlRenderTempEmulationSchema = "results")

# --- Site + OMOP CDM schema --------------------------------------------------
settings <- list(
  cdmDatabaseSchema = "cdm",   # OMOP CDM schema the diagnostics queries read
  minCellCount      = 5L,
  outputFolder      = file.path("results", "BIGQUERY_diag_smoketest")
)

# ===========================================================================
# Run  —  do not edit below
# ===========================================================================

if (is.null(connectionDetails))
  stop("Define `connectionDetails` in the CONFIG block before running.", call. = FALSE)
stopifnot(nzchar(settings$cdmDatabaseSchema))

projectRoot <- normalizePath(".", mustWork = FALSE)
sqlDir      <- file.path(projectRoot, "sql")
dir.create(settings$outputFolder, recursive = TRUE, showWarnings = FALSE)

source("R/vendor_utils.R")   # .getDbms, %||%
source("R/00_prestudy_queries.R")   # runPreStudyDiagnostics()

# helpers.R also defines cohort-generation functions that need
# CohortGenerator/CirceR, but those packages are only required if those
# functions are actually called; runSqlFile()/querySqlFile() (used below)
# only need SqlRender + DatabaseConnector, so sourcing this file is safe here.
source("R/helpers.R")

connection <- DatabaseConnector::connect(connectionDetails)
.checkDbiPostgresBug(connection)

message("\n=== Diagnostics: pre-study characterization queries ===")
runPreStudyDiagnostics(connection, settings)

utils::zip(zipfile = file.path(settings$outputFolder, "diagnostics.zip"), files = list.files(file.path(settings$outputFolder, "diagnostics"), recursive = TRUE, full.names = TRUE, include.dirs = TRUE, all.files = TRUE), flags = "-q")

message("\n=== Done. Results under ", settings$outputFolder, "/diagnostics/ ===")
message("Wrote diagnostics.zip to ", settings$outputFolder)

DatabaseConnector::disconnect(connection)
