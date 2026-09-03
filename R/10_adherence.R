# ===========================================================================
# 10_adherence.R  —  (j) guideline relevance + adherence roll-up
# ===========================================================================
# Protocol's "Application of the Guideline to clinical practice" section:
#   relevance  — per-cohort population size as a fraction of Cohort 1.
#   adherence  — per eligibility leaf (a-e), the breakdown of eligible
#                patients into adherent / alt-guideline / indicated-other /
#                non-indicated / no-treatment (R/guidelineAdherence.R;
#                see that file's header for why the set logic differs from
#                onco-study-modules' original).
#
# Resolves its own cohort ids independently (cohortIdByName(mainManifest,
# cohortNames[[...]]), both from R/03_main_cohorts.R) rather than reusing
# R/09_outcomes.R's internals, matching this repo's existing convention of
# steps not depending on one another's local variables.
# ===========================================================================

message("\n== (j) guideline relevance + adherence ==")

mainManifest <- loadState("mainManifest", "R/03_main_cohorts.R")
cohortNames  <- loadState("cohortNames", "R/03_main_cohorts.R")

idsByCodes <- function(codes)
  as.integer(vapply(codes, function(cd) cohortIdByName(mainManifest, cohortNames[[cd]]),
                     integer(1)))

leaves  <- c("a", "b", "c", "d", "e")
# Leaf "e" (ineligible) pairs with each lens's "other" (f) catch-all, not
# "e"/other_recommended — matches how 03_main_cohorts.R builds T3e from
# c456[["eau:other"]].
armCode <- c(a = "a", b = "b", c = "c", d = "d", e = "f")

t1Id  <- cohortIdByName(mainManifest, cohortNames[["T1"]])
t2Ids <- stats::setNames(idsByCodes(paste0("T2", leaves)), leaves)
t3Ids <- stats::setNames(idsByCodes(paste0("T3", leaves)), leaves)
t4Ids <- stats::setNames(idsByCodes(paste0("T4", armCode[leaves])), leaves)
t5Ids <- stats::setNames(idsByCodes(paste0("T5", armCode[leaves])), leaves)
t6Ids <- stats::setNames(idsByCodes(paste0("T6", armCode[leaves])), leaves)

# full T4-6 a-f universe (for relevance, which reports every lens category,
# not just the 5 leaf-mapped ones adherence uses)
t456AllIds <- idsByCodes(c(paste0("T4", letters[1:6]), paste0("T5", letters[1:6]),
                           paste0("T6", letters[1:6])))

relevantIds <- as.integer(stats::na.omit(c(t1Id, t2Ids, t3Ids, t456AllIds)))

membership <- querySqlFile(connection, "outcome_target_data.sql",
  work_database_schema = settings$workDatabaseSchema,
  cohort_table         = settings$cohortTable,
  target_cohort_ids    = paste(relevantIds, collapse = ", "))
names(membership) <- tolower(names(membership))
membership$cohort_definition_id <- as.integer(membership$cohort_definition_id)
membership$subject_id           <- as.integer(membership$subject_id)

# subject_strata.sql is the single source of truth for age_group/sex/age_sex
# bucketing (shared with demographics.sql, R/04/05/09/12). Both
# computeGuidelineRelevance()/computeAdherenceRollup() work purely off
# subject-id sets filtered from `membership`, so stratifying just means
# pre-filtering membership to a stratum's subjects before calling them --
# no change needed in guidelineAdherence.R itself.
strataTbl <- querySqlFile(connection, "subject_strata.sql",
  work_database_schema = settings$workDatabaseSchema,
  cohort_table         = settings$cohortTable,
  cdm_database_schema  = settings$cdmDatabaseSchema)
names(strataTbl) <- tolower(names(strataTbl))
strataTbl$cohort_definition_id <- as.integer(strataTbl$cohort_definition_id)
strataTbl$subject_id           <- as.integer(strataTbl$subject_id)
membership <- dplyr::left_join(membership, strataTbl,
  by = c("cohort_definition_id", "subject_id"))

nameMap <- dplyr::select(mainManifest, cohort_definition_id = "cohortId",
                         cohort_name = "cohortName")

if (nrow(membership) == 0L) {

  message("  no members in the relevant cohorts — skipping adherence.")

} else {

  # age_group/sex/age_sex come from activeStrataSpecs() (settings$strataColumns,
  # run.R CONFIG) so a site can narrow/disable stratification in one place.
  stratumSpecs <- activeStrataSpecs()
  relevanceList <- adherenceList <- list()
  for (stratumType in names(stratumSpecs)) {
    col  <- stratumSpecs[[stratumType]]
    vals <- if (is.null(col)) "overall" else sort(unique(stats::na.omit(membership[[col]])))
    for (val in vals) {
      m <- if (is.null(col)) membership else membership[membership[[col]] == val, ]

      rel <- computeGuidelineRelevance(m, t1Id, relevantIds,
        minCellCount = settings$minCellCount)
      rel$stratum_type <- stratumType; rel$stratum_value <- val
      relevanceList[[length(relevanceList) + 1L]] <- rel

      adh <- computeAdherenceRollup(m,
        eligibleIds     = t2Ids,
        adherentIds     = t3Ids,
        altGuidelineIds = t4Ids,
        indicatedIds    = t5Ids,
        nonIndicatedIds = t6Ids,
        minCellCount    = settings$minCellCount)
      adh$stratum_type <- stratumType; adh$stratum_value <- val
      adherenceList[[length(adherenceList) + 1L]] <- adh
    }
  }

  relevance <- dplyr::bind_rows(relevanceList) |>
    dplyr::left_join(nameMap, by = "cohort_definition_id") |>
    dplyr::relocate("cohort_name", .after = "cohort_definition_id") |>
    dplyr::relocate("stratum_type", "stratum_value", .after = "cohort_name")
  writeResultCsv(relevance, "guideline_relevance", "guideline")

  adherence <- dplyr::bind_rows(adherenceList) |>
    dplyr::relocate("stratum_type", "stratum_value", .before = "leaf")
  writeResultCsv(adherence, "guideline_adherence", "guideline")

  message("  relevance: ", nrow(relevance), " cohort(s); adherence: ",
          nrow(adherence), " leaf x category row(s)")
}
