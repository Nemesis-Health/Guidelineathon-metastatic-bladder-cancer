# Vendored (trimmed) from OncoStudyModules R/artemisIntegration.R (source-copied,
# not a package dependency). Carries the ARTEMIS pipeline wrapper only.
#
# Upstream also defines computeArtemisCoverage() and computeUncapturedExposures().
# They are intentionally NOT carried here: both depend on OncoStudyModules' own
# censorCounts() helper (which this standalone repo deliberately does not vendor)
# and require a drug_exposure_end_date column that runArtemis()'s extraction SQL
# does not select — i.e. they cannot run in this repo. Their study-facing
# equivalents live, working and censored, in R/06_artemis_assessment.R. If you
# re-sync from upstream, drop those two functions again (and their private
# helpers .countCapturedExposures() / .findUncapturedExposures()).
#
# ---- ARTEMIS Integration -----------------------------------------------------
# Exports:
#   runArtemis()                — full ARTEMIS pipeline wrapper
#   writeArtemisEpisodes()      — write episode table to DB
#   buildEpisodeTable()         — pure-R episode tibble from ARTEMIS output


# ===========================================================================
# runArtemis() ====
# ===========================================================================

#' @title Run ARTEMIS Regimen Alignment Pipeline
#'
#' @description
#' End-to-end wrapper for the ARTEMIS treatment regimen alignment pipeline.
#' Extracts drug exposure data from the CDM, aligns exposures to known
#' regimens, calculates treatment eras, and maps results to OMOP Episode
#' format.
#'
#' This is a migration of the `runARTEMIS()` function from the original
#' study scripts, parameterised to remove all global state.
#'
#' @param executionSettings A [OsmExecutionSettings][createExecutionSettings()]
#'   object. Must have `artemisSettings` and `connectionDetails` set.
#' @param cohortManifestRow A single-row data frame (or list) representing the
#'   ARTEMIS cohort from the manifest. Passed to `ARTEMIS::getConDF()` as
#'   the `json` parameter.
#' @param connection Optional existing `DatabaseConnector` connection. Used
#'   for the regimen concept vocabulary lookup. If `NULL`, a temporary
#'   connection is created and closed automatically.
#' @param regimens Regimen reference data. Defaults to
#'   `ARTEMIS::loadRegimens(condition = "lungCancer")`.
#' @param validDrugs Valid drug concept set. Defaults to
#'   `ARTEMIS::loadDrugs()`.
#' @param alignmentParams Named list of ARTEMIS alignment parameters passed
#'   to `ARTEMIS::generateRawAlignments()`. See that function's
#'   documentation for details. Defaults match the original study settings.
#' @param regimenCombine Integer window in days for regimen combination in
#'   `ARTEMIS::processAlignments()`. Default `28`.
#' @param discontinuationTime Integer discontinuation window in days, passed
#'   to `ARTEMIS::processAlignments()` (ARTEMIS >= 1.6.0 folds era assignment
#'   into that function). Default `120`.
#'
#' @return A named list:
#'   \describe{
#'     \item{episodes}{OMOP-format episode [tibble::tibble()]}
#'     \item{eras}{Processed eras from ARTEMIS}
#'     \item{rawAlignments}{Raw alignment output}
#'     \item{validDrugExposures}{Drug exposure records for valid anticancer
#'       drugs (the denominator for coverage calculations)}
#'   }
#'
#' @export
runArtemis <- function(executionSettings,
                       cohortManifestRow,
                       connection = NULL,
                       regimens = NULL,
                       validDrugs = NULL,
                       alignmentParams = list(
                         g = 0.4, Tfac = 0.5, verbose = 0,
                         mem = -1, method = "PropDiff"
                       ),
                       regimenCombine = 28L,
                       discontinuationTime = 120L) {

  rlang::check_installed("ARTEMIS",
    reason = "to run the ARTEMIS regimen alignment pipeline")
  rlang::check_installed("DatabaseConnector",
    reason = "to connect to the CDM database")

  # ARTEMIS must be ATTACHED (not just loaded via `::`): loadRegimens() does
  # data("regimens", package = "ARTEMIS", envir = regimens_env) internally, but
  # then checks exists("regimens") without envir = regimens_env, so the check
  # only succeeds when package:ARTEMIS is already on the search path.
  if (!"package:ARTEMIS" %in% search())
    suppressMessages(library(ARTEMIS))

  if (!inherits(executionSettings, "OsmExecutionSettings"))
    stop("`executionSettings` must be a OsmExecutionSettings object.",
         call. = FALSE)

  if (is.null(executionSettings$artemisSettings))
    stop("ARTEMIS settings are not configured. Use `createArtemisSettings()`.",
         call. = FALSE)

  if (is.null(connection))
    stop("`connection` is required. Pass an active DatabaseConnector connection.",
         call. = FALSE)

  # --- Default regimen / drug reference data --------------------------------
  if (is.null(regimens)) {
    allRegimens <- ARTEMIS::loadRegimens()
    regimens <- allRegimens[
      allRegimens$condition == "Non-small cell lung cancer" |
      allRegimens$condition == "Non-small cell lung cancer squamous", ]
  }
  if (is.null(validDrugs))
    validDrugs <- ARTEMIS::loadDrugs()

  # --- Validate reference data ------------------------------------------------
  if (!is.data.frame(regimens) || nrow(regimens) == 0) {
    # Try loading without condition filter as fallback
    allRegimens <- tryCatch(ARTEMIS::loadRegimens(), error = function(e) data.frame())
    nAll <- if (is.data.frame(allRegimens)) nrow(allRegimens) else 0L

    stop(
      "ARTEMIS regimen reference is empty. ",
      "`ARTEMIS::loadRegimens(condition = 'lungCancer')` returned 0 rows.\n",
      "  Total regimens (all conditions): ", nAll, "\n",
      if (nAll > 0) {
        conditions <- if ("condition" %in% names(allRegimens))
          paste(unique(allRegimens$condition), collapse = ", ")
        else "unknown (no 'condition' column)"
        paste0("  Available conditions: ", conditions, "\n")
      },
      "  ARTEMIS version: ", tryCatch(
        as.character(utils::packageVersion("ARTEMIS")),
        error = function(e) "unknown"
      ), "\n",
      "This is likely an ARTEMIS package version issue. ",
      "Check `ARTEMIS::loadRegimens()` and update the `condition` parameter.",
      call. = FALSE
    )
  }

  if (!is.data.frame(validDrugs) || nrow(validDrugs) == 0)
    stop(
      "ARTEMIS valid drug list is empty. ",
      "`ARTEMIS::loadDrugs()` returned 0 rows.\n",
      "  ARTEMIS version: ", tryCatch(
        as.character(utils::packageVersion("ARTEMIS")),
        error = function(e) "unknown"
      ),
      call. = FALSE
    )

  cli::cli_alert_success(
    "ARTEMIS reference loaded: {nrow(regimens)} regimens, {nrow(validDrugs)} valid drugs"
  )

  cli::cli_h2("Running ARTEMIS pipeline")

  # --- Step 1: Extract drug exposure data from CDM --------------------------
  # We bypass ARTEMIS::getConDF() entirely because it internally re-generates
  # the cohort via CohortGenerator::generateCohortSet(), which uses
  # DatabaseConnector::insertTable() and fails with PostgreSQL/JDBC
  # ("parameter type `data.frame` is ambiguous or not supported").
  #
  # Our ARTEMIS cohort is ALREADY in the cohort table from Section 3 of run.R.
  # So we run the same drug-exposure SQL that getConDF would have run,
  # but join directly against our existing cohort table filtered by cohort ID.
  cli::cli_progress_step("Extracting drug exposure data")

  artemisCohortId <- if (is.data.frame(cohortManifestRow)) {
    cohortManifestRow$id[1]
  } else {
    cohortManifestRow[["id"]]
  }

  conDfSql <- SqlRender::render(
    "SELECT CAST(de.person_id AS VARCHAR) AS person_id,
            de.drug_exposure_start_date,
            de.drug_concept_id,
            ca.ancestor_concept_id,
            c.concept_name
     FROM @cdm_schema.drug_exposure de
     JOIN @work_schema.@cohort_table ch
       ON ch.subject_id = de.person_id
      AND ch.cohort_definition_id = @artemis_cohort_id
     LEFT JOIN @vocab_schema.concept_ancestor ca
       ON de.drug_concept_id = ca.descendant_concept_id
     LEFT JOIN @vocab_schema.concept c
       ON ca.ancestor_concept_id = c.concept_id
     WHERE LOWER(c.concept_class_id) = 'ingredient'",
    cdm_schema        = executionSettings$cdmDatabaseSchema,
    vocab_schema      = executionSettings$vocabDatabaseSchema,
    work_schema       = executionSettings$workDatabaseSchema,
    cohort_table      = executionSettings$cohortTable,
    artemis_cohort_id = as.integer(artemisCohortId)
  )
  conDfSql <- SqlRender::translate(conDfSql, targetDialect = .getDbms(connection))

  conDF <- DatabaseConnector::querySql(connection, conDfSql,
                                       snakeCaseToCamelCase = FALSE)
  names(conDF) <- tolower(names(conDF))

  cli::cli_alert_success(
    "Drug exposure extracted: {nrow(conDF)} records for cohort ID {artemisCohortId}"
  )

  # --- Canonicalise drug tokens to the ARTEMIS regimen vocabulary -----------
  # ARTEMIS::stringDF_from_cdm() builds each patient's alignment token straight
  # from the CDM *ingredient* concept_name and uses validDrugs only to filter,
  # never to rename. But the regimen shortStrings are tokenised from ARTEMIS's
  # own drug names (validDrugs$name). These coincide for most drugs, so alignment
  # "just works" — EXCEPT for antibody-drug conjugates, where RxNorm names the
  # ingredient by the antibody alone: CDM "enfortumab" vs regimen "enfortumab
  # vedotin" (same for brentuximab / polatuzumab / tisotumab vedotin, ...). The
  # tokens never match, so no such regimen ever aligns and those exposures go
  # silently UNCAPTURED — this is why the EV-Pembro cohort was 0 despite present
  # enfortumab exposures. Overwrite the token with the matching validDrugs$name
  # so the patient and regimen strings share one vocabulary; lower-cased to match
  # the regimen tokens' convention (stringDF_from_cdm strips the spaces). A no-op
  # where the names already agree (verified: every regimen token that has a
  # validDrugs entry equals cleaned validDrugs$name, so this cannot regress a
  # currently-aligning drug). This is an upstream ARTEMIS bug (any drug whose
  # RxNorm ingredient name != HemOnc component name is affected) — patched here
  # rather than in the vendored package.
  vdKeep  <- !is.na(validDrugs$name) & nzchar(validDrugs$name)
  vdName  <- stats::setNames(tolower(as.character(validDrugs$name[vdKeep])),
                             as.character(validDrugs$valid_concept_id[vdKeep]))
  vdKey   <- as.character(conDF$ancestor_concept_id)
  vdHit   <- vdKey %in% names(vdName)
  conDF$concept_name[vdHit] <- vdName[vdKey[vdHit]]

  # --- Step 2: Build string representations ---------------------------------
  cli::cli_progress_step("Building drug string representations")
  stringDF <- ARTEMIS::stringDF_from_cdm(
    con_df     = conDF,
    validDrugs = validDrugs
  )

  # --- Step 3: Generate raw alignments --------------------------------------
  cli::cli_progress_step("Generating raw alignments")
  rawAlignments <- do.call(
    ARTEMIS::generateRawAlignments,
    c(list(stringDF = stringDF, regimens = regimens), alignmentParams)
  )

  # --- Step 4: Process alignments (post-process + line-of-therapy eras) -----
  # ARTEMIS >= 1.6.0: processAlignments() no longer takes `regimens`, and it
  # absorbs the old calculateEras() behaviour via `discontinuationTime`. Its
  # output already carries the personID / component / t_start / t_end columns
  # that buildEpisodeTable() consumes (see Step 6).
  cli::cli_progress_step("Processing alignments")
  processedAlignments <- ARTEMIS::processAlignments(
    rawAlignments,
    regimenCombine      = regimenCombine,
    discontinuationTime = discontinuationTime
  )

  # --- Step 5: Reference dates (earliest valid drug exposure per patient) ---
  validExposures <- conDF[
    conDF$ancestor_concept_id %in% validDrugs$valid_concept_id, ]

  # --- Early exit if no alignments were produced ----------------------------
  noAlignments <- is.null(processedAlignments) ||
    (is.data.frame(processedAlignments) && nrow(processedAlignments) == 0)

  if (noAlignments) {
    cli::cli_alert_warning(
      "ARTEMIS produced no regimen alignments for {dplyr::n_distinct(conDF$person_id)} patients. \\
       This may indicate the regimen reference does not match the drug exposures in this CDM."
    )
    return(list(
      episodes           = .emptyEpisodeTable(),
      eras               = data.frame(),
      rawAlignments      = rawAlignments,
      validDrugExposures = validExposures,
      conDF              = conDF,
      stringDF           = stringDF,
      validDrugs         = validDrugs,
      regimens           = regimens
    ))
  }

  # --- Step 6: Treatment eras -----------------------------------------------
  # ARTEMIS >= 1.6.0 folds era / line-of-therapy assignment into
  # processAlignments() (Step 4), so the processed alignments already are the
  # eras (personID / component / t_start / t_end). The standalone
  # ARTEMIS::calculateEras() helper no longer exists.
  processedEras <- processedAlignments

  referenceDates <- validExposures |>
    dplyr::summarise(
      refDate = min(.data$drug_exposure_start_date),
      .by = "person_id"
    ) |>
    dplyr::rename(personID = "person_id") |>
    dplyr::mutate(personID = as.character(.data$personID))

  # --- Step 7: Regimen concepts from vocabulary -----------------------------
  cli::cli_progress_step("Looking up regimen concepts")
  regimenConcepts <- .getRegimenConcepts(
    connection        = connection,
    executionSettings = executionSettings
  )

  # --- Step 8: Build OMOP episode table ------------------------------------
  cli::cli_progress_step("Building episode table")
  episodes <- buildEpisodeTable(processedEras, referenceDates, regimenConcepts)

  cli::cli_alert_success(
    "ARTEMIS complete: {nrow(episodes)} episodes for \\
     {dplyr::n_distinct(episodes$person_id)} patients"
  )

  list(
    episodes           = episodes,
    eras               = processedEras,
    rawAlignments      = rawAlignments,
    validDrugExposures = validExposures,
    conDF              = conDF,
    stringDF           = stringDF,
    validDrugs         = validDrugs,
    regimens           = regimens
  )
}


# ===========================================================================
# buildEpisodeTable() ====
# ===========================================================================

#' @title Build OMOP Episode Table from ARTEMIS Output
#'
#' @description
#' Pure-R function that converts ARTEMIS processed eras into an OMOP-format
#' episode table. Can be called standalone if you have pre-existing ARTEMIS
#' output.
#'
#' @param processedEras Data frame of processed treatment eras — the output of
#'   `ARTEMIS::processAlignments()` (ARTEMIS >= 1.6.0). Expected columns:
#'   `personID` (character), `component`, `t_start`, `t_end`.
#' @param referenceDates Data frame with columns `personID` (character) and
#'   `refDate` (Date) — the earliest valid drug exposure date per patient.
#' @param regimenConcepts Data frame with columns `concept_name` and
#'   `concept_id` — regimen concepts from the vocabulary. Used to map
#'   component names to OMOP concept IDs.
#' @param startEpisodeId Starting episode ID for sequential numbering.
#'   Default `1L`.
#'
#' @return A [tibble::tibble()] in OMOP Episode format with columns:
#'   `episode_id`, `person_id`, `episode_concept_id`, `episode_start_date`,
#'   `episode_start_datetime`, `episode_end_date`, `episode_end_datetime`,
#'   `episode_parent_id`, `episode_number`, `episode_object_concept_id`,
#'   `episode_type_concept_id`, `episode_source_value`,
#'   `episode_source_concept_id`.
#'
#' @export
buildEpisodeTable <- function(processedEras,
                              referenceDates,
                              regimenConcepts,
                              startEpisodeId = 1L) {

  if (!is.data.frame(processedEras))
    stop("`processedEras` must be a data frame.", call. = FALSE)
  if (nrow(processedEras) == 0L)
    return(.emptyEpisodeTable())

  reqEra <- c("personID", "component", "t_start", "t_end")
  missing <- setdiff(reqEra, names(processedEras))
  if (length(missing) > 0)
    stop(sprintf("`processedEras` is missing columns: %s",
                 paste(missing, collapse = ", ")), call. = FALSE)

  if (!is.data.frame(referenceDates))
    stop("`referenceDates` must be a data frame.", call. = FALSE)
  if (!all(c("personID", "refDate") %in% names(referenceDates)))
    stop("`referenceDates` must have columns `personID` and `refDate`.",
         call. = FALSE)

  if (!is.data.frame(regimenConcepts))
    stop("`regimenConcepts` must be a data frame.", call. = FALSE)

  # Normalise concept_name: replace "&" with "and" for matching
  eras <- processedEras |>
    dplyr::left_join(referenceDates, by = "personID") |>
    dplyr::mutate(
      concept_name = stringr::str_replace_all(.data$component, "&", "and")
    )

  # Match component names to regimen concept IDs
  eras <- eras |>
    dplyr::left_join(regimenConcepts, by = "concept_name",
                     relationship = "many-to-many")

  startEpisodeId <- as.integer(startEpisodeId)

  episodes <- eras |>
    dplyr::arrange(.data$personID, .data$t_start) |>
    dplyr::mutate(
      episode_id = startEpisodeId + dplyr::row_number() - 1L
    ) |>
    dplyr::mutate(
      # kept character, not as.integer(): some sites' person_id exceeds int32
      # and silently becomes NA -- retyped to BIGINT in writeArtemisEpisodes()
      person_id                 = .data$personID,
      episode_concept_id        = 32941L,
      episode_start_date        = .data$refDate + as.integer(.data$t_start),
      episode_start_datetime    = NA_real_,
      episode_end_date          = .data$refDate + as.integer(.data$t_end),
      episode_end_datetime      = NA_real_,
      episode_parent_id         = NA_integer_,
      episode_number            = dplyr::row_number(),
      episode_object_concept_id = as.integer(.data$concept_id %||% NA_integer_),
      episode_type_concept_id   = 0L,
      episode_source_value      = .data$component,
      episode_source_concept_id = 0L,
      .by = "personID"
    ) |>
    dplyr::select(
      "episode_id", "person_id", "episode_concept_id",
      "episode_start_date", "episode_start_datetime",
      "episode_end_date", "episode_end_datetime",
      "episode_parent_id", "episode_number",
      "episode_object_concept_id", "episode_type_concept_id",
      "episode_source_value", "episode_source_concept_id"
    )

  tibble::as_tibble(episodes)
}


# ===========================================================================
# writeArtemisEpisodes() ====
# ===========================================================================

#' @title Write ARTEMIS Episodes to Database
#'
#' @description
#' Inserts an OMOP-format episode table (as returned by [buildEpisodeTable()]
#' or [runArtemis()]) into the work schema. Replaces the inline insertion
#' pattern from the original `run.R`.
#'
#' @param connection A `DatabaseConnector` connection object.
#' @param executionSettings A [OsmExecutionSettings][createExecutionSettings()]
#'   object with `artemisSettings` configured.
#' @param episodes A data frame of episodes in OMOP format. `person_id` is
#'   character (see [buildEpisodeTable()]) and is retyped to `BIGINT` in the
#'   database as part of writing it, not narrowed in R beforehand.
#' @param dropExisting If `TRUE` (default), drops the existing episode table
#'   before writing.
#'
#' @return Invisible `NULL`. Called for its side effect.
#'
#' @export
writeArtemisEpisodes <- function(connection,
                                 executionSettings,
                                 episodes,
                                 dropExisting = TRUE) {

  rlang::check_installed("DatabaseConnector",
    reason = "to write episodes to the database")

  if (!inherits(executionSettings, "OsmExecutionSettings"))
    stop("`executionSettings` must be a OsmExecutionSettings object.",
         call. = FALSE)
  if (is.null(executionSettings$artemisSettings))
    stop("ARTEMIS settings are not configured.", call. = FALSE)
  if (!is.data.frame(episodes))
    stop("`episodes` must be a data frame.", call. = FALSE)

  stageTable <- paste0(executionSettings$artemisSettings$episodeTable, "_staging")

  # stage as character, then rebuild with person_id CAST to BIGINT
  # No bulkLoad argument passed deliberately -- see the matching insertTable()
  # call in R/01_artemis.R for why.
  DatabaseConnector::insertTable(
    connection     = connection,
    databaseSchema = executionSettings$workDatabaseSchema,
    tableName      = stageTable,
    data           = as.data.frame(episodes),
    dropTableIfExists = TRUE,
    createTable       = TRUE,
    camelCaseToSnakeCase = FALSE
  )

  episodeCols <- paste(
    "episode_id", "CAST(person_id AS BIGINT) AS person_id",
    "episode_concept_id", "episode_start_date", "episode_start_datetime",
    "episode_end_date", "episode_end_datetime", "episode_parent_id",
    "episode_number", "episode_object_concept_id", "episode_type_concept_id",
    "episode_source_value", "episode_source_concept_id",
    sep = ", ")

  sql <- if (dropExisting) {
    "DROP TABLE IF EXISTS @schema.@final;
     SELECT @cols INTO @schema.@final FROM @schema.@stage;"
  } else {
    "INSERT INTO @schema.@final
       (episode_id, person_id, episode_concept_id, episode_start_date,
        episode_start_datetime, episode_end_date, episode_end_datetime,
        episode_parent_id, episode_number, episode_object_concept_id,
        episode_type_concept_id, episode_source_value, episode_source_concept_id)
     SELECT @cols FROM @schema.@stage;"
  }
  sql <- paste(sql, "DROP TABLE @schema.@stage;")
  sql <- SqlRender::render(sql,
                           schema = executionSettings$workDatabaseSchema,
                           final  = executionSettings$artemisSettings$episodeTable,
                           stage  = stageTable, cols = episodeCols,
                           warnOnMissingParameters = FALSE)
  sql <- SqlRender::translate(sql, targetDialect = .getDbms(connection))
  DatabaseConnector::executeSql(connection, sql)

  cli::cli_alert_success(
    "Wrote {nrow(episodes)} episodes to \\
     {executionSettings$workDatabaseSchema}.\\
     {executionSettings$artemisSettings$episodeTable} (person_id retyped to BIGINT)"
  )

  invisible(NULL)
}


# ===========================================================================
# Internal helpers ====
# ===========================================================================

#' Query regimen concepts from the vocabulary
#' @noRd
.getRegimenConcepts <- function(connection, executionSettings) {

  rlang::check_installed("DatabaseConnector",
    reason = "to query regimen concepts from the vocabulary")

  sql_template <- paste(
    "SELECT concept_name, concept_id",
    "FROM @vocab_schema.concept",
    "WHERE concept_class_id = 'Regimen'",
    "AND standard_concept = 'S'"
  )

  rendered_sql <- SqlRender::render(
    sql_template,
    vocab_schema = executionSettings$vocabDatabaseSchema
  )

  ownConnection <- FALSE
  if (is.null(connection)) {
    connection <- DatabaseConnector::connect(
      executionSettings$connectionDetails
    )
    ownConnection <- TRUE
  }

  on.exit({
    if (ownConnection) DatabaseConnector::disconnect(connection)
  })

  result <- DatabaseConnector::querySql(connection, rendered_sql,
                                         snakeCaseToCamelCase = FALSE)
  names(result) <- tolower(names(result))
  tibble::as_tibble(result)
}


#' Return empty episode tibble with correct columns
#' @noRd
.emptyEpisodeTable <- function() {
  tibble::tibble(
    episode_id                = integer(0),
    person_id                 = character(0),  # matches buildEpisodeTable()'s populated case
    episode_concept_id        = integer(0),
    episode_start_date        = as.Date(character(0)),
    episode_start_datetime    = numeric(0),
    episode_end_date          = as.Date(character(0)),
    episode_end_datetime      = numeric(0),
    episode_parent_id         = integer(0),
    episode_number            = integer(0),
    episode_object_concept_id = integer(0),
    episode_type_concept_id   = integer(0),
    episode_source_value      = character(0),
    episode_source_concept_id = integer(0)
  )
}
