# ===========================================================================
# charlsonScore.R  —  Charlson Comorbidity Index scoring (pure math)
# ===========================================================================
# Ported verbatim from onco-study-modules R/comorbidities.R
# (computeCharlsonScore() / .charlsonWeights) — pure dplyr over a per-subject
# flag data frame, no DB/OSM-class dependency, so it needs no adaptation.
# Weights: Charlson 1987 / Quan 2005.
#
# Wiring (which cohorts supply which component flag) lives in
# R/11_baseline_characterization.R, not here — this file is just the scoring
# math, reusable regardless of how many of the 19 components are available.
# ===========================================================================

.charlsonWeights <- c(
  myocardial_infarction         = 1L,
  congestive_heart_failure      = 1L,
  peripheral_vascular_disease   = 1L,
  cerebrovascular_disease       = 1L,
  dementia                      = 1L,
  chronic_pulmonary_disease     = 1L,
  rheumatologic_disease         = 1L,
  peptic_ulcer_disease          = 1L,
  mild_liver_disease            = 1L,
  diabetes_without_complication = 1L,
  diabetes_with_complication    = 2L,
  hemiplegia_paraplegia         = 2L,
  renal_disease                 = 2L,
  any_malignancy                = 2L,
  leukemia                      = 2L,
  lymphoma                      = 2L,
  moderate_severe_liver_disease = 3L,
  metastatic_solid_tumor        = 6L,
  aids_hiv                      = 6L
)

# Canonical component names + weights (see .charlsonWeights above).
charlsonComponents <- function() .charlsonWeights

# `components`: one row per subject, `subject_id` + one logical/0-1 column
# per recognised Charlson component (see charlsonComponents()). Unknown
# columns are ignored; missing components just don't contribute — so this
# still returns a (partial, understated) score when only some components are
# wired up. Hierarchy adjustments (severe form clears the milder one before
# scoring): diabetes_with_complication > diabetes_without_complication;
# moderate_severe_liver_disease > mild_liver_disease; metastatic_solid_tumor >
# any_malignancy.
computeCharlsonScore <- function(components, category = TRUE) {

  if (!is.data.frame(components))
    stop("`components` must be a data frame.", call. = FALSE)
  if (!"subject_id" %in% names(components))
    stop("`components` must contain a `subject_id` column.", call. = FALSE)
  if (nrow(components) == 0) {
    out <- tibble::tibble(subject_id = components$subject_id, cci_score = integer(0))
    if (category) out$cci_category <- character(0)
    return(out)
  }

  knownCols <- intersect(names(.charlsonWeights), names(components))
  if (length(knownCols) == 0) {
    warning("No recognised Charlson component columns in `components`. ",
            "Returning zero scores. See charlsonComponents().", call. = FALSE)
    out <- tibble::tibble(subject_id = components$subject_id, cci_score = 0L)
    if (category) out$cci_category <- "0"
    return(out)
  }

  flags <- components[, knownCols, drop = FALSE]
  flags <- as.data.frame(lapply(flags, function(x) {
    if (is.logical(x)) return(as.integer(x))
    if (is.numeric(x)) return(as.integer(x > 0))
    stop("Charlson component columns must be logical or numeric.", call. = FALSE)
  }))

  if (all(c("diabetes_with_complication", "diabetes_without_complication") %in% knownCols)) {
    flags$diabetes_without_complication <- ifelse(
      flags$diabetes_with_complication == 1L, 0L, flags$diabetes_without_complication)
  }
  if (all(c("moderate_severe_liver_disease", "mild_liver_disease") %in% knownCols)) {
    flags$mild_liver_disease <- ifelse(
      flags$moderate_severe_liver_disease == 1L, 0L, flags$mild_liver_disease)
  }
  if (all(c("metastatic_solid_tumor", "any_malignancy") %in% knownCols)) {
    flags$any_malignancy <- ifelse(
      flags$metastatic_solid_tumor == 1L, 0L, flags$any_malignancy)
  }

  weights <- .charlsonWeights[knownCols]
  scoreMatrix <- as.matrix(flags) %*% as.integer(weights)
  score <- as.integer(scoreMatrix[, 1])

  out <- tibble::tibble(subject_id = components$subject_id, cci_score = score)
  if (category) {
    out$cci_category <- dplyr::case_when(
      score == 0L               ~ "0",
      score >= 1L & score <= 2L ~ "1-2",
      score >= 3L & score <= 4L ~ "3-4",
      score >= 5L               ~ ">=5",
      TRUE                      ~ NA_character_
    )
  }
  out
}
