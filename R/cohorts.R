# ===========================================================================
# cohorts.R  —  cohort generation, cohort ids and eligibility test ids
# ===========================================================================
# Thin reimplementations of the OncoStudyModules orchestration using the OHDSI
# packages directly (CirceR, CohortGenerator), so this project has no
# dependency on OncoStudyModules. Also the id lookups for the generated
# cohorts and the eligibility test-id slots.
# ===========================================================================

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
# patches in R/db_compat.R that this connection's dialect/driver needs
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
