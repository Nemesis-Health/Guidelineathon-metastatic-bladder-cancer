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

nameMap <- dplyr::select(mainManifest, cohort_definition_id = "cohortId",
                         cohort_name = "cohortName")

if (nrow(membership) == 0L) {

  message("  no members in the relevant cohorts — skipping adherence.")

} else {

  relevance <- computeGuidelineRelevance(membership, t1Id, relevantIds,
    minCellCount = settings$minCellCount) |>
    dplyr::left_join(nameMap, by = "cohort_definition_id") |>
    dplyr::relocate("cohort_name", .after = "cohort_definition_id")
  writeResultCsv(relevance, "guideline_relevance")

  adherence <- computeAdherenceRollup(membership,
    eligibleIds     = t2Ids,
    adherentIds     = t3Ids,
    altGuidelineIds = t4Ids,
    indicatedIds    = t5Ids,
    nonIndicatedIds = t6Ids,
    minCellCount    = settings$minCellCount)
  writeResultCsv(adherence, "guideline_adherence")

  message("  relevance: ", nrow(relevance), " cohort(s); adherence: ",
          nrow(adherence), " leaf x category row(s)")
}
