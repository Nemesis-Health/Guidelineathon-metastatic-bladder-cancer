# ===========================================================================
# 07_demographics.R  —  per-cohort demographic strata (counts + continuous age)
# ===========================================================================
# Two outputs alongside cohort_counts.csv:
#   demographics.csv — every cohort in bc_cohort crossed with three strata:
#     age group at index (>65 / <=65), sex (Male / Female / Other-Unknown),
#     and index year. Long/tidy: one row per cohort x characteristic x stratum.
#     Carries a `pct` column (% of that cohort's total N, computed from the
#     raw pre-censoring counts so it isn't distorted by rows that get
#     censored individually).
#   demographics_age_continuous.csv — age at index per cohort as a continuous
#     variable: n / mean / SD / median / IQR / min / max, per the protocol's
#     "continuous variables summarized as mean (SD), min, max, median, IQR."
#
# Cells < minCellCount are censored to -minCellCount — same privacy rule as
# R/05_eligibility_coverage.R.
# ===========================================================================

message("\n== demographics (age / sex / index year per cohort) ==")

mainManifest <- loadState("mainManifest", "R/03_main_cohorts.R")

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

  # pct: % of the cohort's total N within each characteristic, computed on
  # the RAW (pre-censoring) counts so a censored row elsewhere in the same
  # cohort/characteristic doesn't distort the denominator; only after pct is
  # computed do both n_subjects and pct get censored together.
  cohortN <- demo |>
    dplyr::filter(.data$characteristic == "sex") |>
    dplyr::group_by(.data$cohort_definition_id) |>
    dplyr::summarise(cohort_n = sum(.data$n_subjects), .groups = "drop")
  demo <- dplyr::left_join(demo, cohortN, by = "cohort_definition_id")
  demo$pct <- ifelse(demo$cohort_n > 0,
                     round(demo$n_subjects / demo$cohort_n * 100, 2), NA_real_)

  # privacy: censor small cells (n_subjects and its paired pct together)
  small <- !is.na(demo$n_subjects) & demo$n_subjects > 0 &
           demo$n_subjects < settings$minCellCount
  demo$pct       <- ifelse(small, NA_real_, demo$pct)
  demo$n_subjects <- ifelse(small, -settings$minCellCount, demo$n_subjects)

  demo <- demo[order(demo$cohort_definition_id, demo$characteristic, demo$sort_key),
               c("cohort_definition_id", "cohort_name", "characteristic",
                 "stratum", "n_subjects", "pct")]
  writeResultCsv(demo, "demographics")
  message("  demographics: ", nrow(demo), " rows across ",
          dplyr::n_distinct(demo$cohort_definition_id), " cohorts")
}

# --- continuous age summary --------------------------------------------------
ageCont <- querySqlFile(connection, "demographics_continuous.sql",
  work_database_schema = settings$workDatabaseSchema,
  cohort_table         = settings$cohortTable,
  cdm_database_schema  = settings$cdmDatabaseSchema)
names(ageCont) <- tolower(names(ageCont))

if (nrow(ageCont) == 0L) {
  message("  no cohort members found — skipping continuous age summary.")
} else {
  ageCont$cohort_definition_id <- as.integer(ageCont$cohort_definition_id)
  ageCont$n                    <- as.integer(ageCont$n)
  ageCont <- dplyr::left_join(ageCont, nmeMap, by = "cohort_definition_id")

  small <- ageCont$n > 0 & ageCont$n < settings$minCellCount
  statCols <- c("mean_age", "sd_age", "min_age", "lq_age", "median_age", "uq_age", "max_age")
  ageCont[statCols] <- lapply(ageCont[statCols], function(x) ifelse(small, NA_real_, as.double(x)))
  ageCont$n <- ifelse(small, -settings$minCellCount, ageCont$n)

  ageCont <- ageCont[order(ageCont$cohort_definition_id),
                     c("cohort_definition_id", "cohort_name", "n", statCols)]
  writeResultCsv(ageCont, "demographics_age_continuous")
  message("  demographics_age_continuous: ", nrow(ageCont), " cohort(s)")
}
