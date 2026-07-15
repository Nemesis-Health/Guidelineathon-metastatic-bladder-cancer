# ===========================================================================
# 07_demographics.R  —  per-cohort demographic strata (counts)
# ===========================================================================
# One output alongside cohort_counts.csv:
#   demographics.csv — every cohort in bc_cohort crossed with three strata:
#     age group at index (>65 / <=65), sex (Male / Female / Other-Unknown),
#     and index year. Long/tidy: one row per cohort x characteristic x stratum.
#
# Counts only — no derived % column (denominator = cohort N, available in
# cohort_counts.csv / by summing strata). Cells < minCellCount are censored to
# -minCellCount — same privacy rule as R/05_eligibility_coverage.R.
# ===========================================================================

message("\n== demographics (age / sex / index year per cohort) ==")

demo <- querySqlFile(connection, "demographics.sql",
  work_database_schema = settings$workDatabaseSchema,
  cohort_table         = settings$cohortTable,
  cdm_database_schema  = settings$cdmDatabaseSchema)
names(demo) <- tolower(names(demo))

if (nrow(demo) == 0L) {
  message("  no cohort members found — skipping demographics.")
} else {
  # cohort_definition_id -> human name (from the main manifest built in step (c))
  nmeMap <- data.frame(
    cohort_definition_id = as.integer(mainManifest$cohortId),
    cohort_name          = mainManifest$cohortName,
    stringsAsFactors     = FALSE)
  demo$cohort_definition_id <- as.integer(demo$cohort_definition_id)
  demo$n_subjects           <- as.integer(demo$n_subjects)
  demo <- dplyr::left_join(demo, nmeMap, by = "cohort_definition_id")

  # privacy: censor small cells
  small <- !is.na(demo$n_subjects) & demo$n_subjects > 0 &
           demo$n_subjects < settings$minCellCount
  demo$n_subjects <- ifelse(small, -settings$minCellCount, demo$n_subjects)

  demo <- demo[order(demo$cohort_definition_id, demo$characteristic, demo$sort_key),
               c("cohort_definition_id", "cohort_name", "characteristic",
                 "stratum", "n_subjects")]
  writeResultCsv(demo, "demographics")
  message("  demographics: ", nrow(demo), " rows across ",
          dplyr::n_distinct(demo$cohort_definition_id), " cohorts")
}
