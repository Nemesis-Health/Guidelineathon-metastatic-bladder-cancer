# ===========================================================================
# 02_eligibility_inputs.R  —  (b) eligibility labs AND cohorts -> one table
# ===========================================================================
# Approach A: every eligibility input lands in @labCohortTable.
#   1. lab_cohorts.sql  -> labs + raw normalised rows
#   2. generate ECOG + condition cohorts
#   3. INSERT their membership into @labCohortTable under their test-id slots
# Test-id slots: cohorts/extras/eligibility_test_ids.csv (see testIds()).
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
  lab_cohort_table = settings$labCohortTable), labScratch, testIdParams()))
message("  labs written to ", settings$labCohortTable, " + ", settings$rawLabResultsTable)

# The criteria table must hold exactly the registry's lab slots.
critIds <- DatabaseConnector::renderTranslateQuerySql(connection,
  "SELECT test_id FROM @work_database_schema.@criteria_table;",
  work_database_schema = settings$workDatabaseSchema,
  criteria_table = labScratch$criteria_table)[[1]]
labIds <- testIds()$test_id[testIds()$kind == "lab"]
if (!setequal(critIds, labIds) || anyDuplicated(critIds))
  stop("lab_cohorts.sql criteria test_ids (", paste(sort(critIds), collapse = ", "),
       ") don't match the lab rows of eligibility_test_ids.csv (",
       paste(labIds, collapse = ", "), ").", call. = FALSE)

# --- 2. generate ECOG + condition cohorts -----------------------------------
# cohort name -> test-id slot in the unified table (the non-lab registry rows).
eligMap <- with(testIds()[testIds()$kind != "lab", ],
                tibble::tibble(cohortName = source_cohort, test_id = test_id))

covJson <- readJsonCohorts(file.path(cohortsDir, "04_Eligibility"))
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
