# ===========================================================================
# pipeline.R  —  the steps run.R runs, grouped into stages
# ===========================================================================
# Each step is a script in R/steps/, sourced at global scope in the order
# listed. Its number gives its stage: 00 diagnostics, 1x cohorts, then one
# stage per results/eligibility/ subfolder. A step that needs an earlier
# step's result reads it with loadState() (R/pipeline.R), so a step can run on
# its own after a crash once the steps it reads from have run.
#
#   diagnostics         pre-study queries on the CDM -> results/diagnostics/
#   cohorts             ARTEMIS episodes, eligibility inputs, the main cohort
#                       tree (work-schema tables, plus cohort_counts.csv and
#                       attrition_target_1a.csv in characterization/)
#   characterization    demographics, covariates, body measurements + CCI,
#                       roll-ups; 21_covariates.R generates the comorbidity
#                       cohorts 22 and 32 read, so it runs before both
#   labs                lab ranges, eligibility-input coverage, lab coverage
#                       by comorbidity subgroup
#   artemis             ARTEMIS alignment assessment
#   outcomes            DTI / OS / TTNT / TTD / TTD-LoT2 / TFI
#   guideline           guideline relevance + adherence
#   treatment_patterns  treatment patterns by line of therapy
# ===========================================================================

pipelineStages <- list(
  diagnostics        = "00_diagnostics.R",
  cohorts            = c("10_artemis.R", "11_eligibility_inputs.R", "12_main_cohorts.R"),
  characterization   = c("20_demographics.R", "21_covariates.R",
                         "22_baseline_characterization.R", "23_rollups.R"),
  labs               = c("30_lab_ranges.R", "31_eligibility_coverage.R",
                         "32_covariate_lab_coverage.R"),
  artemis            = "40_artemis_assessment.R",
  outcomes           = "50_outcomes.R",
  guideline          = "60_adherence.R",
  treatment_patterns = "70_treatment_patterns.R"
)
studyStages <- setdiff(names(pipelineStages), "diagnostics")

# --- resumable state checkpoints --------------------------------------------
# Several steps build an expensive/derived R object (mainManifest, covSet,
# episodes, regimenClass, ...) that lives only in memory. If the R session
# crashes after that step ran, re-sourcing a later step used to fail with a
# bare "object not found" — forcing you to reconstruct it by hand. These two
# helpers checkpoint such objects to disk as they're built, and transparently
# reload them if a later step is sourced standalone without the object
# already in memory (falling back to `producedBy` in the error message when
# neither the in-memory object nor a checkpoint exists, e.g. an early crash).
saveState <- function(name, obj, path = NULL) {
  path <- path %||% file.path(settings$stateFolder, paste0(name, ".rds"))
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  saveRDS(obj, path)
}

loadState <- function(name, producedBy, path = NULL) {
  if (exists(name, envir = .GlobalEnv, inherits = FALSE))
    return(get(name, envir = .GlobalEnv))
  path <- path %||% file.path(settings$stateFolder, paste0(name, ".rds"))
  if (!file.exists(path))
    stop("`", name, "` isn't in memory and no checkpoint was found at ", path,
         " — make sure ", producedBy, " has been run first.", call. = FALSE)
  message("  (resuming) loaded `", name, "` from ", path)
  readRDS(path)
}

runStage <- function(stage) {
  message("\n=== Stage: ", stage, " ===")
  for (f in pipelineStages[[stage]]) source(file.path("R", "steps", f))
}

# diagnostics.zip holds results/diagnostics/, study_results.zip
# results/eligibility/; both are aggregate and already censored.
zipResults <- function(part) {
  folder <- c(diagnostics = "diagnostics", study = "eligibility")[[part]]
  zipFile <- file.path(settings$outputFolder,
                       c(diagnostics = "diagnostics.zip", study = "study_results.zip")[[part]])
  utils::zip(zipfile = zipFile,
             files = list.files(file.path(settings$outputFolder, folder), recursive = TRUE,
                                full.names = TRUE, include.dirs = TRUE, all.files = TRUE),
             flags = "-q")
  message("Wrote ", zipFile)
}
