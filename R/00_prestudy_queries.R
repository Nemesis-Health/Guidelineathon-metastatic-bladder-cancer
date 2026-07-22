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

stagePreStudyDiagnostics <- function(projectRoot = NULL, outputFolder = NULL) {
  if (is.null(outputFolder) || !nzchar(outputFolder)) outputFolder <- "results"
  outputFolder <- normalizePath(outputFolder, mustWork = FALSE)
  stageDir <- file.path(outputFolder, "diagnostics")
  dir.create(stageDir, recursive = TRUE, showWarnings = FALSE)

  candidateRoots <- c()
  if (!is.null(projectRoot) && nzchar(projectRoot)) {
    candidateRoots <- c(candidateRoots, normalizePath(projectRoot, mustWork = FALSE))
  }
  candidateRoots <- c(candidateRoots, normalizePath(getwd(), mustWork = FALSE))
  candidateRoots <- c(candidateRoots, normalizePath(file.path("~", "onco-pre-study"), mustWork = FALSE))
  candidateRoots <- unique(candidateRoots)

  sourceDir <- NULL
  for (root in candidateRoots) {
    preStudyDirs <- c(
      file.path(root, "outputs_v6"),
      file.path(root, "outputs"),
      file.path(root, "outputs_v5"),
      file.path(root, "outputs_all"),
      file.path(root, "outputs_test")
    )
    sourceDir <- preStudyDirs[dir.exists(preStudyDirs)][1]
    if (!is.null(sourceDir) && dir.exists(sourceDir)) break
  }

  if (is.null(sourceDir) || !dir.exists(sourceDir)) return(invisible(stageDir))

  diagnosticsFiles <- list.files(sourceDir, pattern = "\\.csv$", full.names = FALSE, ignore.case = TRUE)
  if (length(diagnosticsFiles) == 0L) return(invisible(stageDir))

  file.copy(file.path(sourceDir, diagnosticsFiles), file.path(stageDir, diagnosticsFiles), overwrite = TRUE)
  invisible(stageDir)
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
  stagePreStudyDiagnostics(outputFolder = outputFolder)
}

