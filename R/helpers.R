# ===========================================================================
# helpers.R  —  self-contained cohort-generation + SQL utilities
# ===========================================================================
# Thin reimplementations of the OncoStudyModules orchestration using the OHDSI
# packages directly (CirceR, CohortGenerator, SqlRender, DatabaseConnector), so
# this project has no dependency on OncoStudyModules.
# ===========================================================================

# --- resumable state checkpoints --------------------------------------------
# Several steps build an expensive/derived R object (mainManifest, covSet,
# episodes, regimenClass, ...) that lives only in memory. If the R session
# crashes after that step ran, re-sourcing a later step used to fail with a
# bare "object not found" — forcing you to reconstruct it by hand. These two
# helpers checkpoint such objects to disk as they're built, and transparently
# reload them if a later step is sourced standalone without the object
# already in memory (falling back to `producedBy` in the error message when
# neither the in-memory object nor a checkpoint exists, e.g. an early crash).
saveState <- function(name, obj, path = NULL) {
  path <- path %||% file.path(settings$outputFolder, "state", paste0(name, ".rds"))
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  saveRDS(obj, path)
}

loadState <- function(name, producedBy, path = NULL) {
  if (exists(name, envir = .GlobalEnv, inherits = FALSE))
    return(get(name, envir = .GlobalEnv))
  path <- path %||% file.path(settings$outputFolder, "state", paste0(name, ".rds"))
  if (!file.exists(path))
    stop("`", name, "` isn't in memory and no checkpoint was found at ", path,
         " — make sure ", producedBy, " has been run first.", call. = FALSE)
  message("  (resuming) loaded `", name, "` from ", path)
  readRDS(path)
}

# --- read JSON cohort definitions from a directory tree --------------------
# Manifest name = filename with "_" -> " " (matches the study convention).
# cohortId is assigned by row order here (see buildCohortSet()), and a
# directory can hold more than one JSON cohort (cohorts/01_Target/ has both
# Target_1A.json and Target_1A_PC_allowed.json) - so the order list.files()
# returns them in determines which cohort gets which id downstream.
# list.files() sorts using the session's LC_COLLATE locale, which is NOT the
# same across every machine this runs on (e.g. a bare/C-locale Docker image
# vs. a desktop OS's language locale can order "Target_1A.json" vs.
# "Target_1A_PC_allowed.json" differently, since they diverge on "." vs "_"
# right after the shared "Target_1A" prefix). Re-sort explicitly with the
# "radix" method, which is locale-independent (effectively C-locale byte
# order), so cohortId assignment is deterministic regardless of where this
# is run.
readJsonCohorts <- function(dir) {
  files <- list.files(dir, pattern = "[.]json$", recursive = TRUE, full.names = TRUE)
  files <- sort(files, method = "radix")
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

# --- fail loudly on a NULL/missing SqlRender parameter, instead of letting
# SqlRender silently substitute it as an empty string (e.g. a NULL
# `settings$someKey` turning `-@some_param` into a bare `-`, which only
# surfaces later as a cryptic DBMS-specific syntax error) ------------------
.checkSqlRenderParams <- function(file, params) {
  bad <- names(params)[vapply(params, function(x) length(x) == 0L || is.na(x)[1], logical(1))]
  if (length(bad) > 0L)
    stop("querySqlFile/runSqlFile(\"", file, "\"): parameter(s) ",
         paste(bad, collapse = ", "), " are NULL/NA — check that `settings` ",
         "defines them (see run.R) before sourcing this step.", call. = FALSE)
}

# --- render + translate + execute a .sql file ------------------------------
runSqlFile <- function(connection, file, ...) {
  .checkSqlRenderParams(file, list(...))
  sql <- paste(readLines(file.path(sqlDir, file), warn = FALSE), collapse = "\n")
  sql <- SqlRender::render(sql, ..., warnOnMissingParameters = FALSE)
  sql <- SqlRender::translate(sql, targetDialect = .getDbms(connection))
  DatabaseConnector::executeSql(connection, sql)
}

# --- render + translate + query a .sql file --------------------------------
querySqlFile <- function(connection, file, ...) {
  .checkSqlRenderParams(file, list(...))
  sql <- paste(readLines(file.path(sqlDir, file), warn = FALSE), collapse = "\n")
  sql <- SqlRender::render(sql, ..., warnOnMissingParameters = FALSE)
  sql <- SqlRender::translate(sql, targetDialect = .getDbms(connection))
  DatabaseConnector::querySql(connection, sql)
}

# --- render (no translate, no execute) a .sql file --------------------------
# For assembling one file's fully-resolved text as a fragment injected into
# another template (e.g. subject_strata.sql's body becomes demographics.sql's
# `coh` CTE, or a stratifyTemplate's strata subquery) -- resolve the source
# fragment's own placeholders here FIRST, so the two files' parameters can't
# collide when the outer template is rendered.
renderSqlFile <- function(file, ...) {
  .checkSqlRenderParams(file, list(...))
  sql <- paste(readLines(file.path(sqlDir, file), warn = FALSE), collapse = "\n")
  SqlRender::render(sql, ..., warnOnMissingParameters = FALSE)
}

# --- write a result data frame to results/eligibility ----------------------
writeResultCsv <- function(df, name) {
  d <- file.path(settings$outputFolder, "eligibility")
  dir.create(d, recursive = TRUE, showWarnings = FALSE)
  readr::write_csv(df, file.path(d, paste0(name, ".csv")), na = "")
}

# --- id lookup for a generated cohort by manifest name ---------------------
cohortIdByName <- function(manifest, name) {
  hit <- manifest$cohortId[manifest$cohortName == name]
  if (length(hit) == 0L) NA_integer_ else as.integer(hit[1])
}
