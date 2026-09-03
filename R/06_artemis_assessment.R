# ===========================================================================
# 06_artemis_assessment.R  —  ARTEMIS regimen-alignment assessment
# ===========================================================================
# Descriptive assessment of the ARTEMIS run from step (a). Reads the in-memory
# `artemisResult` (returned by runArtemis() and still in global scope) so no
# extra CDM queries are needed. All patient/record counts < minCellCount are
# censored to -minCellCount and the paired record/episode count is blanked,
# matching R/05_eligibility_coverage.R.
#
# This is the study-owned home for the ARTEMIS coverage/uncaptured analytics.
# Upstream OncoStudyModules ships equivalents (computeArtemisCoverage() /
# computeUncapturedExposures()) but they are NOT vendored into R/artemis.R:
# they depend on a `censorCounts()` helper this standalone repo does not carry,
# and on a `drug_exposure_end_date` column the extraction SQL never selects.
# We reimplement the same ideas against the columns we actually have
# (start-date only), so exposure coverage is start-date containment.
#
# COHORT STRATA: every output carries a leading `cohort` column and is emitted
# once per stratum, stacked in the same CSV:
#   scan_cohort        — the full ARTEMIS scan cohort (as before).
#   target_1a          — restricted to the "T1 Metastatic bladder cancer" cohort
#                        (== cohort1Id; step 05's Target-1A coverage denominator).
#                        This is "the metastatic subset".
#   target_1a_post_met — the metastatic subset restricted to the STUDY PERIOD OF
#                        INTEREST: only exposures / episodes dated on or after the
#                        patient's metastasis date. Target 1A indexes on the first
#                        metastasis measurement, so its cohort_start_date IS the
#                        metastasis date. Day 0 counts as post-metastasis, matching
#                        the pre-study diagnostics convention (chunks 29/40).
# Since every ARTEMIS frame is keyed by person_id, the first two strata are just a
# person-id filter; the third adds a per-person date floor.
#
# WHAT THE DATE FLOOR APPLIES TO (target_1a_post_met only):
#   * exposures (conDF / validDrugExposures) — kept when
#     drug_exposure_start_date >= metastasis date.
#   * episodes — kept when episode_start_date >= metastasis date. So the regimen
#     list, the episodes-per-patient distribution and the patient-level coverage
#     all describe regimens STARTED after metastasis.
#   * raw alignments — ARTEMIS stores these as day OFFSETS (t_start) from each
#     patient's first valid exposure, not as dates, so they are re-dated the same
#     way buildEpisodeTable() does (refDate + t_start) before the floor is applied.
#   * the CAPTURE TEST is deliberately NOT date-floored: a post-metastasis
#     exposure is tested against ALL of that patient's episodes, including one that
#     started before metastasis. Otherwise a dose 10 days after metastasis, covered
#     by a regimen that started 20 days before it, would be reported as uncaptured
#     — an artefact of the window, not a data gap. Exposure-level coverage and
#     artemis_uncaptured_drugs stay exact complements of each other.
#
# Outputs (results/csv/):
#   artemis_summary.csv          — patients + records per pipeline stage
#   artemis_coverage.csv         — cohort-, patient- & exposure-level coverage
#                                  (incl. % of the cohort with >=1 aligned regimen)
#   artemis_drug_exposures.csv   — anticancer exposures per ingredient (freq desc)
#   artemis_regimens_aligned.csv — aligned episodes per regimen (freq desc)
#   artemis_episodes_per_patient.csv — episode-count distribution per patient
#   artemis_uncaptured_drugs.csv — exposures overlapping no episode, per drug
# ===========================================================================

message("\n== ARTEMIS assessment ==")

# artemisResult is normally still in scope from step (a) in the same session,
# but step (a) persists it to disk too (see R/01_artemis.R), so a session that
# only re-runs (b)-(e) can reload it here instead of re-running the alignment.
if (!exists("artemisResult")) {
  rdsPath <- file.path(settings$outputFolder, "artemis_result.rds")
  if (file.exists(rdsPath)) {
    message("  artemisResult not in scope (ARTEMIS step (a) did not run this ",
            "session) — reloading from ", rdsPath)
    artemisResult <- readRDS(rdsPath)
  }
}

if (!exists("artemisResult")) {
  message("  artemisResult not in scope and no saved artemis_result.rds found ",
          "in the output folder — skipping assessment.")
} else {

  minCell   <- settings$minCellCount
  conDF     <- artemisResult$conDF               # all ingredient-level exposures
  validExp  <- artemisResult$validDrugExposures  # anticancer subset (the ARTEMIS input)
  episodes  <- artemisResult$episodes            # aligned regimen episodes
  rawAlign  <- artemisResult$rawAlignments

  # --- restrict exposures to ATC ingredients (aligned with regimen picking) --
  # loadDrugs() (hence validExp) carries supportive agents — steroids,
  # anticoagulants, antiemetics — that clutter the drug-exposure, uncaptured and
  # coverage tables with non-anticancer noise. Restrict the exposure-based
  # assessment to ingredients descending from ATC 2nd-level classes. When
  # settings$assessmentAtcClasses is NULL (default) this MIRRORS the regimen
  # anticancer filter: L01/L03/L04, plus L02 (endocrine) unless
  # stripEndocrineTherapy is TRUE. Set an explicit vector (e.g. c("L01")) to
  # override, or character(0) to keep every ingredient.
  atcClasses <- settings$assessmentAtcClasses
  if (is.null(atcClasses)) {
    atcClasses <- c("L01", "L03", "L04")
    if (!isTRUE(settings$stripEndocrineTherapy))
      atcClasses <- c(atcClasses, "L02")
  }
  if (length(atcClasses) > 0L && is.data.frame(validExp) && nrow(validExp) > 0L) {
    atcIds <- DatabaseConnector::querySql(connection, SqlRender::translate(
      SqlRender::render(
        "SELECT DISTINCT ca.descendant_concept_id AS concept_id
           FROM @vocab.concept a
           JOIN @vocab.concept_ancestor ca ON ca.ancestor_concept_id = a.concept_id
          WHERE a.vocabulary_id = 'ATC' AND a.concept_class_id = 'ATC 2nd'
            AND a.concept_code IN (@codes)",
        vocab = settings$vocabDatabaseSchema,
        codes = paste0("'", atcClasses, "'", collapse = ", ")),
      targetDialect = .getDbms(connection)))
    names(atcIds) <- tolower(names(atcIds))
    n0 <- nrow(validExp)
    validExp <- validExp[validExp$ancestor_concept_id %in% atcIds$concept_id, ,
                         drop = FALSE]
    message("  restricted valid exposures to ATC ", paste(atcClasses, collapse = "/"),
            " ingredient(s): ", n0, " -> ", nrow(validExp), " record(s).")
  }

  # --- censoring helpers (same rule as step 05) -----------------------------
  censorN <- function(x)
    ifelse(!is.na(x) & x > 0 & x < minCell, -minCell, as.integer(x))
  # censor a (patients, records) pair: blank records once patients are censored
  censorPair <- function(df, patCol, recCol) {
    if (nrow(df) == 0L) return(df)
    df[[patCol]] <- censorN(df[[patCol]])
    df[[recCol]] <- ifelse(df[[patCol]] < 0, NA_integer_, as.integer(df[[recCol]]))
    df
  }

  nrec <- function(df) if (is.data.frame(df)) nrow(df) else 0L
  npat <- function(df, col = "person_id")
    if (is.data.frame(df) && col %in% names(df)) dplyr::n_distinct(df[[col]]) else NA_integer_
  pct  <- function(n, d) if (is.na(n) || is.na(d) || d <= 0) NA_real_ else round(100 * n / d, 1)

  # ARTEMIS scan-cohort subjects (from step (a), if still in scope)
  nScan <- NA_integer_
  if (exists("artemisCounts") && exists("artemisCohortId"))
    nScan <- suppressWarnings(as.integer(
      artemisCounts$cohortSubjects[artemisCounts$cohortId == artemisCohortId][1]))

  # raw-alignment person-id column (name varies across ARTEMIS versions)
  raPcol <- if (is.data.frame(rawAlign))
    intersect(c("personID", "person_id", "personId"), names(rawAlign))[1] else NA_character_

  # ingredient map for the capture rule (regimen-independent; shared across strata)
  regIngredients <- regimenIngredientMap(artemisResult$regimens)

  # --- cohort strata: subject sets from the generated cohort table ----------
  # Returns one row per subject: person_id (character — some sites' person_id
  # exceeds int32) and index_date, the EARLIEST cohort_start_date for that
  # subject. Target 1A limits to the first metastasis so there is one entry per
  # subject anyway; MIN() just makes the date floor deterministic if a cohort
  # ever emits several.
  queryCohortSubjects <- function(cohortDefId) {
    empty <- data.frame(person_id = character(0),
                        index_date = as.Date(character(0)),
                        stringsAsFactors = FALSE)
    if (length(cohortDefId) != 1L || is.na(cohortDefId)) return(empty)
    df <- DatabaseConnector::querySql(connection, SqlRender::translate(
      # CAST to VARCHAR in SQL, not as.character() in R: a bigint person_id
      # arrives as a double and as.character() would render it in scientific
      # notation ("1.23e+12"), which never matches the ARTEMIS frames' ids
      # (conDfSql in R/artemis.R casts to VARCHAR the same way).
      SqlRender::render(
        "SELECT CAST(subject_id AS VARCHAR) AS person_id,
                MIN(cohort_start_date) AS index_date
           FROM @work.@tbl
          WHERE cohort_definition_id = @id
          GROUP BY subject_id",
        work = settings$workDatabaseSchema, tbl = settings$cohortTable,
        id = as.integer(cohortDefId)),
      targetDialect = .getDbms(connection)))
    names(df) <- tolower(names(df))
    data.frame(person_id  = as.character(df$person_id),
               index_date = as.Date(df$index_date),
               stringsAsFactors = FALSE)
  }
  # person_id -> index date, as a named Date vector for O(1) lookup by id
  indexDateMap <- function(df) {
    v <- as.Date(df$index_date); names(v) <- df$person_id; v
  }

  target1aId   <- cohortIdByName(mainManifest, "T1 Metastatic bladder cancer")
  t1a          <- queryCohortSubjects(target1aId)
  t1aSubjects  <- t1a$person_id
  t1aMetDate   <- indexDateMap(t1a)   # Target 1A indexes on first metastasis
  scanSubjects <- if (exists("artemisCohortId"))
    queryCohortSubjects(artemisCohortId)$person_id else character(0)
  message("  strata: scan_cohort (", length(scanSubjects), " subj) + target_1a / ",
          "target_1a_post_met (", length(t1aSubjects), " subj)")

  # Raw alignments carry day OFFSETS (t_start) from each patient's first VALID
  # exposure, not dates — buildEpisodeTable() re-dates them as refDate + t_start.
  # Reproduce refDate here (from the UNRESTRICTED validDrugExposures, exactly as
  # runArtemis() did) so the post-met stratum can date-floor them the same way.
  raRefDate <- NULL
  {
    ve0 <- artemisResult$validDrugExposures
    if (is.data.frame(ve0) && nrow(ve0) > 0L) {
      r <- tapply(as.integer(as.Date(ve0$drug_exposure_start_date)),
                  as.character(ve0$person_id), min)
      raRefDate <- structure(as.Date(as.integer(r), origin = "1970-01-01"),
                             names = names(r))
    }
  }

  # Compute all six tables for one stratum. persons = NULL -> full cohort (no
  # filter, byte-identical to the unstratified output); a character vector ->
  # restrict every frame to those person_ids. scanN = the "scan cohort subjects"
  # summary count for this stratum. cohortN = the stratum's own denominator (all
  # subjects of the defining cohort, whether or not ARTEMIS ever scanned them) —
  # used for the "cohort_subject" coverage level. indexDates = NULL for the
  # whole-history strata; a named Date vector (person_id -> metastasis date) adds
  # a per-person date floor, keeping only records on or after that date.
  assessStratum <- function(persons, label, scanN, cohortN = NA_integer_,
                            indexDates = NULL) {
    # person filter, then (when indexDates is given and the frame has `dateCol`)
    # the on-or-after-metastasis date floor. Day 0 is kept (>=), matching the
    # pre-study diagnostics convention.
    filt <- function(df, dateCol = NULL, pcol = "person_id") {
      if (is.null(persons)) return(df)
      if (!is.data.frame(df)) return(df)
      if (!(pcol %in% names(df)) || nrow(df) == 0L) return(df[0, , drop = FALSE])
      df <- df[as.character(df[[pcol]]) %in% persons, , drop = FALSE]
      if (is.null(dateCol)) return(df)
      restrictToOnOrAfter(df, dateCol, indexDates, pcol)
    }
    cdf <- filt(conDF,   "drug_exposure_start_date")
    vex <- filt(validExp, "drug_exposure_start_date")
    eps <- filt(episodes, "episode_start_date")
    # Episodes for the CAPTURE TEST are person-filtered but NOT date-floored: a
    # post-metastasis dose covered by a regimen that started before metastasis is
    # captured, not a data gap (see the WHAT THE DATE FLOOR APPLIES TO note above).
    epsForCapture <- if (is.null(indexDates)) eps else filt(episodes)

    ra <- if (is.null(persons)) rawAlign
          else if (is.data.frame(rawAlign) && nrow(rawAlign) && !is.na(raPcol))
            rawAlign[as.character(rawAlign[[raPcol]]) %in% persons, , drop = FALSE]
          else if (is.data.frame(rawAlign)) rawAlign[0, , drop = FALSE]
          else rawAlign
    # date-floor the raw alignments by re-dating their t_start day offset
    if (!is.null(indexDates) && is.data.frame(ra) && nrow(ra) > 0L &&
        !is.na(raPcol) && "t_start" %in% names(ra) && !is.null(raRefDate)) {
      ra$.alignDate <- raRefDate[as.character(ra[[raPcol]])] +
        as.integer(ra$t_start)
      ra <- restrictToOnOrAfter(ra, ".alignDate", indexDates, raPcol)
      ra$.alignDate <- NULL
    }
    raPat <- if (is.data.frame(ra) && !is.na(raPcol) && raPcol %in% names(ra))
      dplyr::n_distinct(ra[[raPcol]]) else NA_integer_

    # capture: exposure start within a grace window of an episode of a regimen
    # containing that ingredient (see capturedExposureRids in artemis_uncaptured.R)
    capturedRids <- capturedExposureRids(vex, epsForCapture, regIngredients)

    # 1. summary — entity counts per pipeline stage
    summaryTbl <- censorPair(tibble::tibble(
      cohort     = label,
      metric     = c("ARTEMIS scan cohort (subjects)",
                     "Ingredient-level drug exposures",
                     "Valid anticancer drug exposures",
                     "Raw alignments (pre-processing)",
                     "Regimen episodes aligned"),
      n_patients = c(scanN, npat(cdf), npat(vex), raPat, npat(eps)),
      n_records  = c(NA_integer_, nrec(cdf), nrec(vex), nrec(ra), nrec(eps))),
      "n_patients", "n_records")

    # 2. coverage — cohort-, patient- and exposure-level (CSV carries counts, not %)
    #    cohort_subject  : share of the WHOLE defining cohort with >=1 aligned
    #                      regimen episode — i.e. "% of the metastatic subset that
    #                      has at least one regimen". Patients ARTEMIS never
    #                      scanned stay in the denominator, so this is the
    #                      treatment-capture rate for the cohort as designed.
    #    scanned_subject : same numerator over the subjects ARTEMIS actually
    #                      scanned — the alignment success rate, with the
    #                      never-scanned patients taken out of the denominator.
    #                      The two differ only when the cohort isn't a subset of
    #                      the ARTEMIS scan cohort.
    #    patient         : share of patients WITH a valid anticancer exposure.
    #    exposure        : share of valid anticancer exposures that are captured.
    nWithRegimen <- npat(eps)
    totPat <- npat(vex); covPat <- nWithRegimen
    totExp <- nrec(vex); covExp <- length(capturedRids)
    coverageTbl <- tibble::tibble(
      cohort    = label,
      level     = c("cohort_subject", "scanned_subject", "patient", "exposure"),
      n_covered = censorN(c(nWithRegimen, nWithRegimen, covPat, covExp)),
      n_total   = censorN(c(cohortN, scanN, totPat, totExp)))

    # 3. valid anticancer exposures per ingredient
    drugTbl <- tibble::tibble()
    if (nrec(vex) > 0L) {
      drugTbl <- vex |>
        dplyr::summarise(n_records  = dplyr::n(),
                         n_patients = dplyr::n_distinct(.data$person_id),
                         .by = c("ancestor_concept_id", "concept_name")) |>
        dplyr::rename(drug_concept_id = "ancestor_concept_id",
                      drug_name = "concept_name") |>
        dplyr::arrange(dplyr::desc(.data$n_records))
      drugTbl <- censorPair(drugTbl, "n_patients", "n_records")
      drugTbl <- dplyr::mutate(drugTbl, cohort = label, .before = 1)
    }

    # 4. aligned regimen episodes per regimen
    regTbl <- tibble::tibble()
    if (nrec(eps) > 0L && "episode_source_value" %in% names(eps)) {
      regTbl <- eps |>
        dplyr::summarise(n_episodes = dplyr::n(),
                         n_patients = dplyr::n_distinct(.data$person_id),
                         .by = "episode_source_value") |>
        dplyr::rename(regimen = "episode_source_value") |>
        dplyr::arrange(dplyr::desc(.data$n_episodes))
      regTbl <- censorPair(regTbl, "n_patients", "n_episodes")
      regTbl <- dplyr::mutate(regTbl, cohort = label, .before = 1)
    }

    # 5. episodes-per-patient distribution
    perPatientTbl <- tibble::tibble()
    if (nrec(eps) > 0L) {
      perPatientTbl <- eps |>
        dplyr::summarise(n_episodes = dplyr::n(), .by = "person_id") |>
        dplyr::summarise(n_patients = dplyr::n_distinct(.data$person_id),
                         .by = "n_episodes") |>
        dplyr::arrange(.data$n_episodes)
      perPatientTbl$n_patients <- censorN(perPatientTbl$n_patients)
      perPatientTbl <- dplyr::mutate(perPatientTbl, cohort = label, .before = 1)
    }

    # 6. uncaptured valid exposures per drug
    uncapTbl <- tibble::tibble()
    if (nrec(vex) > 0L) {
      ue <- vex; ue$.rid <- seq_len(nrow(ue))
      ue <- ue[!(ue$.rid %in% capturedRids), , drop = FALSE]
      if (nrow(ue) > 0L) {
        uncapTbl <- ue |>
          dplyr::summarise(n_records  = dplyr::n(),
                           n_patients = dplyr::n_distinct(.data$person_id),
                           .by = c("ancestor_concept_id", "concept_name")) |>
          dplyr::rename(drug_concept_id = "ancestor_concept_id",
                        drug_name = "concept_name") |>
          dplyr::arrange(dplyr::desc(.data$n_records))
        uncapTbl <- censorPair(uncapTbl, "n_patients", "n_records")
        uncapTbl <- dplyr::mutate(uncapTbl, cohort = label, .before = 1)
      }
    }

    message("    ", label, ": ", nrec(vex), " valid exp (", npat(vex),
            " pts) -> ", nrec(eps), " episodes; >=1 regimen ", pct(nWithRegimen, cohortN),
            "% of cohort (n=", cohortN, "); coverage patient ",
            pct(covPat, totPat), "%, exposure ", pct(covExp, totExp), "%")
    list(summary = summaryTbl, coverage = coverageTbl, drug = drugTbl,
         reg = regTbl, perPat = perPatientTbl, uncap = uncapTbl)
  }

  # Target-1A scan count = 1A subjects actually present in the ARTEMIS scan set.
  scanN1a <- if (length(scanSubjects))
    length(intersect(t1aSubjects, scanSubjects)) else length(t1aSubjects)
  # The metastatic subset's own denominator: every Target-1A subject, scanned or not.
  cohortN1a <- length(t1aSubjects)

  full <- assessStratum(NULL, "scan_cohort", nScan, cohortN = nScan)
  t1a  <- assessStratum(t1aSubjects, "target_1a", scanN1a, cohortN = cohortN1a)
  # Same subset, restricted to the period of interest: on or after metastasis.
  t1aP <- assessStratum(t1aSubjects, "target_1a_post_met", scanN1a,
                        cohortN = cohortN1a, indexDates = t1aMetDate)

  stack <- function(field)
    dplyr::bind_rows(full[[field]], t1a[[field]], t1aP[[field]])

  writeResultCsv(stack("summary"),  "artemis_summary")
  writeResultCsv(stack("coverage"), "artemis_coverage")
  writeResultCsv(stack("drug"),     "artemis_drug_exposures")
  writeResultCsv(stack("reg"),      "artemis_regimens_aligned")
  writeResultCsv(stack("perPat"),   "artemis_episodes_per_patient")
  writeResultCsv(stack("uncap"),    "artemis_uncaptured_drugs")

  message("  artemis_* written with cohort strata (scan_cohort, target_1a, ",
          "target_1a_post_met)")
}
