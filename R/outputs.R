# ===========================================================================
# outputs.R  —  strata and the results/eligibility/ files
# ===========================================================================
# Which strata are reported, writeResultCsv() for every study CSV, and the
# per-folder README.md files.
# ===========================================================================

# --- which subject_strata.sql breakdowns are active --------------------------
# Single control point for settings$strataColumns (R/study_settings.R), so every
# stratified output reads the same setting instead of hardcoding its own
# on/off list. Two shapes, for the two ways stratified outputs consume
# subject_strata.sql:
#   activeStrataTypes() -- "overall" + whichever of settings$strataColumns
#     are enabled, e.g. c("overall", "age_group", "sex"). SQL-side outputs
#     (lab_value_distribution.sql, lab_timing_to_index.sql,
#     eligibility_input_coverage.sql, cohort_counts_stratified.sql) always
#     compute every view (cheap -- a single extra GROUP BY column each);
#     the caller filters its result to `stratum_type %in% activeStrataTypes()`
#     before writing, so disabled views never reach the CSV.
#   activeStrataSpecs() -- named list, stratum_type -> column name to group
#     by (NULL for "overall"), filtered to the active types. R-side outputs
#     that loop over stratum columns themselves (R/steps/50_outcomes.R,
#     R/steps/60_adherence.R, R/steps/22_baseline_characterization.R,
#     R/steps/70_treatment_patterns.R) iterate this instead of their own literal
#     list -- disabled strata are never computed there at all, not just
#     hidden after the fact.
#   strataColumnNames -- every per-subject strata column subject_strata.sql
#     emits that can be reported (index_year is separate: outcomes add it
#     themselves). Each stratum_type is named after its column.
strataColumnNames <- c("age_group", "sex", "age_sex", "age_band",
                       "index_period", "index_period_2021")

activeStrataTypes <- function()
  c("overall", intersect(strataColumnNames, settings$strataColumns))

activeStrataSpecs <- function() {
  specs <- c(list(overall = NULL), stats::setNames(as.list(strataColumnNames), strataColumnNames))
  specs[activeStrataTypes()]
}

# subject_strata.sql stratifies every cohort at the subject's first
# metastasis, its T1all start date. strataSql() renders it as a fragment for
# SQL-side consumers to inject; queryStrata() runs it for R-side ones.
strataParams <- function() {
  manifest <- loadState("mainManifest", "R/steps/12_main_cohorts.R")
  names    <- loadState("cohortNames", "R/steps/12_main_cohorts.R")
  list(work_database_schema = settings$workDatabaseSchema,
       cohort_table         = settings$cohortTable,
       cdm_database_schema  = settings$cdmDatabaseSchema,
       metastasis_cohort_id = cohortIdByName(manifest, names[["T1all"]]))
}
strataSql <- function() do.call(renderSqlFile, c(list("subject_strata.sql"), strataParams()))
queryStrata <- function(connection)
  do.call(querySqlFile, c(list(connection, "subject_strata.sql"), strataParams()))

# --- write a result data frame to results/eligibility/<category> -----------
# Every writeResultCsv() call names one of these; keep in sync with
# README.md's <!-- category:... --> markers (writeCategoryReadmes() below).
resultCategories <- c("characterization", "labs", "artemis", "outcomes",
                      "guideline", "treatment_patterns")

writeResultCsv <- function(df, name, category) {
  stopifnot(category %in% resultCategories)
  d <- file.path(settings$outputFolder, "eligibility", category)
  dir.create(d, recursive = TRUE, showWarnings = FALSE)
  readr::write_csv(df, file.path(d, paste0(name, ".csv")), na = "")
}

# --- per-category README, excerpted verbatim from this repo's own README.md
# Each results/eligibility/<category>/README.md is the text between README.md's
# <!-- shared --> markers (censoring and strata, which apply to every folder)
# followed by the text between that category's <!-- category:X --> markers.
# A missing or duplicated marker pair skips that part with a warning rather
# than failing the run over documentation.
readmeBlock <- function(lines, open, close) {
  startIdx <- which(lines == open)
  endIdx   <- which(lines == close)
  if (length(startIdx) != 1L || length(endIdx) != 1L || endIdx <= startIdx) {
    warning("README.md markers ", open, " missing or duplicated -- skipping.",
            call. = FALSE)
    return(NULL)
  }
  lines[(startIdx + 1L):(endIdx - 1L)]
}

writeCategoryReadmes <- function() {
  readmePath <- file.path(projectRoot, "README.md")
  if (!file.exists(readmePath)) return(invisible(NULL))
  lines  <- readLines(readmePath, warn = FALSE)
  shared <- readmeBlock(lines, "<!-- shared -->", "<!-- /shared -->")
  for (category in resultCategories) {
    body <- readmeBlock(lines, paste0("<!-- category:", category, " -->"),
                        paste0("<!-- /category:", category, " -->"))
    if (is.null(body)) next
    d <- file.path(settings$outputFolder, "eligibility", category)
    dir.create(d, recursive = TRUE, showWarnings = FALSE)
    writeLines(c(body, if (!is.null(shared)) c("", shared)), file.path(d, "README.md"))
  }
}
