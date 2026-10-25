# ===========================================================================
# 31_eligibility_coverage.R  —  eligibility-input counts & cohort coverage
# ===========================================================================
# Two outputs alongside cohort_counts.csv:
#   lab_cohort_counts.csv         — raw content of the unified eligibility table
#                                   (per test-id, whole population).
#   eligibility_input_coverage.csv — each input crossed with every cohort in
#                                   the main tree (same scope as
#                                   lab_value_distribution.csv): n_cohort,
#                                   n_tested (performed), n_passed, from the
#                                   same rows eligibility uses (labRowsSql()).
#                                   lab_window: -30..30 around metastasis,
#                                   -30..0 before treatment start (defaults).
#   eligibility_test_kappa.csv     — agreement between every pair of lab
#                                   tests in T1 (Target 1A): 2x2 pass/fail
#                                   counts, % agreement and Cohen's kappa.
#   eligibility_lab_coverage_kappa.csv — the same for whether each pair of
#                                   labs (and ECOG) was tested, all T1 members.
# Counts < minCellCount are censored to -minCellCount.
# ===========================================================================

message("\n== eligibility input counts + T1 (mBC) coverage ==")

mainManifest <- loadState("mainManifest", "R/steps/12_main_cohorts.R")
cohortNames  <- loadState("cohortNames", "R/steps/12_main_cohorts.R")
cohortIndex  <- loadState("cohortIndex", "R/steps/12_main_cohorts.R")

# test-id -> human label, from cohorts/extras/eligibility_test_ids.csv.
inputLabels <- with(testIds(), stats::setNames(label, test_id))

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
# bucketing (shared with demographics.sql, R/steps/30_lab_ranges.R,
# R/steps/50_outcomes.R, R/steps/70_treatment_patterns.R). Reused here both to
# stratify the coverage query itself and to build the matching per-(cohort,
# stratum) denominators (a stratum's "n_cohort" is that cohort's members in
# that stratum, not the cohort's whole N).
strataFragment <- strataSql()

strataTbl <- queryStrata(connection)
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
  denomFor("overall"), lapply(strataColumnNames, function(col) denomFor(col, col)))

treatedIds <- treatedCohortIds()
cov <- querySqlFile(connection, "eligibility_input_coverage.sql",
  work_database_schema  = settings$workDatabaseSchema,
  cohort_table          = settings$cohortTable,
  cohort_definition_ids = paste(targetIds, collapse = ", "),
  condition_window_ids  = testIdParams()$condition_window_ids,
  lab_rows_sql          = labRowsSql(targetIds, passingOnly = FALSE, treatedIds = treatedIds),
  subject_strata_sql    = strataFragment)
names(cov) <- tolower(names(cov))
# settings$strataColumns (R/study_settings.R, via activeStrataTypes()) controls
# which stratum views actually reach the CSV -- the SQL always computes all
# four (cheap), a site that wants fewer/none just filters here.
cov <- cov[cov$stratum_type %in% activeStrataTypes(), ]
cov$cohort_definition_id <- as.integer(cov$cohort_definition_id)
cov$label <- label(cov$test_id)
cov <- dplyr::left_join(cov, denomTbl, by = c("cohort_definition_id", "stratum_type", "stratum_value"))
cov <- dplyr::left_join(cov,
  dplyr::select(mainManifest, cohort_definition_id = "cohortId", cohort_name = "cohortName"),
  by = "cohort_definition_id")
cov$n_cohort <- censor(cov$n_cohort)
cov$n_tested <- censor(cov$n_tested)
cov$n_passed <- censor(cov$n_passed)
cov$lab_window <- labWindowLabel(cov$cohort_definition_id, treatedIds)
cov <- cov[c("cohort_definition_id","cohort_name","stratum_type","stratum_value",
             "lab_window","test_id","label","n_cohort","n_tested","n_passed")]
cov <- cov[order(cov$cohort_definition_id, cov$stratum_type, cov$stratum_value, cov$test_id), ]
writeResultCsv(cov, "eligibility_input_coverage", "labs")
message("  eligibility_input_coverage: ", nrow(cov), " rows across ",
        dplyr::n_distinct(cov$cohort_definition_id), " cohorts")

# --- agreement between lab tests, T1 ---------------------------------------
# Two outputs from the rows eligibility uses (labRowsSql(), closest rule):
#   eligibility_test_kappa.csv         — per pair of lab tests, among T1
#     members with a result for both: pass/fail agreement. same_lab flags
#     pairs on the same lab, which agree or disagree by design (e.g. Hb >= 9
#     vs Hb < 9 must never both pass).
#   eligibility_lab_coverage_kappa.csv — per pair of labs (ECOG counted as
#     one), among all T1 members: agreement on whether each was tested in
#     the window.
t1Id <- cohortIdByName(mainManifest, cohortNames[["T1"]])
ecogIds <- testIds()$test_id[testIds()$kind == "ecog"]
t1All <- DatabaseConnector::renderTranslateQuerySql(connection,
  "SELECT CAST(subject_id AS VARCHAR) AS subject_id, cohort_definition_id AS test_id, cat, passes
     FROM (@lab_rows_sql) lr WHERE cat IS NOT NULL OR cohort_definition_id IN (@ecog_ids);",
  lab_rows_sql = labRowsSql(t1Id, passingOnly = FALSE), ecog_ids = paste(ecogIds, collapse = ", "))
names(t1All) <- tolower(names(t1All))
t1All$subject_id <- as.character(t1All$subject_id)
t1All$cat[is.na(t1All$cat)] <- "ECOG"
t1Rows <- dplyr::summarise(t1All[t1All$cat != "ECOG", ], passes = max(.data$passes),
                           .by = c("subject_id", "test_id", "cat"))
t1Tested <- dplyr::distinct(t1All, .data$subject_id, .data$cat)
strataT1 <- strataTbl[strataTbl$cohort_definition_id == t1Id, ]
strataT1$subject_id <- format(strataT1$subject_id, scientific = FALSE, trim = TRUE)
labOf <- dplyr::distinct(t1Rows, .data$test_id, .data$cat)

# 2x2 counts, % agreement and Cohen's kappa of two 0/1 vectors.
agreement <- function(x, y) {
  n <- length(x)
  a <- sum(x == 1 & y == 1); b <- sum(x == 1 & y == 0); c <- sum(x == 0 & y == 1); d <- sum(x == 0 & y == 0)
  pe <- ((a + b) * (a + c) + (c + d) * (b + d)) / n^2
  tibble::tibble(n = n, a = a, b = b, c = c, d = d, pct_agree = round(100 * (a + d) / n, 2),
                 kappa = if (pe < 1) round(((a + d) / n - pe) / (1 - pe), 4) else NA_real_)
}
# agreement()'s columns with no rows: keeps the outputs' shape at a site
# with no pairs to compare (e.g. ECOG but no labs).
noAgreement <- tibble::tibble(n = integer(), a = integer(), b = integer(), c = integer(),
                              d = integer(), pct_agree = double(), kappa = double())

# every unordered pair of v (none when fewer than two; combn() on a single
# number would enumerate 1..n instead)
pairsOf <- function(v) if (length(v) < 2L) matrix(v[0], nrow = 2L) else utils::combn(v, 2L)

testPairs <- pairsOf(sort(unique(t1Rows$test_id)))
kappaFor <- function(rows) {
  byTest <- split(rows[c("subject_id", "passes")], rows$test_id)
  dplyr::bind_rows(dplyr::mutate(noAgreement, test_id_1 = integer(), test_id_2 = integer(), .before = 1),
                   lapply(seq_len(ncol(testPairs)), function(k) {
    t1 <- byTest[[as.character(testPairs[1, k])]]; t2 <- byTest[[as.character(testPairs[2, k])]]
    if (is.null(t1) || is.null(t2)) return(NULL)
    both <- merge(t1, t2, by = "subject_id")
    if (nrow(both) == 0L) return(NULL)
    dplyr::mutate(agreement(both$passes.x, both$passes.y),
                  test_id_1 = testPairs[1, k], test_id_2 = testPairs[2, k], .before = 1)
  }))
}

# every lab tested in T1, plus ECOG even where no grade is recorded
labPairs <- pairsOf(sort(union(unique(t1Rows$cat), "ECOG")))
coverageKappaFor <- function(members, tested) {
  empty <- dplyr::mutate(noAgreement, lab_1 = character(), lab_2 = character(), .before = 1)
  if (length(members) == 0L) return(empty)
  dplyr::bind_rows(empty, lapply(seq_len(ncol(labPairs)), function(k) {
    x <- as.integer(members %in% tested$subject_id[tested$cat == labPairs[1, k]])
    y <- as.integer(members %in% tested$subject_id[tested$cat == labPairs[2, k]])
    dplyr::mutate(agreement(x, y), lab_1 = labPairs[1, k], lab_2 = labPairs[2, k], .before = 1)
  }))
}

# overall, then each active stratum; f(subjects in the view) -> rows
byStratum <- function(f) {
  out <- dplyr::bind_rows(lapply(c(list(overall = NULL), as.list(strataColumnNames)), function(col) {
    if (is.null(col)) return(dplyr::mutate(f(strataT1$subject_id), stratum_type = "overall",
                                           stratum_value = "overall"))
    groups <- split(strataT1$subject_id, strataT1[[col]])
    dplyr::bind_rows(lapply(names(groups), function(v)
      dplyr::mutate(f(groups[[v]]), stratum_type = col, stratum_value = v)))
  }))
  out[out$stratum_type %in% activeStrataTypes(), ]
}

# Censor the 2x2 counts; blank % agreement and kappa when the total or any
# cell is censored, since either would let the censored cell be solved back.
censorAgreement <- function(df) {
  cells <- c("a", "b", "c", "d")
  small <- df$n < settings$minCellCount |
    Reduce(`|`, lapply(cells, function(v) df[[v]] > 0 & df[[v]] < settings$minCellCount))
  df$pct_agree[small] <- NA; df$kappa[small] <- NA
  for (v in c("n", cells)) df[[v]] <- censor(df[[v]])
  df
}

kappaOut <- censorAgreement(byStratum(function(ids) kappaFor(t1Rows[t1Rows$subject_id %in% ids, ])))
kappaOut <- dplyr::rename(kappaOut, n_both = "n", n_pass_both = "a", n_pass_1_only = "b",
                          n_pass_2_only = "c", n_fail_both = "d")
kappaOut$label_1  <- label(kappaOut$test_id_1)
kappaOut$label_2  <- label(kappaOut$test_id_2)
kappaOut$same_lab <- labOf$cat[match(kappaOut$test_id_1, labOf$test_id)] ==
                     labOf$cat[match(kappaOut$test_id_2, labOf$test_id)]
kappaOut <- dplyr::mutate(kappaOut, cohort_definition_id = t1Id, cohort_name = cohortNames[["T1"]])
kappaOut <- kappaOut[c("cohort_definition_id", "cohort_name", "stratum_type", "stratum_value",
                       "test_id_1", "label_1", "test_id_2", "label_2", "same_lab", "n_both",
                       "n_pass_both", "n_pass_1_only", "n_pass_2_only", "n_fail_both",
                       "pct_agree", "kappa")]
writeResultCsv(kappaOut, "eligibility_test_kappa", "labs")
message("  eligibility_test_kappa: ", nrow(kappaOut), " test pairs x strata")

covKappaOut <- censorAgreement(byStratum(function(ids) coverageKappaFor(ids, t1Tested)))
covKappaOut <- dplyr::rename(covKappaOut, n_cohort = "n", n_tested_both = "a",
                             n_tested_1_only = "b", n_tested_2_only = "c", n_tested_neither = "d")
covKappaOut <- dplyr::mutate(covKappaOut, cohort_definition_id = t1Id, cohort_name = cohortNames[["T1"]])
covKappaOut <- covKappaOut[c("cohort_definition_id", "cohort_name", "stratum_type", "stratum_value",
                             "lab_1", "lab_2", "n_cohort", "n_tested_both", "n_tested_1_only",
                             "n_tested_2_only", "n_tested_neither", "pct_agree", "kappa")]
writeResultCsv(covKappaOut, "eligibility_lab_coverage_kappa", "labs")
message("  eligibility_lab_coverage_kappa: ", nrow(covKappaOut), " lab pairs x strata")
