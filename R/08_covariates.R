# ===========================================================================
# 08_covariates.R  —  covariate overlap with cohort 1A (mBC)
# ===========================================================================
# Descriptive covariate counts NOT used by the main cohort tree, reported as an
# overlap with cohort 1A (the overall mBC cohort):
#   * comorbidities  — 1A subjects with >=1 qualifying record ON/BEFORE their 1A
#                      index (prevalent baseline comorbidity).
#   * performance status strata — 1A subjects with an ECOG record in the stratum
#                      within +/- labIndexWindowDays of index (KPS folded in).
#
# One output: covariate_overlap.csv (code, label, n_1a, n_overlap), small
# cells censored to -minCellCount (same rule as step 05). No derived % column:
# it is n_overlap / n_1a, computable downstream.
#
# Comorbidity cohorts are generated into their OWN table (covariateCohortTable),
# never bc_cohort. TO ADD A COMORBIDITY: drop its JSON into cohorts/02_Covariate/
# with a filename whose "_"->" " form matches a `cohortName` in comorbMap below
# (e.g. Renal_Disease.json -> "Renal Disease"). Missing entries are skipped with
# a message, so the file is all that is needed once its row is listed here.
# ===========================================================================

message("\n== covariate overlap with 1A (comorbidities + performance status) ==")

# code -> covariate cohort name (filename with "_"->" ") -> human label
comorbMap <- tibble::tribble(
  ~code,      ~cohortName,                 ~label,
  "T2DM",     "Type 2 Diabetes",           "Type 2 diabetes mellitus",
  "HTN",      "Hypertension",              "Hypertension",
  "CVD",      "Cardiovascular Disease",    "Cardiovascular disease",
  "Stroke",   "Stroke",                    "Stroke",
  "VTE",      "Venous Thrombotic Events",  "Venous thromboembolic events",
  "LiverDx",  "Liver Disease",             "Liver disease",
  "RenalDx",  "Renal Disease",             "Renal disease",
  "Dementia", "Dementia",                  "Dementia"
)
# performance-status strata (derived from the reserved ECOG slots 24-27)
psLabels <- c("PS1" = "Performance status = 0", "PS2" = "Performance status = 1",
              "PS2+" = "Performance status >= 2", "PS 0-2" = "Performance status 0-2",
              "PS 0-1" = "Performance status 0-1")

cohort1Id <- cohortIdByName(mainManifest, "T1 Metastatic bladder cancer")
nT1 <- as.integer(querySqlFile(connection, "n_target1a.sql",
  work_database_schema = settings$workDatabaseSchema,
  cohort_table = settings$cohortTable, cohort1_id = cohort1Id)[[1]][1])

# --- comorbidities: generate the present JSONs into a SEPARATE table ---------
covJson  <- readJsonCohorts(file.path(cohortsDir, "02_Covariate"))
present  <- comorbMap[comorbMap$cohortName %in% covJson$cohortName, ]
absent   <- comorbMap[!comorbMap$cohortName %in% covJson$cohortName, ]
if (nrow(absent))
  message("  skipping ", nrow(absent), " comorbidity cohort(s) with no JSON in ",
          "cohorts/02_Covariate/ (add the file to include): ",
          paste(absent$code, collapse = ", "))

comorbRows <- tibble::tibble()
if (nrow(present)) {
  covSet <- buildCohortSet(
    jsonCohorts = covJson[covJson$cohortName %in% present$cohortName, ], startId = 1L)
  generateCohorts(connection, covSet, dropTables = TRUE,
                  cohortTable = settings$covariateCohortTable)

  ov <- querySqlFile(connection, "covariate_overlap.sql",
    work_database_schema   = settings$workDatabaseSchema,
    cohort_table           = settings$cohortTable,
    covariate_cohort_table = settings$covariateCohortTable,
    cohort1_id             = cohort1Id)
  names(ov) <- tolower(names(ov))

  # covariate cohort id -> name -> code/label (cohorts with 0 overlap: n = 0)
  idName <- data.frame(covariate_id = as.integer(covSet$cohortId),
                       cohortName   = covSet$cohortName, stringsAsFactors = FALSE)
  comorbRows <- present |>
    dplyr::left_join(idName, by = "cohortName") |>
    dplyr::left_join(
      dplyr::mutate(ov, covariate_id = as.integer(.data$covariate_id)),
      by = "covariate_id") |>
    dplyr::transmute(.data$code, .data$label,
                     n_overlap = dplyr::coalesce(as.integer(.data$n_overlap), 0L))
}

# --- performance status strata (from ECOG slots 24-27 in the lab table) ------
ps <- querySqlFile(connection, "ps_overlap.sql",
  work_database_schema = settings$workDatabaseSchema,
  cohort_table         = settings$cohortTable,
  lab_cohort_table     = settings$labCohortTable,
  cohort1_id           = cohort1Id,
  window               = settings$labIndexWindowDays)
names(ps) <- tolower(names(ps))
psRows <- tibble::tibble(code = ps$code,
                         label = unname(psLabels[ps$code]),
                         n_overlap = as.integer(ps$n_overlap))

# --- combine, censor, write --------------------------------------------------
out <- dplyr::bind_rows(psRows, comorbRows)
out$n_1a <- nT1

small <- !is.na(out$n_overlap) & out$n_overlap > 0 & out$n_overlap < settings$minCellCount
out$n_overlap <- ifelse(small, -settings$minCellCount, out$n_overlap)

out <- out[c("code", "label", "n_1a", "n_overlap")]
writeResultCsv(out, "covariate_overlap")
message("  covariate_overlap: ", nrow(out), " covariates x 1A (n=", nT1, ")")
