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

  invisible(list(stagingDir = stagingDir, archivePath = archivePath, manifestPath = file.path(stagingDir, "prestudy_query_manifest.csv")))
}

exportPreStudyQueries()
