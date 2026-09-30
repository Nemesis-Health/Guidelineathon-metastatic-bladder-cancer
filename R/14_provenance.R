# ===========================================================================
# 14_provenance.R  —  (n) record provenance of the bladder cancer and
# other-malignancy condition codes
# ===========================================================================
# sql/provenance/*.sql : every condition_occurrence record a population
#   patient has for a concept set, split by condition_type_concept_id (EHR,
#   claims, registry, ...) -- all of a patient's records, not only those near
#   index. One row per type, plus an 'ALL' row (empty type_concept_id)
#   pooling them.
#     bladder_cancer_provenance.sql   -- [GDE] Bladder Cancer (codeset 5 in
#                                        Target_1A.json)
#     other_malignancy_provenance.sql -- [GDE] Excluded primaries (codeset 3),
#                                        the set T1A's "no other cancer" rule
#                                        excludes on
#   The population is built in the SQL itself, not read from bc_cohort: each
#   patient's first metastasis measurement ([GDE] metastasis (measurement),
#   codeset 0), limited to patients with a bladder cancer code from 180 days
#   before to 30 days after it. T1A's age and other-cancer rules are not
#   applied, so it is broader than Target 1A.
#
# Two outputs: bladder_cancer_provenance.csv and other_malignancy_provenance.csv
# (type_concept_id, type_concept_name, n_patients, n_records), n_patients
# censored to -minCellCount and n_records blanked on a censored row (same rule
# as lab_cohort_counts.csv).
#
# Reads the CDM only, so it doesn't depend on any earlier step.
# sql/provenance/translated/ holds per-dialect copies of the same queries for
# running by hand; the pipeline reads the OHDSI SQL sources.
# ===========================================================================

message("\n== (n) record provenance of bladder cancer / other-malignancy codes ==")

provenanceQueries <- c(
  bladder_cancer_provenance   = "provenance/bladder_cancer_provenance.sql",
  other_malignancy_provenance = "provenance/other_malignancy_provenance.sql")

for (name in names(provenanceQueries)) {
  prov <- querySqlFile(connection, provenanceQueries[[name]],
    cdm_database_schema        = settings$cdmDatabaseSchema,
    vocabulary_database_schema = settings$vocabDatabaseSchema)
  names(prov) <- tolower(names(prov))
  prov$n_patients <- as.integer(prov$n_patients)
  prov$n_records  <- as.integer(prov$n_records)

  small <- prov$n_patients > 0 & prov$n_patients < settings$minCellCount
  prov$n_patients <- ifelse(small, -settings$minCellCount, prov$n_patients)
  prov$n_records  <- ifelse(small, NA, prov$n_records)

  out <- dplyr::transmute(prov,
    type_concept_id   = as.integer(.data$type_concept_id),
    type_concept_name = .data$type_concept_name,
    n_patients        = .data$n_patients,
    n_records         = .data$n_records)
  # 'ALL' first, then types by record count as the SQL orders them
  out <- out[order(!is.na(out$type_concept_id)), ]
  writeResultCsv(out, name, "characterization")
  message("  ", name, ": ", sum(!is.na(out$type_concept_id)), " record types")
}
