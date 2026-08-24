# ===========================================================================
# timeToEvent.R  —  generic time-to-event engine (KM + time-diff stats)
# ===========================================================================
# Ported from onco-study-modules R/timeToEvent.R (computeTimeToEvent(),
# computeTimeDiffStats()) with the resultsDb/databaseId write-through removed —
# this repo writes CSVs directly from the step file via writeResultCsv(), not
# from inside the engine. The math (survival::survfit + broom::tidy) is
# otherwise unchanged.
#
# computeTimeToEvent(): pairs a target (index) cohort with an event cohort and
# produces three outputs: summary stats (n, n_event, median/quartiles/deciles
# of time-to-event), a time-diff histogram, and tidy Kaplan-Meier data (+
# median survival). Used for OS / TTNT / TTD.
#
# computeTimeDiffStats(): non-censored counterpart for a pre-computed
# time_diff column (e.g. DTI — no right-censoring concept).
#
# Both apply the same privacy-censoring rule as the rest of this repo: a
# count with 0 < n < minCellCount is written as -minCellCount, and any paired
# statistic on that row is blanked (NA).
# ===========================================================================

# --- computeTimeToEvent() ---------------------------------------------------
# targetData:  subject_id, indexDateCol (default cohort_start_date),
#              censorDateCol (default cohort_end_date), optional strata cols.
# eventData:   subject_id, eventDateCol (default cohort_start_date); zero or
#              more rows per subject (only the earliest post-index event is
#              used).
computeTimeToEvent <- function(targetData,
                                eventData,
                                indexDateCol  = "cohort_start_date",
                                censorDateCol = "cohort_end_date",
                                eventDateCol  = "cohort_start_date",
                                priorOutcomeHandling = c("ignore",
                                                          "bring_forward",
                                                          "remove_patients"),
                                strata = NULL,
                                histogramBreaks = c(-Inf, -365, -180, -90,
                                                     -60, -30, 0, 30, 60,
                                                     90, 180, 365, Inf),
                                minCellCount = 5L) {

  priorOutcomeHandling <- match.arg(priorOutcomeHandling)

  if (!is.data.frame(targetData))
    stop("`targetData` must be a data frame.", call. = FALSE)
  if (!is.data.frame(eventData))
    stop("`eventData` must be a data frame.", call. = FALSE)

  reqTarget <- c("subject_id", indexDateCol, censorDateCol)
  missingT  <- setdiff(reqTarget, names(targetData))
  if (length(missingT) > 0)
    stop("`targetData` is missing columns: ", paste(missingT, collapse = ", "),
         call. = FALSE)

  if (!"subject_id" %in% names(eventData))
    stop("`eventData` must have a `subject_id` column.", call. = FALSE)
  if (!eventDateCol %in% names(eventData))
    stop("`eventData` is missing column '", eventDateCol, "'.", call. = FALSE)

  if (!is.null(strata)) {
    missS <- setdiff(strata, names(targetData))
    if (length(missS) > 0)
      stop("`targetData` is missing strata columns: ",
           paste(missS, collapse = ", "), call. = FALSE)
  }

  # Slim eventData to avoid suffix collisions when both frames share names.
  eventKeep     <- unique(c("subject_id", eventDateCol))
  eventDataSlim <- eventData[, intersect(eventKeep, names(eventData)), drop = FALSE]

  if (eventDateCol != "subject_id" && eventDateCol %in% names(targetData)) {
    safeName <- paste0("event__", eventDateCol)
    names(eventDataSlim)[names(eventDataSlim) == eventDateCol] <- safeName
    eventDateCol <- safeName
  }

  ds <- dplyr::left_join(targetData, eventDataSlim, by = "subject_id")

  ds <- ds |>
    dplyr::mutate(
      has_prior_event = dplyr::if_else(
        !is.na(.data[[eventDateCol]]) &
          .data[[eventDateCol]] < .data[[indexDateCol]],
        TRUE, FALSE
      )
    ) |>
    dplyr::mutate(
      has_prior_event = any(.data$has_prior_event),
      .by = "subject_id"
    )

  ds <- switch(
    priorOutcomeHandling,
    "ignore" = {
      ds |> dplyr::mutate(
        !!eventDateCol := dplyr::if_else(
          .data[[eventDateCol]] < .data[[indexDateCol]],
          as.Date(NA), .data[[eventDateCol]]
        )
      )
    },
    "bring_forward" = {
      ds |> dplyr::mutate(
        !!eventDateCol := dplyr::if_else(
          .data[[eventDateCol]] < .data[[indexDateCol]],
          .data[[indexDateCol]], .data[[eventDateCol]]
        )
      )
    },
    "remove_patients" = {
      ds |> dplyr::filter(!.data$has_prior_event)
    }
  )

  # Drop events before index (after handling); keep earliest event per subject.
  ds <- ds |>
    dplyr::filter(
      is.na(.data[[eventDateCol]]) |
        .data[[eventDateCol]] >= .data[[indexDateCol]]
    ) |>
    dplyr::arrange(is.na(.data[[eventDateCol]]), .data[[eventDateCol]]) |>
    dplyr::slice(1, .by = "subject_id")

  ds <- ds |>
    dplyr::mutate(
      flag = !is.na(.data[[eventDateCol]]) &
        .data[[eventDateCol]] <= .data[[censorDateCol]],
      time = as.integer(
        pmin(.data[[eventDateCol]], .data[[censorDateCol]], na.rm = TRUE) -
          .data[[indexDateCol]]
      )
    )

  # --- 1. Summary statistics ------------------------------------------------
  grp <- strata %||% character(0)

  summaryStats <- ds |>
    dplyr::group_by(dplyr::across(dplyr::all_of(grp))) |>
    dplyr::summarise(
      count       = dplyr::n(),
      n_event     = sum(.data$flag, na.rm = TRUE),
      min_time    = suppressWarnings(min(.data$time[.data$flag], na.rm = TRUE)),
      c10_time    = suppressWarnings(stats::quantile(.data$time[.data$flag], 0.10, na.rm = TRUE)),
      q25_time    = suppressWarnings(stats::quantile(.data$time[.data$flag], 0.25, na.rm = TRUE)),
      median_time = suppressWarnings(stats::median(.data$time[.data$flag], na.rm = TRUE)),
      q75_time    = suppressWarnings(stats::quantile(.data$time[.data$flag], 0.75, na.rm = TRUE)),
      c90_time    = suppressWarnings(stats::quantile(.data$time[.data$flag], 0.90, na.rm = TRUE)),
      max_time    = suppressWarnings(max(.data$time[.data$flag], na.rm = TRUE)),
      .groups     = "drop"
    ) |>
    tibble::as_tibble()

  inf_cols <- c("min_time", "c10_time", "q25_time", "median_time",
                "q75_time", "c90_time", "max_time")
  summaryStats <- summaryStats |>
    dplyr::mutate(dplyr::across(dplyr::all_of(inf_cols),
      ~ dplyr::if_else(is.infinite(.x), NA_real_, as.double(.x))))

  summaryStats <- .censorTteCounts(summaryStats, minCellCount,
                                    countCols = c("count", "n_event"),
                                    suppCols  = inf_cols)

  # --- 2. Histogram ----------------------------------------------------------
  histData <- ds |>
    dplyr::mutate(time_bin = cut(.data$time, breaks = histogramBreaks,
                                  right = FALSE, ordered_result = TRUE)) |>
    dplyr::group_by(dplyr::across(dplyr::all_of(c(grp, "time_bin")))) |>
    dplyr::summarise(count = dplyr::n(), .groups = "drop") |>
    dplyr::mutate(count = dplyr::case_when(
      .data$count > 0 & .data$count < minCellCount ~ as.double(-minCellCount),
      TRUE ~ as.double(.data$count))) |>
    tibble::as_tibble()

  # --- 3. Kaplan-Meier ---------------------------------------------------------
  kmData         <- tibble::tibble()
  medianSurvival <- tibble::tibble()

  hasSurvival <- requireNamespace("survival", quietly = TRUE)
  hasBroom    <- requireNamespace("broom", quietly = TRUE)
  if (!hasSurvival || !hasBroom) {
    missingPkgs <- c("survival", "broom")[!c(hasSurvival, hasBroom)]
    warning("Kaplan-Meier outputs (km, median survival, milestones) skipped: ",
            "required package(s) not available: ",
            paste(missingPkgs, collapse = ", "), ". Install them and re-run.",
            call. = FALSE)
  }

  if (hasSurvival && hasBroom && nrow(ds) > 0) {
    km <- .fitSurvival(ds, strata)
    kmData         <- km$kmData
    medianSurvival <- km$medianSurvival

    km_count_cols <- intersect(c("n.risk", "n.censor", "n.event"), names(kmData))
    if (length(km_count_cols) > 0) {
      kmData <- kmData |>
        dplyr::mutate(dplyr::across(dplyr::all_of(km_count_cols), ~ dplyr::case_when(
          .x > 0 & .x < minCellCount ~ as.double(-minCellCount),
          TRUE ~ as.double(.x))))
    }

    if ("n" %in% names(medianSurvival)) {
      medianSurvival <- medianSurvival |>
        dplyr::mutate(n = dplyr::case_when(
          .data$n > 0 & .data$n < minCellCount ~ as.double(-minCellCount),
          TRUE ~ as.double(.data$n))) |>
        dplyr::mutate(dplyr::across(dplyr::any_of(c("median", "lower", "upper")),
          ~ dplyr::case_when(.data$n < 0 ~ NA_real_, TRUE ~ as.double(.x))))
    }
  }

  if (nrow(kmData) > 0) {
    kmData <- .normalizeKmStrata(kmData, strata = strata, ds = ds)
  }

  list(
    summaryStats   = summaryStats,
    histogram      = histData,
    kmData         = kmData,
    medianSurvival = medianSurvival
  )
}


# --- computeTimeDiffStats() -------------------------------------------------
# Non-censored descriptive stats + histogram on a pre-computed time_diff
# column (e.g. buildDtiEvents() output).
computeTimeDiffStats <- function(data,
                                  timeCol = "time_diff",
                                  groupCols = NULL,
                                  histogramBreaks = c(-Inf, -365, -180, -90,
                                                       -60, -30, 0, 30, 60,
                                                       90, 180, 365, Inf),
                                  minCellCount = 5L) {

  if (!is.data.frame(data))
    stop("`data` must be a data frame.", call. = FALSE)
  if (!timeCol %in% names(data))
    stop("`data` is missing column '", timeCol, "'.", call. = FALSE)

  grp <- groupCols %||% character(0)

  summaryStats <- data |>
    dplyr::group_by(dplyr::across(dplyr::all_of(grp))) |>
    dplyr::summarise(
      count       = dplyr::n(),
      min_time    = suppressWarnings(min(.data[[timeCol]], na.rm = TRUE)),
      c10_time    = suppressWarnings(stats::quantile(.data[[timeCol]], 0.10, na.rm = TRUE)),
      lq_time     = suppressWarnings(stats::quantile(.data[[timeCol]], 0.25, na.rm = TRUE)),
      median_time = suppressWarnings(stats::median(.data[[timeCol]], na.rm = TRUE)),
      uq_time     = suppressWarnings(stats::quantile(.data[[timeCol]], 0.75, na.rm = TRUE)),
      c90_time    = suppressWarnings(stats::quantile(.data[[timeCol]], 0.90, na.rm = TRUE)),
      max_time    = suppressWarnings(max(.data[[timeCol]], na.rm = TRUE)),
      .groups     = "drop"
    ) |>
    tibble::as_tibble()

  stat_cols <- c("min_time", "c10_time", "lq_time", "median_time",
                 "uq_time", "c90_time", "max_time")
  summaryStats <- summaryStats |>
    dplyr::mutate(dplyr::across(dplyr::all_of(stat_cols),
      ~ dplyr::if_else(is.infinite(.x), NA_real_, as.double(.x))))

  summaryStats <- summaryStats |>
    dplyr::mutate(count = dplyr::case_when(
      .data$count > 0 & .data$count < minCellCount ~ as.double(-minCellCount),
      TRUE ~ as.double(.data$count))) |>
    dplyr::mutate(dplyr::across(dplyr::all_of(stat_cols),
      ~ dplyr::case_when(.data$count < 0 ~ NA_real_, TRUE ~ .x)))

  histData <- data |>
    dplyr::mutate(time_bin = cut(.data[[timeCol]], breaks = histogramBreaks,
                                  right = FALSE, ordered_result = TRUE)) |>
    dplyr::group_by(dplyr::across(dplyr::all_of(c(grp, "time_bin")))) |>
    dplyr::summarise(count = dplyr::n(), .groups = "drop") |>
    dplyr::mutate(count = dplyr::case_when(
      .data$count > 0 & .data$count < minCellCount ~ as.double(-minCellCount),
      TRUE ~ as.double(.data$count))) |>
    tibble::as_tibble()

  list(summaryStats = summaryStats, histogram = histData)
}


# --- internal helpers --------------------------------------------------------

# Ensure tidy KM output always carries a `strata` column: broom::tidy(survfit)
# omits it when the formula stratum has only one level (common in per-cohort
# bladder runs), but extractSurvivalMilestones() needs it.
.normalizeKmStrata <- function(kmData, strata = NULL, ds = NULL) {
  if (!is.data.frame(kmData)) return(kmData)
  if ("strata" %in% names(kmData)) return(kmData)

  if (!is.null(strata) && length(strata) > 0) {
    present <- intersect(strata, names(kmData))
    if (length(present) > 0) {
      kmData$strata <- if (length(present) == 1L) {
        as.character(kmData[[present[1]]])
      } else {
        apply(kmData[, present, drop = FALSE], 1L, function(x) paste(x, collapse = ", "))
      }
      return(kmData)
    }
    if (is.data.frame(ds) && all(strata %in% names(ds))) {
      levels <- unique(ds[, strata, drop = FALSE])
      if (nrow(levels) == 1L) {
        label <- if (length(strata) == 1L) as.character(levels[[1]]) else
          paste(apply(levels, 1L, paste, collapse = ", "), collapse = ", ")
        n <- nrow(kmData)
        kmData$strata <- if (n == 0L) character(0) else rep(label, n)
        return(kmData)
      }
    }
  }

  n <- nrow(kmData)
  kmData$strata <- if (n == 0L) character(0) else rep("All", n)
  kmData
}

# Strata label for median-survival rows when survfit has no $strata component.
.medianStrataLabel <- function(ds, strata) {
  if (is.null(strata) || length(strata) == 0) return("All")
  if (!all(strata %in% names(ds))) return("All")
  levels <- unique(ds[, strata, drop = FALSE])
  if (nrow(levels) != 1L) return("All")
  if (length(strata) == 1L) return(as.character(levels[[1]]))
  paste(apply(levels, 1L, paste, collapse = ", "), collapse = ", ")
}

# Median survival from a survfit object (supports multi-strata fits).
# broom::glance() errors on multi-strata survfit; use summary()$table instead.
.tidyMedianSurvival <- function(fit, strata = NULL, ds = NULL) {
  tab <- summary(fit)$table
  if (is.null(dim(tab))) {
    return(tibble::tibble(
      strata = .medianStrataLabel(ds, strata),
      n      = as.integer(tab[["records"]]),
      median = as.numeric(tab[["median"]]),
      lower  = as.numeric(tab[["0.95LCL"]]),
      upper  = as.numeric(tab[["0.95UCL"]])
    ))
  }

  strata_names <- rownames(tab)
  if (is.null(strata_names) || length(strata_names) == 0L) {
    strata_names <- if (is.null(fit$strata)) {
      rep(.medianStrataLabel(ds, strata), nrow(tab))
    } else {
      names(fit$strata)
    }
  }

  tibble::tibble(
    strata = strata_names,
    n      = as.integer(tab[, "records"]),
    median = as.numeric(tab[, "median"]),
    lower  = as.numeric(tab[, "0.95LCL"]),
    upper  = as.numeric(tab[, "0.95UCL"])
  )
}

# Fit survival model and return tidy KM data + median survival.
.fitSurvival <- function(ds, strata = NULL) {
  surv_object <- survival::Surv(ds$time, ds$flag)

  formula <- if (!is.null(strata) && length(strata) > 0) {
    stats::as.formula(paste("surv_object ~", paste(strata, collapse = " + ")))
  } else {
    stats::as.formula("surv_object ~ 1")
  }

  fit <- survival::survfit(formula, data = ds)

  kmData <- broom::tidy(fit) |> dplyr::filter(.data$estimate < 1)
  kmData <- .normalizeKmStrata(kmData, strata, ds = ds)
  kmData <- tibble::as_tibble(kmData)

  medianSurvival <- tryCatch(
    .tidyMedianSurvival(fit, strata = strata, ds = ds),
    error = function(e) tibble::tibble()
  )

  list(kmData = kmData, medianSurvival = medianSurvival)
}

# Privacy-censor count columns in a TTE summary table: counts below
# minCellCount become -minCellCount, and any suppCols on a censored row are
# blanked to NA. Same rule as this repo's other censoring code (e.g.
# R/05_eligibility_coverage.R's `censor()`, R/03_main_cohorts.R inline).
.censorTteCounts <- function(df, minCellCount, countCols, suppCols) {
  for (cc in countCols) {
    if (cc %in% names(df)) {
      df[[cc]] <- dplyr::case_when(
        df[[cc]] > 0 & df[[cc]] < minCellCount ~ as.double(-minCellCount),
        TRUE ~ as.double(df[[cc]]))
    }
  }

  censored_rows <- Reduce(`|`, lapply(countCols, function(cc) {
    if (cc %in% names(df)) df[[cc]] < 0 else rep(FALSE, nrow(df))
  }))

  for (sc in suppCols) {
    if (sc %in% names(df)) {
      df[[sc]] <- dplyr::if_else(censored_rows, NA_real_, as.double(df[[sc]]))
    }
  }

  df
}
