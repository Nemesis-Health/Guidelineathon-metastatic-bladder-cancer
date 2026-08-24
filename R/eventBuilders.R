# ===========================================================================
# eventBuilders.R  —  per-outcome event tibbles for computeTimeToEvent()
# ===========================================================================
# buildLineOfTherapyEvents() and buildDtiEvents() are ported verbatim from
# onco-study-modules R/eventBuilders.R — pure-R over the ARTEMIS episode
# tibble, no OncoStudyModules class dependency. fetchDeathEvents() is
# reimplemented against this repo's own conventions (querySqlFile() +
# sql/fetch_death_events.sql) instead of the OsmExecutionSettings-typed
# original, since this repo does not vendor OncoStudyModules' SQL directory.
#
# anchorEpisodes() and combineEarliestEvent() are new (not in the reference):
# see R/09_outcomes.R for why line-of-therapy ranking needs an anchor, and
# why TTNT/TTD/TFI's event dates need to be death-aware.
# ===========================================================================

# --- anchorEpisodes() --------------------------------------------------------
# Restricts `episodes` to those on/after each subject's own anchor date
# before line-of-therapy ranking. Without this, buildLineOfTherapyEvents()/
# buildDtiEvents() rank a person's ARTEMIS episodes across their WHOLE
# history — but the protocol allows prior systemic therapy into a treated
# cohort as long as it was >12 months before the mBC index, so such a
# patient's true "line 1" for THIS disease can be preceded by an unrelated,
# older episode that would otherwise be mis-ranked as line 1, shifting every
# subsequent line's numbering. `anchorDates` is any data frame with
# `subject_id`/`cohort_start_date` (e.g. a target cohort's own rows); the
# anchor is per-subject, not per-row, so duplicate subjects (a person
# appearing under several cohort aliases with the same index date) collapse
# via `distinct()` before the join.
anchorEpisodes <- function(episodes, anchorDates) {
  if (!is.data.frame(episodes))
    stop("`episodes` must be a data frame.", call. = FALSE)
  for (col in c("subject_id", "cohort_start_date")) {
    if (!col %in% names(anchorDates))
      stop("`anchorDates` is missing column '", col, "'.", call. = FALSE)
  }

  anchors <- anchorDates |>
    dplyr::transmute(person_id = as.integer(.data$subject_id),
                     .anchor = as.Date(.data$cohort_start_date)) |>
    dplyr::distinct()

  episodes |>
    dplyr::mutate(person_id = as.integer(.data$person_id)) |>
    dplyr::inner_join(anchors, by = "person_id") |>
    dplyr::filter(.data$episode_start_date >= .data$.anchor) |>
    dplyr::select(-".anchor")
}


# --- combineEarliestEvent() --------------------------------------------------
# Merges any number of (subject_id, cohort_start_date) event tibbles into
# one, taking the EARLIEST date per subject. Used to make an event
# death-aware: e.g. TTD's discontinuation date should be
# min(episode_end_date, death_date) per the protocol's discontinuation
# definition ("... or death, whichever occurs first") — ARTEMIS episode
# boundaries already encode the other two discontinuation reasons (next
# regimen start, >120-day gap), but know nothing about death.
combineEarliestEvent <- function(...) {
  evs <- list(...)
  evs <- evs[vapply(evs, function(e) is.data.frame(e) && nrow(e) > 0, logical(1))]
  if (length(evs) == 0)
    return(tibble::tibble(subject_id = integer(0), cohort_start_date = as.Date(character(0))))

  dplyr::bind_rows(evs) |>
    dplyr::mutate(subject_id = as.integer(.data$subject_id),
                  cohort_start_date = as.Date(.data$cohort_start_date)) |>
    dplyr::summarise(cohort_start_date = min(.data$cohort_start_date, na.rm = TRUE),
                     .by = "subject_id")
}

# --- fetchDeathEvents() -----------------------------------------------------
# One row per subject (with a death record) among members of any
# `targetCohortIds`. Powers the OS outcome.
fetchDeathEvents <- function(connection, targetCohortIds) {
  targetCohortIds <- as.integer(stats::na.omit(targetCohortIds))
  if (length(targetCohortIds) == 0)
    return(tibble::tibble(subject_id = integer(0),
                          cohort_start_date = as.Date(character(0))))

  result <- querySqlFile(connection, "fetch_death_events.sql",
    work_database_schema = settings$workDatabaseSchema,
    cohort_table         = settings$cohortTable,
    cdm_database_schema  = settings$cdmDatabaseSchema,
    target_cohort_ids    = paste(targetCohortIds, collapse = ", "))
  names(result) <- tolower(names(result))
  tibble::as_tibble(result)
}


# --- buildLineOfTherapyEvents() ---------------------------------------------
# Converts an ARTEMIS episode tibble into the event-tibble shape
# computeTimeToEvent() expects. Lines of therapy are numbered chronologically
# per subject (episode 1 = earliest episode_start_date; ties broken by
# episode_end_date then episode_source_value for determinism).
#
#   eventType = "next_lot"        -> episode_start_date of episode
#                                     `lineNumber + 1` (powers TTNT when the
#                                     target cohort is indexed at LoT-lineNumber
#                                     start).
#   eventType = "discontinuation" -> episode_end_date of episode `lineNumber`
#                                     (powers TTD).
buildLineOfTherapyEvents <- function(episodes,
                                      lineNumber = 1L,
                                      eventType = c("next_lot", "discontinuation")) {
  eventType <- match.arg(eventType)

  if (!is.data.frame(episodes))
    stop("`episodes` must be a data frame.", call. = FALSE)
  required <- c("person_id", "episode_start_date", "episode_end_date",
                "episode_source_value")
  miss <- setdiff(required, names(episodes))
  if (length(miss) > 0)
    stop("`episodes` is missing columns: ", paste(miss, collapse = ", "),
         call. = FALSE)

  lineNumber <- as.integer(lineNumber)
  if (is.na(lineNumber) || lineNumber < 1L)
    stop("`lineNumber` must be a positive integer.", call. = FALSE)

  if (nrow(episodes) == 0) {
    return(tibble::tibble(subject_id = integer(0),
                          cohort_start_date = as.Date(character(0))))
  }

  ranked <- episodes |>
    dplyr::arrange(.data$person_id, .data$episode_start_date,
                   .data$episode_end_date, .data$episode_source_value) |>
    dplyr::mutate(.lot = dplyr::row_number(), .by = "person_id")

  targetLine <- if (eventType == "next_lot") lineNumber + 1L else lineNumber
  pick <- ranked |> dplyr::filter(.data$.lot == targetLine)

  if (eventType == "next_lot") {
    tibble::tibble(subject_id = as.integer(pick$person_id),
                   cohort_start_date = as.Date(pick$episode_start_date))
  } else {
    tibble::tibble(subject_id = as.integer(pick$person_id),
                   cohort_start_date = as.Date(pick$episode_end_date))
  }
}


# --- buildDtiEvents() --------------------------------------------------------
# DTI event tibble (Cohort T1 only): for each subject in `targetData`, joins
# the first chronological ARTEMIS episode and returns
# time_diff = episode_start_date - cohort_start_date (days). Subjects with no
# episode are dropped (DTI is only defined for patients who initiated
# treatment).
buildDtiEvents <- function(targetData, episodes, lineNumber = 1L) {
  if (!is.data.frame(targetData))
    stop("`targetData` must be a data frame.", call. = FALSE)
  for (col in c("subject_id", "cohort_start_date")) {
    if (!col %in% names(targetData))
      stop("`targetData` is missing column '", col, "'.", call. = FALSE)
  }

  if (!is.data.frame(episodes))
    stop("`episodes` must be a data frame.", call. = FALSE)
  required <- c("person_id", "episode_start_date", "episode_end_date",
                "episode_source_value")
  miss <- setdiff(required, names(episodes))
  if (length(miss) > 0)
    stop("`episodes` is missing columns: ", paste(miss, collapse = ", "),
         call. = FALSE)

  lineNumber <- as.integer(lineNumber)
  if (is.na(lineNumber) || lineNumber < 1L)
    stop("`lineNumber` must be a positive integer.", call. = FALSE)

  if (nrow(episodes) == 0)
    return(tibble::tibble(subject_id = integer(0), time_diff = integer(0)))

  ranked <- episodes |>
    dplyr::arrange(.data$person_id, .data$episode_start_date,
                   .data$episode_end_date, .data$episode_source_value) |>
    dplyr::mutate(.lot = dplyr::row_number(), .by = "person_id") |>
    dplyr::filter(.data$.lot == lineNumber) |>
    dplyr::select(subject_id = "person_id", lot_start_date = "episode_start_date")

  joined <- targetData |>
    dplyr::select("subject_id", "cohort_start_date") |>
    dplyr::inner_join(ranked, by = "subject_id")

  tibble::tibble(subject_id = as.integer(joined$subject_id),
                 time_diff  = as.integer(joined$lot_start_date - joined$cohort_start_date))
}
