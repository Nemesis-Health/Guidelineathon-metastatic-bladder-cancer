# ===========================================================================
# helpers.R  —  self-contained cohort-generation + SQL utilities
# ===========================================================================
# Thin reimplementations of the OncoStudyModules orchestration using the OHDSI
# packages directly (CirceR, CohortGenerator, SqlRender, DatabaseConnector), so
# this project has no dependency on OncoStudyModules.
# ===========================================================================

# --- read JSON cohort definitions from a directory tree --------------------
# Manifest name = filename with "_" -> " " (matches the study convention).
readJsonCohorts <- function(dir) {
  files <- list.files(dir, pattern = "[.]json$", recursive = TRUE, full.names = TRUE)
  tibble::tibble(
    cohortName = gsub("_", " ", tools::file_path_sans_ext(basename(files))),
    json       = vapply(files, function(f) readr::read_file(f), character(1)),
    file       = files
  )
}

# --- CirceR: cohort-expression JSON -> OHDSI cohort SQL --------------------
# generateStats = TRUE bakes Circe's inclusion-rule-statistics SQL into the
# query (populates cohort_inclusion / cohort_inclusion_stats / cohort_summary_stats
# on generation) — only worth it for JSON cohorts with named InclusionRules
# whose attrition we actually want (Target 1A).
jsonToCohortSql <- function(json, generateStats = FALSE) {
  expr <- CirceR::cohortExpressionFromJson(json)
  CirceR::buildCohortQuery(expr, CirceR::createGenerateOptions(generateStats = generateStats))
}

# --- assemble a CohortGenerator cohortDefinitionSet ------------------------
# `jsonCohorts`  : tibble(cohortName, json) — SQL built via CirceR.
# `customCohorts`: tibble(cohortName, sql)  — pre-rendered SQL templates
#                  (leave @target_* for CohortGenerator to fill).
# `generateStats`: applies to all `jsonCohorts` rows in this call (see
#                  jsonToCohortSql); custom SQL templates have no Circe
#                  inclusion rules, so it has no effect on them.
buildCohortSet <- function(jsonCohorts = NULL, customCohorts = NULL, startId = 1L,
                           generateStats = FALSE) {
  parts <- list()
  nextId <- as.integer(startId)
  if (!is.null(jsonCohorts) && nrow(jsonCohorts) > 0) {
    j <- jsonCohorts
    j$cohortId <- seq.int(nextId, length.out = nrow(j))
    j$sql <- vapply(j$json, jsonToCohortSql, character(1), generateStats = generateStats)
    nextId <- max(j$cohortId) + 1L
    parts$json <- tibble::tibble(cohortId = j$cohortId, cohortName = j$cohortName,
                                 sql = j$sql, json = j$json)
  }
  if (!is.null(customCohorts) && nrow(customCohorts) > 0) {
    cc <- customCohorts
    cc$cohortId <- seq.int(nextId, length.out = nrow(cc))
    parts$custom <- tibble::tibble(cohortId = cc$cohortId, cohortName = cc$cohortName,
                                   sql = cc$sql, json = NA_character_)
  }
  dplyr::bind_rows(parts)
}

# --- generate a cohortDefinitionSet into the work schema -------------------
generateCohorts <- function(connection, cohortDefinitionSet, dropTables = TRUE,
                            cohortTable = settings$cohortTable) {
  tableNames <- CohortGenerator::getCohortTableNames(cohortTable = cohortTable)
  if (dropTables) {
    CohortGenerator::dropCohortStatsTables(
      connection = connection, cohortDatabaseSchema = settings$workDatabaseSchema,
      cohortTableNames = tableNames, dropCohortTable = TRUE) |> suppressWarnings() |> try(silent = TRUE)
  }
  CohortGenerator::createCohortTables(
    connection = connection, cohortDatabaseSchema = settings$workDatabaseSchema,
    cohortTableNames = tableNames, incremental = FALSE)

  # Fill @vocabulary_database_schema up-front (CirceR SQL references it); the
  # rest (@cdm/@target_*) are filled by generateCohortSet.
  cds <- cohortDefinitionSet
  cds$sql <- vapply(cds$sql, function(s)
    SqlRender::render(s, vocabulary_database_schema = settings$vocabDatabaseSchema,
                      warnOnMissingParameters = FALSE), character(1))

  CohortGenerator::generateCohortSet(
    connection = connection, cdmDatabaseSchema = settings$cdmDatabaseSchema,
    cohortDatabaseSchema = settings$workDatabaseSchema,
    cohortTableNames = tableNames, cohortDefinitionSet = cds, incremental = FALSE)

  counts <- CohortGenerator::getCohortCounts(
    connection = connection, cohortDatabaseSchema = settings$workDatabaseSchema,
    cohortTable = tableNames$cohortTable, cohortDefinitionSet = cds)
  # Select only the count columns: some CohortGenerator versions merge the whole
  # cohortDefinitionSet (cohortName/sql/json) into getCohortCounts()'s result,
  # which would duplicate cohortName (.x/.y) and drag sql/json into the join.
  dplyr::left_join(cds[c("cohortId", "cohortName")],
                   counts[c("cohortId", "cohortEntries", "cohortSubjects")],
                   by = "cohortId")
}

# --- render + translate + execute a .sql file ------------------------------
runSqlFile <- function(connection, file, ...) {
  sql <- paste(readLines(file.path(sqlDir, file), warn = FALSE), collapse = "\n")
  sql <- SqlRender::render(sql, ..., warnOnMissingParameters = FALSE)
  sql <- SqlRender::translate(sql, targetDialect = .getDbms(connection))
  DatabaseConnector::executeSql(connection, sql)
}

# --- render + translate + query a .sql file --------------------------------
querySqlFile <- function(connection, file, ...) {
  sql <- paste(readLines(file.path(sqlDir, file), warn = FALSE), collapse = "\n")
  sql <- SqlRender::render(sql, ..., warnOnMissingParameters = FALSE)
  sql <- SqlRender::translate(sql, targetDialect = .getDbms(connection))
  DatabaseConnector::querySql(connection, sql)
}

# --- write a result data frame to results/csv ------------------------------
writeResultCsv <- function(df, name) {
  d <- file.path(settings$outputFolder, "csv")
  dir.create(d, recursive = TRUE, showWarnings = FALSE)
  readr::write_csv(df, file.path(d, paste0(name, ".csv")), na = "")
}

# --- id lookup for a generated cohort by manifest name ---------------------
cohortIdByName <- function(manifest, name) {
  hit <- manifest$cohortId[manifest$cohortName == name]
  if (length(hit) == 0L) NA_integer_ else as.integer(hit[1])
}
