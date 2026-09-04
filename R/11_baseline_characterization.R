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
#     every cohort in the main tree x subject_strata.sql stratum (matches
#     R/08_covariates.R's own scope). Each cohort's components are anchored
#     to THAT COHORT'S OWN index date via sql/charlson_components.sql (same
#     unbounded on/before-index look-back as covariate_overlap.csv -- fixed
#     from an earlier version of this file, which flagged a component
#     whenever a subject was EVER a member of the comorbidity cohort, with
#     no date bound at all). Flags + strata are computed entirely in SQL via
#     conditional aggregation, not pulled per-subject and joined/pivoted in R.
#     16 of 19 canonical components are wired (R/charlsonScore.R for
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

nameMap <- dplyr::select(mainManifest, cohort_definition_id = "cohortId",
                         cohort_name = "cohortName")

# --- weight / height / BMI, per cohort x variable x stratum -----------------
# Computed entirely in SQL (percentiles via the same ROW_NUMBER/CASE
# interpolation as lab_value_distribution_portable.sql/
# demographics_continuous.sql, stratified the same UNION-ALL way) rather than
# pulling one row per cohort member with a vitals measurement into R and
# aggregating there.
strataFragment <- renderSqlFile("subject_strata.sql",
  work_database_schema = settings$workDatabaseSchema,
  cohort_table         = settings$cohortTable,
  cdm_database_schema  = settings$cdmDatabaseSchema)

vitalsOut <- querySqlFile(connection, "baseline_vitals.sql",
  cdm_database_schema  = settings$cdmDatabaseSchema,
  work_database_schema = settings$workDatabaseSchema,
  cohort_table         = settings$cohortTable,
  vitals_window_days   = settings$vitalsWindowDays,
  subject_strata_sql   = strataFragment)
names(vitalsOut) <- tolower(names(vitalsOut))

if (nrow(vitalsOut) == 0L) {

  message("  no weight/height/BMI measurements found near any cohort index — skipping baseline_vitals.")

} else {

  vitalsOut$cohort_definition_id <- as.integer(vitalsOut$cohort_definition_id)
  # settings$strataColumns (run.R CONFIG, via activeStrataTypes()) controls
  # which stratum views actually reach the CSV -- the SQL always computes all
  # four (cheap), a site that wants fewer/none just filters here.
  vitalsOut <- vitalsOut[vitalsOut$stratum_type %in% activeStrataTypes(), ]

  small <- vitalsOut$n > 0 & vitalsOut$n < settings$minCellCount
  statCols <- c("mean", "sd", "median", "lq", "uq", "min", "max")
  vitalsOut[statCols] <- lapply(vitalsOut[statCols], function(x) ifelse(small, NA_real_, as.double(x)))
  vitalsOut$n <- ifelse(small, -settings$minCellCount, vitalsOut$n)

  vitalsOut <- dplyr::left_join(vitalsOut, nameMap, by = "cohort_definition_id") |>
    dplyr::relocate("cohort_name", .after = "cohort_definition_id")
  vitalsOut <- vitalsOut[c("cohort_definition_id", "cohort_name", "variable",
                          "stratum_type", "stratum_value", "n", statCols)]
  writeResultCsv(vitalsOut, "baseline_vitals", "characterization")
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

targetIds <- mainManifest$cohortId

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

    # One row per (cohort, subject) a subject belongs to across the whole
    # main tree, with every Charlson component flag AND the age_group/sex/
    # age_sex strata already computed in SQL (sql/charlson_components.sql --
    # each component's on/before-index look-back matches
    # covariate_overlap.csv's; component_flags_sql is a small dynamically-
    # built list of "MAX(CASE WHEN cov.cohort_definition_id = <id> THEN 1
    # ELSE 0 END) AS <component>" expressions, since which comorbidity
    # cohorts are present varies by run -- the query itself, not R, does the
    # JOIN/aggregation work that scales with subject volume). The SAME
    # subject is scored once per cohort, since their comorbidity flags (and
    # hence CCI) can differ by which cohort's index anchors the look-back
    # (e.g. a later treatment-initiation index has more time for
    # comorbidities to accrue than the earlier mBC index).
    componentFlagsSql <- paste(sprintf(
      "MAX(CASE WHEN cov.cohort_definition_id = %d THEN 1 ELSE 0 END) AS %s",
      flagIds$covariate_id, flagIds$component), collapse = ",\n       ")

    strataFragment <- renderSqlFile("subject_strata.sql",
      work_database_schema = settings$workDatabaseSchema,
      cohort_table         = settings$cohortTable,
      cdm_database_schema  = settings$cdmDatabaseSchema)

    components <- querySqlFile(connection, "charlson_components.sql",
      work_database_schema   = settings$workDatabaseSchema,
      cohort_table           = settings$cohortTable,
      covariate_cohort_table = settings$covariateCohortTable,
      cohort_definition_ids  = paste(targetIds, collapse = ", "),
      component_flags_sql    = componentFlagsSql,
      subject_strata_sql     = strataFragment)
    names(components) <- tolower(names(components))
    components$cohort_definition_id <- as.integer(components$cohort_definition_id)
    components$subject_id           <- as.integer(components$subject_id)

    # metastatic_solid_tumor: derive from Target_1A.json's OWN metastasis
    # measurement marker (AJCC/UICC Stage 4, AJCC/UICC M1, Metastasis — its
    # PrimaryCriteria's ConceptSet id 0), not the generic claims-oriented
    # Charlson SNOMED condition list wired above (a real smoke-test run
    # found that one firing for 0 of 504 T1 subjects — this test CDM's
    # condition coding is sparse outside the concept sets Target_1A.json
    # itself uses). Re-deriving from the exact marker that defines Cohort 1
    # membership keeps a single source of truth and stays correct if that
    # marker ever changes, unlike a hardcoded assumption. No cohort join
    # needed: metastasis_marker.sql has no date restriction (the marker
    # predates or equals T1 entry, hence every downstream cohort's own
    # later-or-equal index too — see that file's header), so presence is a
    # pure subject-level fact, independent of which target cohort a
    # `components` row is for.
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
      target_cohort_ids     = paste(targetIds, collapse = ", "),
      ancestor_concept_ids  = paste(metastasisConceptIds, collapse = ", "))
    names(metastasisFlag) <- tolower(names(metastasisFlag))
    metastasisFlag$subject_id <- as.integer(metastasisFlag$subject_id)

    components$metastatic_solid_tumor <-
      as.integer(components$subject_id %in% metastasisFlag$subject_id)

    # computeCharlsonScore() ignores unknown columns and preserves row order,
    # so cohort_definition_id and the strata columns (not themselves
    # recognised components) survive by just carrying them over positionally
    # afterward -- already joined in charlson_components.sql above, no
    # separate subject_strata.sql fetch/join needed here.
    cci <- computeCharlsonScore(components)
    cci$cohort_definition_id <- components$cohort_definition_id
    cci$age_group <- components$age_group
    cci$sex       <- components$sex
    cci$age_sex   <- components$age_sex

    cciStrataViews <- activeStrataSpecs()
    cciOut <- dplyr::bind_rows(lapply(names(cciStrataViews), function(st) {
      col <- cciStrataViews[[st]]
      grp <- c("cohort_definition_id", col)
      agg <- dplyr::count(cci, dplyr::across(dplyr::all_of(grp)), .data$cci_category, name = "n")
      agg$stratum_type <- st
      agg$stratum_value <- if (is.null(col)) "overall" else agg[[col]]
      agg
    }))
    small <- cciOut$n > 0L & cciOut$n < settings$minCellCount
    cciOut$n <- ifelse(small, -settings$minCellCount, cciOut$n)
    cciOut <- dplyr::left_join(cciOut, nameMap, by = "cohort_definition_id") |>
      dplyr::relocate(c("cohort_definition_id", "cohort_name", "stratum_type", "stratum_value"),
                      .before = "cci_category")
    cciOut <- cciOut[c("cohort_definition_id", "cohort_name", "stratum_type",
                       "stratum_value", "cci_category", "n")]
    cciOut <- cciOut[order(cciOut$cohort_definition_id, cciOut$stratum_type,
                           cciOut$stratum_value, cciOut$cci_category), ]

    writeResultCsv(cciOut, "charlson_cci", "characterization")
    message("  charlson_cci: ", dplyr::n_distinct(components$subject_id), " subject(s) across ",
            dplyr::n_distinct(components$cohort_definition_id), " cohorts, ",
            nrow(flagIds) + 1L, " of 19 component(s) wired")
  }
}
