# ===========================================================================
# 12_treatment_patterns.R  —  (l) treatment patterns by line of therapy
# ===========================================================================
# Protocol's "Treatment patterns" section: regimen distribution per LoT
# (number and percentage of patients on each regimen, at each LoT, for the
# treated population), % of Cohort 1 who received no treatment at all, and
# Sankey-ready LoT1->LoT2->LoT3 flow data.
#
# Builds a `treatedPatients`-equivalent tibble directly in R (no new SQL):
# the in-memory `episodes` (R/01_artemis.R), anchored to each Cohort-1
# member's own index date (anchorEpisodes(), R/eventBuilders.R — same fix as
# R/09_outcomes.R, so a pre-existing unrelated episode isn't mis-ranked as
# line 1), joined to the in-memory `regimenClass` data frame (also a global
# from R/01_artemis.R) by episode_source_value = regName. Reimplemented
# directly against this shape rather than porting onco-study-modules'
# computeCategoryCounts()/computeTreatmentPathways() input contract, though
# the same pure-dplyr approach.
#
# Outputs:
#   treatment_pattern_untreated.csv — Cohort 1 n, treated n, untreated n/pct.
#   treatment_pattern_regimen.csv   — lot_number x regimen name, n + pct-of-LoT.
#   treatment_pattern_category.csv  — lot_number x lens category (class_eau /
#                                      class_hemonc_mbc / class_any x a-f).
#   treatment_pathways.csv          — lot1/lot2/lot3 class_eau category ->
#                                      count. Capped at 3 lines, matching the
#                                      protocol's Sankey framing (LoT1->LoT2->
#                                      LoT3); not a rendered plot.
#   treatment_pattern_by_year.csv   — cohort x lot_number x treatment_year x
#                                      lens category, n + pct-of-(cohort/lot/
#                                      year). Protocol: "results are further
#                                      stratified by index year to evaluate
#                                      the changes in the treatment of mBC...
#                                      with the introduction of enfortumab."
#                                      Unlike the tables above (pooled across
#                                      every Cohort-1 initiator but not split
#                                      by cohort), this one is PER TREATED
#                                      COHORT - "treatment share by cohort" -
#                                      including "mBC initiated base" itself
#                                      (the whole unsplit treated population -
#                                      the most useful slice for seeing the
#                                      actual regimen mix shift over time,
#                                      since every T4/T5/T6 single-arm cohort
#                                      is 100% one category by construction
#                                      and T3a-e are further restricted to
#                                      eligible-and-adherent) plus T3a-e and
#                                      T4-6a-f individually.
#
# treatment_share_by_year_plot() (below) renders one of those slices as the
# stacked-bar-by-year chart used in the sibling final_app project. Call it
# interactively for whichever cohort/LoT/lens you want to look at.
# ===========================================================================

message("\n== (l) treatment patterns ==")

if (is.null(episodes) || nrow(episodes) == 0L) {

  message("  no ARTEMIS episodes — skipping treatment patterns.")

} else {

  t1Id <- cohortIdByName(mainManifest, cohortNames[["T1"]])

  t1Members <- querySqlFile(connection, "outcome_target_data.sql",
    work_database_schema = settings$workDatabaseSchema,
    cohort_table         = settings$cohortTable,
    target_cohort_ids    = as.character(t1Id))
  names(t1Members) <- tolower(names(t1Members))
  t1Members$subject_id        <- as.integer(t1Members$subject_id)
  t1Members$cohort_start_date <- as.Date(t1Members$cohort_start_date)

  if (nrow(t1Members) == 0L) {

    message("  no Cohort 1 members — skipping treatment patterns.")

  } else {

    episodesAnchored <- anchorEpisodes(episodes, t1Members)

    treatedPatients <- episodesAnchored |>
      dplyr::arrange(.data$person_id, .data$episode_start_date,
                     .data$episode_end_date, .data$episode_source_value) |>
      dplyr::mutate(lot_number = dplyr::row_number(), .by = "person_id") |>
      dplyr::left_join(regimenClass, by = c(episode_source_value = "regName"))

    censorN <- function(x)
      ifelse(!is.na(x) & x > 0 & x < settings$minCellCount, -settings$minCellCount, x)

    nT1      <- dplyr::n_distinct(t1Members$subject_id)
    nTreated <- dplyr::n_distinct(treatedPatients$person_id)

    # --- untreated % -----------------------------------------------------
    untreated <- tibble::tibble(
      n_t1          = nT1,
      n_treated     = censorN(nTreated),
      n_untreated   = censorN(nT1 - nTreated),
      pct_untreated = round((nT1 - nTreated) / nT1 * 100, 2))
    if (untreated$n_treated < 0 || untreated$n_untreated < 0)
      untreated$pct_untreated <- NA_real_
    writeResultCsv(untreated, "treatment_pattern_untreated")

    # --- regimen distribution by LoT --------------------------------------
    lotTotals <- dplyr::count(treatedPatients, .data$lot_number, name = "lot_n")

    regimenCounts <- treatedPatients |>
      dplyr::count(.data$lot_number, .data$episode_source_value, name = "n_patients") |>
      dplyr::rename(regName = "episode_source_value") |>
      dplyr::left_join(lotTotals, by = "lot_number") |>
      dplyr::mutate(pct_of_lot = round(.data$n_patients / .data$lot_n * 100, 2))
    small <- regimenCounts$n_patients > 0 & regimenCounts$n_patients < settings$minCellCount
    regimenCounts$pct_of_lot <- ifelse(small, NA_real_, regimenCounts$pct_of_lot)
    regimenCounts$n_patients <- ifelse(small, -settings$minCellCount, regimenCounts$n_patients)
    writeResultCsv(regimenCounts, "treatment_pattern_regimen")

    # --- category distribution by LoT, one block per classification lens --
    lensCols <- c(eau = "class_eau", hemonc_mbc = "class_hemonc_mbc", any = "class_any")
    catCounts <- dplyr::bind_rows(lapply(names(lensCols), function(lens) {
      treatedPatients |>
        dplyr::count(.data$lot_number, category = .data[[lensCols[[lens]]]],
                     name = "n_patients") |>
        dplyr::mutate(lens = lens, .before = 1)
    })) |>
      dplyr::left_join(lotTotals, by = "lot_number") |>
      dplyr::mutate(pct_of_lot = round(.data$n_patients / .data$lot_n * 100, 2))
    small <- catCounts$n_patients > 0 & catCounts$n_patients < settings$minCellCount
    catCounts$pct_of_lot <- ifelse(small, NA_real_, catCounts$pct_of_lot)
    catCounts$n_patients <- ifelse(small, -settings$minCellCount, catCounts$n_patients)
    writeResultCsv(catCounts, "treatment_pattern_category")

    # --- pathways (Sankey-ready): lot1/lot2/lot3 class_eau -> count --------
    lotSlice <- function(n) {
      out <- dplyr::filter(treatedPatients, .data$lot_number == n)
      out <- dplyr::select(out, "person_id", "class_eau")
      names(out)[2] <- paste0("lot", n)
      out
    }

    wide <- lotSlice(1L) |>
      dplyr::full_join(lotSlice(2L), by = "person_id") |>
      dplyr::full_join(lotSlice(3L), by = "person_id")

    pathways <- dplyr::count(wide, .data$lot1, .data$lot2, .data$lot3, name = "n_patients") |>
      dplyr::arrange(dplyr::desc(.data$n_patients))
    small <- pathways$n_patients > 0 & pathways$n_patients < settings$minCellCount
    pathways$n_patients <- ifelse(small, -settings$minCellCount, pathways$n_patients)
    writeResultCsv(pathways, "treatment_pathways")

    # --- treatment share by cohort x line x calendar year -------------------
    idsByCodes <- function(codes)
      as.integer(vapply(codes, function(cd) cohortIdByName(mainManifest, cohortNames[[cd]]),
                        integer(1)))
    # "mBC initiated base" (the unsplit treatment-initiated population, before
    # any EAU/HemOnc/any-ingredient classification) is the most useful of
    # these for seeing the ACTUAL regimen mix shift over time — every T4/T5/T6
    # single-arm cohort is 100% one category by construction, so it can't show
    # a mix at all; T3a-e are further restricted to eligible-and-adherent.
    # Resolved by literal name (03_main_cohorts.R's addCustom() call), not via
    # cohortNames[[...]] — it isn't part of that lookup table.
    baseCohortId <- cohortIdByName(mainManifest, "mBC initiated base")
    treatedCohortIds <- as.integer(stats::na.omit(c(baseCohortId, idsByCodes(
      c(paste0("T3", letters[1:5]),
        paste0("T4", letters[1:6]), paste0("T5", letters[1:6]), paste0("T6", letters[1:6]))))))

    treatedMembership <- querySqlFile(connection, "outcome_target_data.sql",
      work_database_schema = settings$workDatabaseSchema,
      cohort_table         = settings$cohortTable,
      target_cohort_ids    = paste(treatedCohortIds, collapse = ", "))
    names(treatedMembership) <- tolower(names(treatedMembership))
    treatedMembership$cohort_definition_id <- as.integer(treatedMembership$cohort_definition_id)
    treatedMembership$subject_id           <- as.integer(treatedMembership$subject_id)

    nameMapTP <- dplyr::select(mainManifest, cohort_definition_id = "cohortId",
                               cohort_name = "cohortName")

    # Per-subject age group / sex (sql/outcome_strata.sql — the same lookup
    # R/09_outcomes.R uses), so this table can be sliced the same way every
    # other stratified output in this pipeline is: one dimension at a time
    # (overall / age_group / sex), not crossed.
    strataTbl <- querySqlFile(connection, "outcome_strata.sql",
      work_database_schema = settings$workDatabaseSchema,
      cohort_table         = settings$cohortTable,
      cdm_database_schema  = settings$cdmDatabaseSchema)
    names(strataTbl) <- tolower(names(strataTbl))
    strataTbl$cohort_definition_id <- as.integer(strataTbl$cohort_definition_id)
    strataTbl$subject_id           <- as.integer(strataTbl$subject_id)

    # fans out one treatedPatients row per treated cohort a subject belongs
    # to (a subject is normally in several at once - one T3 leaf if eligible
    # + adherent, plus one T4/T5/T6 category apiece under each lens) - that's
    # intentional, since each cohort is its own population/denominator below.
    byYear <- treatedPatients |>
      dplyr::mutate(treatment_year = as.integer(format(.data$episode_start_date, "%Y"))) |>
      dplyr::inner_join(
        dplyr::select(treatedMembership, "cohort_definition_id", subject_id = "subject_id"),
        by = c(person_id = "subject_id"), relationship = "many-to-many") |>
      dplyr::left_join(strataTbl,
        by = c(cohort_definition_id = "cohort_definition_id", person_id = "subject_id"))

    # `groupCol = NULL` -> "overall" (no extra grouping column, one row per
    # cohort x lot x year x category); "age_group"/"sex" add that column into
    # the grouping so each of its levels gets its own denominator.
    yearCatCountsFor <- function(data, stratumType, groupCol = NULL) {
      grp <- c("cohort_definition_id", "lot_number", "treatment_year", groupCol)
      totals <- data |>
        dplyr::group_by(dplyr::across(dplyr::all_of(grp))) |>
        dplyr::summarise(year_lot_n = dplyr::n_distinct(.data$person_id), .groups = "drop")
      dplyr::bind_rows(lapply(names(lensCols), function(lens) {
        data |>
          dplyr::group_by(dplyr::across(dplyr::all_of(grp)), category = .data[[lensCols[[lens]]]]) |>
          dplyr::summarise(n_patients = dplyr::n_distinct(.data$person_id), .groups = "drop") |>
          dplyr::mutate(lens = lens, .before = 1)
      })) |>
        dplyr::left_join(totals, by = grp) |>
        dplyr::mutate(pct_of_year_lot = round(.data$n_patients / .data$year_lot_n * 100, 2),
                     stratum_type = stratumType, .before = 1)
    }

    yearCatCounts <- dplyr::bind_rows(
      yearCatCountsFor(byYear, "overall"),
      yearCatCountsFor(byYear, "age_group", "age_group"),
      yearCatCountsFor(byYear, "sex", "sex")
    ) |>
      dplyr::left_join(nameMapTP, by = "cohort_definition_id") |>
      dplyr::relocate("cohort_name", .after = "cohort_definition_id")

    small <- yearCatCounts$n_patients > 0 & yearCatCounts$n_patients < settings$minCellCount
    yearCatCounts$pct_of_year_lot <- ifelse(small, NA_real_, yearCatCounts$pct_of_year_lot)
    yearCatCounts$n_patients      <- ifelse(small, -settings$minCellCount, yearCatCounts$n_patients)
    writeResultCsv(yearCatCounts, "treatment_pattern_by_year")

    message("  treatment patterns: ", nTreated, " treated of ", nT1, " T1 subject(s)")
  }
}

# ===========================================================================
# treatment_share_by_year_plot() — stacked bar chart, one cohort/LoT/lens at
# a time (matches ~/final_app's "treatment share by year" chart). Not called
# automatically; run interactively, e.g.:
#   treatment_share_by_year_plot(yearCatCounts, cohort_id = 4, lot = 1)
# ===========================================================================
treatment_share_by_year_plot <- function(df, cohort_id, lot = 1L, lens_name = "eau") {
  plot_df <- df |>
    dplyr::filter(.data$cohort_definition_id == cohort_id, .data$lot_number == lot,
                  .data$lens == lens_name, !is.na(.data$pct_of_year_lot))
  if (nrow(plot_df) == 0) {
    message("No non-censored rows for cohort ", cohort_id, ", LoT", lot, ", lens '", lens_name, "'.")
    return(invisible(NULL))
  }
  cohort_label <- plot_df$cohort_name[1]
  ggplot2::ggplot(plot_df, ggplot2::aes(x = factor(.data$treatment_year),
                                        y = .data$pct_of_year_lot, fill = .data$category)) +
    ggplot2::geom_col(position = "stack") +
    ggplot2::scale_y_continuous(labels = scales::percent_format(scale = 1)) +
    ggplot2::labs(title = paste0(cohort_label, " — LoT", lot, " regimen share by year"),
                 x = "Index year", y = "% of patients", fill = "Category") +
    ggplot2::theme_minimal(base_size = 12)
}
