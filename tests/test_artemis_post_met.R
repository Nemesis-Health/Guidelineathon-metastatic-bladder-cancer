# Unit tests for the post-metastasis window helper and the capture rule it
# composes with (R/artemis_uncaptured.R). Plain-script style, matching
# tests/test_prestudy_queries.R: any failure stops with a message.
#
# Run from the repository root:  Rscript tests/test_artemis_post_met.R

projectRoot <- normalizePath(".", mustWork = TRUE)
source(file.path(projectRoot, "R", "artemis_uncaptured.R"))

check <- function(cond, what) if (!isTRUE(cond)) stop("FAIL: ", what, call. = FALSE)

d <- function(x) as.Date(x)

# --- restrictToOnOrAfter ---------------------------------------------------
exp0 <- data.frame(
  person_id = c("1", "1", "1", "2", "2", "3"),
  drug_exposure_start_date = d(c("2020-01-01", "2020-06-01", "2020-06-15",
                                 "2019-12-31", "2020-03-02", "2020-05-05")),
  stringsAsFactors = FALSE)
# person 3 deliberately has NO index date
met <- structure(d(c("2020-06-01", "2020-03-01")), names = c("1", "2"))

kept <- restrictToOnOrAfter(exp0, "drug_exposure_start_date", met)
check(nrow(kept) == 3L, "three records survive the on-or-after-met floor")
check(identical(sort(kept$person_id), c("1", "1", "2")),
      "only persons with an index date survive (person 3 dropped)")
check(d("2020-06-01") %in% kept$drug_exposure_start_date,
      "day 0 (a record ON the metastasis date) is kept")
check(!(d("2020-01-01") %in% kept$drug_exposure_start_date),
      "a pre-metastasis record is dropped")

# NULL indexDates is a no-op (the whole-history strata)
check(identical(restrictToOnOrAfter(exp0, "drug_exposure_start_date", NULL), exp0),
      "NULL indexDates leaves the frame untouched")
# missing columns / empty frames are no-ops rather than errors
check(nrow(restrictToOnOrAfter(exp0[0, ], "drug_exposure_start_date", met)) == 0L,
      "an empty frame stays empty")
check(identical(restrictToOnOrAfter(exp0, "no_such_col", met), exp0),
      "an absent date column is a no-op")

# a non-person_id key column (the raw-alignment path uses personID)
ra <- data.frame(personID = c("1", "1"), .alignDate = d(c("2020-05-01", "2020-07-01")),
                 stringsAsFactors = FALSE)
check(nrow(restrictToOnOrAfter(ra, ".alignDate", met, "personID")) == 1L,
      "the floor honours a custom person-id column")

# --- capture rule: ingredient-aware + grace window ------------------------
regimens <- data.frame(
  regName   = c("Gemcitabine, Cisplatin", "Gemcitabine monotherapy"),
  regString = c("0.Gemcitabine;14.Cisplatin", "0.Gemcitabine"),
  stringsAsFactors = FALSE)
regIng <- regimenIngredientMap(regimens)
check(setequal(regIng[["Gemcitabine, Cisplatin"]], c("gemcitabine", "cisplatin")),
      "regString parses into clean ingredient tokens")

episodes <- data.frame(
  person_id            = "1",
  episode_start_date   = d("2020-06-01"),
  episode_end_date     = d("2020-06-30"),
  episode_source_value = "Gemcitabine monotherapy",
  stringsAsFactors = FALSE)
vex <- data.frame(
  person_id                = c("1", "1", "1"),
  drug_exposure_start_date = d(c("2020-06-10", "2020-06-10", "2020-09-01")),
  concept_name             = c("Gemcitabine", "Cisplatin", "Gemcitabine"),
  ancestor_concept_id      = c(1L, 2L, 1L),
  drug_concept_id          = c(11L, 22L, 11L),
  stringsAsFactors = FALSE)

cap <- capturedExposureRids(vex, episodes, regIng, graceDays = 30L)
check(identical(cap, 1L),
      "only the gemcitabine dose inside the gemcitabine-monotherapy era is captured")
# row 2 is cisplatin during a gemcitabine-only era -> ingredient-aware miss
# row 3 is 63 days after the era end -> outside the 30-day grace window
check(nrow(uncapturedExposures(
  list(validDrugExposures = vex, episodes = episodes, regimens = regimens))) == 2L,
  "the two misses show up as uncaptured exposures")

# --- the two composed: post-met exposures tested against ALL episodes -----
# An episode that STARTS before metastasis still captures a post-metastasis dose.
metOne  <- structure(d("2020-06-05"), names = "1")
postVex <- restrictToOnOrAfter(vex, "drug_exposure_start_date", metOne)
check(nrow(postVex) == 3L, "all three exposures fall after this metastasis date")
capPost <- capturedExposureRids(postVex, episodes, regIng, graceDays = 30L)
check(length(capPost) == 1L,
      "a post-met dose covered by a pre-met episode is captured, not a data gap")
# whereas date-flooring the episodes too would have lost it
epsFloored <- restrictToOnOrAfter(episodes, "episode_start_date", metOne)
check(nrow(epsFloored) == 0L, "the episode itself starts before metastasis")
check(length(capturedExposureRids(postVex, epsFloored, regIng)) == 0L,
      "flooring the episodes as well would falsely report the dose uncaptured")

cat("test_artemis_post_met.R: all checks passed\n")
