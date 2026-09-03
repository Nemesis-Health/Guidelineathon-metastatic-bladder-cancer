# ===========================================================================
# 00_prestudy_queries.R — pre-study characterization queries
# ===========================================================================
# Runs the mirrored onco-pre-study characterization queries (sql/prestudy/,
# committed in this repo) against the live connection and writes one CSV per
# chunk to results/diagnostics/.
# ===========================================================================

# Executes the mirrored onco-pre-study characterization queries
# (sql/prestudy/chunks/*.sql) against the live connection and writes one CSV
# per chunk into settings$outputFolder/diagnostics. 00_setup.sql builds the
# shared `#`-prefixed temp tables every other chunk reads, so it must run
# first and on the same connection/session as the result chunks.
runPreStudyDiagnostics <- function(connection, settings) {
  chunkDir <- file.path("prestudy", "chunks")
  allChunks <- sort(list.files(file.path(sqlDir, chunkDir), pattern = "\\.sql$"))
  setupFile <- "00_setup.sql"
  resultChunks <- setdiff(allChunks, setupFile)

  diagDir <- file.path(settings$outputFolder, "diagnostics")
  dir.create(diagDir, recursive = TRUE, showWarnings = FALSE)

  message("Running pre-study setup (00_setup.sql) ...")
  runSqlFile(connection, file.path(chunkDir, setupFile),
             cdm_database_schema = settings$cdmDatabaseSchema,
             min_cell_count      = settings$minCellCount)

  for (f in resultChunks) {
    message(sprintf("Running %s", f))
    result <- querySqlFile(connection, file.path(chunkDir, f),
                            cdm_database_schema = settings$cdmDatabaseSchema,
                            min_cell_count      = settings$minCellCount)
    readr::write_csv(result, file.path(diagDir, sub("\\.sql$", ".csv", f)), na = "")
  }

  invisible(diagDir)
}

