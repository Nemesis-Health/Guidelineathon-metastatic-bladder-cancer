projectRoot <- normalizePath(".", mustWork = TRUE)
source(file.path(projectRoot, "R", "00_prestudy_queries.R"))

tmp <- tempfile("prestudy-export")
dir.create(tmp, recursive = TRUE)
projectDir <- file.path(tmp, "onco-pre-study")
outputDir <- file.path(tmp, "results")
dir.create(file.path(projectDir, "sql", "postgresql"), recursive = TRUE)
writeLines("SELECT 1 AS n", file.path(projectDir, "sql", "postgresql", "example.sql"))
writeLines("demo", file.path(projectDir, "README.md"))

exportPreStudyQueries(projectRoot = projectDir, outputFolder = outputDir)

manifest <- file.path(outputDir, "prestudy_queries", "prestudy_query_manifest.csv")
archive <- file.path(outputDir, "prestudy_queries.zip")

if (!file.exists(manifest)) stop("manifest was not created")
if (!file.exists(archive)) stop("archive was not created")

cat("prestudy export smoke test passed\n")
