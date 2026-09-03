# ===========================================================================
# 04_lab_ranges.R  —  (d) lab test ranges on the main cohorts
# ===========================================================================
# lab_value_distribution_portable.sql : per cohort x lab (cat) x stratum
#   (overall/age_group/sex/age_sex) summary of std_value, censored at
#   minCellCount, over the Target-1A cohort tree from step (c). (One row
#   per lab: the raw table's per-criterion/test_id fan-out is collapsed,
#   since std_value does not depend on the threshold.)
# lab_results_summary_portable.sql    : per (cat, concept, unit) QC summary of
#   the raw normalised table (unit-resolution sanity check).
# lab_results_rollup_portable.sql     : per-category headline of the same table,
#   one row per (cat, is_ambiguous) in the standard unit, with unit-resolution
#   health folded into QC columns instead of extra rows.
# lab_timing_to_index_portable.sql    : per lab (cat) x direction
#   (before/after/any), the distribution of days from the Target 1A /
#   Target 1A PC allowed index to the closest measurement in that direction
#   -- a subject's ENTIRE history, not the +/- 14/7-day eligibility window
#   lab_value_distribution_portable.sql restricts to.
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

# subject_strata.sql is the single source of truth for age_group/sex/age_sex
# bucketing (shared with demographics.sql, R/09_outcomes.R,
# R/12_treatment_patterns.R) -- resolve it once, reused as the
# stratification join for every query in this step.
strataFragment <- renderSqlFile("subject_strata.sql",
  work_database_schema = settings$workDatabaseSchema,
  cohort_table         = settings$cohortTable,
  cdm_database_schema  = settings$cdmDatabaseSchema)

labDist <- querySqlFile(connection, "lab_value_distribution_portable.sql",
  target_database_schema = settings$workDatabaseSchema,
  target_cohort_table    = settings$cohortTable,
  raw_lab_results_table  = settings$rawLabResultsTable,
  cohort_definition_ids  = paste(targetIds, collapse = ", "),
  lab_window_before_days = settings$labWindowBeforeDays,
  lab_window_after_days  = settings$labWindowAfterDays,
  min_cell_count         = settings$minCellCount,
  subject_strata_sql     = strataFragment)
names(labDist) <- tolower(names(labDist))
# settings$strataColumns (run.R CONFIG, via activeStrataTypes()) controls
# which stratum views actually reach the CSV -- the SQL always computes all
# four (cheap), a site that wants fewer/none just filters here.
labDist <- labDist[labDist$stratum_type %in% activeStrataTypes(), ]
writeResultCsv(labDist, "lab_value_distribution")
message("  lab_value_distribution: ", nrow(labDist), " rows")

# Timing-to-index: Target 1A + Target 1A PC allowed only (not the full T1-T6
# tree -- the metastasis index is only meaningful for these two, since it's
# their own qualifying event; the T4-6/L01-initiated cohorts index on
# treatment start instead).
mBcId       <- cohortIdByName(mainManifest, cohortNames[["T1"]])
pcAllowedId <- cohortIdByName(mainManifest, "Target 1A PC allowed")
metsCohortIds <- as.integer(stats::na.omit(c(mBcId, pcAllowedId)))

labTiming <- querySqlFile(connection, "lab_timing_to_index_portable.sql",
  target_database_schema = settings$workDatabaseSchema,
  target_cohort_table    = settings$cohortTable,
  raw_lab_results_table  = settings$rawLabResultsTable,
  cohort_definition_ids  = paste(metsCohortIds, collapse = ", "),
  min_cell_count         = settings$minCellCount,
  subject_strata_sql     = strataFragment)
names(labTiming) <- tolower(names(labTiming))
labTiming <- labTiming[labTiming$stratum_type %in% activeStrataTypes(), ]
writeResultCsv(labTiming, "lab_timing_to_index")
message("  lab_timing_to_index: ", nrow(labTiming), " rows")

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
        normalizePath(file.path(settings$outputFolder, "eligibility"), mustWork = FALSE))
