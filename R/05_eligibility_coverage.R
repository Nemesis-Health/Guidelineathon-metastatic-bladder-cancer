# ===========================================================================
# 05_eligibility_coverage.R  —  eligibility-input counts & cohort coverage
# ===========================================================================
# Two outputs alongside cohort_counts.csv:
#   lab_cohort_counts.csv         — raw content of the unified eligibility table
#                                   (per test-id, whole population).
#   eligibility_input_coverage.csv — each input crossed with every cohort in
#                                   the main tree (same scope as
#                                   lab_value_distribution.csv): n_cohort,
#                                   n_tested (performed), n_passed.
# Counts < minCellCount are censored to -minCellCount.
# ===========================================================================

message("\n== eligibility input counts + T1 (mBC) coverage ==")

# test-id -> human label (labs from lab_cohorts.sql #criteria; ECOG/conditions
# from step (b)).
inputLabels <- c(
  "1"="aPTT<=1.5xULN","2"="ALT<=2.5xULN","3"="ALT<=5xULN","4"="ANC>=1500",
  "5"="AST<=2.5xULN","6"="AST<=5xULN","7"="CrCl>=30","8"="Cr<=1.5xULN",
  "9"="DBil<=ULN","10"="GFR<30","11"="GFR30-60","12"="GFR<60","13"="GFR>60",
  "14"="GFR>=30","15"="Hb>=9","16"="HbA1c7-8%","17"="HbA1c<6%","18"="INR<=1.5xULN",
  "19"="PLT>=100k","20"="PT<=1.5xULN","21"="TBil<=3xULN","22"="TBil<=1.5xULN",
  "23"="TBil>1.5xULN","44"="ANC<1500","45"="PLT<100k","46"="HbA1c>=8%",
  "47"="Hb<9","48"="GFR30-60excl",
  "24"="ECOG 0","25"="ECOG 1","26"="ECOG 2","27"="ECOG >=3",
  "28"="Liver metastasis","29"="Gilbert's syndrome","31"="Anticoagulant therapy",
  "33"="Neuropathy (present)","34"="Skin disorders (present)",
  "35"="Polyuria","36"="Polydipsia","40"="Hearing loss (present)")

censor <- function(x) ifelse(!is.na(x) & x > 0 & x < settings$minCellCount,
                             -settings$minCellCount, x)
label  <- function(id) unname(inputLabels[as.character(id)])

# --- raw eligibility-table counts (whole population) -----------------------
labCohortCounts <- querySqlFile(connection, "lab_cohort_counts.sql",
  work_database_schema = settings$workDatabaseSchema,
  lab_cohort_table     = settings$labCohortTable)
names(labCohortCounts) <- tolower(names(labCohortCounts))
labCohortCounts$label      <- label(labCohortCounts$test_id)
labCohortCounts$n_subjects <- censor(labCohortCounts$n_subjects)
labCohortCounts$n_records  <- ifelse(labCohortCounts$n_subjects < 0, NA,
                                     labCohortCounts$n_records)
labCohortCounts <- labCohortCounts[c("test_id","label","n_subjects","n_records")]
writeResultCsv(labCohortCounts, "lab_cohort_counts", "labs")
message("  lab_cohort_counts: ", nrow(labCohortCounts), " test-id slots")

# --- coverage (tested / passed per input), every cohort in the main tree ---
targetIds <- mainManifest$cohortId

# subject_strata.sql is the single source of truth for age_group/sex/age_sex
# bucketing (shared with demographics.sql, R/04_lab_ranges.R,
# R/09_outcomes.R, R/12_treatment_patterns.R). Reused here both to
# stratify the coverage query itself and to build the matching per-(cohort,
# stratum) denominators (a stratum's "n_cohort" is that cohort's members in
# that stratum, not the cohort's whole N).
strataFragment <- renderSqlFile("subject_strata.sql",
  work_database_schema = settings$workDatabaseSchema,
  cohort_table         = settings$cohortTable,
  cdm_database_schema  = settings$cdmDatabaseSchema)

strataTbl <- querySqlFile(connection, "subject_strata.sql",
  work_database_schema = settings$workDatabaseSchema,
  cohort_table         = settings$cohortTable,
  cdm_database_schema  = settings$cdmDatabaseSchema)
names(strataTbl) <- tolower(names(strataTbl))
strataTbl$cohort_definition_id <- as.integer(strataTbl$cohort_definition_id)
denomFor <- function(stratumType, col = NULL) {
  if (is.null(col)) {
    dplyr::count(strataTbl, cohort_definition_id, name = "n_cohort") |>
      dplyr::mutate(stratum_type = "overall", stratum_value = "overall", .before = 1)
  } else {
    dplyr::count(strataTbl, cohort_definition_id, stratum_value = .data[[col]], name = "n_cohort") |>
      dplyr::mutate(stratum_type = stratumType, .before = 1)
  }
}
denomTbl <- dplyr::bind_rows(
  denomFor("overall"), denomFor("age_group", "age_group"),
  denomFor("sex", "sex"), denomFor("age_sex", "age_sex"))

cov <- querySqlFile(connection, "eligibility_input_coverage.sql",
  work_database_schema  = settings$workDatabaseSchema,
  cohort_table          = settings$cohortTable,
  lab_cohort_table      = settings$labCohortTable,
  raw_lab_results_table = settings$rawLabResultsTable,
  cohort_definition_ids = paste(targetIds, collapse = ", "),
  lab_window_before_days = settings$labWindowBeforeDays,
  lab_window_after_days  = settings$labWindowAfterDays,
  subject_strata_sql     = strataFragment)
names(cov) <- tolower(names(cov))
# settings$strataColumns (run.R CONFIG, via activeStrataTypes()) controls
# which stratum views actually reach the CSV -- the SQL always computes all
# four (cheap), a site that wants fewer/none just filters here.
cov <- cov[cov$stratum_type %in% activeStrataTypes(), ]
cov$cohort_definition_id <- as.integer(cov$cohort_definition_id)
cov$label <- label(cov$test_id)
cov <- dplyr::left_join(cov, denomTbl, by = c("cohort_definition_id", "stratum_type", "stratum_value"))
cov <- dplyr::left_join(cov,
  dplyr::select(mainManifest, cohort_definition_id = "cohortId", cohort_name = "cohortName"),
  by = "cohort_definition_id")
cov$n_tested <- censor(cov$n_tested)
cov$n_passed <- censor(cov$n_passed)
cov <- cov[c("cohort_definition_id","cohort_name","stratum_type","stratum_value",
             "test_id","label","n_cohort","n_tested","n_passed")]
cov <- cov[order(cov$cohort_definition_id, cov$stratum_type, cov$stratum_value, cov$test_id), ]
writeResultCsv(cov, "eligibility_input_coverage", "labs")
message("  eligibility_input_coverage: ", nrow(cov), " rows across ",
        dplyr::n_distinct(cov$cohort_definition_id), " cohorts")
