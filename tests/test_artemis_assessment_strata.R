# Integration test for R/06_artemis_assessment.R's cohort strata.
#
# Sources the real assessment script against a tiny in-memory SQLite CDM (real
# DatabaseConnector + SqlRender, no stubs) and a hand-built `artemisResult`, then
# asserts the numbers in every emitted CSV — in particular the two things the
# post-metastasis work added:
#   * the `target_1a_post_met` stratum's date floor, and
#   * the `cohort_subject` / `scanned_subject` coverage levels ("% of the
#     metastatic subset with >=1 aligned regimen").
#
# Run from the repository root:  Rscript tests/test_artemis_assessment_strata.R

suppressMessages(library(DatabaseConnector))
projectRoot <- normalizePath(".", mustWork = TRUE)
source(file.path(projectRoot, "R", "vendor_utils.R"))
source(file.path(projectRoot, "R", "artemis_uncaptured.R"))

check <- function(cond, what) if (!isTRUE(cond)) stop("FAIL: ", what, call. = FALSE)
d <- function(x) as.Date(x)

# --- fixture ---------------------------------------------------------------
# P1  T1A, metastasis 2020-06-05. Its only episode STARTS 2020-06-01, i.e. before
#     metastasis -> it drops out of the post-met regimen list but must still
#     capture P1's post-met gemcitabine dose.
# P2  T1A, metastasis 2020-01-01. Episode and both doses are post-met.
# P3  scan cohort only (not metastatic) -> must not leak into the 1A strata.
# P4  T1A but no drug exposures at all -> stays in the cohort_subject denominator.
GEM <- 1L; CIS <- 2L; DEX <- 3L      # ingredient (ancestor) concept ids

conDF <- data.frame(
  person_id = c("1", "1", "1", "1", "1", "2", "2", "3"),
  drug_exposure_start_date = d(c("2020-03-01", "2020-06-10", "2020-06-10",
                                 "2020-09-01", "2020-06-11", "2020-02-01",
                                 "2020-02-01", "2021-01-01")),
  ancestor_concept_id = c(GEM, GEM, CIS, GEM, DEX, GEM, CIS, GEM),
  concept_name = c("Gemcitabine", "Gemcitabine", "Cisplatin", "Gemcitabine",
                   "Dexamethasone", "Gemcitabine", "Cisplatin", "Gemcitabine"),
  drug_concept_id = c(11L, 11L, 22L, 11L, 33L, 11L, 22L, 11L),
  stringsAsFactors = FALSE)

episodes <- data.frame(
  person_id            = c("1", "2"),
  episode_start_date   = d(c("2020-06-01", "2020-02-01")),
  episode_end_date     = d(c("2020-06-30", "2020-02-28")),
  episode_source_value = c("Gemcitabine monotherapy", "Gemcitabine, Cisplatin"),
  stringsAsFactors = FALSE)

# raw alignments carry DAY OFFSETS from each patient's first valid exposure:
# P1 refDate 2020-03-01 (t_start 92 -> 2020-06-01, pre-met; 200 -> 2020-09-17,
# post-met), P2 refDate 2020-02-01 (t_start 0 -> 2020-02-01, post-met).
rawAlignments <- data.frame(
  personID = c("1", "1", "2"), t_start = c(92L, 200L, 0L),
  t_end = c(121L, 230L, 27L), stringsAsFactors = FALSE)

artemisResult <- list(
  conDF = conDF, validDrugExposures = conDF, episodes = episodes,
  rawAlignments = rawAlignments,
  regimens = data.frame(
    regName   = c("Gemcitabine, Cisplatin", "Gemcitabine monotherapy"),
    regString = c("0.Gemcitabine;14.Cisplatin", "0.Gemcitabine"),
    stringsAsFactors = FALSE))

# --- in-memory CDM: cohort table + the ATC vocabulary rows step (f) reads ---
connection <- connect(createConnectionDetails(dbms = "sqlite", server = ":memory:"))
on.exit(disconnect(connection), add = TRUE)
put <- function(tbl, df) suppressMessages(insertTable(
  connection, databaseSchema = "main", tableName = tbl, data = df,
  createTable = TRUE, dropTableIfExists = TRUE, camelCaseToSnakeCase = FALSE))

T1A_ID <- 1L; SCAN_ID <- 99L
put("bc_cohort", data.frame(
  cohort_definition_id = c(rep(T1A_ID, 3), rep(SCAN_ID, 3)),
  subject_id           = c("1", "2", "4", "1", "2", "3"),
  cohort_start_date    = d(c("2020-06-05", "2020-01-01", "2020-04-01",
                             "2020-06-05", "2020-01-01", "2021-01-01")),
  cohort_end_date      = d(rep("2021-12-31", 6)), stringsAsFactors = FALSE))
# L01 is the only ATC 2nd class present; only GEM/CIS descend from it, so the
# assessment's ATC restriction must drop the dexamethasone exposure.
put("concept", data.frame(concept_id = 100L, vocabulary_id = "ATC",
                          concept_class_id = "ATC 2nd", concept_code = "L01",
                          stringsAsFactors = FALSE))
put("concept_ancestor", data.frame(ancestor_concept_id = c(100L, 100L),
                                   descendant_concept_id = c(GEM, CIS)))

# --- run the real script ---------------------------------------------------
outputFolder <- file.path(tempfile("artemis-strata"))
dir.create(outputFolder, recursive = TRUE)
settings <- list(minCellCount = 1L, outputFolder = outputFolder,
                 workDatabaseSchema = "main", vocabDatabaseSchema = "main",
                 cohortTable = "bc_cohort", stripEndocrineTherapy = TRUE,
                 assessmentAtcClasses = NULL)
mainManifest <- data.frame(cohortId = T1A_ID,
                           cohortName = "T1 Metastatic bladder cancer",
                           stringsAsFactors = FALSE)
artemisCohortId <- SCAN_ID
artemisCounts <- data.frame(cohortId = SCAN_ID, cohortSubjects = 3L)
writeResultCsv <- function(df, name) {
  dir.create(file.path(settings$outputFolder, "eligibility"), recursive = TRUE,
             showWarnings = FALSE)
  readr::write_csv(df, file.path(settings$outputFolder, "eligibility",
                                 paste0(name, ".csv")), na = "")
}
cohortIdByName <- function(manifest, name) {
  hit <- manifest$cohortId[manifest$cohortName == name]
  if (length(hit) == 0L) NA_integer_ else as.integer(hit[1])
}

suppressMessages(source(file.path(projectRoot, "R", "06_artemis_assessment.R")))

rd <- function(name) as.data.frame(readr::read_csv(
  file.path(outputFolder, "eligibility", paste0(name, ".csv")),
  show_col_types = FALSE, progress = FALSE))

# --- all three strata present, in order, in every file --------------------
STRATA <- c("scan_cohort", "target_1a", "target_1a_post_met")
for (f in c("artemis_summary", "artemis_coverage", "artemis_drug_exposures",
            "artemis_regimens_aligned", "artemis_episodes_per_patient",
            "artemis_uncaptured_drugs")) {
  x <- rd(f)
  check(names(x)[1] == "cohort", paste0(f, ": leading cohort column"))
  check(identical(unique(x$cohort), STRATA),
        paste0(f, ": all three strata, scan -> 1A -> post-met"))
}

# --- coverage --------------------------------------------------------------
cov <- rd("artemis_coverage")
get <- function(stratum, lvl, col)
  cov[[col]][cov$cohort == stratum & cov$level == lvl]
check(identical(unique(cov$level),
                c("cohort_subject", "scanned_subject", "patient", "exposure")),
      "coverage carries the two new cohort-level rows plus patient/exposure")

# target_1a: P1+P2 have an episode; the metastatic subset is P1,P2,P4 (n=3), of
# which P1,P2 were scanned. So 2/3 of the subset has >=1 regimen, 2/2 scanned.
check(get("target_1a", "cohort_subject", "n_covered") == 2 &&
      get("target_1a", "cohort_subject", "n_total") == 3,
      "target_1a: 2 of 3 metastatic subjects have >=1 aligned regimen")
check(get("target_1a", "scanned_subject", "n_total") == 2,
      "target_1a: the scanned denominator excludes the never-scanned P4")
# 6 ATC-L01 exposures over 2 patients (the dexamethasone row is dropped, and P3
# is not metastatic); captured = P1 gem 06-10 + both of P2's doses.
check(get("target_1a", "patient", "n_total") == 2 &&
      get("target_1a", "exposure", "n_total") == 6 &&
      get("target_1a", "exposure", "n_covered") == 3,
      "target_1a: 3 of 6 anticancer exposures captured")

# target_1a_post_met: P1's episode STARTS pre-metastasis, so only P2 has a
# regimen started after metastasis -> 1 of 3.
check(get("target_1a_post_met", "cohort_subject", "n_covered") == 1 &&
      get("target_1a_post_met", "cohort_subject", "n_total") == 3,
      "post_met: only 1 of 3 metastatic subjects starts a regimen after metastasis")
# exposures: P1 loses its 2020-03-01 pre-met dose -> 5 records over 2 patients.
# Capture is NOT date-floored, so P1's post-met gemcitabine is still captured by
# its pre-met episode: 3 of 5, exactly as in the whole-history stratum.
check(get("target_1a_post_met", "exposure", "n_total") == 5 &&
      get("target_1a_post_met", "exposure", "n_covered") == 3,
      "post_met: pre-met dose dropped, and a pre-met episode still captures")

# --- summary funnel --------------------------------------------------------
sm <- rd("artemis_summary")
gm <- function(stratum, metric, col)
  sm[[col]][sm$cohort == stratum & sm$metric == metric]
check(gm("target_1a", "ARTEMIS scan cohort (subjects)", "n_patients") == 2,
      "summary: 1A scan-stage count is the scanned intersection")
check(gm("target_1a", "Ingredient-level drug exposures", "n_records") == 7 &&
      gm("target_1a_post_met", "Ingredient-level drug exposures", "n_records") == 6,
      "summary: conDF is date-floored too (P1's pre-met dose drops)")
# raw alignments: 3 rows for 1A; the post-met floor re-dates t_start and drops
# P1's 2020-06-01 alignment, keeping P1@2020-09-17 and P2@2020-02-01.
check(gm("target_1a", "Raw alignments (pre-processing)", "n_records") == 3 &&
      gm("target_1a_post_met", "Raw alignments (pre-processing)", "n_records") == 2,
      "summary: raw alignments are date-floored via refDate + t_start")
check(gm("target_1a_post_met", "Regimen episodes aligned", "n_patients") == 1,
      "summary: one patient has a post-met episode")

# --- regimen / drug / uncaptured listings ---------------------------------
reg <- rd("artemis_regimens_aligned")
check(identical(reg$regimen[reg$cohort == "target_1a_post_met"],
                "Gemcitabine, Cisplatin"),
      "post_met regimen list holds only the regimen started after metastasis")
check(setequal(reg$regimen[reg$cohort == "target_1a"],
               c("Gemcitabine monotherapy", "Gemcitabine, Cisplatin")),
      "target_1a regimen list holds both regimens")

drg <- rd("artemis_drug_exposures")
check(!("Dexamethasone" %in% drg$drug_name),
      "the ATC restriction keeps the supportive agent out of every stratum")
check(drg$n_records[drg$cohort == "target_1a" & drg$drug_name == "Gemcitabine"] == 4 &&
      drg$n_records[drg$cohort == "target_1a_post_met" & drg$drug_name == "Gemcitabine"] == 3,
      "post_met drug list drops the pre-metastasis gemcitabine dose")

unc <- rd("artemis_uncaptured_drugs")
uncPost <- unc[unc$cohort == "target_1a_post_met", ]
check(sum(uncPost$n_records) == 2, "post_met: 2 uncaptured exposures (5 - 3 captured)")
check(setequal(uncPost$drug_name, c("Gemcitabine", "Cisplatin")),
      "post_met uncaptured: the out-of-window gemcitabine and the off-regimen cisplatin")
# coverage and the uncaptured table stay exact complements, per stratum
for (st in STRATA) {
  tot <- cov$n_total[cov$cohort == st & cov$level == "exposure"]
  capd <- cov$n_covered[cov$cohort == st & cov$level == "exposure"]
  check(sum(unc$n_records[unc$cohort == st]) == tot - capd,
        paste0(st, ": uncaptured records == total - captured"))
}

# --- P3 (non-metastatic) shows up only in scan_cohort ---------------------
check(gm("scan_cohort", "Valid anticancer drug exposures", "n_records") == 7,
      "scan_cohort keeps P3's exposure (7 = 6 for 1A + 1 for P3)")

cat("test_artemis_assessment_strata.R: all checks passed\n")
