# ===========================================================================
# study_settings.R  —  fixed study settings (do not edit)
# ===========================================================================
# Settings that are the same at every site: work table names, the study's
# time windows, ARTEMIS reference filters, maintenance merging and the
# reported strata. They are part of the study design, so results stay
# comparable across sites only if nobody changes them.
#
# R/setup.R merges these under the site's `settings` list from run.R. If the
# study team asks a site to change one, add that field to the site's own
# `settings` list in run.R rather than editing this file; a field there takes
# precedence over the value here.
# README.md's "CONFIG settings reference" has the full detail on each.
# ===========================================================================

studySettings <- list(

  # --- Work tables ------------------------------------------------------------
  # Written to settings$workDatabaseSchema and dropped/recreated on each run.
  # Rename only if these names clash with tables already in that schema.
  cohortTable          = "bc_cohort",                  # main cohort tree (JSON + SQL-built cohorts)
  labCohortTable       = "bc_lab_cohort",              # unified eligibility table (labs + ECOG + conditions)
  rawLabResultsTable   = "bc_raw_lab_results",         # every normalised lab result, pass or fail
  covariateCohortTable = "bc_covariate_cohort",        # descriptive covariates (comorbidities); NOT part of the main tree
  artemisCohortName    = "ARTEMIS bladder cohort",     # cohort name ARTEMIS aligns against
  episodeTable         = "bc_artemis_episodes",        # ARTEMIS treatment episodes
  regimenClassTable    = "bc_regimen_classifications", # regimen -> treatment category lookup

  # --- Eligibility windows ----------------------------------------------------
  # Near-index eligibility inputs (labs, ECOG/PS) for Target 2a-2d, the
  # covariate PS overlap (step h), eligibility-input coverage (step e) and lab
  # value distributions (step d): days before / after index a record may fall.
  labWindowBeforeDays = 30L,
  labWindowAfterDays  = 30L,

  # How labs and ECOG decide eligibility in Target 2a-2d and T1-CE.
  #   "closest": per lab, the one result closest to index within the window
  #              decides every test of that lab (ties: before index wins; on the
  #              same day the worst value counts).
  #   "any":     a test passes if any passing result falls in the window.
  labValueSelection = "closest",

  # The same window for cohorts indexed on treatment start (the initiated
  # bases, T3-T6): 30 days before up to and including the start date, so
  # results taken after treatment began don't count. Condition flags use it
  # too for these cohorts.
  treatedLabWindowBeforeDays = 30L,
  treatedLabWindowAfterDays  = 0L,

  # Condition flags in Target 2a-2d and eligibility-input coverage (liver
  # metastasis, Gilbert's syndrome, neuropathy, skin disorders, hearing loss).
  # A flag counts when its cohort era overlaps this window; how long a
  # condition stays live is set by its cohort's end strategy, not here.
  conditionFlagWindowBeforeDays = 30L,
  conditionFlagWindowAfterDays  = 30L,

  # Baseline weight/height/BMI (step k): days before/after index. Wider than
  # the lab window, following onco-study-modules' convention.
  bodyMeasurementsWindowDays = 90L,

  # --- ARTEMIS reference + alignment ------------------------------------------
  # Drop endocrine-therapy regimens (tamoxifen, abiraterone, GnRH agonists, ...)
  # from the ARTEMIS reference, via is_endocrine in
  # cohorts/extras/regimen_reference.csv. FALSE counts them as anticancer
  # treatment.
  stripEndocrineTherapy = TRUE,

  # Which drugs go into each patient's alignment string. Non-regimen and
  # supportive drugs are gap noise that lowers alignment scores and shrinks
  # eras. TRUE keeps only drugs that appear in a kept regimen.
  validDrugsRegimenComponents = TRUE,

  # ATC 2nd-level classes kept in the alignment string, applied together with
  # the regimen-component filter above. character(0) turns the class filter
  # off. Regimens whose components are all filtered out can no longer align
  # and are dropped from the reference (logged).
  validDrugsAtcClasses = c("L01", "L02", "L03", "L04"),

  # ATC classes kept in the exposure assessment (step f: drug_exposures,
  # uncaptured, coverage). NULL mirrors the regimen anticancer filter (L01,
  # L03, L04, plus L02 when stripEndocrineTherapy is FALSE); character(0)
  # keeps every recognised ingredient, for debugging coverage numbers.
  assessmentAtcClasses = NULL,

  # --- Lines of therapy -------------------------------------------------------
  # Fold maintenance therapy into the line it maintains before lines are
  # numbered (outcomes and treatment patterns), e.g. avelumab after
  # platinum-based chemotherapy is part of line 1, not line 2. The rules are
  # maintenanceRules in R/treatment_lines.R. A maintenance episode must start
  # within maintenanceMaxGapDays of the earlier regimen's end. FALSE numbers
  # every ARTEMIS episode as its own line.
  maintenanceMerge      = TRUE,
  maintenanceMaxGapDays = 180L,

  # --- Stratification ---------------------------------------------------------
  # subject_strata.sql breakdowns reported, on top of "overall", on every
  # stratified output (read by activeStrataTypes()/activeStrataSpecs() in
  # R/outputs.R). See README.md "Stratification" for the definitions.
  # character(0) turns stratification off everywhere.
  strataColumns = c("age_group", "sex", "age_sex",
                    "age_band", "index_period", "index_period_2021")
)
