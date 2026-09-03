# ===========================================================================
# 11_baseline_characterization.R  —  (k) weight/height/BMI + Charlson CCI
# ===========================================================================
# Two protocol-required baseline covariates not covered by
# R/07_demographics.R (age/sex/index year) or R/08_covariates.R (individual
# comorbidity flags + PS strata):
#
#   baseline_vitals.csv — per-cohort weight (kg) / height (cm) / BMI, closest
#     measurement to index within +/- settings$vitalsWindowDays
#     (sql/baseline_vitals.sql). Every cohort in bc_cohort, same scope as
#     R/07_demographics.R.
#
#   charlson_cci.csv — Charlson Comorbidity Index category distribution,
#     Cohort 1 only (matches R/08_covariates.R's existing "overlap with 1A"
#     scope). 16 of 19 canonical components are wired (R/charlsonScore.R for
#     the full list), sourced from Fortin/Reps/Ryan 2022 (BMC Med Inform
#     Decis Mak 22:225; 2023 correction 23:110) — the standard OHDSI-authored
#     SNOMED translation of the Quan 2005 Charlson coding algorithm — via new
#     comorbidity cohorts wired into R/08_covariates.R's `comorbMap`
#     (Myocardial_Infarction.json, Congestive_Heart_Failure.json,
#     Peripheral_Vascular_Disease.json, Chronic_Pulmonary_Disease.json,
#     Rheumatic_Disease.json, Peptic_Ulcer_Disease.json,
#     Diabetes_With_Complications.json, Hemiplegia_Paraplegia.json,
#     AIDS_HIV.json, and a corrected Liver_Disease.json split into
#     mild/Liver_Disease_Severe tiers). `metastatic_solid_tumor` is the one
#     exception: it's derived from Target_1A.json's own measurement-domain
#     metastasis marker (sql/metastasis_marker.sql), not the generic
#     Metastatic_Solid_Tumor.json concept set (still generated for
#     `covariate_overlap.csv`, just not consulted for CCI) — a real
#     smoke-test run found that generic claims-oriented SNOMED list firing
#     for 0 of 504 T1 subjects (this test CDM's condition coding is sparse
#     outside the concept sets Target_1A.json itself uses), which would have
#     silently understated nearly every subject's score by 6 points. Only
#     `leukemia` and `lymphoma` remain unwired: the same source's coding
#     algorithm merges them (and other non-hematologic tumors) into one
#     716-concept "malignancy except skin neoplasms" bucket with no
#     leukemia-only/lymphoma-only split available from a citable source, so
#     computeCharlsonScore() (R/charlsonScore.R) silently omits both and the
#     score is a (small) UNDERSTATEMENT of the true CCI for anyone with a
#     hematologic malignancy. `any_malignancy` is also unwired, but this is
#     immaterial here: every Cohort 1 member has `metastatic_solid_tumor`
#     (weight 6), which the scoring hierarchy always supersedes
#     `any_malignancy` (weight 2) with. See README "Known gaps".
#
# Depends on `covSet` (the generated comorbidity-cohort id/name map) from
# R/08_covariates.R — run this step after it.
# ===========================================================================

message("\n== (k) baseline characterization: vitals + Charlson CCI ==")

mainManifest <- loadState("mainManifest", "R/03_main_cohorts.R")
cohortNames  <- loadState("cohortNames", "R/03_main_cohorts.R")

nameMap <- dplyr::select(mainManifest, cohort_definition_id = "cohortId",
                         cohort_name = "cohortName")

# --- weight / height / BMI --------------------------------------------------
vitals <- querySqlFile(connection, "baseline_vitals.sql",
  cdm_database_schema  = settings$cdmDatabaseSchema,
  work_database_schema = settings$workDatabaseSchema,
  cohort_table         = settings$cohortTable,
  vitals_window_days   = settings$vitalsWindowDays)
names(vitals) <- tolower(names(vitals))
vitals$cohort_definition_id <- as.integer(vitals$cohort_definition_id)

# subject_strata.sql is the single source of truth for age_group/sex/age_sex
# bucketing (shared with demographics.sql, R/04_lab_ranges.R,
# R/09_outcomes.R, R/12_treatment_patterns.R). Aggregation here happens in R
# (not SQL), so the stratification join is a plain left_join + an extra
# grouping column, not a UNION-ALL rewrite of the SQL file.
strataTbl <- querySqlFile(connection, "subject_strata.sql",
  work_database_schema = settings$workDatabaseSchema,
  cohort_table         = settings$cohortTable,
  cdm_database_schema  = settings$cdmDatabaseSchema)
names(strataTbl) <- tolower(names(strataTbl))
strataTbl$cohort_definition_id <- as.integer(strataTbl$cohort_definition_id)
vitals <- dplyr::left_join(vitals, strataTbl,
  by = c("cohort_definition_id", "subject_id"))

summarizeVital <- function(df, valueCol, minCellCount, stratumType, groupCol = NULL) {
  grp <- c("cohort_definition_id", groupCol)
  agg <- df |>
    dplyr::filter(!is.na(.data[[valueCol]])) |>
    dplyr::group_by(dplyr::across(dplyr::all_of(grp))) |>
    dplyr::summarise(
      n      = dplyr::n(),
      mean   = mean(.data[[valueCol]]),
      sd     = stats::sd(.data[[valueCol]]),
      median = stats::median(.data[[valueCol]]),
      lq     = stats::quantile(.data[[valueCol]], 0.25),
      uq     = stats::quantile(.data[[valueCol]], 0.75),
      min    = min(.data[[valueCol]]),
      max    = max(.data[[valueCol]]),
      .groups = "drop")

  small    <- agg$n > 0L & agg$n < minCellCount
  statCols <- c("mean", "sd", "median", "lq", "uq", "min", "max")
  agg[statCols] <- lapply(agg[statCols], function(x) ifelse(small, NA_real_, as.double(x)))
  agg$n <- ifelse(small, -as.integer(minCellCount), as.integer(agg$n))
  agg$variable <- valueCol
  agg$stratum_type <- stratumType
  agg$stratum_value <- if (is.null(groupCol)) "overall" else agg[[groupCol]]
  dplyr::relocate(agg, "variable", "stratum_type", "stratum_value",
                  .after = "cohort_definition_id")[
    c("cohort_definition_id", "variable", "stratum_type", "stratum_value",
      "n", statCols)]
}

if (nrow(vitals) == 0L) {

  message("  no weight/height/BMI measurements found near any cohort index — skipping baseline_vitals.")

} else {

  # age_group/sex/age_sex come from activeStrataSpecs() (settings$strataColumns,
  # run.R CONFIG) so a site can narrow/disable stratification in one place.
  strataViews <- activeStrataSpecs()
  vitalsOut <- dplyr::bind_rows(lapply(c("weight_kg", "height_cm", "bmi"), function(v) {
      dplyr::bind_rows(lapply(names(strataViews), function(st)
        summarizeVital(vitals, v, settings$minCellCount, st, strataViews[[st]])))
    })) |>
    dplyr::left_join(nameMap, by = "cohort_definition_id") |>
    dplyr::relocate("cohort_name", .after = "cohort_definition_id")
  writeResultCsv(vitalsOut, "baseline_vitals")
  message("  baseline_vitals: ", nrow(vitalsOut), " row(s)")
}

# --- Charlson CCI (Cohort 1 only) -------------------------------------------
# code -> canonical Charlson component name (R/charlsonScore.R). Hypertension
# and Venous Thrombotic Events are NOT Charlson components, so they're not
# listed here — they stay as their own standalone rows in covariate_overlap.csv.
# `metastatic_solid_tumor` is deliberately absent from this map — it's
# derived separately, below, from Target_1A.json's own metastasis marker
# (see the comment there for why). `diabetes_with_complication`/
# `mild_liver_disease` supersede `diabetes_without_complication`/
# `moderate_severe_liver_disease` automatically per computeCharlsonScore()'s
# hierarchy rules when a subject has both.
charlsonMap <- tibble::tribble(
  ~cohortName,                     ~component,
  "Type 2 Diabetes",              "diabetes_without_complication",
  "Diabetes With Complications",  "diabetes_with_complication",
  "Myocardial Infarction",        "myocardial_infarction",
  "Congestive Heart Failure",     "congestive_heart_failure",
  "Peripheral Vascular Disease",  "peripheral_vascular_disease",
  "Stroke",                       "cerebrovascular_disease",
  "Chronic Pulmonary Disease",    "chronic_pulmonary_disease",
  "Rheumatic Disease",            "rheumatologic_disease",
  "Peptic Ulcer Disease",         "peptic_ulcer_disease",
  "Liver Disease",                "mild_liver_disease",
  "Liver Disease Severe",         "moderate_severe_liver_disease",
  "Renal Disease",                "renal_disease",
  "Hemiplegia Paraplegia",        "hemiplegia_paraplegia",
  "AIDS HIV",                     "aids_hiv",
  "Dementia",                     "dementia"
)

t1Id <- cohortIdByName(mainManifest, cohortNames[["T1"]])

covSet <- tryCatch(loadState("covSet", "R/08_covariates.R"), error = function(e) NULL)

if (is.null(covSet) || nrow(covSet) == 0L) {

  message("  no comorbidity cohorts generated (see step (h)) — skipping Charlson CCI.")

} else {

  flagIds <- dplyr::inner_join(charlsonMap,
    dplyr::transmute(covSet, cohortName, covariate_id = as.integer(cohortId)),
    by = "cohortName")

  if (nrow(flagIds) == 0L) {

    message("  none of the mapped comorbidity cohorts were generated — skipping Charlson CCI.")

  } else {

    flagMembership <- querySqlFile(connection, "outcome_target_data.sql",
      work_database_schema = settings$workDatabaseSchema,
      cohort_table         = settings$covariateCohortTable,
      target_cohort_ids    = paste(flagIds$covariate_id, collapse = ", "))
    names(flagMembership) <- tolower(names(flagMembership))
    flagMembership$cohort_definition_id <- as.integer(flagMembership$cohort_definition_id)
    flagMembership$subject_id           <- as.integer(flagMembership$subject_id)

    t1Members <- querySqlFile(connection, "outcome_target_data.sql",
      work_database_schema = settings$workDatabaseSchema,
      cohort_table         = settings$cohortTable,
      target_cohort_ids    = as.character(t1Id))
    names(t1Members) <- tolower(names(t1Members))
    t1Members$subject_id <- as.integer(t1Members$subject_id)

    components <- tibble::tibble(subject_id = unique(t1Members$subject_id))

    for (i in seq_len(nrow(flagIds))) {
      flaggedSubjects <- flagMembership$subject_id[
        flagMembership$cohort_definition_id == flagIds$covariate_id[i]]
      components[[flagIds$component[i]]] <-
        as.integer(components$subject_id %in% flaggedSubjects)
    }

    # metastatic_solid_tumor: derive from Target_1A.json's OWN metastasis
    # measurement marker (AJCC/UICC Stage 4, AJCC/UICC M1, Metastasis — its
    # PrimaryCriteria's ConceptSet id 0), not the generic claims-oriented
    # Charlson SNOMED condition list wired above (a real smoke-test run
    # found that one firing for 0 of 504 T1 subjects — this test CDM's
    # condition coding is sparse outside the concept sets Target_1A.json
    # itself uses). Re-deriving from the exact marker that defines Cohort 1
    # membership keeps a single source of truth and stays correct if that
    # marker ever changes, unlike a hardcoded assumption.
    target1aConceptSets <- jsonlite::fromJSON(
      readr::read_file(file.path(cohortsDir, "01_Target", "Target_1A.json")),
      simplifyVector = FALSE)$ConceptSets
    metastasisConceptSet <- Filter(function(cs) cs$id == 0, target1aConceptSets)[[1]]
    if (any(vapply(metastasisConceptSet$expression$items,
                   function(it) isTRUE(it$isExcluded), logical(1))))
      stop("Target_1A.json's metastasis concept set (id 0) now has an ",
           "excluded item — update sql/metastasis_marker.sql's caller to ",
           "handle exclusions.", call. = FALSE)
    metastasisConceptIds <- vapply(metastasisConceptSet$expression$items,
      function(it) it$concept$CONCEPT_ID, integer(1))

    metastasisFlag <- querySqlFile(connection, "metastasis_marker.sql",
      cdm_database_schema   = settings$cdmDatabaseSchema,
      vocab_database_schema = settings$vocabDatabaseSchema,
      work_database_schema  = settings$workDatabaseSchema,
      cohort_table          = settings$cohortTable,
      target_cohort_ids     = as.character(t1Id),
      ancestor_concept_ids  = paste(metastasisConceptIds, collapse = ", "))
    names(metastasisFlag) <- tolower(names(metastasisFlag))
    metastasisFlag$subject_id <- as.integer(metastasisFlag$subject_id)

    components$metastatic_solid_tumor <-
      as.integer(components$subject_id %in% metastasisFlag$subject_id)

    cci <- computeCharlsonScore(components)
    cciOut <- dplyr::count(cci, .data$cci_category, name = "n")
    small <- cciOut$n > 0L & cciOut$n < settings$minCellCount
    cciOut$n <- ifelse(small, -settings$minCellCount, cciOut$n)
    cciOut$cohort_definition_id <- t1Id
    cciOut <- dplyr::left_join(cciOut, nameMap, by = "cohort_definition_id") |>
      dplyr::relocate(c("cohort_definition_id", "cohort_name"), .before = "cci_category")

    writeResultCsv(cciOut, "charlson_cci")
    message("  charlson_cci: ", nrow(components), " subject(s), ",
            nrow(flagIds) + 1L, " of 19 component(s) wired")
  }
}
