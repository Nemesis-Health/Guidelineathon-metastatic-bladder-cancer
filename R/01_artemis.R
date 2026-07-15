# ===========================================================================
# 01_artemis.R  —  (a) ARTEMIS scan cohort + regimen alignment -> episodes
# ===========================================================================
# runArtemis() reads subjects already present in the cohort table for the
# ARTEMIS cohort id, so we generate that scan cohort first, then align.
# Episodes are written to `episodeTable`; the regimen_reference.csv lens columns
# are loaded into the work schema for the 4/5/6 splits in step 03.
# ===========================================================================

message("\n== (a) ARTEMIS ==")

# --- ARTEMIS scan cohort ----------------------------------------------------
artemisJson <- readJsonCohorts(file.path(cohortsDir, "00_ARTEMIS"))
stopifnot(settings$artemisCohortName %in% artemisJson$cohortName)
artemisSet  <- buildCohortSet(jsonCohorts = artemisJson, startId = 1L)

artemisCounts <- generateCohorts(connection, artemisSet, dropTables = TRUE)
artemisCohortId <- artemisSet$cohortId[
  artemisSet$cohortName == settings$artemisCohortName][1]
message("ARTEMIS scan cohort (id ", artemisCohortId, "): ",
        artemisCounts$cohortSubjects[artemisCounts$cohortId == artemisCohortId], " subject(s)")

# --- Valid-drug list --------------------------------------------------------
# loadDrugs() + Methotrexate concept-id patch. The list is restricted to
# regimen-component drugs *after* the reference is built (below) so the alignment
# string isn't diluted with supportive drugs. No ATC/endocrine strip: the
# anticancer decision is made at the *regimen* level.
validDrugs <- ARTEMIS::loadDrugs()
validDrugs$valid_concept_id[validDrugs$name == "Methotrexate"] <- "1305058"

# --- Regimen reference: keep only anticancer regimens -----------------------
# ARTEMIS's built-in name-matching blacklist is DISABLED (ignore_default_list):
# it removes any regimen whose string contains a supportive drug word, which
# deletes ~300 real chemo combinations (CHOP, Vd, Cabazitaxel+Prednisone, ...)
# just for containing a steroid. Instead every regimen is classified in the
# checked-in cohorts/extras/regimen_reference.csv (HemOnc `Has modality`, with an
# ATC-ingredient fallback; regenerate with build_regimen_reference.R). A regimen
# is kept when it is anticancer, plus endocrine therapy unless
# settings$stripEndocrineTherapy is TRUE (default). This drops supportive /
# hormone monotherapies (hydrocortisone, methylprednisolone, warfarin, ...) while
# keeping chemo-plus-steroid combinations, which name-based blacklisting cannot.
# The same file's lens columns are loaded into the work schema below (step 03).
emptyBlacklist <- tempfile(fileext = ".txt"); file.create(emptyBlacklist)
regimens <- ARTEMIS::loadRegimens(condition = "all",
  concept_file = emptyBlacklist, ignore_default_list = TRUE)

regRef <- readr::read_csv(file.path(extrasDir, "regimen_reference.csv"),
                          show_col_types = FALSE)
includeEndocrine <- !isTRUE(settings$stripEndocrineTherapy)
keepCode <- regRef$regCode[
  regRef$anticancer == 1L |
  (includeEndocrine & !is.na(regRef$is_endocrine) & regRef$is_endocrine == 1L)]

missing <- setdiff(unique(regimens$regCode), regRef$regCode)
if (length(missing) > 0L)
  warning(length(missing), " regimen(s) absent from regimen_reference.csv — ",
          "regenerate with build_regimen_reference.R after a vocabulary/ARTEMIS ",
          "upgrade. They are treated as non-anticancer and dropped.", call. = FALSE)

nBefore  <- length(unique(regimens$regCode))
regimens <- regimens[regimens$regCode %in% keepCode, , drop = FALSE]
message("Kept ", length(unique(regimens$regCode)), " anticancer regimen(s) of ",
        nBefore, " (endocrine ", if (includeEndocrine) "included" else "excluded", ").")

# --- Restrict the drugs ARTEMIS encodes (denoise the alignment string) ------
# ARTEMIS encodes every validDrugs exposure into each patient's alignment
# string; non-regimen / supportive drugs there are pure gap noise that lowers
# alignment scores and shrinks eras (see DEVELOPMENT.md §10.4). Two composable
# filters, both on by default, applied as an intersection:
#   (1) settings$validDrugsRegimenComponents — keep only drugs appearing in a
#       kept regimen's shortString (the alignment template).
#   (2) settings$validDrugsAtcClasses — keep only drugs under these ATC 2nd-level
#       classes (default L01-L04 = anticancer/immunomodulating; drops steroids
#       H02, rescue agents V03, ...). character(0)/NULL = no ATC restriction.
.cleanDrug <- function(x) tolower(gsub("[[:space:]]+", "", x))
.regTokens <- function(v) {
  t <- sub("^[0-9]+\\.", "", trimws(unlist(strsplit(v, ";", fixed = TRUE))))
  unique(.cleanDrug(t[nzchar(t)]))
}
vdKeep <- rep(TRUE, nrow(validDrugs))
if (isTRUE(settings$validDrugsRegimenComponents))
  vdKeep <- vdKeep & (.cleanDrug(validDrugs$name) %in% .regTokens(regimens$shortString))
if (length(settings$validDrugsAtcClasses) > 0L) {
  atcIds <- DatabaseConnector::querySql(connection, SqlRender::translate(
    SqlRender::render(
      "SELECT DISTINCT ca.descendant_concept_id AS concept_id
         FROM @vocab.concept a
         JOIN @vocab.concept_ancestor ca ON ca.ancestor_concept_id = a.concept_id
        WHERE a.vocabulary_id = 'ATC' AND a.concept_class_id = 'ATC 2nd'
          AND a.concept_code IN (@codes)",
      vocab = settings$vocabDatabaseSchema,
      codes = paste0("'", settings$validDrugsAtcClasses, "'", collapse = ", ")),
    targetDialect = .getDbms(connection)))
  names(atcIds) <- tolower(names(atcIds))
  vdKeep <- vdKeep &
    (validDrugs$valid_concept_id %in% as.character(atcIds$concept_id))
}
nBeforeVd  <- nrow(validDrugs)
validDrugs <- validDrugs[vdKeep, , drop = FALSE]
message("Restricted validDrugs: ", nBeforeVd, " -> ", nrow(validDrugs),
        " (regimen-components=", isTRUE(settings$validDrugsRegimenComponents),
        ", ATC=", if (length(settings$validDrugsAtcClasses))
          paste(settings$validDrugsAtcClasses, collapse = "/") else "none", ").")

# Drop regimens that can no longer align: if the restriction removed a drug that
# is part of a regimen's shortString, ARTEMIS's subset precondition (regimen
# drugs must all appear in the patient string) can never match it. Keeps the
# reference and the encodable-drug set consistent. Only runs when a drug was
# actually removed, so with both filters off the reference is untouched.
if (any(!vdKeep)) {
  vdCleanKept <- .cleanDrug(validDrugs$name)
  byReg <- tapply(regimens$shortString, regimens$regName, .regTokens)
  alignable <- names(byReg)[vapply(byReg,
    function(d) all(d %in% vdCleanKept), logical(1))]
  nBeforeReg <- length(unique(regimens$regName))
  regimens <- regimens[regimens$regName %in% alignable, , drop = FALSE]
  if (nBeforeReg - length(alignable) > 0L)
    message("Dropped ", nBeforeReg - length(alignable), " regimen(s) with a ",
            "filtered-out component (no longer alignable).")
}

# --- Align ------------------------------------------------------------------
artemisResult <- runArtemis(
  executionSettings = executionSettings,
  cohortManifestRow = data.frame(id = artemisCohortId),
  connection        = connection,
  regimens          = regimens,
  validDrugs        = validDrugs
)
episodes <- artemisResult$episodes
message("ARTEMIS produced ", nrow(episodes), " regimen episode(s).")

if (nrow(episodes) > 0L) {
  writeArtemisEpisodes(connection = connection,
                       executionSettings = executionSettings,
                       episodes = episodes)
  saveRDS(episodes, file.path(settings$outputFolder, "episodes.rds"))
}

# --- Regimen classification table (lens columns -> work schema for step 03) -
regimenClass <- as.data.frame(regRef[, c("regName", "regCode",
  "class_eau", "class_hemonc_mbc", "class_any")])
DatabaseConnector::insertTable(
  connection = connection, databaseSchema = settings$workDatabaseSchema,
  tableName = settings$regimenClassTable, dropTableIfExists = TRUE,
  data = regimenClass, progressBar = FALSE)
message("Loaded ", nrow(regimenClass), " regimen classifications into ",
        settings$workDatabaseSchema, ".", settings$regimenClassTable)
