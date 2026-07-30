# ===========================================================================
# 00_prestudy_queries.R — package external onco-pre-study query assets
# ===========================================================================
# Copies the latest onco-pre-study query-related assets into the study results
# folder and writes a zip archive for downstream sharing.
# ===========================================================================

exportPreStudyQueries <- function(projectRoot = NULL, outputFolder = NULL) {
  getSetting <- function(name, default = NULL) {
    if (exists("settings", mode = "list") && !is.null(settings[[name]])) {
      settings[[name]]
    } else {
      default
    }
  }

  if (is.null(projectRoot) || !nzchar(projectRoot)) {
    projectRoot <- if (!is.null(getSetting("preStudyProjectRoot")) && nzchar(getSetting("preStudyProjectRoot"))) {
      getSetting("preStudyProjectRoot")
    } else {
      normalizePath(getwd(), mustWork = FALSE)
    }
  }
  if (is.null(outputFolder) || !nzchar(outputFolder)) {
    outputFolder <- getSetting("outputFolder", file.path("results"))
  }

  projectRoot <- normalizePath(projectRoot, mustWork = FALSE)
  outputFolder <- normalizePath(outputFolder, mustWork = FALSE)
  repoRoot <- normalizePath(getwd(), mustWork = FALSE)

  stagingDir <- file.path(outputFolder, "prestudy_queries")
  dir.create(stagingDir, recursive = TRUE, showWarnings = FALSE)

  manifest <- list()
  copyTargets <- c("README.md", "db_config.yaml", "run.R", "docs", "scripts", "sql")

  for (target in copyTargets) {
    src <- file.path(projectRoot, target)
    if (!file.exists(src)) next

    dest <- file.path(stagingDir, target)
    if (dir.exists(src)) {
      dir.create(dest, recursive = TRUE, showWarnings = FALSE)
      file.copy(src, dest, recursive = TRUE, overwrite = TRUE)
      files <- list.files(src, recursive = TRUE, full.names = TRUE, include.dirs = FALSE)
      if (length(files) > 0L) {
        relFiles <- sub(paste0("^", projectRoot, "/?"), "", files, fixed = TRUE)
        manifest[[length(manifest) + 1L]] <- data.frame(
          source_path = relFiles,
          destination_path = file.path(stagingDir, relFiles),
          stringsAsFactors = FALSE
        )
      }
    } else {
      dir.create(dirname(dest), recursive = TRUE, showWarnings = FALSE)
      file.copy(src, dest, overwrite = TRUE)
      manifest[[length(manifest) + 1L]] <- data.frame(
        source_path = target,
        destination_path = dest,
        stringsAsFactors = FALSE
      )
    }
  }

  if (length(manifest) == 0L) {
    writeLines(
      c("No onco-pre-study query assets were found.", paste("Searched:", projectRoot)),
      file.path(stagingDir, "README.txt")
    )
    manifest[[1L]] <- data.frame(
      source_path = "<none>",
      destination_path = file.path(stagingDir, "README.txt"),
      stringsAsFactors = FALSE
    )
  }

  manifestDf <- dplyr::bind_rows(manifest)
  readr::write_csv(manifestDf, file.path(stagingDir, "prestudy_query_manifest.csv"), na = "")

  # Mirror SQL Server queries into the study `sql/prestudy` folder so the
  # study can be self-contained. Only copy from an external onco-pre-study
  # checkout's `sql/sql_server`; if that isn't available, the repo-local
  # `sql/prestudy` bundle (committed separately) is used as-is.
  tryCatch({
    destSqlDir <- file.path(repoRoot, "sql", "prestudy")
    dir.create(destSqlDir, recursive = TRUE, showWarnings = FALSE)

    srcSqlDir <- file.path(projectRoot, "sql", "sql_server")

    if (dir.exists(srcSqlDir) &&
        normalizePath(srcSqlDir, mustWork = FALSE) != normalizePath(destSqlDir, mustWork = FALSE)) {
      sqlFiles <- list.files(srcSqlDir, pattern = "\\.sql$", full.names = TRUE, recursive = TRUE, include.dirs = FALSE)
      if (length(sqlFiles) > 0L) {
        for (sqlFile in sqlFiles) {
          relPath <- substring(sqlFile, nchar(srcSqlDir) + 2L)
          destFile <- file.path(destSqlDir, relPath)
          dir.create(dirname(destFile), recursive = TRUE, showWarnings = FALSE)
          file.copy(sqlFile, destFile, overwrite = TRUE)

          projRows <- data.frame(
            source_path = file.path("sql", "sql_server", relPath),
            destination_path = destFile,
            stringsAsFactors = FALSE
          )
          manifestDf <- dplyr::bind_rows(manifestDf, projRows)
        }
        readr::write_csv(manifestDf, file.path(stagingDir, "prestudy_query_manifest.csv"), na = "")
      }
    }
  }, error = function(e) {
    message("Warning: could not mirror SQL Server queries into project sql folder: ", e$message)
  })

  invisible(list(stagingDir = stagingDir, manifestPath = file.path(stagingDir, "prestudy_query_manifest.csv")))
}

zipPreStudyQueries <- function(outputFolder = NULL, archiveName = NULL) {
  if (is.null(outputFolder) || !nzchar(outputFolder)) outputFolder <- "results"
  outputFolder <- normalizePath(outputFolder, mustWork = FALSE)
  if (is.null(archiveName) || !nzchar(archiveName)) {
    archiveName <- "prestudy_queries.zip"
  }

  stagingDir <- file.path(outputFolder, "prestudy_queries")
  if (!dir.exists(stagingDir)) return(invisible(NULL))

  oldWd <- getwd()
  on.exit(setwd(oldWd), add = TRUE)
  setwd(stagingDir)
  filesToZip <- list.files(".", recursive = TRUE, include.dirs = TRUE, all.files = TRUE)
  filesToZip <- filesToZip[filesToZip != "."]
  if (length(filesToZip) > 0L) {
    utils::zip(zipfile = file.path(outputFolder, archiveName), files = filesToZip, flags = "-q")
  }

  invisible(file.path(outputFolder, archiveName))
}

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

if (exists("settings", mode = "list")) {
  outputFolder <- if (!is.null(settings$outputFolder) && nzchar(settings$outputFolder)) {
    settings$outputFolder
  } else {
    "results"
  }
  archiveName <- if (!is.null(settings$preStudyArchiveName) && nzchar(settings$preStudyArchiveName)) {
    settings$preStudyArchiveName
  } else {
    "prestudy_queries.zip"
  }
  exportPreStudyQueries(outputFolder = outputFolder)
  zipPreStudyQueries(outputFolder = outputFolder, archiveName = archiveName)
}

