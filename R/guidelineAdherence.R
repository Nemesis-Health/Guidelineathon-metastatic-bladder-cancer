# ===========================================================================
# guidelineAdherence.R  —  relevance + adherence roll-up (pure set-math)
# ===========================================================================
# Implements the protocol's "Application of the Guideline to clinical
# practice" section. Adapted from onco-study-modules' computeGuidelineAdherence()
# in shape and censoring convention, but with corrected set logic: that
# function assumes cohorts 4/5/6 already exclude one another (the protocol's
# literal cohort definitions: "5a = enfortumab regimens except those in 4a"),
# but in THIS repo cohorts 4/5/6(a-f) are three INDEPENDENT regimen-
# classification lenses (see cohorts/extras/regimen_reference.csv:
# class_eau/class_hemonc_mbc/class_any are computed separately, not as
# sequential exclusions), so naively intersecting cohort 5/6 membership would
# double-count patients already captured as adherent/alt-guideline. Every
# bucket below explicitly excludes every earlier bucket instead.
# ===========================================================================

# --- computeGuidelineRelevance() --------------------------------------------
# Per-cohort population size as a fraction of the base cohort (Cohort 1).
# `cohortIds` is any vector of cohort_definition_ids (base included or not —
# doesn't matter, it's just one more row).
computeGuidelineRelevance <- function(membership, baseId, cohortIds, minCellCount = 5L) {
  cohortIds <- as.integer(stats::na.omit(unique(cohortIds)))
  subjectsIn <- function(id)
    unique(membership$subject_id[membership$cohort_definition_id == id])

  baseSize <- length(subjectsIn(baseId))
  rows <- lapply(cohortIds, function(id) {
    n <- length(subjectsIn(id))
    tibble::tibble(cohort_definition_id = id, n = as.integer(n),
                   pct_of_base = if (baseSize > 0) round(n / baseSize * 100, 2) else NA_real_)
  })

  out <- dplyr::bind_rows(rows)
  small <- out$n > 0L & out$n < minCellCount
  out$pct_of_base <- dplyr::if_else(small, NA_real_, out$pct_of_base)
  out$n <- dplyr::if_else(small, -as.integer(minCellCount), out$n)
  out
}


# --- computeAdherenceRollup() ------------------------------------------------
# Per leaf (a-e), partitions the eligible population (`eligibleIds`) into
# five disjoint buckets:
#   adherent        = eligible ∩ adherentIds (cohort 3's arm)
#   alt_guideline   = (eligible ∩ altGuidelineIds) \ adherent            (cohort 4's arm)
#   indicated_other = (eligible ∩ indicatedIds) \ (adherent ∪ alt_guideline)      (cohort 5's arm)
#   non_indicated   = (eligible ∩ nonIndicatedIds) \ (all of the above)  (cohort 6's arm)
#   no_treatment    = eligible \ (all of the above)
# `eligibleIds`/`adherentIds`/... are named-by-leaf vectors (names "a".."e");
# all must share the same leaf names. Leaf "e" (ineligible) pairs with each
# lens's "other" (f) category, not "e"/other_recommended — the caller resolves
# that when building the id vectors (matches how 03_main_cohorts.R builds T3e
# from `c456[["eau:other"]]`, not `c456[["eau:other_recommended"]]`).
computeAdherenceRollup <- function(membership, eligibleIds, adherentIds,
                                   altGuidelineIds, indicatedIds,
                                   nonIndicatedIds, minCellCount = 5L) {
  leaves <- names(eligibleIds)
  subjectsIn <- function(id) {
    if (is.null(id) || is.na(id)) return(integer(0))
    unique(membership$subject_id[membership$cohort_definition_id == id])
  }

  rows <- list()
  for (lf in leaves) {
    elig <- subjectsIn(eligibleIds[[lf]])

    adherent     <- intersect(elig, subjectsIn(adherentIds[[lf]]))
    altGuideline <- setdiff(intersect(elig, subjectsIn(altGuidelineIds[[lf]])),
                            adherent)
    indicated    <- setdiff(intersect(elig, subjectsIn(indicatedIds[[lf]])),
                            union(adherent, altGuideline))
    nonIndicated <- setdiff(intersect(elig, subjectsIn(nonIndicatedIds[[lf]])),
                            Reduce(union, list(adherent, altGuideline, indicated)))
    treated      <- Reduce(union, list(adherent, altGuideline, indicated, nonIndicated))
    noTreatment  <- setdiff(elig, treated)

    counts <- list(adherent = length(adherent), alt_guideline = length(altGuideline),
                   indicated_other = length(indicated), non_indicated = length(nonIndicated),
                   no_treatment = length(noTreatment))
    eligN <- length(elig)
    for (cat in names(counts)) {
      n <- counts[[cat]]
      rows[[length(rows) + 1L]] <- tibble::tibble(
        leaf = lf, category = cat, n = as.integer(n), eligible_n = as.integer(eligN),
        pct_of_eligible = if (eligN > 0) round(n / eligN * 100, 2) else NA_real_)
    }
  }

  out <- dplyr::bind_rows(rows)
  small <- out$n > 0L & out$n < minCellCount
  out$pct_of_eligible <- dplyr::if_else(small, NA_real_, out$pct_of_eligible)
  out$n <- dplyr::if_else(small, -as.integer(minCellCount), out$n)
  smallElig <- out$eligible_n > 0L & out$eligible_n < minCellCount
  out$eligible_n <- dplyr::if_else(smallElig, -as.integer(minCellCount), out$eligible_n)
  out
}
