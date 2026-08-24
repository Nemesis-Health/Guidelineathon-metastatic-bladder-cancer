# ===========================================================================
# survivalMilestones.R  —  KM point estimates at fixed milestone times
# ===========================================================================
# Ported verbatim from onco-study-modules R/survivalMilestones.R — generic,
# study-agnostic. Reads the survival probability (+ 95% CI, n-at-risk) off a
# tidy KM curve (computeTimeToEvent()$kmData) at each requested time point.
# Used for the protocol's 1/2/3-year survival estimates (365/730/1095 days).
# ===========================================================================

# kmData: tidy KM tibble with `time`, `estimate`, `strata` (may also carry
# `conf.low`, `conf.high`, `n.risk`). Step-function semantics: for milestone
# t, the estimate is the row with the largest `time` not exceeding t; before
# the first event, survival is 1.0.
extractSurvivalMilestones <- function(kmData,
                                       milestones = c(365, 730, 1095),
                                       minCellCount = 5L) {

  if (!is.data.frame(kmData))
    stop("`kmData` must be a data frame.", call. = FALSE)
  if (!is.numeric(milestones) || length(milestones) == 0)
    stop("`milestones` must be a non-empty numeric vector.", call. = FALSE)
  if (any(milestones < 0))
    stop("`milestones` values must be non-negative.", call. = FALSE)

  required <- c("time", "estimate")
  miss <- setdiff(required, names(kmData))
  if (length(miss) > 0)
    stop("`kmData` is missing columns: ", paste(miss, collapse = ", "),
         call. = FALSE)

  # survfit/broom sometimes omit `strata` (unstratified fit, or a single
  # stratum level in a per-cohort run). Repair rather than fail.
  if (!"strata" %in% names(kmData)) {
    present <- intersect(names(kmData), c("age_group", "sex", "index_year"))
    if (length(present) == 1L) {
      kmData$strata <- as.character(kmData[[present[1]]])
    } else if (length(present) > 1L) {
      kmData$strata <- apply(kmData[, present, drop = FALSE], 1L,
                             function(x) paste(x, collapse = ", "))
    } else {
      n <- nrow(kmData)
      kmData$strata <- if (n == 0L) character(0) else rep("All", n)
    }
  }

  hasCi   <- all(c("conf.low", "conf.high") %in% names(kmData))
  hasRisk <- "n.risk" %in% names(kmData)

  if (nrow(kmData) == 0) {
    out <- tibble::tibble(strata = character(0), milestone = numeric(0),
                          surv_prob = numeric(0))
    if (hasCi)   out$lower     <- numeric(0)
    if (hasCi)   out$upper     <- numeric(0)
    if (hasRisk) out$n_at_risk <- integer(0)
    return(out)
  }

  strataLevels <- unique(kmData$strata)

  rows <- list()
  for (s in strataLevels) {
    sub <- kmData[kmData$strata == s, , drop = FALSE]
    sub <- sub[order(sub$time), , drop = FALSE]

    for (m in milestones) {
      stepRow <- sub[sub$time <= m, , drop = FALSE]
      if (nrow(stepRow) == 0) {
        row <- list(strata = s, milestone = m, surv_prob = 1.0)
        if (hasCi) { row$lower <- NA_real_; row$upper <- NA_real_ }
        if (hasRisk) row$n_at_risk <- NA_integer_
      } else {
        last <- stepRow[nrow(stepRow), , drop = FALSE]
        row <- list(strata = s, milestone = m, surv_prob = as.numeric(last$estimate))
        if (hasCi) {
          row$lower <- as.numeric(last$conf.low)
          row$upper <- as.numeric(last$conf.high)
        }
        if (hasRisk) row$n_at_risk <- as.integer(last$n.risk)
      }
      rows[[length(rows) + 1]] <- tibble::as_tibble(row)
    }
  }

  result <- dplyr::bind_rows(rows)

  if (hasRisk) {
    censor <- !is.na(result$n_at_risk) & result$n_at_risk > 0L &
              result$n_at_risk < minCellCount
    if (any(censor)) {
      result$surv_prob[censor] <- NA_real_
      if (hasCi) {
        result$lower[censor] <- NA_real_
        result$upper[censor] <- NA_real_
      }
      result$n_at_risk[censor] <- -as.integer(minCellCount)
    }
  }

  tibble::as_tibble(result)
}
