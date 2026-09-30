# Regenerates the per-dialect copies of the provenance queries from the
# OHDSI SQL sources in this folder. Run from the repo root:
#   Rscript sql/provenance/translate.R
# The two schema parameters are left as @placeholders to replace by hand.

dir <- "sql/provenance"
sources <- list.files(dir, pattern = "[.]sql$", full.names = TRUE)
dialects <- SqlRender::listSupportedDialects()$dialect

for (dialect in dialects) {
  outDir <- file.path(dir, "translated", gsub(" ", "_", dialect))
  dir.create(outDir, recursive = TRUE, showWarnings = FALSE)
  for (src in sources) {
    sql <- SqlRender::translate(SqlRender::render(SqlRender::readSql(src)), dialect)
    header <- paste0(
      "-- Generated from ", basename(src), " by translate.R for ", dialect, ".\n",
      "-- Replace @cdm_database_schema and @vocabulary_database_schema\n",
      "-- before running.\n\n")
    SqlRender::writeSql(paste0(header, sql), file.path(outDir, basename(src)))
  }
}
