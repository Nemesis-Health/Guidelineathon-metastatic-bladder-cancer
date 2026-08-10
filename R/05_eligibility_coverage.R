# ===========================================================================
# 05_eligibility_coverage.R  —  eligibility-input counts & Target 1A coverage
# ===========================================================================
# Two outputs alongside cohort_counts.csv:
#   lab_cohort_counts.csv         — raw content of the unified eligibility table
#                                   (per test-id, whole population).
#   eligibility_input_coverage.csv — each input crossed with Target 1A:
#                                   n_target1a, n_tested (performed), n_passed.
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

cohort1Id <- cohortIdByName(mainManifest, "T1 Metastatic bladder cancer")

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
writeResultCsv(labCohortCounts, "lab_cohort_counts")
message("  lab_cohort_counts: ", nrow(labCohortCounts), " test-id slots")

# --- Target 1A coverage (tested / passed per input) ------------------------
nT1a <- querySqlFile(connection, "n_target1a.sql",
  work_database_schema = settings$workDatabaseSchema,
  cohort_table = settings$cohortTable, cohort1_id = cohort1Id)
nT1a <- as.integer(nT1a[[1]][1])

cov <- querySqlFile(connection, "eligibility_input_coverage.sql",
  work_database_schema  = settings$workDatabaseSchema,
  cohort_table          = settings$cohortTable,
  lab_cohort_table      = settings$labCohortTable,
  raw_lab_results_table = settings$rawLabResultsTable,
  cohort1_id            = cohort1Id,
  lab_window_before_days = settings$labWindowBeforeDays,
  lab_window_after_days  = settings$labWindowAfterDays)
names(cov) <- tolower(names(cov))
cov$label      <- label(cov$test_id)
cov$n_target1a <- if (nrow(cov) > 0) nT1a else integer(0)
cov$n_tested   <- censor(cov$n_tested)
cov$n_passed   <- censor(cov$n_passed)
cov <- cov[c("test_id","label","n_target1a","n_tested","n_passed")]
cov <- cov[order(cov$test_id), ]
writeResultCsv(cov, "eligibility_input_coverage")
message("  eligibility_input_coverage: ", nrow(cov),
        " inputs crossed with T1 mBC (n=", nT1a, ")")
