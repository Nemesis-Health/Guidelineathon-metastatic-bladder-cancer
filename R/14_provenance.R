# ===========================================================================
# 14_provenance.R  —  (n) record provenance of the Target 1A defining
# condition codes
# ===========================================================================
# sql/provenance/*.sql : every condition_occurrence record a Target 1A member
#   has for a concept set, split by condition_type_concept_id (EHR, claims,
#   registry, ...) -- all of a member's records, not only those near index.
#   One row per type, plus an 'ALL' row (empty type_concept_id) pooling them.
#     bladder_cancer_provenance.sql   -- [GDE] Bladder Cancer (codeset 5 in
#                                        Target_1A.json)
#     other_malignancy_provenance.sql -- [GDE] Excluded primaries (codeset 3),
#                                        the set T1A's "no other cancer" rule
#                                        excludes on
#
# Two outputs: bladder_cancer_provenance.csv and other_malignancy_provenance.csv
# (cohort_definition_id, cohort_name, type_concept_id, type_concept_name,
# n_patients, n_records), n_patients censored to -minCellCount and n_records
# blanked on a censored row (same rule as lab_cohort_counts.csv).
#
# Depends on R/03_main_cohorts.R (mainManifest, cohortNames), so must run
# after it. sql/provenance/translated/ holds per-dialect copies of the same
# queries for running by hand; the pipeline reads the OHDSI SQL sources.
# ===========================================================================

message("\n== (n) record provenance of Target 1A condition codes ==")

mainManifest <- loadState("mainManifest", "R/03_main_cohorts.R")
cohortNames  <- loadState("cohortNames", "R/03_main_cohorts.R")

targetCohortId <- cohortIdByName(mainManifest, cohortNames[["T1"]])
if (is.na(targetCohortId))
  stop("Target 1A (T1) cohort id not found in mainManifest -- has R/03_main_cohorts.R run?",
       call. = FALSE)

provenanceQueries <- c(
  bladder_cancer_provenance   = "provenance/bladder_cancer_provenance.sql",
  other_malignancy_provenance = "provenance/other_malignancy_provenance.sql")

for (name in names(provenanceQueries)) {
  prov <- querySqlFile(connection, provenanceQueries[[name]],
    cdm_database_schema        = settings$cdmDatabaseSchema,
    vocabulary_database_schema = settings$vocabDatabaseSchema,
    cohort_database_schema     = settings$workDatabaseSchema,
    cohort_table               = settings$cohortTable,
    cohort_id                  = targetCohortId)
  names(prov) <- tolower(names(prov))
  prov$n_patients <- as.integer(prov$n_patients)
  prov$n_records  <- as.integer(prov$n_records)

  small <- prov$n_patients > 0 & prov$n_patients < settings$minCellCount
  prov$n_patients <- ifelse(small, -settings$minCellCount, prov$n_patients)
  prov$n_records  <- ifelse(small, NA, prov$n_records)

  out <- dplyr::transmute(prov,
    cohort_definition_id = targetCohortId,
    cohort_name          = cohortNames[["T1"]],
    type_concept_id      = as.integer(.data$type_concept_id),
    type_concept_name    = .data$type_concept_name,
    n_patients           = .data$n_patients,
    n_records            = .data$n_records)
  # 'ALL' first, then types by record count as the SQL orders them
  out <- out[order(!is.na(out$type_concept_id)), ]
  writeResultCsv(out, name, "characterization")
  message("  ", name, ": ", sum(!is.na(out$type_concept_id)), " record types")
}
