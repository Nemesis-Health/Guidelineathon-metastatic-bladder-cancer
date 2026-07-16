# ===========================================================================
# 04_lab_ranges.R  —  (d) lab test ranges on the main cohorts
# ===========================================================================
# lab_value_distribution_portable.sql : per cohort x lab (cat) summary of
#   std_value, censored at minCellCount, over the Target-1A cohort tree from
#   step (c). (One row per lab: the raw table's per-criterion/test_id fan-out
#   is collapsed, since std_value does not depend on the threshold.)
# lab_results_summary_portable.sql    : per (cat, concept, unit) QC summary of
#   the raw normalised table (unit-resolution sanity check).
# lab_results_rollup_portable.sql     : per-category headline of the same table,
#   one row per (cat, is_ambiguous) in the standard unit, with unit-resolution
#   health folded into QC columns instead of extra rows.
# The _portable versions compute quantiles via ROW_NUMBER/COUNT/FLOOR (same
# result as PERCENTILE_CONT, which SqlRender cannot translate); the originals
# are kept alongside for comparison.
# ===========================================================================

message("\n== (d) lab test ranges on main cohorts ==")

# The manifest holds only the main cohort tree (T1-T6 + the Target 1A JSON
# leaves), so take every cohort in it. (Was a "^Target 1A" name-prefix match,
# which the T1-T6 rename would otherwise miss.)
targetIds <- mainManifest$cohortId
message("Target cohorts for lab distribution: ", length(targetIds))

labDist <- querySqlFile(connection, "lab_value_distribution_portable.sql",
  target_database_schema = settings$workDatabaseSchema,
  target_cohort_table    = settings$cohortTable,
  raw_lab_results_table  = settings$rawLabResultsTable,
  cohort_definition_ids  = paste(targetIds, collapse = ", "),
  lab_window_before_days = settings$labWindowBeforeDays,
  lab_window_after_days  = settings$labWindowAfterDays,
  min_cell_count         = settings$minCellCount)
names(labDist) <- tolower(names(labDist))
writeResultCsv(labDist, "lab_value_distribution")
message("  lab_value_distribution: ", nrow(labDist), " rows")

labSummary <- querySqlFile(connection, "lab_results_summary_portable.sql",
  work_database_schema       = settings$workDatabaseSchema,
  raw_lab_results_table      = settings$rawLabResultsTable,
  vocabulary_database_schema = settings$vocabDatabaseSchema,
  min_cell_count             = settings$minCellCount)
names(labSummary) <- tolower(names(labSummary))
writeResultCsv(labSummary, "lab_results_summary")
message("  lab_results_summary: ", nrow(labSummary), " rows")

labRollup <- querySqlFile(connection, "lab_results_rollup_portable.sql",
  work_database_schema       = settings$workDatabaseSchema,
  raw_lab_results_table      = settings$rawLabResultsTable,
  normals_table              = "bc_lab_normals",
  vocabulary_database_schema = settings$vocabDatabaseSchema,
  min_cell_count             = settings$minCellCount)
names(labRollup) <- tolower(names(labRollup))
writeResultCsv(labRollup, "lab_results_rollup")
message("  lab_results_rollup: ", nrow(labRollup), " rows")

message("\nResults written under: ",
        normalizePath(file.path(settings$outputFolder, "csv"), mustWork = FALSE))
