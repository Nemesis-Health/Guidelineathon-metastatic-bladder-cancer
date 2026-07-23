projectRoot <- normalizePath(".", mustWork = TRUE)
source(file.path(projectRoot, "R", "00_prestudy_queries.R"))

tmp <- tempfile("prestudy-export")
dir.create(tmp, recursive = TRUE)
projectDir <- file.path(tmp, "onco-pre-study")
outputDir <- file.path(tmp, "results")
dir.create(file.path(projectDir, "sql", "postgresql"), recursive = TRUE)
dir.create(file.path(projectDir, "outputs_v6"), recursive = TRUE)
dir.create(file.path(outputDir, "eligibility"), recursive = TRUE)
writeLines("SELECT 1 AS n", file.path(projectDir, "sql", "postgresql", "example.sql"))
writeLines("demo", file.path(projectDir, "README.md"))
writeLines("prestudy output", file.path(projectDir, "outputs_v6", "prestudy_output.csv"))
writeLines("main study output", file.path(outputDir, "eligibility", "main_study.csv"))

exportPreStudyQueries(projectRoot = projectDir, outputFolder = outputDir)
zipPreStudyQueries(outputFolder = outputDir)
stagePreStudyDiagnostics(projectRoot = projectDir, outputFolder = outputDir)

manifest <- file.path(outputDir, "prestudy_queries", "prestudy_query_manifest.csv")
archive <- file.path(outputDir, "prestudy_queries.zip")

if (!file.exists(manifest)) stop("manifest was not created")
if (!dir.exists(file.path(outputDir, "prestudy_queries"))) stop("pre-study staging directory was not created")
if (!file.exists(archive)) stop("pre-study archive was not created")
if (!file.exists(file.path(outputDir, "diagnostics", "prestudy_output.csv"))) {
  stop("diagnostics staging directory did not receive the pre-study output CSV")
}

# Regression test: a repository-local sql/prestudy bundle should be usable even
# when the external onco-pre-study checkout is unavailable.
repoOnlyTmp <- tempfile("prestudy-repo-only")
dir.create(repoOnlyTmp, recursive = TRUE)
repoOnlyDir <- file.path(repoOnlyTmp, "repo")
repoOnlyOutput <- file.path(repoOnlyTmp, "results")
dir.create(file.path(repoOnlyDir, "sql", "prestudy"), recursive = TRUE)
dir.create(repoOnlyOutput, recursive = TRUE)
writeLines("SELECT 2 AS n", file.path(repoOnlyDir, "sql", "prestudy", "bundled.sql"))

oldWd <- getwd()
setwd(repoOnlyDir)
tryCatch({
  exportPreStudyQueries(projectRoot = NULL, outputFolder = repoOnlyOutput)

  bundledFiles <- list.files(file.path(repoOnlyDir, "sql", "prestudy"), recursive = TRUE)
  if (!identical(bundledFiles, "bundled.sql")) {
    stop("repo-local sql/prestudy bundle was duplicated or corrupted: ",
         paste(bundledFiles, collapse = ", "))
  }
  if (!identical(readLines(file.path(repoOnlyDir, "sql", "prestudy", "bundled.sql")), "SELECT 2 AS n")) {
    stop("repo-local bundled SQL file content was corrupted")
  }
}, finally = {
  setwd(oldWd)
})

cat("prestudy export smoke test passed\n")
