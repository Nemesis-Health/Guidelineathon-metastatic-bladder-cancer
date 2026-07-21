# ===========================================================================
# build_regimen_reference.R
# ===========================================================================
# Regenerates cohorts/extras/regimen_reference.csv: one row per regimen ARTEMIS
# can emit (ARTEMIS::loadRegimens("all"), blacklist OFF), carrying BOTH the
# reference-filter columns (used by R/01_artemis.R to keep only anticancer
# regimens) and the cohort-split lens columns (loaded into the work schema for
# the 4/5/6 splits in R/03_main_cohorts.R). One file, one generator, so the two
# roles cannot drift out of sync and a reviewer sees every regimen whole.
# Re-run when ARTEMIS or the HemOnc/ATC vocabulary is upgraded.
#
# Columns
#   regName, regCode
#   source            hemonc | atc | none  — how the row was classified
#   -- reference filter (R/01_artemis.R) --
#   is_chemo, is_immuno, is_targeted, is_supportive
#                     HemOnc `Has modality` groups (blank for source != hemonc)
#   is_endocrine      hormonal ANTICANCER therapy: a HemOnc `Has endocrine tx Rx`
#                     ingredient that is ATC L02 (tamoxifen, abiraterone, GnRH,
#                     aminoglutethimide, ...). Deliberately NOT the HemOnc
#                     Endocrine-therapy modality, which also tags glucocorticoids
#                     (prednisone/dexamethasone, ATC H02) that are supportive, not
#                     anticancer — those get is_endocrine=0 / is_supportive=1.
#   anticancer        1 if the regimen delivers cancer-directed therapy. HemOnc:
#                     any cancer-directed modality except pure endocrine. ATC
#                     fallback (no HemOnc concept): a component in ATC L01/L03/L04.
#                     R/01_artemis.R keeps anticancer==1, plus is_endocrine==1
#                     unless settings$stripEndocrineTherapy is TRUE (default).
#   hemonc_modalities "; "-joined raw HemOnc modalities (transparency)
#   -- cohort-split lenses (R/03_main_cohorts.R) --
#   class_eau         EAU first-line lens. HAND-CURATED: carried forward verbatim
#                     from the existing CSV by regCode; new regimens default to
#                     "other" (status="new").
#   class_hemonc_mbc  HemOnc metastatic-bladder lens: the ingredient arm when the
#                     regimen has a HemOnc `Has accepted use` link to a bladder/
#                     urothelial condition, else "other". Uses other_recommended
#                     for bladder-indicated non-arm regimens.
#   class_any         any-regimen lens: the ingredient arm for every regimen;
#                     catch-all is plain "other" (ingredient-based, no guideline).
#   accepted_uses     "; "-joined HemOnc `Has accepted use` conditions
#   status            carried | new  (class_eau provenance)
#
# Ingredient arm (class_hemonc_mbc / class_any), by precedence, via HemOnc
# `Has ... Rx` -> RxNorm ingredients: ev_pembro (enfortumab 37498261 +
# pembrolizumab) > cisplatin > carboplatin > pdl1_mono (sole PD-(L)1 agent) >
# (none).
#
# NOTE anticancer==0 rows are kept for completeness but never become episodes
# (R/01_artemis.R drops them), so their class_* values are moot.
#
# Usage (edit CONFIG: connectionDetails + vocabDatabaseSchema):
#   ARTEMIS_PYTHON=/path/to/py PYTHONUTF8=1 LC_ALL=en_US.UTF-8 \
#     Rscript cohorts/extras/build_regimen_reference.R
# ===========================================================================

suppressMessages(library(ARTEMIS))   # must be ATTACHED: loadRegimens() data path

# HemOnc modality groups -> reference-filter flags
.MODALITY_GROUPS <- list(
  chemo      = c("Chemotherapy", "Chemoimmunotherapy", "Chemohormonotherapy",
                 "Chemoradiotherapy", "Chemoradioimmunotherapy"),
  immuno     = c("Immunotherapy", "Chemoimmunotherapy", "Chemoradioimmunotherapy"),
  targeted   = c("Targeted therapy", "Antibody-drug conjugate therapy",
                 "Immunotoxin therapy", "Peptide-drug conjugate therapy",
                 "Radioconjugate therapy"),
  endocrine  = c("Endocrine therapy", "Chemohormonotherapy", "Hormonoradiotherapy"),
  supportive = c("Supportive therapy", "Growth factor therapy",
                 "Glucocorticoid therapy", "Immunosuppressive therapy",
                 "Anticoagulation", "Antibiotic therapy",
                 "Antifibrinolytic therapy", "Null therapy"))
# cancer-directed modalities (drive anticancer); excludes pure "Endocrine therapy"
.CANCER_MODALITIES <- c(
  "Chemotherapy", "Chemoimmunotherapy", "Chemohormonotherapy", "Chemoradiotherapy",
  "Chemoradioimmunotherapy", "Immunotherapy", "Targeted therapy",
  "Antibody-drug conjugate therapy", "Immunotoxin therapy",
  "Peptide-drug conjugate therapy", "Radioconjugate therapy", "Radiotherapy",
  "Hormonoradiotherapy", "Tumor treating fields")
# cancer-directed HemOnc regimen -> RxNorm ingredient relationships (arm)
.CANCER_RX <- c("Has cytotox chemo Rx", "Has targeted tx Rx", "Has immunotherapy Rx",
                "Has AB-drug cjgt Rx", "Has antineopl Rx", "Has radiocjgt Rx",
                "Has PDC Rx")
.ARM_INGREDIENTS <- c("cisplatin", "carboplatin", "enfortumab", "pembrolizumab",
                      "atezolizumab", "avelumab", "nivolumab", "durvalumab")
.PDL1 <- c("pembrolizumab", "atezolizumab", "avelumab", "nivolumab", "durvalumab")

.clean <- function(x) tolower(gsub("[[:space:]]+", "", x))
.regDrugs <- function(s) if (is.na(s) || !nzchar(s)) character(0) else
  unique(sub("^[0-9]+\\.", "", trimws(strsplit(s, ";", fixed = TRUE)[[1]])))

#' @param connection          active DatabaseConnector connection to a CDM/vocab
#' @param vocabDatabaseSchema schema with concept / concept_relationship /
#'                            concept_ancestor ("main" for a bare SQLite file)
#' @param priorCsv            data.frame of the existing regimen_reference.csv
#'                            (class_eau carry-forward); NULL -> all "other"
makeRegimenReference <- function(connection, vocabDatabaseSchema, priorCsv = NULL) {
  dbms <- attr(connection, "dbms")
  q <- function(sql, ...) {
    s <- SqlRender::translate(SqlRender::render(sql, ..., warnOnMissingParameters = FALSE),
                              targetDialect = dbms)
    r <- DatabaseConnector::querySql(connection, s, snakeCaseToCamelCase = FALSE)
    stats::setNames(r, tolower(names(r)))
  }

  # -- HemOnc modality per regimen --
  modRows <- q("SELECT reg.concept_code AS regcode, m.concept_name AS modality
     FROM @vocab.concept reg
     JOIN @vocab.concept_relationship cr ON cr.concept_id_1 = reg.concept_id
       AND cr.relationship_id = 'Has modality' AND cr.invalid_reason IS NULL
     JOIN @vocab.concept m ON cr.concept_id_2 = m.concept_id
    WHERE reg.vocabulary_id = 'HemOnc' AND reg.concept_class_id = 'Regimen'",
    vocab = vocabDatabaseSchema)
  modByReg <- split(modRows$modality, as.character(modRows$regcode))

  # -- ATC L01-L04 descendant ingredients (modality fallback + endocrine split) --
  atc <- q("SELECT a.concept_code AS atc, ca.descendant_concept_id AS concept_id
     FROM @vocab.concept a
     JOIN @vocab.concept_ancestor ca ON ca.ancestor_concept_id = a.concept_id
    WHERE a.vocabulary_id = 'ATC' AND a.concept_class_id = 'ATC 2nd'
      AND a.concept_code IN ('L01', 'L02', 'L03', 'L04')", vocab = vocabDatabaseSchema)
  antineoIds <- as.character(atc$concept_id[atc$atc %in% c("L01", "L03", "L04")])
  endoIds    <- as.character(atc$concept_id[atc$atc == "L02"])

  vd <- ARTEMIS::loadDrugs()
  vd$valid_concept_id[vd$name == "Methotrexate"] <- "1305058"
  antineoNames <- unique(.clean(vd$name[vd$valid_concept_id %in% antineoIds]))
  endoNames    <- unique(.clean(vd$name[vd$valid_concept_id %in% endoIds]))

  # -- ingredient arm inputs (RxNorm ingredients via HemOnc *Rx relationships) --
  ing <- q("SELECT concept_id, LOWER(concept_name) AS nm FROM @vocab.concept
    WHERE domain_id = 'Drug' AND concept_class_id = 'Ingredient'
      AND standard_concept = 'S' AND LOWER(concept_name) IN (@names)",
    vocab = vocabDatabaseSchema,
    names = paste0("'", .ARM_INGREDIENTS, "'", collapse = ", "))
  ingId <- function(x) ing$concept_id[ing$nm == x]
  CIS <- ingId("cisplatin"); CARBO <- ingId("carboplatin"); EV <- ingId("enfortumab")
  PEMB <- ingId("pembrolizumab"); PDL1 <- ing$concept_id[ing$nm %in% .PDL1]
  rxRows <- q("SELECT reg.concept_code AS regcode, cr.concept_id_2 AS ing
     FROM @vocab.concept reg
     JOIN @vocab.concept_relationship cr ON cr.concept_id_1 = reg.concept_id
       AND cr.invalid_reason IS NULL AND cr.relationship_id IN (@rels)
    WHERE reg.vocabulary_id = 'HemOnc' AND reg.concept_class_id = 'Regimen'",
    vocab = vocabDatabaseSchema, rels = paste0("'", .CANCER_RX, "'", collapse = ", "))
  rxByReg <- split(rxRows$ing, as.character(rxRows$regcode))

  # -- endocrine anticancer ingredients (drives is_endocrine): a regimen's HemOnc
  # `Has endocrine tx Rx` RxNorm ingredients that are ATC L02. Concept-id match,
  # so it catches salt forms (abiraterone acetate) and — critically — EXCLUDES
  # glucocorticoids (prednisone/dexamethasone are H02, not L02), which HemOnc's
  # `Endocrine therapy` modality would otherwise fold in.
  endoRxRows <- q("SELECT reg.concept_code AS regcode, cr.concept_id_2 AS ing
     FROM @vocab.concept reg
     JOIN @vocab.concept_relationship cr ON cr.concept_id_1 = reg.concept_id
       AND cr.relationship_id = 'Has endocrine tx Rx' AND cr.invalid_reason IS NULL
    WHERE reg.vocabulary_id = 'HemOnc' AND reg.concept_class_id = 'Regimen'",
    vocab = vocabDatabaseSchema)
  endoRxByReg <- split(as.character(endoRxRows$ing), as.character(endoRxRows$regcode))

  # -- accepted-use conditions (bladder gate + accepted_uses string) --
  bladder <- q("SELECT concept_id FROM @vocab.concept
    WHERE vocabulary_id = 'HemOnc' AND concept_class_id = 'Condition'
      AND (LOWER(concept_name) LIKE '%bladder%' OR LOWER(concept_name) LIKE '%urothelial%')
      AND LOWER(concept_name) NOT LIKE '%gallbladder%'", vocab = vocabDatabaseSchema)
  bladderIds <- as.integer(bladder$concept_id)
  au <- q("SELECT reg.concept_code AS regcode, c2.concept_id AS cond_id,
                  c2.concept_name AS cond_name
     FROM @vocab.concept reg
     JOIN @vocab.concept_relationship cr ON cr.concept_id_1 = reg.concept_id
       AND cr.relationship_id = 'Has accepted use' AND cr.invalid_reason IS NULL
     JOIN @vocab.concept c2 ON cr.concept_id_2 = c2.concept_id
    WHERE reg.vocabulary_id = 'HemOnc' AND reg.concept_class_id = 'Regimen'",
    vocab = vocabDatabaseSchema)
  acceptedByReg <- tapply(au$cond_name, as.character(au$regcode),
                          function(v) paste(sort(unique(v)), collapse = "; "))
  bladderReg <- unique(as.character(au$regcode[au$cond_id %in% bladderIds]))

  # -- prior class_eau --
  priorEau <- character(0)
  if (is.data.frame(priorCsv) && nrow(priorCsv) > 0L && "class_eau" %in% names(priorCsv))
    priorEau <- stats::setNames(as.character(priorCsv$class_eau),
                                as.character(priorCsv$regCode))

  # -- regimen universe (blacklist off) --
  emptyBl  <- tempfile(fileext = ".txt"); file.create(emptyBl)
  regimens <- ARTEMIS::loadRegimens(condition = "all",
    concept_file = emptyBl, ignore_default_list = TRUE)
  drugsByReg <- tapply(regimens$regString, regimens$regName,
    function(v) unique(.clean(unlist(lapply(v, .regDrugs)))))
  reg <- unique(regimens[, c("regName", "regCode")])
  reg <- reg[!duplicated(reg$regName), , drop = FALSE]

  hasGroup <- function(mods, g) as.integer(any(mods %in% .MODALITY_GROUPS[[g]]))
  # endocrine = a HemOnc endocrine-tx ingredient that is ATC L02 (excludes
  # glucocorticoids, which HemOnc's Endocrine-therapy modality would include)
  isEndocrine <- function(rc) as.integer(any(endoRxByReg[[rc]] %in% endoIds))
  arm <- function(s) {
    if (length(EV) && EV %in% s && PEMB %in% s) return("ev_pembro")
    if (CIS   %in% s) return("cisplatin")
    if (CARBO %in% s) return("carboplatin")
    if (length(s) == 1L && s %in% PDL1) return("pdl1_mono")
    NA_character_
  }

  rows <- lapply(seq_len(nrow(reg)), function(i) {
    rn <- reg$regName[i]; rc <- as.character(reg$regCode[i])
    mods <- modByReg[[rc]]
    if (!is.null(mods)) {
      src <- "hemonc"
      flags <- list(is_chemo = hasGroup(mods, "chemo"), is_immuno = hasGroup(mods, "immuno"),
                    is_targeted = hasGroup(mods, "targeted"),
                    is_endocrine = isEndocrine(rc),
                    is_supportive = hasGroup(mods, "supportive"))
      anticancer <- as.integer(any(mods %in% .CANCER_MODALITIES))
      hemMods <- paste(sort(unique(mods)), collapse = "; ")
    } else {
      d <- drugsByReg[[rn]]; if (is.null(d)) d <- character(0)
      anti <- any(d %in% antineoNames); endo <- any(d %in% endoNames)
      src <- if (anti || endo) "atc" else "none"
      flags <- list(is_chemo = NA_integer_, is_immuno = NA_integer_,
                    is_targeted = NA_integer_, is_endocrine = as.integer(endo),
                    is_supportive = NA_integer_)
      anticancer <- as.integer(anti)
      hemMods <- ""
    }
    rxIng <- rxByReg[[rc]]; if (is.null(rxIng)) rxIng <- integer(0)
    a <- arm(rxIng)
    isBladder <- rc %in% bladderReg
    data.frame(
      regName = rn, regCode = reg$regCode[i], source = src,
      is_chemo = flags$is_chemo, is_immuno = flags$is_immuno,
      is_targeted = flags$is_targeted, is_endocrine = flags$is_endocrine,
      is_supportive = flags$is_supportive, anticancer = anticancer,
      hemonc_modalities = hemMods,
      class_eau = if (rc %in% names(priorEau)) priorEau[[rc]] else "other",
      class_hemonc_mbc = if (!isBladder) "other"
                         else if (is.na(a)) "other_recommended" else a,
      # class_any is the most permissive lens: any enfortumab-containing regimen
      # (incl. EV monotherapy, which arm() leaves NA without pembro) is grouped
      # into ev_pembro here, though class_eau / class_hemonc_mbc keep it separate.
      class_any = if (length(EV) && EV %in% rxIng) "ev_pembro"
                  else if (is.na(a)) "other" else a,
      accepted_uses = if (rc %in% names(acceptedByReg)) acceptedByReg[[rc]] else "",
      status = if (rc %in% names(priorEau)) "carried" else "new",
      stringsAsFactors = FALSE)
  })
  out <- do.call(rbind, rows)
  out[order(out$regName), ]
}

# --- executable entry point (skipped when sourced with REFERENCE_SOURCE_ONLY) -
if (!exists("REFERENCE_SOURCE_ONLY")) {
  connectionDetails   <- NULL   # <-- DatabaseConnector::createConnectionDetails(...)
  vocabDatabaseSchema <- ""     # <-- schema with concept / concept_relationship / …

  if (is.null(connectionDetails) || !nzchar(vocabDatabaseSchema))
    stop("Set connectionDetails and vocabDatabaseSchema in the CONFIG block.",
         call. = FALSE)

  .scriptArg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
  extrasDir  <- if (length(.scriptArg))
    dirname(normalizePath(sub("^--file=", "", .scriptArg[1]))) else "cohorts/extras"
  csvPath <- file.path(extrasDir, "regimen_reference.csv")
  prior   <- if (file.exists(csvPath))
    readr::read_csv(csvPath, show_col_types = FALSE) else NULL

  conn <- DatabaseConnector::connect(connectionDetails)
  on.exit(DatabaseConnector::disconnect(conn), add = TRUE)
  tbl <- makeRegimenReference(conn, vocabDatabaseSchema, prior)
  readr::write_csv(tbl, csvPath, na = "")

  cat(sprintf("Wrote %d regimens: %d anticancer, %d endocrine-only.\n",
      nrow(tbl), sum(tbl$anticancer == 1, na.rm = TRUE),
      sum(tbl$anticancer == 0 & !is.na(tbl$is_endocrine) & tbl$is_endocrine == 1)))
  cat("source:\n"); print(table(tbl$source))
  cat("class_hemonc_mbc:\n"); print(table(tbl$class_hemonc_mbc))
  cat("class_any:\n"); print(table(tbl$class_any))
}
