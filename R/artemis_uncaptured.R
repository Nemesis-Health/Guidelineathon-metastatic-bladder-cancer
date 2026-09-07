# ===========================================================================
# artemis_uncaptured.R  —  drill into ARTEMIS uncaptured exposures + view them
# ===========================================================================
# artemis_uncaptured_drugs.csv (step 06) is an aggregate: per ingredient, how
# many anticancer exposures ARTEMIS did NOT fold into an aligned regimen episode.
# These helpers drill that down to the *patient* level for one ingredient, and
# open the ARTEMIS per-patient alignment viewer on those patients.
#
# CAPTURE RULE (shared with R/06_artemis_assessment.R via capturedExposureRids):
# an exposure is captured when its start date falls within `graceDays` of an
# episode window OF A REGIMEN THAT CONTAINS THAT INGREDIENT. Two refinements over
# plain date-containment:
#   * ingredient-aware — a cisplatin dose during a Gemcitabine-monotherapy era is
#     NOT captured by that era (the regimen has no cisplatin); only episodes of
#     regimens that actually contain the drug count.
#   * grace window — ARTEMIS fragments a continuous course into short eras
#     (alternating e.g. GC <-> Gemcitabine monotherapy) with gaps; graceDays pads
#     each episode so doses in those inter-era gaps still count as captured.
# (There are no drug-exposure END dates to work with — see the step-06 header.)
#
# Both read the in-memory `artemisResult` from runArtemis() (still in scope after
# a run.R session). Sourced by run.R so they are available after step (a).
# ===========================================================================

.DEFAULT_GRACE_DAYS <- 30L

.cleanName <- function(x) tolower(gsub("[[:space:]]+", "", x))

# clean ingredient tokens from an ARTEMIS regString ("14.Cisplatin;0.Gemcitabine;...")
.regTokens <- function(regString) {
  if (is.na(regString) || !nzchar(regString)) return(character(0))
  t <- sub("^[0-9]+\\.", "", trimws(strsplit(regString, ";", fixed = TRUE)[[1]]))
  unique(.cleanName(t[nzchar(t)]))
}

#' regName -> set of clean ingredient tokens (from ARTEMIS regimens)
#' @param regimens artemisResult$regimens (needs regName, regString)
regimenIngredientMap <- function(regimens) {
  stopifnot(all(c("regName", "regString") %in% names(regimens)))
  lapply(split(regimens$regString, regimens$regName),
         function(v) unique(unlist(lapply(v, .regTokens))))
}

#' Row indices of validExp that are CAPTURED (ingredient-aware, grace-padded)
#'
#' @param validExp      exposures (person_id, drug_exposure_start_date, concept_name)
#' @param episodes      aligned episodes (person_id, episode_start_date,
#'                      episode_end_date, episode_source_value = regName)
#' @param regIngredients regName -> ingredient tokens, from regimenIngredientMap()
#' @param graceDays     days to pad each episode window on both sides
#' @return integer row indices into `validExp`
capturedExposureRids <- function(validExp, episodes, regIngredients,
                                 graceDays = .DEFAULT_GRACE_DAYS) {
  if (!is.data.frame(validExp) || nrow(validExp) == 0L) return(integer(0))
  if (!is.data.frame(episodes) || nrow(episodes) == 0L) return(integer(0))
  ex <- data.frame(
    .rid       = seq_len(nrow(validExp)),
    person_id  = as.character(validExp$person_id),
    date       = as.Date(validExp$drug_exposure_start_date),
    ingredient = .cleanName(validExp$concept_name),
    stringsAsFactors = FALSE)
  ep <- data.frame(
    person_id = as.character(episodes$person_id),
    start     = as.Date(episodes$episode_start_date) - graceDays,
    end       = as.Date(episodes$episode_end_date)   + graceDays,
    regName   = as.character(episodes$episode_source_value),
    stringsAsFactors = FALSE)
  j <- dplyr::inner_join(ex, ep, by = "person_id", relationship = "many-to-many")
  j <- j[j$date >= j$start & j$date <= j$end, , drop = FALSE]
  if (nrow(j) == 0L) return(integer(0))
  inReg <- mapply(function(ing, reg) {
    toks <- regIngredients[[reg]]
    !is.null(toks) && ing %in% toks
  }, j$ingredient, j$regName, USE.NAMES = FALSE)
  sort(unique(j$.rid[inReg]))
}

#' Restrict a person-keyed frame to records on or after each person's index date
#'
#' The "period of interest" filter behind the `target_1a_post_met` stratum in
#' R/06_artemis_assessment.R. Target 1A indexes on the first metastasis
#' measurement, so its `cohort_start_date` IS the metastasis date and this
#' becomes an on-or-after-metastasis floor. Day 0 is KEPT (`>=`), matching the
#' pre-study diagnostics convention (chunks 29/40).
#'
#' Persons absent from `indexDates` are dropped, not kept: with no index date
#' there is no way to place their records relative to metastasis, so keeping them
#' would silently mix un-windowed records into a windowed result.
#'
#' @param df         data frame with a person-id column and a date column
#' @param dateCol    name of the date column to test
#' @param indexDates named Date vector, person_id -> index date (names are the
#'   person ids as character). NULL returns `df` unchanged.
#' @param pcol       name of the person-id column (default "person_id")
#' @return `df` with only the rows on or after that person's index date
restrictToOnOrAfter <- function(df, dateCol, indexDates, pcol = "person_id") {
  if (is.null(indexDates) || !is.data.frame(df) || nrow(df) == 0L) return(df)
  if (!(pcol %in% names(df)) || !(dateCol %in% names(df))) return(df)
  idx  <- indexDates[as.character(df[[pcol]])]
  keep <- !is.na(idx) & as.Date(df[[dateCol]]) >= idx
  df[keep, , drop = FALSE]
}

#' Patients with an uncaptured exposure of a given ingredient
#'
#' @param artemisResult list from runArtemis() (needs $validDrugExposures,
#'   $episodes, $regimens)
#' @param ingredient    filter — an RxNorm ingredient concept_id (numeric or
#'   all-digit string, matched on `ancestor_concept_id`) or an ingredient name
#'   (character, case-insensitive on `concept_name`). NULL returns all uncaptured.
#' @param graceDays     capture grace window (default 30, same as step 06 uses).
#' @return data.frame, one row per uncaptured exposure: person_id,
#'   ingredient_concept_id, ingredient, drug_concept_id, exposure_start_date.
uncapturedExposures <- function(artemisResult, ingredient = NULL,
                                graceDays = .DEFAULT_GRACE_DAYS) {
  validExp <- artemisResult$validDrugExposures
  empty <- data.frame(person_id = character(0), ingredient_concept_id = integer(0),
                      ingredient = character(0), drug_concept_id = integer(0),
                      exposure_start_date = as.Date(character(0)),
                      stringsAsFactors = FALSE)
  if (!is.data.frame(validExp) || nrow(validExp) == 0L) return(empty)

  regIngredients <- regimenIngredientMap(artemisResult$regimens)
  captured <- capturedExposureRids(validExp, artemisResult$episodes,
                                   regIngredients, graceDays)
  ue <- validExp[!(seq_len(nrow(validExp)) %in% captured), , drop = FALSE]

  if (!is.null(ingredient)) {
    byId <- is.numeric(ingredient) || all(grepl("^[0-9]+$", ingredient))
    ue <- if (byId)
      ue[ue$ancestor_concept_id %in% as.integer(ingredient), , drop = FALSE]
    else
      ue[tolower(ue$concept_name) %in% tolower(ingredient), , drop = FALSE]
  }
  ue <- ue[order(as.character(ue$person_id),
                 as.Date(ue$drug_exposure_start_date)), , drop = FALSE]
  data.frame(
    person_id             = as.character(ue$person_id),
    ingredient_concept_id = ue$ancestor_concept_id,
    ingredient            = ue$concept_name,
    drug_concept_id       = ue$drug_concept_id,
    exposure_start_date   = as.Date(ue$drug_exposure_start_date),
    stringsAsFactors = FALSE)
}

#' Open ARTEMIS's per-patient alignment viewer for the given patients
#'
#' Filters the raw alignments to `personIds` and calls [ARTEMIS::plotAlignment()],
#' which draws each patient's drug exposures against their aligned regimen bars —
#' an uncaptured drug shows as a mark with no covering regimen. Returns a ggplot
#' (one patient) or a named list of ggplots (several). Patients with no alignment
#' at all won't appear (nothing aligned to show).
#'
#' @param artemisResult list from runArtemis() (needs $rawAlignments, $regimens)
#' @param personIds     person ids to plot (e.g. uncapturedExposures(...)$person_id)
#' @param add_summary   passed to [ARTEMIS::plotAlignment()]. Default FALSE: the
#'   summary path (`regimenEndsBeforeLastDrug`) references an `interval` column
#'   that only ARTEMIS's line-of-therapy step adds, so with raw alignments it
#'   errors ("object 'interval' not found"). FALSE skips it; the swimlane itself
#'   is unaffected. Set TRUE only if your ARTEMIS version fixes that helper.
plotUncapturedAlignment <- function(artemisResult, personIds, add_summary = FALSE, ...) {
  pa <- artemisResult$rawAlignments
  if (!is.data.frame(pa) || nrow(pa) == 0L)
    stop("artemisResult$rawAlignments is empty — nothing to plot.", call. = FALSE)
  pcol <- intersect(c("personID", "person_id", "personId"), names(pa))[1]
  if (is.na(pcol))
    stop("No person-id column found in rawAlignments.", call. = FALSE)
  if (pcol != "personID") pa$personID <- pa[[pcol]]
  pa <- pa[as.character(pa$personID) %in% as.character(personIds), , drop = FALSE]
  if (nrow(pa) == 0L) {
    message("None of those patients have raw alignments to plot.")
    return(invisible(NULL))
  }
  ARTEMIS::plotAlignment(pa, regimens = artemisResult$regimens,
                         add_summary = add_summary, ...)
}
