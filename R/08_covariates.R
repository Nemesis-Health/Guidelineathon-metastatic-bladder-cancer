# ===========================================================================
# 08_covariates.R  —  covariate overlap, every main cohort x stratum
# ===========================================================================
# Descriptive covariate counts NOT used by the main cohort tree, reported as an
# overlap with every cohort in the main tree (same scope as
# eligibility_input_coverage.csv/lab_value_distribution.csv), each anchored to
# THAT COHORT'S OWN index date:
#   * comorbidities  — members with >=1 qualifying record ON/BEFORE their own
#                      index (prevalent baseline comorbidity) -- an unbounded
#                      look-back, not a windowed one.
#   * performance status strata — members with an ECOG record in the stratum
#                      within labWindowBeforeDays before / labWindowAfterDays
#                      after their own index (KPS folded in) -- deliberately
#                      a near-index window, not the comorbidities' unbounded
#                      look-back: PS is a point-in-time functional
#                      assessment, not a chronic condition flag.
#
# Every (cohort, covariate) pair is reported once overall and once per
# subject_strata.sql stratum (age_group/sex/age_sex) -- same convention as
# every other stratified output; settings$strataColumns (via
# activeStrataTypes()) controls which views actually get written.
#
# One output: covariate_overlap.csv (cohort_definition_id, cohort_name,
# stratum_type, stratum_value, code, label, n_cohort, n_overlap), small cells
# censored to -minCellCount (same rule as step 05). Every (cohort, stratum,
# code) combination gets an explicit row, zero-filled where there's no
# overlap at all -- not silently absent. No derived % column: it is
# n_overlap / n_cohort, computable downstream.
#
# Comorbidity cohorts are generated into their OWN table (covariateCohortTable),
# never bc_cohort. TO ADD A COMORBIDITY: drop its JSON into cohorts/02_Covariate/
# with a filename whose "_"->" " form matches a `cohortName` in comorbMap below
# (e.g. Renal_Disease.json -> "Renal Disease"). Missing entries are skipped with
# a message, so the file is all that is needed once its row is listed here.
# ===========================================================================

message("\n== covariate overlap with the main cohort tree (comorbidities + performance status) ==")

# code -> covariate cohort name (filename with "_"->" ") -> human label
#
# The last 11 rows (MI onward) exist for Charlson CCI scoring
# (R/11_baseline_characterization.R, R/charlsonScore.R) — sourced from
# Fortin/Reps/Ryan 2022 (BMC Med Inform Decis Mak 22:225, 2023 correction
# 23:110), the standard OHDSI-authored SNOMED translation of the Quan 2005
# Charlson coding algorithm — but they double as their own comorbidity rows
# here for free.
comorbMap <- tibble::tribble(
  ~code,          ~cohortName,                   ~label,
  "T2DM",         "Type 2 Diabetes",             "Type 2 diabetes mellitus",
  "HTN",          "Hypertension",                "Hypertension",
  "CVD",          "Cardiovascular Disease",       "Cardiovascular disease",
  "Stroke",       "Stroke",                       "Stroke",
  "VTE",          "Venous Thrombotic Events",     "Venous thromboembolic events",
  "LiverDx",      "Liver Disease",                "Liver disease (mild)",
  "RenalDx",      "Renal Disease",                "Renal disease",
  "Dementia",     "Dementia",                     "Dementia",
  "MI",           "Myocardial Infarction",        "Myocardial infarction",
  "CHF",          "Congestive Heart Failure",     "Congestive heart failure",
  "PVD",          "Peripheral Vascular Disease",  "Peripheral vascular disease",
  "COPD",         "Chronic Pulmonary Disease",    "Chronic pulmonary disease",
  "RheumDx",      "Rheumatic Disease",            "Rheumatic disease",
  "PUD",          "Peptic Ulcer Disease",         "Peptic ulcer disease",
  "DMComplic",    "Diabetes With Complications",  "Diabetes with chronic complications",
  "Hemiplegia",   "Hemiplegia Paraplegia",        "Hemiplegia or paraplegia",
  "AIDS",         "AIDS HIV",                     "AIDS/HIV",
  "LiverDxSevere","Liver Disease Severe",         "Liver disease (moderate/severe)",
  "MetSolidTumor","Metastatic Solid Tumor",        "Metastatic solid tumor"
)
# performance-status strata (derived from the reserved ECOG slots 24-27)
psLabels <- c("PS1" = "Performance status = 0", "PS2" = "Performance status = 1",
              "PS2+" = "Performance status >= 2", "PS 0-2" = "Performance status 0-2",
              "PS 0-1" = "Performance status 0-1")

mainManifest <- loadState("mainManifest", "R/03_main_cohorts.R")
targetIds <- mainManifest$cohortId

# subject_strata.sql is the single source of truth for age_group/sex/age_sex
# bucketing (shared with demographics.sql, R/04/05/09/10/12) -- resolve it
# once, reused both to stratify the two overlap queries below and to build
# the matching per-(cohort, stratum) denominators (a stratum's "n_cohort" is
# that cohort's members in that stratum, not the cohort's whole N).
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
denomTbl <- denomTbl[denomTbl$stratum_type %in% activeStrataTypes(), ]

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
  saveState("covSet", covSet)
  generateCohorts(connection, covSet, dropTables = TRUE,
                  cohortTable = settings$covariateCohortTable)

  ov <- querySqlFile(connection, "covariate_overlap.sql",
    work_database_schema   = settings$workDatabaseSchema,
    cohort_table           = settings$cohortTable,
    covariate_cohort_table = settings$covariateCohortTable,
    cohort_definition_ids  = paste(targetIds, collapse = ", "),
    subject_strata_sql     = strataFragment)
  names(ov) <- tolower(names(ov))
  ov <- ov[ov$stratum_type %in% activeStrataTypes(), ]
  ov$cohort_definition_id <- as.integer(ov$cohort_definition_id)
  ov$covariate_id         <- as.integer(ov$covariate_id)

  # covariate cohort id -> name, so overlap rows can be matched back to
  # code/label (idName), and every present covariate gets a skeleton row per
  # (cohort, stratum) below even when the query above has no matching row
  # (zero overlap, not silently absent).
  idName <- data.frame(covariate_id = as.integer(covSet$cohortId),
                       cohortName   = covSet$cohortName, stringsAsFactors = FALSE)

  skeleton <- dplyr::cross_join(
    dplyr::select(denomTbl, "stratum_type", "stratum_value", "cohort_definition_id", "n_cohort"),
    dplyr::select(present, "code", "label", "cohortName")) |>
    dplyr::left_join(idName, by = "cohortName")

  comorbRows <- skeleton |>
    dplyr::left_join(
      dplyr::mutate(ov, covariate_id = as.integer(.data$covariate_id)),
      by = c("stratum_type", "stratum_value", "cohort_definition_id", "covariate_id")) |>
    dplyr::transmute(.data$stratum_type, .data$stratum_value, .data$cohort_definition_id,
                     .data$n_cohort, .data$code, .data$label,
                     n_overlap = dplyr::coalesce(as.integer(.data$n_overlap), 0L))
}

# --- performance status strata (from ECOG slots 24-27 in the lab table) ------
ps <- querySqlFile(connection, "ps_overlap.sql",
  work_database_schema   = settings$workDatabaseSchema,
  cohort_table           = settings$cohortTable,
  lab_cohort_table       = settings$labCohortTable,
  cohort_definition_ids  = paste(targetIds, collapse = ", "),
  lab_window_before_days = settings$labWindowBeforeDays,
  lab_window_after_days  = settings$labWindowAfterDays,
  subject_strata_sql     = strataFragment)
names(ps) <- tolower(names(ps))
ps <- ps[ps$stratum_type %in% activeStrataTypes(), ]
ps$cohort_definition_id <- as.integer(ps$cohort_definition_id)

psSkeleton <- dplyr::cross_join(
  dplyr::select(denomTbl, "stratum_type", "stratum_value", "cohort_definition_id", "n_cohort"),
  tibble::tibble(code = names(psLabels), label = unname(psLabels)))

psRows <- psSkeleton |>
  dplyr::left_join(ps, by = c("stratum_type", "stratum_value", "cohort_definition_id", "code")) |>
  dplyr::transmute(.data$stratum_type, .data$stratum_value, .data$cohort_definition_id,
                   .data$n_cohort, .data$code, .data$label,
                   n_overlap = dplyr::coalesce(as.integer(.data$n_overlap), 0L))

# --- combine, censor, write --------------------------------------------------
out <- dplyr::bind_rows(psRows, comorbRows)
out <- dplyr::left_join(out,
  dplyr::select(mainManifest, cohort_definition_id = "cohortId", cohort_name = "cohortName"),
  by = "cohort_definition_id")

small <- !is.na(out$n_overlap) & out$n_overlap > 0 & out$n_overlap < settings$minCellCount
out$n_overlap <- ifelse(small, -settings$minCellCount, out$n_overlap)

out <- out[c("cohort_definition_id", "cohort_name", "stratum_type", "stratum_value",
             "code", "label", "n_cohort", "n_overlap")]
out <- out[order(out$cohort_definition_id, out$stratum_type, out$stratum_value, out$code), ]
writeResultCsv(out, "covariate_overlap", "characterization")
message("  covariate_overlap: ", nrow(out), " rows across ",
        dplyr::n_distinct(out$cohort_definition_id), " cohorts")
