# ===========================================================================
# 13_covariate_lab_coverage.R  —  (m) lab test coverage by comorbidity
# subgroup, Target 1A only
# ===========================================================================
# covariate_lab_coverage.sql : Target 1A members split into with/without each
#   of three comorbidities -- Heme Disorders, Liver Disease, Renal Disease --
#   using the SAME unbounded on/before-index lookback as covariate_overlap.csv
#   ("ever before index"), crossed with every lab (cat) in
#   bc_raw_lab_results, counting subjects with >=1 measurement in the
#   eligibility lab window (labWindowBeforeDays before / labWindowAfterDays
#   after Target 1A's own index) -- same window lab_value_distribution.csv
#   uses. Every (subgroup, test) combination gets an explicit row, zero-filled
#   where a subgroup has no coverage at all for that test.
#
# One output: covariate_lab_coverage.csv (cohort_definition_id, subgroup,
# subgroup_count, test, n_with_test), n_with_test censored to -minCellCount
# (same rule as lab_value_distribution.csv / covariate_overlap.csv).
#
# Depends on R/03_main_cohorts.R (mainManifest, cohortNames) and
# R/08_covariates.R (covSet -- the generated covariate cohort ids), so must
# run after both.
# ===========================================================================

message("\n== (m) lab test coverage by comorbidity subgroup, Target 1A only ==")

mainManifest <- loadState("mainManifest", "R/03_main_cohorts.R")
cohortNames  <- loadState("cohortNames", "R/03_main_cohorts.R")
covSet       <- loadState("covSet", "R/08_covariates.R")

targetCohortId <- cohortIdByName(mainManifest, cohortNames[["T1"]])
if (is.na(targetCohortId))
  stop("Target 1A (T1) cohort id not found in mainManifest -- has R/03_main_cohorts.R run?",
       call. = FALSE)

covariateIdFor <- function(name) {
  hit <- covSet$cohortId[covSet$cohortName == name]
  if (length(hit) == 0L)
    stop("Covariate cohort '", name, "' not found in covSet -- is its JSON present in ",
         "cohorts/02_Covariate/ and listed in R/08_covariates.R's comorbMap?", call. = FALSE)
  as.integer(hit[1])
}

cov <- querySqlFile(connection, "covariate_lab_coverage.sql",
  work_database_schema   = settings$workDatabaseSchema,
  cohort_table           = settings$cohortTable,
  covariate_cohort_table = settings$covariateCohortTable,
  raw_lab_results_table  = settings$rawLabResultsTable,
  target_cohort_id       = targetCohortId,
  heme_covariate_id      = covariateIdFor("Heme Disorders"),
  liver_covariate_id     = covariateIdFor("Liver Disease"),
  renal_covariate_id     = covariateIdFor("Renal Disease"),
  lab_window_before_days = settings$labWindowBeforeDays,
  lab_window_after_days  = settings$labWindowAfterDays)
names(cov) <- tolower(names(cov))
cov$has_flag       <- as.integer(cov$has_flag)
cov$subgroup_count <- as.integer(cov$subgroup_count)
cov$n_with_test    <- as.integer(cov$n_with_test)

out <- dplyr::transmute(cov,
  cohort_definition_id = targetCohortId,
  subgroup             = ifelse(.data$has_flag == 1L, .data$code, paste0("no_", .data$code)),
  subgroup_count       = .data$subgroup_count,
  test                 = .data$cat,
  n_with_test          = .data$n_with_test)

small <- out$n_with_test > 0 & out$n_with_test < settings$minCellCount
out$n_with_test <- ifelse(small, -settings$minCellCount, out$n_with_test)

# subgroup_count is the same comorbidity/T1 population covariate_overlap.csv
# reports as n_overlap (same unbounded on/before-index lookback) -- censor it
# the same way, or an uncensored value here discloses what's suppressed there.
smallSubgroup <- out$subgroup_count > 0 & out$subgroup_count < settings$minCellCount
out$subgroup_count <- ifelse(smallSubgroup, -settings$minCellCount, out$subgroup_count)

out <- out[order(out$subgroup, out$test), ]
writeResultCsv(out, "covariate_lab_coverage", "labs")
message("  covariate_lab_coverage: ", nrow(out), " rows across ",
        dplyr::n_distinct(out$subgroup), " subgroups")
