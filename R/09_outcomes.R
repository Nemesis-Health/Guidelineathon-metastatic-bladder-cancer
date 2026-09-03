# ===========================================================================
# 09_outcomes.R  —  (i) outcomes: DTI / OS / TTNT / TTD / TFI
# ===========================================================================
# Protocol outcomes via computeTimeToEvent()/computeTimeDiffStats()
# (R/timeToEvent.R) + extractSurvivalMilestones() (R/survivalMilestones.R),
# fed by the event builders in R/eventBuilders.R:
#
#   dti      — T1 only.       first LoT start - Cohort 1 index. Median (IQR).
#   os       — every cohort    (T1, T2a-e, T3a-e, T4-6a-f, plus the L01-
#              anchored initiated cohorts). Index -> death, KM.
#   ttnt     — treated cohorts (T3a-e, T4-6a-f; indexed at LoT1 start). KM to
#              LoT2 start (or death, whichever first).
#   ttd      — treated cohorts. KM to LoT1 discontinuation (episode end, or
#              death, whichever first).
#   ttd_lot2 — treated cohorts, re-indexed at LoT2 start (subjects who
#              reached a 2nd line only). KM to LoT2 discontinuation.
#   tfi      — treated cohorts, re-indexed at LoT1 discontinuation. KM to
#              LoT2 start (or death) — the protocol's "first to second LoT"
#              scope; LoT3+ TFI/TTNT/TTD are out of scope (matches the
#              protocol's own stated scope in the research questions).
#
# Every KM outcome also gets 1/2/3-year milestones. Every outcome is run
# "overall" plus once per protocol stratum (age_group / sex / index_year) —
# one at a time, matching the protocol's stratification list -- plus the
# age x sex crossed view (subject_strata.sql's age_sex column).
#
# Episode ranking is ANCHORED before any line-of-therapy event is built
# (anchorEpisodes(), R/eventBuilders.R): the protocol allows a patient into a
# treated cohort with prior systemic therapy as long as it was >12 months
# before the mBC index, so ARTEMIS may have an earlier, unrelated episode on
# record that would otherwise be mis-ranked as "line 1" and shift every
# subsequent line's numbering. DTI is anchored to Cohort 1's own index;
# TTNT/TTD/TFI/TTD-LoT2 are anchored to the subject's own treatment-start
# index (identical across every T3-6 alias a subject appears under, since
# they all derive their cohort_start_date from the same base cohort row).
#
# TTNT/TTD/TFI are death-aware (combineEarliestEvent(), R/eventBuilders.R):
# the protocol defines each as "... or death, whichever occurs first" —
# ARTEMIS episode boundaries already encode the other discontinuation
# reasons (next regimen start, >120-day gap) but know nothing about death.
#
# Depends on cohort ids resolved via cohortIdByName(mainManifest, cohortNames[[...]])
# (both built in R/03_main_cohorts.R) and the in-memory `episodes` tibble
# (built in R/01_artemis.R).
# ===========================================================================

message("\n== (i) outcomes (DTI / OS / TTNT / TTD / TFI) ==")

mainManifest <- loadState("mainManifest", "R/03_main_cohorts.R")
cohortNames  <- loadState("cohortNames", "R/03_main_cohorts.R")
episodes     <- loadState("episodes", "R/01_artemis.R",
                          path = file.path(settings$outputFolder, "episodes.rds"))

if (is.null(episodes) || nrow(episodes) == 0L) {

  message("  no ARTEMIS episodes — skipping outcomes.")

} else {

  # --- resolve the outcome-relevant cohort ids -------------------------------
  idsByCodes <- function(codes)
    as.integer(vapply(codes, function(cd) cohortIdByName(mainManifest, cohortNames[[cd]]),
                       integer(1)))

  t1Id    <- cohortIdByName(mainManifest, cohortNames[["T1"]])
  t2Ids   <- idsByCodes(paste0("T2", letters[1:5]))
  t3Ids   <- idsByCodes(paste0("T3", letters[1:5]))
  t456Ids <- idsByCodes(c(paste0("T4", letters[1:6]), paste0("T5", letters[1:6]),
                           paste0("T6", letters[1:6])))
  # L01-anchored initiated cohorts (R/03_main_cohorts.R): not part of the
  # cohortNames T-code map, so resolved directly by their assigned name.
  # OS-only (see file header) -- they have no lens-split, so they're left out
  # of treatedTargetCohortIds/TTNT/TTD/TFI, which need the ARTEMIS-episode
  # machinery those splits are built from.
  l01Ids  <- as.integer(stats::na.omit(c(
    cohortIdByName(mainManifest, "mBC initiated base (L01)"),
    cohortIdByName(mainManifest, "mBC initiated base (L01, PC allowed)"))))

  allTargetCohortIds     <- as.integer(stats::na.omit(c(t1Id, t2Ids, t3Ids, t456Ids, l01Ids)))
  treatedTargetCohortIds <- as.integer(stats::na.omit(c(t3Ids, t456Ids)))

  outcomeCohortIds <- list(
    dti      = as.integer(stats::na.omit(t1Id)),
    os       = allTargetCohortIds,
    ttnt     = treatedTargetCohortIds,
    ttd      = treatedTargetCohortIds,
    ttd_lot2 = treatedTargetCohortIds,
    tfi      = treatedTargetCohortIds
  )
  outcomeTypes <- c(dti = "time_diff", os = "km", ttnt = "km", ttd = "km",
                    ttd_lot2 = "km", tfi = "km")

  # --- target data: membership + dates + strata ------------------------------
  targetData <- querySqlFile(connection, "outcome_target_data.sql",
    work_database_schema = settings$workDatabaseSchema,
    cohort_table         = settings$cohortTable,
    target_cohort_ids    = paste(allTargetCohortIds, collapse = ", "))
  names(targetData) <- tolower(names(targetData))
  targetData$cohort_definition_id <- as.integer(targetData$cohort_definition_id)
  targetData$subject_id           <- as.integer(targetData$subject_id)
  targetData$cohort_start_date    <- as.Date(targetData$cohort_start_date)
  targetData$cohort_end_date      <- as.Date(targetData$cohort_end_date)

  strataTbl <- querySqlFile(connection, "subject_strata.sql",
    work_database_schema = settings$workDatabaseSchema,
    cohort_table         = settings$cohortTable,
    cdm_database_schema  = settings$cdmDatabaseSchema)
  names(strataTbl) <- tolower(names(strataTbl))
  strataTbl$cohort_definition_id <- as.integer(strataTbl$cohort_definition_id)
  strataTbl$subject_id           <- as.integer(strataTbl$subject_id)

  targetData <- dplyr::left_join(targetData, strataTbl,
    by = c("cohort_definition_id", "subject_id"))
  targetData <- tibble::as_tibble(targetData)

  if (nrow(targetData) == 0L) {

    message("  no members in the outcome-relevant cohorts — skipping outcomes.")

  } else {

    # --- anchor episodes before any line-of-therapy ranking -------------------
    episodesForDti <- anchorEpisodes(episodes,
      dplyr::filter(targetData, .data$cohort_definition_id == t1Id))
    episodesForTreatment <- anchorEpisodes(episodes,
      dplyr::filter(targetData, .data$cohort_definition_id %in% treatedTargetCohortIds))

    # --- shared person-level / episode-level events ---------------------------
    deathEvents <- fetchDeathEvents(connection, allTargetCohortIds)
    ttntEvents  <- combineEarliestEvent(
      buildLineOfTherapyEvents(episodesForTreatment, 1L, "next_lot"), deathEvents)
    ttdEvents   <- combineEarliestEvent(
      buildLineOfTherapyEvents(episodesForTreatment, 1L, "discontinuation"), deathEvents)
    ttdLot2Events <- combineEarliestEvent(
      buildLineOfTherapyEvents(episodesForTreatment, 2L, "discontinuation"), deathEvents)
    # TFI's terminal event ("next LoT start, or death before that") is
    # identical in construction to TTNT's — only the index date differs.
    tfiEvents <- ttntEvents

    # target/event pair per outcome: ttd_lot2 and tfi re-index the treated
    # cohort's rows onto a different anchor date (LoT2 start / LoT1
    # discontinuation) before running the same TTE engine.
    targetFor <- function(nm, cohortData) {
      switch(nm,
        ttd_lot2 = dplyr::inner_join(
                     dplyr::select(cohortData, -"cohort_start_date"),
                     dplyr::select(ttntEvents, "subject_id", "cohort_start_date"),
                     by = "subject_id"),
        tfi      = dplyr::inner_join(
                     dplyr::select(cohortData, -"cohort_start_date"),
                     dplyr::select(ttdEvents, "subject_id", "cohort_start_date"),
                     by = "subject_id"),
        cohortData)
    }

    eventFor <- function(nm, target) {
      switch(nm,
        dti      = buildDtiEvents(target, episodesForDti, lineNumber = 1L),
        os       = deathEvents,
        ttnt     = ttntEvents,
        ttd      = ttdEvents,
        ttd_lot2 = ttdLot2Events,
        tfi      = tfiEvents)
    }

    # one dimension at a time, per the protocol's stratification list, plus
    # the age x sex crossed view (subject_strata.sql's age_sex column).
    # age_group/sex/age_sex come from activeStrataSpecs() (settings$strataColumns,
    # run.R CONFIG) so a site can narrow/disable them in one place; index_year
    # is protocol-mandated and always on, independent of that setting.
    outcomeStrata <- c(activeStrataSpecs(), list(index_year = "index_year"))

    nameMap <- dplyr::select(mainManifest, cohort_definition_id = "cohortId",
                             cohort_name = "cohortName")

    tagRows <- function(tbl, cid, stratumName) {
      if (is.null(tbl) || nrow(tbl) == 0L) return(NULL)
      dplyr::mutate(tbl, cohort_definition_id = cid, stratum_type = stratumName,
                    .before = 1)
    }

    for (nm in names(outcomeCohortIds)) {
      cohortIds <- outcomeCohortIds[[nm]]
      summaryParts <- histParts <- kmParts <- medianParts <- milestoneParts <- list()

      for (cid in cohortIds) {
        cohortData <- dplyr::filter(targetData, .data$cohort_definition_id == cid)
        if (nrow(cohortData) == 0L) next
        target <- targetFor(nm, cohortData)
        if (nrow(target) == 0L) next
        ev <- eventFor(nm, target)

        for (stratumName in names(outcomeStrata)) {
          stratumCols <- outcomeStrata[[stratumName]]

          if (outcomeTypes[[nm]] == "time_diff") {
            evGrouped <- ev
            if (!is.null(stratumCols)) {
              evGrouped <- dplyr::left_join(ev,
                dplyr::select(target, "subject_id", dplyr::all_of(stratumCols)),
                by = "subject_id")
            }
            res <- computeTimeDiffStats(evGrouped, timeCol = "time_diff",
              groupCols = stratumCols, minCellCount = settings$minCellCount)

            summaryParts[[length(summaryParts) + 1L]] <-
              tagRows(res$summaryStats, cid, stratumName)
            histParts[[length(histParts) + 1L]] <-
              tagRows(res$histogram, cid, stratumName)

          } else {
            res <- computeTimeToEvent(targetData = target, eventData = ev,
              strata = stratumCols, minCellCount = settings$minCellCount)
            milestones <- if (nrow(res$kmData) > 0L) {
              extractSurvivalMilestones(res$kmData, milestones = c(365, 730, 1095),
                                        minCellCount = settings$minCellCount)
            } else {
              tibble::tibble()
            }

            summaryParts[[length(summaryParts) + 1L]]   <- tagRows(res$summaryStats, cid, stratumName)
            histParts[[length(histParts) + 1L]]          <- tagRows(res$histogram, cid, stratumName)
            kmParts[[length(kmParts) + 1L]]              <- tagRows(res$kmData, cid, stratumName)
            medianParts[[length(medianParts) + 1L]]      <- tagRows(res$medianSurvival, cid, stratumName)
            milestoneParts[[length(milestoneParts) + 1L]] <- tagRows(milestones, cid, stratumName)
          }
        }
      }

      writeOutcomeCsv <- function(parts, suffix) {
        tbl <- dplyr::bind_rows(parts)
        if (nrow(tbl) == 0L) return(invisible())
        tbl <- dplyr::left_join(tbl, nameMap, by = "cohort_definition_id") |>
          dplyr::relocate("cohort_name", .after = "cohort_definition_id")
        writeResultCsv(tbl, paste0("outcome_", nm, "_", suffix))
      }

      writeOutcomeCsv(summaryParts, "summary")
      writeOutcomeCsv(histParts, "histogram")
      if (outcomeTypes[[nm]] == "km") {
        writeOutcomeCsv(kmParts, "km")
        writeOutcomeCsv(medianParts, "median_survival")
        writeOutcomeCsv(milestoneParts, "milestones")
      }
      message("  ", nm, ": done (", length(cohortIds), " cohort(s))")
    }
  }
}
