# ===========================================================================
# 15_rollups.R  —  (o) condition and drug roll-ups (protocol's concept-based
# baseline comorbidities: condition groups and drug era groups)
# ===========================================================================
# sql/condition_rollup.sql : conditions on/before index, in disease categories
#   (SNOMED parents + descendants; one category per concept, by precedence).
# sql/drug_rollup.sql      : drugs on/before index, in ATC 1st-level groups
#   (a drug counts in every group it belongs to).
# Both cover every cohort in the main tree, anchored to each cohort's own
# index, with an unbounded look-back (as the comorbidity overlap), and are
# stratified like every other output (subject_strata.sql).
#
# Drugs come from drug_era, as the protocol specifies; a CDM whose drug_era
# is empty falls back to drug_exposure start dates (logged, and recorded in
# drug_rollup.csv's source_table column).
#
# other_cancer_rollup.csv: condition_rollup.sql with cancer =
#   TRUE on T1, the mixed bag and T1all: the cohorts' own "Excluded
#   primaries" codes within [index - 180d, index + 30d], by cancer site (the
#   ICD-10 C-blocks), with records and subjects with >= 2 records.
#
# Three outputs: condition_rollup.csv, drug_rollup.csv and
# other_cancer_rollup.csv (cohort_definition_id, cohort_name, stratum_type,
# stratum_value, category [+ atc_code], n_cohort, n_subjects [+
# n_subjects_2plus, n_records]), counts censored to -minCellCount.
# ===========================================================================

message("\n== (o) condition and drug roll-ups ==")

mainManifest <- loadState("mainManifest", "R/03_main_cohorts.R")
cohortNames  <- loadState("cohortNames", "R/03_main_cohorts.R")
targetIds    <- mainManifest$cohortId

strataFragment <- renderSqlFile("subject_strata.sql",
  work_database_schema = settings$workDatabaseSchema,
  cohort_table         = settings$cohortTable,
  cdm_database_schema  = settings$cdmDatabaseSchema)

drugEraRows <- DatabaseConnector::renderTranslateQuerySql(connection,
  "SELECT TOP 1 person_id FROM @cdm_database_schema.drug_era;",
  cdm_database_schema = settings$cdmDatabaseSchema)
useDrugEra <- nrow(drugEraRows) > 0L
drugSource <- if (useDrugEra) "drug_era" else "drug_exposure"
if (!useDrugEra) message("  drug_era is empty -- drug roll-up uses drug_exposure instead.")

nameMap <- data.frame(cohort_definition_id = as.integer(mainManifest$cohortId),
                      cohort_name = mainManifest$cohortName)

# Query rows carry the per-(cohort, stratum) denominator as category
# "n_cohort"; move it into its own column, censor, keep the active strata.
shapeRollup <- function(raw) {
  names(raw) <- tolower(names(raw))
  raw$cohort_definition_id <- as.integer(raw$cohort_definition_id)
  raw$n_subjects <- as.integer(raw$n_subjects)
  key <- c("cohort_definition_id", "stratum_type", "stratum_value")
  denom <- raw[raw$category == "n_cohort", c(key, "n_subjects")]
  names(denom)[names(denom) == "n_subjects"] <- "n_cohort"
  out <- dplyr::left_join(raw[raw$category != "n_cohort", ], denom, by = key)
  out <- out[out$stratum_type %in% activeStrataTypes(), ]
  censor <- function(x) ifelse(!is.na(x) & x > 0 & x < settings$minCellCount,
                               -settings$minCellCount, x)
  if ("n_records" %in% names(out)) {   # condition_rollup.sql only
    out$n_records[out$n_subjects > 0 & out$n_subjects < settings$minCellCount] <- NA
    out$n_subjects_2plus <- censor(as.integer(out$n_subjects_2plus))
  }
  out$n_cohort   <- censor(out$n_cohort)
  out$n_subjects <- censor(out$n_subjects)
  out <- dplyr::left_join(out, nameMap, by = "cohort_definition_id")
  out[order(out$cohort_definition_id, out$stratum_type, out$stratum_value,
            out$category_order), ]
}

conditions <- shapeRollup(querySqlFile(connection, "condition_rollup.sql",
  work_database_schema       = settings$workDatabaseSchema,
  cohort_table               = settings$cohortTable,
  cdm_database_schema        = settings$cdmDatabaseSchema,
  vocabulary_database_schema = settings$vocabDatabaseSchema,
  cohort_definition_ids      = paste(targetIds, collapse = ", "),
  cancer                     = FALSE,
  subject_strata_sql         = strataFragment))
conditions$category_order <- as.integer(conditions$category_order)
# Not reported: the vocabulary maps metastases recorded as conditions to the
# primary-site malignancy (a liver metastasis becomes 'Malignant neoplasm of
# liver'), so this category would mix other primaries with this cohort's own
# metastases. The category stays in the SQL so neoplasm codes don't fall
# through into the organ categories.
conditions <- conditions[conditions$category != "Neoplasm (other than bladder cancer)", ]
conditions <- conditions[order(conditions$cohort_definition_id, conditions$stratum_type,
                               conditions$stratum_value, conditions$category_order), ]
writeResultCsv(conditions[c("cohort_definition_id", "cohort_name", "stratum_type",
                            "stratum_value", "category", "n_cohort", "n_subjects")],
               "condition_rollup", "characterization")
message("  condition_rollup: ", dplyr::n_distinct(conditions$category), " categories across ",
        dplyr::n_distinct(conditions$cohort_definition_id), " cohorts")

drugs <- shapeRollup(querySqlFile(connection, "drug_rollup.sql",
  work_database_schema       = settings$workDatabaseSchema,
  cohort_table               = settings$cohortTable,
  cdm_database_schema        = settings$cdmDatabaseSchema,
  vocabulary_database_schema = settings$vocabDatabaseSchema,
  cohort_definition_ids      = paste(targetIds, collapse = ", "),
  use_drug_era               = as.integer(useDrugEra),
  subject_strata_sql         = strataFragment))
drugs$atc_code     <- ifelse(drugs$category_order == "ZZ", NA, drugs$category_order)
drugs$source_table <- drugSource
writeResultCsv(drugs[c("cohort_definition_id", "cohort_name", "stratum_type", "stratum_value",
                       "atc_code", "category", "n_cohort", "n_subjects", "source_table")],
               "drug_rollup", "characterization")
message("  drug_rollup (", drugSource, "): ", dplyr::n_distinct(drugs$category), " groups across ",
        dplyr::n_distinct(drugs$cohort_definition_id), " cohorts")

# Other cancers: the "Excluded primaries" concept set the T1 cohorts' rule uses.
cancerSet <- Filter(function(cs) cs$name == "[GDE] Excluded primaries",
  jsonlite::fromJSON(file.path(cohortsDir, "01_Target", "Target_1A.json"),
                     simplifyVector = FALSE)$ConceptSets)[[1]]
cancerCodeset <- SqlRender::render(
  CirceR::buildConceptSetQuery(as.character(jsonlite::toJSON(cancerSet$expression, auto_unbox = TRUE))),
  vocabulary_database_schema = settings$vocabDatabaseSchema)
cancers <- shapeRollup(querySqlFile(connection, "condition_rollup.sql",
  work_database_schema       = settings$workDatabaseSchema,
  cohort_table               = settings$cohortTable,
  cdm_database_schema        = settings$cdmDatabaseSchema,
  vocabulary_database_schema = settings$vocabDatabaseSchema,
  cohort_definition_ids      = paste(idsByCodes(c("T1", "T1mb", "T1all")), collapse = ", "),
  cancer                     = TRUE,
  cancer_codeset_sql         = cancerCodeset,
  subject_strata_sql         = strataFragment))
cancers$category_order <- as.integer(cancers$category_order)
cancers <- cancers[order(cancers$cohort_definition_id, cancers$stratum_type,
                         cancers$stratum_value, cancers$category_order), ]
writeResultCsv(cancers[c("cohort_definition_id", "cohort_name", "stratum_type", "stratum_value",
                         "category", "n_cohort", "n_subjects", "n_subjects_2plus", "n_records")],
               "other_cancer_rollup", "characterization")
message("  other_cancer_rollup: ", dplyr::n_distinct(cancers$category), " sites across ",
        dplyr::n_distinct(cancers$cohort_definition_id), " cohorts")
