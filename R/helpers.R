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
  path <- path %||% file.path(settings$stateFolder, paste0(name, ".rds"))
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  saveRDS(obj, path)
}

loadState <- function(name, producedBy, path = NULL) {
  if (exists(name, envir = .GlobalEnv, inherits = FALSE))
    return(get(name, envir = .GlobalEnv))
  path <- path %||% file.path(settings$stateFolder, paste0(name, ".rds"))
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

# --- CohortDiagnostics::executeDiagnostics() with upstream-bug patches -----
# Same arguments as CohortDiagnostics::executeDiagnostics(). Applies the
# patches in R/vendor_utils.R that this connection's dialect/driver needs
# (each is a no-op otherwise) for the duration of the call only, restoring
# the original functions on exit -- also on error -- so anything run later
# in the same session gets stock DatabaseConnector/CohortGenerator.
runCohortDiagnostics <- function(connection, ...) {
  patches <- list()
  on.exit(for (p in rev(patches)) .restorePatchedFunctions(p), add = TRUE)
  patches[[1]] <- .patchDbiTempTableInsert(connection)
  patches[[2]] <- .patchBigQueryInclusionRuleIds(connection)
  CohortDiagnostics::executeDiagnostics(connection = connection, ...)
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
         "defines them (see run.R and R/study_settings.R) before sourcing this step.", call. = FALSE)
}

# --- eligibility test ids ----------------------------------------------------
# cohorts/extras/eligibility_test_ids.csv declares every test-id slot of the
# unified eligibility table (@lab_cohort_table). SQL refers to a slot as
# @t_<key> and to sets of slots by the list params of testIdParams().
.testIdCache <- new.env()
testIds <- function() {
  if (is.null(.testIdCache$ids)) {
    ids <- readr::read_csv(file.path(extrasDir, "eligibility_test_ids.csv"),
                           col_types = "icccic", na = "")
    stopifnot(!anyDuplicated(ids$test_id), !anyDuplicated(ids$key),
              grepl("^[a-z0-9_]+$", ids$key),
              ids$kind %in% c("lab", "ecog", "condition", "drug", "symptom"),
              is.na(ids$source_cohort) == (ids$kind == "lab"),
              !is.na(ids$ecog_grade) == (ids$kind == "ecog"))
    # SqlRender fills @t_ab with t_a's value when only t_a is passed, so no
    # key may be a prefix of another.
    pre <- outer(ids$key, ids$key, function(a, b) a != b & startsWith(b, a))
    if (any(pre))
      stop("eligibility_test_ids.csv: key(s) ", paste(ids$key[rowSums(pre) > 0], collapse = ", "),
           " are prefixes of other keys; rename them.", call. = FALSE)
    .testIdCache$ids <- ids
  }
  .testIdCache$ids
}

# SqlRender params: t_<key> = id, plus id lists (comma strings) and the ECOG
# id -> grade CASE branches.
testIdParams <- function() {
  ids  <- testIds()
  of   <- function(kinds) paste(ids$test_id[ids$kind %in% kinds], collapse = ", ")
  ecog <- ids[ids$kind == "ecog", ]
  c(stats::setNames(as.list(ids$test_id), paste0("t_", ids$key)),
    list(ecog_ids             = of("ecog"),
         condition_window_ids = of("condition"),
         passthrough_ids      = of(c("condition", "drug", "symptom")),
         ecog_grade_cases     = paste("WHEN", ecog$test_id, "THEN", ecog$ecog_grade, collapse = " ")))
}

# Stop if rendered SQL still holds a test-id placeholder (param not passed).
.checkTestIdsRendered <- function(sql, file) {
  left <- regmatches(sql, gregexpr(
    "@(t_[a-z0-9_]+|ecog_ids|condition_window_ids|passthrough_ids|ecog_grade_cases)\\b",
    sql, perl = TRUE))[[1]]
  if (length(left))
    stop(file, ": unfilled test-id parameter(s) ", paste(unique(left), collapse = ", "),
         " (pass testIdParams() when rendering).", call. = FALSE)
  sql
}

# --- render + translate + execute a .sql file ------------------------------
runSqlFile <- function(connection, file, ...) {
  .checkSqlRenderParams(file, list(...))
  sql <- paste(readLines(file.path(sqlDir, file), warn = FALSE), collapse = "\n")
  sql <- SqlRender::render(sql, ..., warnOnMissingParameters = FALSE)
  .checkTestIdsRendered(sql, file)
  sql <- SqlRender::translate(sql, targetDialect = .getDbms(connection))
  DatabaseConnector::executeSql(connection, sql)
}

# --- render + translate + query a .sql file --------------------------------
querySqlFile <- function(connection, file, ...) {
  .checkSqlRenderParams(file, list(...))
  sql <- paste(readLines(file.path(sqlDir, file), warn = FALSE), collapse = "\n")
  sql <- SqlRender::render(sql, ..., warnOnMissingParameters = FALSE)
  .checkTestIdsRendered(sql, file)
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
  .checkTestIdsRendered(SqlRender::render(sql, ..., warnOnMissingParameters = FALSE), file)
}

# --- which subject_strata.sql breakdowns are active --------------------------
# Single control point for settings$strataColumns (R/study_settings.R), so every
# stratified output reads the same setting instead of hardcoding its own
# on/off list. Two shapes, for the two ways stratified outputs consume
# subject_strata.sql:
#   activeStrataTypes() -- "overall" + whichever of settings$strataColumns
#     are enabled, e.g. c("overall", "age_group", "sex"). SQL-side outputs
#     (lab_value_distribution_portable.sql, lab_timing_to_index_portable.sql,
#     eligibility_input_coverage.sql, cohort_counts_stratified.sql) always
#     compute all four views (cheap -- a single extra GROUP BY column each);
#     the caller filters its result to `stratum_type %in% activeStrataTypes()`
#     before writing, so disabled views never reach the CSV.
#   activeStrataSpecs() -- named list, stratum_type -> column name to group
#     by (NULL for "overall"), filtered to the active types. R-side outputs
#     that loop over stratum columns themselves (R/steps/50_outcomes.R,
#     R/steps/60_adherence.R, R/steps/22_baseline_characterization.R,
#     R/steps/70_treatment_patterns.R) iterate this instead of their own literal
#     list -- disabled strata are never computed there at all, not just
#     hidden after the fact.
#   strataColumnNames -- every per-subject strata column subject_strata.sql
#     emits that can be reported (index_year is separate: outcomes add it
#     themselves). Each stratum_type is named after its column.
strataColumnNames <- c("age_group", "sex", "age_sex", "age_band",
                       "index_period", "index_period_2021")

activeStrataTypes <- function()
  c("overall", intersect(strataColumnNames, settings$strataColumns))

activeStrataSpecs <- function() {
  specs <- c(list(overall = NULL), stats::setNames(as.list(strataColumnNames), strataColumnNames))
  specs[activeStrataTypes()]
}

# --- write a result data frame to results/eligibility/<category> -----------
# Every writeResultCsv() call names one of these; keep in sync with
# README.md's <!-- category:... --> markers (writeCategoryReadmes() below).
resultCategories <- c("characterization", "labs", "artemis", "outcomes",
                      "guideline", "treatment_patterns")

writeResultCsv <- function(df, name, category) {
  stopifnot(category %in% resultCategories)
  d <- file.path(settings$outputFolder, "eligibility", category)
  dir.create(d, recursive = TRUE, showWarnings = FALSE)
  readr::write_csv(df, file.path(d, paste0(name, ".csv")), na = "")
}

# --- per-category README, excerpted verbatim from this repo's own README.md
# So the folder doc and the real documentation can never drift apart: each
# results/eligibility/<category>/README.md is exactly the text between
# README.md's <!-- category:X --> ... <!-- /category:X --> markers, copied
# as-is. Silently skips a category whose markers are missing/duplicated
# (e.g. running from a checkout without README.md) rather than failing the
# run over documentation.
writeCategoryReadmes <- function() {
  readmePath <- file.path(projectRoot, "README.md")
  if (!file.exists(readmePath)) return(invisible(NULL))
  lines <- readLines(readmePath, warn = FALSE)
  for (category in resultCategories) {
    startIdx <- which(lines == paste0("<!-- category:", category, " -->"))
    endIdx   <- which(lines == paste0("<!-- /category:", category, " -->"))
    if (length(startIdx) != 1L || length(endIdx) != 1L || endIdx <= startIdx) {
      warning("README.md markers for category '", category, "' missing or ",
              "duplicated -- skipping its README.md.", call. = FALSE)
      next
    }
    d <- file.path(settings$outputFolder, "eligibility", category)
    dir.create(d, recursive = TRUE, showWarnings = FALSE)
    writeLines(lines[(startIdx + 1L):(endIdx - 1L)], file.path(d, "README.md"))
  }
}

# --- id lookup for a generated cohort by manifest name ---------------------
# Stops if the name isn't in the manifest (names come from cohortNames in
# R/steps/12_main_cohorts.R, so a miss is a typo or a stale manifest).
cohortIdByName <- function(manifest, name) {
  hit <- manifest$cohortId[manifest$cohortName == name]
  if (length(hit) == 0L)
    stop("Cohort not found in manifest: \"", name, "\"", call. = FALSE)
  as.integer(hit[1])
}

# Ids for cohortNames codes, e.g. idsByCodes(c("T1", "T2a")); stops on any miss.
idsByCodes <- function(codes, manifest = mainManifest, names = cohortNames)
  as.integer(vapply(codes, function(cd) cohortIdByName(manifest, names[[cd]]), integer(1)))

# Cohorts indexed on treatment start, per cohortIndex (R/steps/12_main_cohorts.R).
treatedCohortIds <- function(index = cohortIndex)
  idsByCodes(names(index)[index == "treatment"])

# Cohorts of patients reaching the 2b/2c/2d check (R/steps/12_main_cohorts.R). They
# exist as input-coverage denominators, so they appear in cohort counts and
# input coverage only; every other per-cohort output leaves them out.
reachedNodeCohortIds <- function(manifest = mainManifest) {
  names <- loadState("cohortNames", "R/steps/12_main_cohorts.R")
  as.integer(manifest$cohortId[manifest$cohortName %in% names[c("T2bR", "T2cR", "T2dR")]])
}

# Lab window of each cohort as days around its index, e.g. "-30..0".
labWindowLabel <- function(cohortIds, treatedIds = treatedCohortIds()) {
  treated <- cohortIds %in% treatedIds
  paste0(-ifelse(treated, settings$treatedLabWindowBeforeDays, settings$labWindowBeforeDays), "..",
         ifelse(treated, settings$treatedLabWindowAfterDays, settings$labWindowAfterDays))
}

# eligibility_lab_rows.sql rendered for these anchor cohorts: the one place
# the closest-lab rule and its windows are applied. Treated cohorts use
# settings$treatedLabWindowBefore/AfterDays for labs, ECOG and conditions.
labRowsSql <- function(anchorIds, passingOnly, treatedIds = integer(0),
                       closest = settings$labValueSelection == "closest") {
  ids <- function(x) if (length(x)) paste(x, collapse = ", ") else "-1"
  do.call(renderSqlFile, c(list("eligibility_lab_rows.sql",
    target_database_schema = settings$workDatabaseSchema,
    target_cohort_table    = settings$cohortTable,
    lab_cohort_table       = settings$labCohortTable,
    raw_lab_results_table  = settings$rawLabResultsTable,
    anchor_cohort_ids = ids(anchorIds), treated_cohort_ids = ids(treatedIds),
    closest = closest, passing_only = passingOnly,
    lab_window_before_days = settings$labWindowBeforeDays,
    lab_window_after_days  = settings$labWindowAfterDays,
    condition_flag_window_before_days = settings$conditionFlagWindowBeforeDays,
    condition_flag_window_after_days  = settings$conditionFlagWindowAfterDays,
    treated_lab_window_before_days = settings$treatedLabWindowBeforeDays,
    treated_lab_window_after_days  = settings$treatedLabWindowAfterDays), testIdParams()))
}
