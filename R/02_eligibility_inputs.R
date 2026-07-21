# ===========================================================================
# 02_eligibility_inputs.R  —  (b) eligibility labs AND cohorts -> one table
# ===========================================================================
# Approach A: every eligibility input lands in @labCohortTable.
#   1. lab_cohorts.sql  -> labs (test_ids 1-23, 44-48) + raw normalised rows
#   2. generate ECOG + condition cohorts
#   3. INSERT their membership into @labCohortTable under reserved test-id slots
# The eligibility_2*.sql templates (step 03) then read one table uniformly.
# ===========================================================================

message("\n== (b) eligibility inputs (labs + cohorts -> ", settings$labCohortTable, ") ==")

# --- 1. lab_cohorts.sql -----------------------------------------------------
labScratch <- list(
  cat_concept_table = "bc_lab_cat_concept", unit_factor_table = "bc_lab_unit_factor",
  normals_table = "bc_lab_normals", criteria_table = "bc_lab_criteria",
  grp_table = "bc_lab_grp", scales_table = "bc_lab_scales",
  scored_table = "bc_lab_scored", resolved_table = "bc_lab_resolved",
  debug_table = "bc_lab_debug")

do.call(runSqlFile, c(list(connection = connection, file = "lab_cohorts.sql",
  cdm_database_schema = settings$cdmDatabaseSchema,
  work_database_schema = settings$workDatabaseSchema,
  raw_lab_results_table = settings$rawLabResultsTable,
  lab_cohort_table = settings$labCohortTable), labScratch))
message("  labs written to ", settings$labCohortTable, " + ", settings$rawLabResultsTable)

# --- 2. generate ECOG + condition cohorts -----------------------------------
# cohort name -> reserved test-id slot in the unified table.
eligMap <- tibble::tribble(
  ~cohortName,                   ~test_id,
  "ECOG 0",                      24L,
  "ECOG 1",                      25L,
  "ECOG 2",                      26L,
  "ECOG 3plus",                  27L,
  "Peripheral Neuropathy",       33L,
  "Significant Skin Disorders",  34L,
  "Audiometric Hearing Loss",    40L,
  "Polyuria",                    35L,
  "Polydipsia",                  36L,
  "Anticoagulant Therapy",       31L,
  "Liver Metastasis",            28L,
  "Gilberts Syndrome",           29L
)

covJson <- readJsonCohorts(file.path(cohortsDir, "02_Covariate"))
eligJson <- covJson[covJson$cohortName %in% eligMap$cohortName, ]
missing  <- setdiff(eligMap$cohortName, eligJson$cohortName)
if (length(missing)) stop("Missing eligibility cohort JSON(s): ",
                          paste(missing, collapse = ", "), call. = FALSE)

eligSet <- buildCohortSet(jsonCohorts = eligJson, startId = 1L)
eligCounts <- generateCohorts(connection, eligSet, dropTables = TRUE)
print(eligCounts)

# --- 3. insert each into the unified eligibility table ----------------------
for (i in seq_len(nrow(eligMap))) {
  nm  <- eligMap$cohortName[i]; tid <- eligMap$test_id[i]
  sid <- cohortIdByName(eligSet, nm)
  runSqlFile(connection, "insert_eligibility_cohorts.sql",
             work_database_schema = settings$workDatabaseSchema,
             lab_cohort_table = settings$labCohortTable,
             cohort_table = settings$cohortTable,
             source_cohort_id = sid, test_id = tid)
  message(sprintf("  %-28s (cohort %s) -> %s test_id %d",
                  nm, sid, settings$labCohortTable, tid))
}
