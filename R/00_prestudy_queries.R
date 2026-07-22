# ===========================================================================
# 00_prestudy_queries.R — package external onco-pre-study query assets
# ===========================================================================
# Copies the latest onco-pre-study query-related assets into the study results
# folder and writes a zip archive for downstream sharing.
# ===========================================================================

exportPreStudyQueries <- function(projectRoot = NULL, outputFolder = NULL,
                                  archiveName = NULL) {
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
      file.path("~", "onco-pre-study")
    }
  }
  if (is.null(outputFolder) || !nzchar(outputFolder)) {
    outputFolder <- getSetting("outputFolder", file.path("results"))
  }
  if (is.null(archiveName) || !nzchar(archiveName)) {
    archiveName <- if (!is.null(getSetting("preStudyArchiveName")) && nzchar(getSetting("preStudyArchiveName"))) {
      getSetting("preStudyArchiveName")
    } else {
      "prestudy_queries.zip"
    }
  }

  projectRoot <- normalizePath(projectRoot, mustWork = FALSE)
  outputFolder <- normalizePath(outputFolder, mustWork = FALSE)

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

  archivePath <- file.path(outputFolder, archiveName)
  if (dir.exists(stagingDir)) {
    oldWd <- getwd()
    on.exit(setwd(oldWd), add = TRUE)
    setwd(stagingDir)
    filesToZip <- list.files(".", recursive = TRUE, include.dirs = TRUE, all.files = TRUE)
    filesToZip <- filesToZip[filesToZip != "."]
    if (length(filesToZip) > 0L) {
      utils::zip(zipfile = archivePath, files = filesToZip, flags = "-q")
    }
  }

  # Mirror SQL Server queries into the study `sql/prestudy` folder so the
  # study can be self-contained. Only copy the server-specific SQLs; they
  # will be translated later by the normal pipeline helpers if needed.
  tryCatch({
    srcSqlServerDir <- file.path(projectRoot, "sql", "sql_server")
    if (dir.exists(srcSqlServerDir)) {
      destSqlDir <- file.path(normalizePath(".", mustWork = FALSE), "sql", "prestudy")
      dir.create(destSqlDir, recursive = TRUE, showWarnings = FALSE)
      sqlFiles <- list.files(srcSqlServerDir, pattern = "\\.sql$", full.names = TRUE)
      if (length(sqlFiles) > 0L) {
        file.copy(sqlFiles, file.path(destSqlDir, basename(sqlFiles)), overwrite = TRUE)
        # Add entries to the manifest for the project copies
        projRows <- data.frame(
          source_path = file.path("sql", "sql_server", basename(sqlFiles)),
          destination_path = file.path(destSqlDir, basename(sqlFiles)),
          stringsAsFactors = FALSE
        )
        manifestDf <- dplyr::bind_rows(manifestDf, projRows)
        readr::write_csv(manifestDf, file.path(stagingDir, "prestudy_query_manifest.csv"), na = "")
      }
    }
  }, error = function(e) {
    message("Warning: could not mirror SQL Server queries into project sql folder: ", e$message)
  })

  invisible(list(stagingDir = stagingDir, archivePath = archivePath, manifestPath = file.path(stagingDir, "prestudy_query_manifest.csv")))
}

zipResultsCsvs <- function(outputFolder = NULL,
                           diagnosticsName = "diagnostics.zip",
                           eligibilityName = "eligibility_results.zip") {
  if (is.null(outputFolder) || !nzchar(outputFolder)) outputFolder <- "results"
  outputFolder <- normalizePath(outputFolder, mustWork = FALSE)
  csvDir <- file.path(outputFolder, "csv")
  if (!dir.exists(csvDir)) return(invisible(NULL))

  allCsvs <- list.files(csvDir, pattern = "\\.csv$", full.names = FALSE)
  if (length(allCsvs) == 0L) return(invisible(NULL))

  # Exclude any suspected patient-level / raw files by keyword or extension.
  excludePattern <- "(raw|patient|person|rowlevel|individual|detail|_rds|\\.rds)"
  safeCsvs <- allCsvs[!grepl(excludePattern, allCsvs, ignore.case = TRUE)]
  if (length(safeCsvs) == 0L) return(invisible(NULL))

  diagnosticsList <- c("lab_results_summary.csv", "lab_results_rollup.csv",
                       "lab_value_distribution.csv", "lab_cohort_counts.csv")
  diagnosticsFiles <- intersect(diagnosticsList, safeCsvs)
  eligibilityFiles <- setdiff(safeCsvs, diagnosticsFiles)

  oldWd <- getwd()
  on.exit(setwd(oldWd), add = TRUE)
  setwd(csvDir)

  if (length(diagnosticsFiles) > 0L) {
    utils::zip(zipfile = file.path(outputFolder, diagnosticsName), files = diagnosticsFiles, flags = "-q")
  }
  if (length(eligibilityFiles) > 0L) {
    utils::zip(zipfile = file.path(outputFolder, eligibilityName), files = eligibilityFiles, flags = "-q")
  }
  invisible(list(diagnostics = file.path(outputFolder, diagnosticsName),
                 eligibility = file.path(outputFolder, eligibilityName)))
}

exportPreStudyQueries()
