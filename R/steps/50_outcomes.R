# ===========================================================================
# 50_outcomes.R  —  outcomes: DTI / OS / TTNT / TTD / TFI
# ===========================================================================
# Protocol outcomes via computeTimeToEvent()/computeTimeDiffStats()
# (R/time_to_event.R) + extractSurvivalMilestones() (R/time_to_event.R),
# fed by the event builders in R/treatment_lines.R:
#
#   dti      — T1 only.       treatment start - Cohort 1 index for the base
#              treated cohort's members, i.e. by its rules (first classified
#              regimen starting 30 days before to 90 days after index, washout)
#              via treatedLines(), so -30 to 90 days. Descriptive stats, no KM;
#              also by the first line's treatment category under each
#              classification lens (outcome_dti_by_category_*.csv). Untreated
#              and late starters are in treatment_pattern_untreated.csv.
#   os       — every cohort    (T1, T2a-e, T3a-e, T4-6a-f, plus the L01-
#              anchored initiated cohorts). Index -> death, KM.
#   ttnt     — treated cohorts (T3a-e, T4-6a-f; indexed at LoT1 start). KM to
#              LoT2 start (or death, whichever first).
#   ttd      — treated cohorts. KM to LoT1 discontinuation (the line's end,
#              which is at death at the latest).
#   ttd_lot2 — treated cohorts, re-indexed at LoT2 start (subjects who
#              started a 2nd line within follow-up only). KM to LoT2
#              discontinuation.
#   tfi      — treated cohorts, re-indexed at LoT1 discontinuation, leaving
#              out subjects who died on LoT1 (no treatment-free interval).
#              KM to LoT2 start (or death) — the protocol's "first to second
#              LoT" scope; LoT3+ TFI/TTNT/TTD are out of scope (matches the
#              protocol's own stated scope in the research questions).
#
# Every KM outcome also gets 1/2/3-year milestones. Every outcome is run
# "overall" plus once per protocol stratum (age_group / sex / index_year) —
# one at a time, matching the protocol's stratification list -- plus the
# age x sex crossed view (subject_strata.sql's age_sex column).
#
# Lines of therapy are numbered once, by treatedLines() (R/treatment_lines.R),
# the same numbering step 70 and the DTI use. Episodes are ANCHORED on the
# treatment start first: the protocol allows a patient into a treated cohort
# with prior systemic therapy as long as it was >12 months before the mBC
# index, so ARTEMIS may have an earlier, unrelated episode on record that
# would otherwise be mis-ranked as "line 1" and shift every subsequent line's
# numbering. The treatment start is identical across every T3-6 alias a
# subject appears under, since they all derive their cohort_start_date from
# the same base cohort row, and line 1 is the regimen that row was indexed on.
#
# TTNT/TTD/TFI are death-aware: the protocol defines each as "... or death,
# whichever occurs first". ARTEMIS episode boundaries encode the other
# discontinuation reasons (next regimen start, >120-day gap) but know nothing
# about death, so treatedLines() ends every episode at death (dropping any
# that start after it), and TTNT/TFI take death as their event when it comes
# before the next line (combineEarliestEvent(), R/treatment_lines.R).
#
# Depends on cohort ids resolved via cohortIdByName(mainManifest, cohortNames[[...]])
# (both built in R/steps/12_main_cohorts.R) and the in-memory `episodes` tibble
# (built in R/steps/10_artemis.R).
# ===========================================================================

message("\n== outcomes (DTI / OS / TTNT / TTD / TFI) ==")

mainManifest <- loadState("mainManifest", "R/steps/12_main_cohorts.R")
cohortNames  <- loadState("cohortNames", "R/steps/12_main_cohorts.R")
episodes     <- loadState("episodes", "R/steps/10_artemis.R")
regimenClass <- loadState("regimenClass", "R/steps/10_artemis.R")

if (is.null(episodes) || nrow(episodes) == 0L) {

  message("  no ARTEMIS episodes — skipping outcomes.")

} else {

  # --- resolve the outcome-relevant cohort ids -------------------------------
  t1Id    <- cohortIdByName(mainManifest, cohortNames[["T1"]])
  t2Ids   <- idsByCodes(paste0("T2", letters[1:5]))
  t3Ids   <- idsByCodes(paste0("T3", letters[1:5]))
  t456Ids <- idsByCodes(c(paste0("T4", letters[1:6]), paste0("T5", letters[1:6]),
                           paste0("T6", letters[1:6])))
  # L01-anchored initiated cohorts: OS-only (see file header) -- they have no
  # lens-split, so they're left out of treatedTargetCohortIds/TTNT/TTD/TFI,
  # which need the ARTEMIS-episode machinery those splits are built from.
  l01Ids  <- idsByCodes(c("BaseL01", "BaseL01pc"))

  allTargetCohortIds     <- as.integer(c(t1Id, t2Ids, t3Ids, t456Ids, l01Ids))
  treatedTargetCohortIds <- as.integer(c(t3Ids, t456Ids))

  outcomeCohortIds <- list(
    os       = allTargetCohortIds,
    ttnt     = treatedTargetCohortIds,
    ttd      = treatedTargetCohortIds,
    ttd_lot2 = treatedTargetCohortIds,
    tfi      = treatedTargetCohortIds
  )
  outcomeTypes <- c(os = "km", ttnt = "km", ttd = "km", ttd_lot2 = "km", tfi = "km")

  # --- target data: membership + dates + strata ------------------------------
  targetData <- querySqlFile(connection, "outcome_target_data.sql",
    work_database_schema = settings$workDatabaseSchema,
    cohort_table         = settings$cohortTable,
    target_cohort_ids    = paste(allTargetCohortIds, collapse = ", "))
  names(targetData) <- tolower(names(targetData))
  targetData$cohort_definition_id <- as.integer(targetData$cohort_definition_id)
  # subject_id kept as character, not as.integer() -- see R/treatment_lines.R's
  # anchorEpisodes() comment: some sites' person_id exceeds int32, and this
  # column has to join against ARTEMIS-episode-derived ids (also character).
  # outcome_target_data.sql already CASTs to VARCHAR, so this is defense in
  # depth, not the actual fix -- see that file's comment.
  targetData$subject_id           <- as.character(targetData$subject_id)
  targetData$cohort_start_date    <- as.Date(targetData$cohort_start_date)
  targetData$cohort_end_date      <- as.Date(targetData$cohort_end_date)

  strataTbl <- queryStrata(connection)
  names(strataTbl) <- tolower(names(strataTbl))
  strataTbl$cohort_definition_id <- as.integer(strataTbl$cohort_definition_id)
  # subject_strata.sql is a widely-shared fragment (many SQL + R consumers),
  # so its subject_id column can't be CAST to VARCHAR in SQL without risking
  # other consumers' joins -- format(scientific = FALSE) avoids the
  # scientific-notation risk of a bare as.character() on this double without
  # touching the shared query (see sql/outcome_target_data.sql's comment).
  strataTbl$subject_id           <- format(strataTbl$subject_id, scientific = FALSE, trim = TRUE)

  targetData <- dplyr::left_join(targetData, strataTbl,
    by = c("cohort_definition_id", "subject_id"))
  targetData <- tibble::as_tibble(targetData)

  if (nrow(targetData) == 0L) {

    message("  no members in the outcome-relevant cohorts — skipping outcomes.")

  } else {

    # --- anchor episodes before any line-of-therapy ranking -------------------
    baseMembers <- querySqlFile(connection, "outcome_target_data.sql",
      work_database_schema = settings$workDatabaseSchema,
      cohort_table         = settings$cohortTable,
      target_cohort_ids    = as.character(idsByCodes("Base")))
    names(baseMembers) <- tolower(names(baseMembers))
    baseMembers$subject_id <- as.character(baseMembers$subject_id)
    t1Data    <- dplyr::filter(targetData, .data$cohort_definition_id == t1Id)
    deathEvents <- fetchDeathEvents(connection, allTargetCohortIds)
    dtiStatus <- firstLineStatus(episodes, baseMembers, t1Data, regimenClass,
        maintenance = settings$maintenanceMerge, maxGapDays = settings$maintenanceMaxGapDays,
        deaths = deathEvents)
    # lines of the base treated cohort, numbered once (treatedLines(),
    # R/treatment_lines.R): every T3-6 cohort is indexed on the base cohort's
    # line 1, so these are the lines of each treated cohort member. Every
    # episode ends at death at the latest, so a line's end is its
    # discontinuation date (next regimen, >120-day gap or death).
    treatedLots <- treatedLines(episodes, baseMembers, t1Data, regimenClass,
        maintenance = settings$maintenanceMerge, maxGapDays = settings$maintenanceMaxGapDays,
        deaths = deathEvents)

    # --- shared person-level / episode-level events ---------------------------
    lot1End   <- buildLineOfTherapyEvents(treatedLots, 1L, "discontinuation")
    lot2Start <- buildLineOfTherapyEvents(treatedLots, 1L, "next_lot")
    ttntEvents    <- combineEarliestEvent(lot2Start, deathEvents)
    ttdEvents     <- lot1End
    ttdLot2Events <- buildLineOfTherapyEvents(treatedLots, 2L, "discontinuation")
    # TFI's terminal event ("next LoT start, or death before that") is
    # identical in construction to TTNT's — only the index date differs.
    tfiEvents <- ttntEvents
    # TFI starts at LoT1's end; patients whose LoT1 ended at death (died on
    # first-line treatment) had no treatment-free interval and are left out.
    diedOnLot1 <- dplyr::inner_join(lot1End, dplyr::summarise(deathEvents,
        death = min(as.Date(.data$cohort_start_date)), .by = "subject_id"), by = "subject_id") |>
      dplyr::filter(.data$death <= .data$cohort_start_date)
    tfiStart <- dplyr::anti_join(lot1End, diedOnLot1, by = "subject_id")

    # target/event pair per outcome: ttd_lot2 and tfi re-index the treated
    # cohort's rows onto a different anchor date (LoT2 start / LoT1 end), and
    # keep only subjects who reached it within follow-up, before running the
    # same TTE engine. ttd_lot2 thus covers only patients who started LoT2.
    reindex <- function(cohortData, starts)
      dplyr::inner_join(dplyr::select(cohortData, -"cohort_start_date"),
                        dplyr::select(starts, "subject_id", "cohort_start_date"),
                        by = "subject_id") |>
        dplyr::filter(.data$cohort_start_date <= .data$cohort_end_date)
    targetFor <- function(nm, cohortData) {
      switch(nm,
        ttd_lot2 = reindex(cohortData, lot2Start),
        tfi      = reindex(cohortData, tfiStart),
        cohortData)
    }

    eventFor <- function(nm, target) {
      switch(nm,
        os       = deathEvents,
        ttnt     = ttntEvents,
        ttd      = ttdEvents,
        ttd_lot2 = ttdLot2Events,
        tfi      = tfiEvents)
    }

    # one dimension at a time, per the protocol's stratification list, plus
    # the age x sex crossed view (subject_strata.sql's age_sex column).
    # age_group/sex/age_sex come from activeStrataSpecs() (settings$strataColumns,
    # R/study_settings.R) so a site can narrow/disable them in one place; index_year
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

      writeOutcomeCsv <- function(parts, suffix) {
        tbl <- dplyr::bind_rows(parts)
        if (nrow(tbl) == 0L) return(invisible())
        tbl <- dplyr::left_join(tbl, nameMap, by = "cohort_definition_id") |>
          dplyr::relocate("cohort_name", .after = "cohort_definition_id")
        writeResultCsv(tbl, paste0("outcome_", nm, "_", suffix), "outcomes")
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

    # --- DTI: time from the T1 index to the first line --------------------------
    # firstLineStatus() places every T1 member: treated (base cohort, -30 to
    # 90 days), started_late (first classified regimen after day 90), or not
    # started (prior_treatment / no_treatment). Summaries
    # for two definitions, each with its own n: treated (-30 to 90 days) and
    # unbound (-30 days on: treated + started_late). Buckets cover every T1
    # member. Category = the first regimen's classification under each lens.
    dti <- dplyr::left_join(dplyr::select(t1Data, -"cohort_definition_id"), dtiStatus,
                            by = "subject_id")
    started <- dplyr::filter(dti, .data$status %in% c("treated", "started_late"))
    defs <- dplyr::bind_rows(
      dplyr::mutate(dplyr::filter(started, .data$status == "treated"), definition = "treated"),
      dplyr::mutate(started, definition = "unbound"))
    lenses <- c(eau = "class_eau", hemonc_mbc = "class_hemonc_mbc", any = "class_any")
    byLens <- function(d) dplyr::bind_rows(lapply(names(lenses), function(lens) {
      cls <- dplyr::distinct(dplyr::select(regimenClass, regimen = "regName",
                                           category = dplyr::all_of(lenses[[lens]])))
      dplyr::mutate(dplyr::left_join(d, cls, by = "regimen"), lens = lens,
                    category = dplyr::coalesce(.data$category, "unclassified"))
    }))
    defsCat <- byLens(defs)
    stopifnot(nrow(defsCat) == length(lenses) * nrow(defs))   # one category per lens
    dti$bucket <- dplyr::case_when(
      dti$status == "prior_treatment" ~ "not started: prior treatment",
      dti$status == "no_treatment"                    ~ "not started: none recorded",
      TRUE ~ as.character(cut(dti$days, c(-30, 0, 31, 61, 91, 181, 361, Inf), right = FALSE,
               labels = c("-30 to -1", "0-30", "31-60", "61-90", "91-180", "181-360", ">360"))))
    dti$bucket <- factor(dti$bucket, levels = c("-30 to -1", "0-30", "31-60", "61-90", "91-180",
      "181-360", ">360", "not started: prior treatment", "not started: none recorded"))
    startedCat <- byLens(dplyr::filter(dti, !is.na(.data$days)))
    censorN <- function(x) ifelse(x > 0 & x < settings$minCellCount, -settings$minCellCount, x)
    bucketCounts <- function(d, keys, stratumCols, stratumName) {
      by <- c(keys, stratumCols)
      out <- dplyr::count(d, dplyr::across(dplyr::all_of(c(by, "bucket"))), name = "n") |>
        dplyr::mutate(n_total = sum(.data$n), .by = dplyr::all_of(by)) |>
        dplyr::mutate(pct = round(100 * .data$n / .data$n_total, 2))
      out$pct[out$n < settings$minCellCount | out$n_total < settings$minCellCount] <- NA_real_
      out$n <- censorN(out$n); out$n_total <- censorN(out$n_total)
      tagRows(out, t1Id, stratumName)
    }
    dtiParts <- list(summary = list(), buckets = list(), by_category_summary = list(),
                     by_category_buckets = list())
    for (stratumName in names(outcomeStrata)) {
      sc <- outcomeStrata[[stratumName]]
      dtiParts$summary[[stratumName]] <- tagRows(computeTimeDiffStats(defs, timeCol = "days",
        groupCols = c("definition", sc), minCellCount = settings$minCellCount)$summaryStats, t1Id, stratumName)
      dtiParts$by_category_summary[[stratumName]] <- tagRows(computeTimeDiffStats(defsCat, timeCol = "days",
        groupCols = c("definition", "lens", "category", sc), minCellCount = settings$minCellCount)$summaryStats,
        t1Id, stratumName)
      dtiParts$buckets[[stratumName]] <- bucketCounts(dti, character(0), sc, stratumName)
      dtiParts$by_category_buckets[[stratumName]] <- bucketCounts(startedCat, c("lens", "category"), sc, stratumName)
    }
    for (part in names(dtiParts)) {
      tbl <- dplyr::bind_rows(dtiParts[[part]])
      if (nrow(tbl) == 0L) next
      tbl <- dplyr::left_join(tbl, nameMap, by = "cohort_definition_id") |>
        dplyr::relocate("cohort_name", .after = "cohort_definition_id")
      writeResultCsv(tbl, paste0("outcome_dti_", part), "outcomes")
    }
    message("  dti: ", sum(dti$status == "treated"), " treated, ",
            sum(dti$status == "started_late"), " started after day 90, of ", nrow(dti), " T1")
  }
}
