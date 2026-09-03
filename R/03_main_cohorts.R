# ===========================================================================
# 03_main_cohorts.R  —  (c) main cohort tree
# ===========================================================================
# Target 1A (Cohort 1), drug leaves, covariates, ARTEMIS scan (JSON) + the
# SQL-templated cohorts: initiated base, 4/5/6 a-f, eligibility 2a-2e, 3a-3e.
# Eligibility reads the unified @labCohortTable (labs + ECOG + conditions from
# step (b)). Generated in one pass; JSON cohorts precede the custom SQL, and
# custom ids are assigned in dependency order (2e after 2a-2d, 3x after 2x/4x).
# ===========================================================================

message("\n== (c) main cohorts ==")

# --- JSON cohorts (Target only) ---------------------------------------------
# We deliberately do NOT regenerate 00_ARTEMIS or 02_Covariate here:
#   * the ARTEMIS scan cohort is only needed by runArtemis() in step (a);
#   * the eligibility-input covariates are already materialised in bc_lab_cohort
#     by step (b) (under their test-id slots).
# Nothing in steps (c)–(e) reads those cohorts from bc_cohort, so regenerating
# them would just be a throwaway duplicate. Only Target 1A + the drug-comparison
# leaves go into the final bc_cohort.
jsonCohorts <- readJsonCohorts(file.path(cohortsDir, "01_Target"))
# generateStats = TRUE: Target 1A's 3 named InclusionRules (age>18, prior
# bladder cancer, no other cancer) get Circe's inclusion-rule-statistics SQL,
# so the standard OHDSI attrition table can be pulled after generation below.
jsonSet <- buildCohortSet(jsonCohorts = jsonCohorts, startId = 1L, generateStats = TRUE)

cohort1Id <- cohortIdByName(jsonSet, "Target 1A")
stopifnot(!is.na(cohort1Id))
nextId <- max(jsonSet$cohortId) + 1L

customRows <- list()
addCustom <- function(name, sql) {
  customRows[[length(customRows) + 1L]] <<- tibble::tibble(
    cohortId = nextId, cohortName = name, sql = sql, json = NA_character_)
  id <- nextId; nextId <<- nextId + 1L; id
}

# --- study cohort naming: "<code> <descriptor>" ----------------------------
# Codes: T1 = mBC; T2x = eligibility leaves; T3x = eligible & initiated (EAU);
# T4x/T5x/T6x = initiated splits under the EAU / HemOnc-mBC / any-regimen lens.
cohortNames <- c(
  T1  = "T1 Metastatic bladder cancer",
  T2a = "T2a EV eligible mBC",
  T2b = "T2b Cis-eligible mBC",
  T2c = "T2c Carbo-eligible mBC",
  T2d = "T2d PD-L1-eligible mBC",
  T2e = "T2e Trt Ineligible mBC",
  T3a = "T3a EV-Pembro eligible and initiated mBC_EAU",
  T3b = "T3b Cis eligible and initiated mBC_EAU",
  T3c = "T3c Carbo eligible and initiated mBC_EAU",
  T3d = "T3d PD-L1 eligible and initiated mBC_EAU",
  T3e = "T3e Trt ineligible and initiated other trt mBC_EAU",
  T4a = "T4a EV-Pembro initiated mBC EAU",
  T4b = "T4b Cis initiated mBC EAU",
  T4c = "T4c Carbo initiated mBC EAU",
  T4d = "T4d PD-L1 initiated mBC EAU",
  T4e = "T4e Trt initiated other trt mBC EAU",
  T4f = "T4f Trt initiated other mBC EAU",
  T5a = "T5a EV-Pembro initiated mBC_HemOnc mBC",
  T5b = "T5b Cis initiated mBC_HemOnc mBC",
  T5c = "T5c Carbo initiated mBC_HemOnc mBC",
  T5d = "T5d PD-L1 initiated mBC_HemOnc mBC",
  T5e = "T5e Trt initiated other trt mBC_HemOnc mBC",
  T5f = "T5f Trt initiated other mBC HemOnc",
  T6a = "T6a EV-Pembro initiated mBC",
  T6b = "T6b Cis initiated mBC",
  T6c = "T6c Carbo initiated mBC",
  T6d = "T6d PD-L1 initiated mBC",
  T6e = "T6e Trt initiated other trt mBC",   # empty by construction (class_any has no "other_recommended")
  T6f = "T6f Trt initiated other mBC")       # class_any catch-all (ingredient-based "other")
saveState("cohortNames", cohortNames)
lensCode <- c(eau = "4", hemonc_mbc = "5", any = "6")
labCode  <- c(ev_pembro = "a", cisplatin = "b", carboplatin = "c",
              pdl1_mono = "d", other_recommended = "e", other = "f")

# T1 = the Target 1A JSON cohort (captured above by its file-derived name).
jsonSet$cohortName[jsonSet$cohortId == cohort1Id] <- cohortNames[["T1"]]

# L01-anchored initiated cohorts (Target_1A_initiated_L01.json,
# Target_1A_PC_allowed_initiated_L01.json): standalone ATLAS/Circe cohorts,
# analogous to "mBC initiated base" below but indexed on the earliest
# qualifying raw L01 (antineoplastic) drug exposure instead of an
# ARTEMIS-detected regimen episode. Self-contained (their own InclusionRules
# re-derive metastasis/prior-cancer/no-other-cancer and the L01-naive
# washout) rather than descending from Cohort 1's generated table, so they
# stay portable as plain ATLAS cohort definitions.
l01InitId          <- cohortIdByName(jsonSet, "Target 1A initiated L01")
l01InitPcAllowedId <- cohortIdByName(jsonSet, "Target 1A PC allowed initiated L01")
stopifnot(!is.na(l01InitId), !is.na(l01InitPcAllowedId))
jsonSet$cohortName[jsonSet$cohortId == l01InitId]          <- "mBC initiated base (L01)"
jsonSet$cohortName[jsonSet$cohortId == l01InitPcAllowedId] <- "mBC initiated base (L01, PC allowed)"

# --- initiated base ---------------------------------------------------------
baseTemplate <- paste(readLines(file.path(sqlDir, "Target_1A_initiated_template.sql"),
                                warn = FALSE), collapse = "\n")
baseId <- addCustom("mBC initiated base", SqlRender::render(
  baseTemplate, cohort1_id = cohort1Id,
  regimen_episode_table = settings$episodeTable,
  regimen_classification_table = settings$regimenClassTable))

# --- lens splits : split initiated base by class_eau / class_hemonc_mbc /
#     class_any (each a treatment-category label) ------------------------------
classTemplate <- "
DELETE FROM @target_database_schema.@target_cohort_table
 WHERE cohort_definition_id = @target_cohort_id;
INSERT INTO @target_database_schema.@target_cohort_table
  (cohort_definition_id, subject_id, cohort_start_date, cohort_end_date)
SELECT @target_cohort_id, tc.subject_id, tc.cohort_start_date, tc.cohort_end_date
FROM @target_database_schema.@target_cohort_table tc
JOIN @target_database_schema.@regimen_episode_table re
  ON tc.subject_id = CAST(re.person_id AS BIGINT)
JOIN @target_database_schema.@regimen_classification_table rc
  ON re.episode_source_value = rc.regName
  AND re.episode_start_date = tc.cohort_start_date
WHERE rc.@class_column = '@classification'
  AND tc.cohort_definition_id = @base_cohort_id;
"
# three classification lenses (was cohort_T4/T5/T6) x six treatment categories
classCols   <- c(eau = "class_eau", hemonc_mbc = "class_hemonc_mbc", any = "class_any")
classLabels <- c("ev_pembro", "cisplatin", "carboplatin", "pdl1_mono",
                 "other_recommended", "other")
c456 <- list()
for (lens in names(classCols)) for (lab in classLabels) {
  code <- paste0("T", lensCode[[lens]], labCode[[lab]])
  id <- addCustom(cohortNames[[code]], SqlRender::render(
    classTemplate, regimen_episode_table = settings$episodeTable,
    regimen_classification_table = settings$regimenClassTable,
    class_column = classCols[[lens]], classification = lab, base_cohort_id = baseId))
  c456[[paste0(lens, ":", lab)]] <- id
}

# --- eligibility 2a-2d (read unified @labCohortTable) -----------------------
renderElig <- function(leaf, ...) {
  sql <- paste(readLines(file.path(sqlDir, paste0("eligibility_2", leaf, ".sql")),
                         warn = FALSE), collapse = "\n")
  args <- list(...)
  used <- vapply(names(args), function(p) grepl(paste0("@", p), sql, fixed = TRUE), logical(1))
  do.call(SqlRender::render, c(list(sql = sql), args[used]))
}
# Generated in priority order (2a before 2b before 2c) so 2b/2c can anti-join the
# real 2a/2b membership for their "NOT enfortumab" / "NOT cisplatin" exclusions.
labReg <- list(lab_cohort_table = settings$labCohortTable,
               regimen_episode_table = settings$episodeTable, cohort1_id = cohort1Id,
               lab_window_before_days = settings$labWindowBeforeDays,
               lab_window_after_days  = settings$labWindowAfterDays)
elig2 <- list()
elig2$a <- addCustom(cohortNames[["T2a"]], do.call(renderElig, c(list("a"), labReg)))
elig2$b <- addCustom(cohortNames[["T2b"]], do.call(renderElig,
             c(list("b"), labReg, list(cohort2a_id = elig2$a))))
elig2$c <- addCustom(cohortNames[["T2c"]], do.call(renderElig,
             c(list("c"), labReg, list(cohort2a_id = elig2$a, cohort2b_id = elig2$b))))
elig2$d <- addCustom(cohortNames[["T2d"]], do.call(renderElig, c(list("d"), labReg)))

# --- T2e = Cohort 1 minus T2a-T2d ------------------------------------------
cohort2eId <- addCustom(cohortNames[["T2e"]], renderElig("e", cohort1_id = cohort1Id,
  cohort2a_id = elig2$a, cohort2b_id = elig2$b, cohort2c_id = elig2$c, cohort2d_id = elig2$d))

# --- 3a-3d = 2x INTERSECT 4x ; 3e = 2e INTERSECT 4f ------------------------
intersectTemplate <- "
DELETE FROM @target_database_schema.@target_cohort_table
 WHERE cohort_definition_id = @target_cohort_id;
INSERT INTO @target_database_schema.@target_cohort_table
  (cohort_definition_id, subject_id, cohort_start_date, cohort_end_date)
SELECT @target_cohort_id, tx.subject_id, tx.cohort_start_date, tx.cohort_end_date
FROM @target_database_schema.@target_cohort_table tx
JOIN @target_database_schema.@target_cohort_table elig
  ON tx.subject_id = elig.subject_id
WHERE tx.cohort_definition_id = @cohort4_id
  AND elig.cohort_definition_id = @cohort2_id;
"
# T3a-T3d = T2{a-d} eligible INTERSECT the matching EAU-lens (T4) initiated arm;
# T3e = T2e (ineligible) INTERSECT T4f (EAU-lens "other" initiated).
armByLeaf <- c(a = "ev_pembro", b = "cisplatin", c = "carboplatin", d = "pdl1_mono")
t3code    <- c(a = "T3a", b = "T3b", c = "T3c", d = "T3d")
for (lf in c("a","b","c","d"))
  addCustom(cohortNames[[t3code[[lf]]]], SqlRender::render(intersectTemplate,
    cohort2_id = elig2[[lf]], cohort4_id = c456[[paste0("eau:", armByLeaf[[lf]])]]))
addCustom(cohortNames[["T3e"]], SqlRender::render(intersectTemplate,
  cohort2_id = cohort2eId, cohort4_id = c456[["eau:other"]]))

# --- generate everything ----------------------------------------------------
customSet <- dplyr::bind_rows(customRows)
fullSet   <- dplyr::bind_rows(jsonSet, customSet)
message("Full manifest: ", nrow(fullSet), " cohorts (",
        nrow(jsonSet), " JSON + ", nrow(customSet), " SQL templates).")

cohortCounts <- generateCohorts(connection, fullSet, dropTables = TRUE)
mainManifest <<- fullSet
saveState("mainManifest", mainManifest)

# Stratified counts: subject_strata.sql is the single source of truth for
# age_group/sex/age_sex bucketing (shared with demographics.sql,
# R/04_lab_ranges.R, R/05_eligibility_coverage.R, R/09_outcomes.R,
# R/12_treatment_patterns.R). The "overall" view is CohortGenerator's own
# getCohortCounts() result (above), reshaped into the same long format
# rather than re-derived, so it can't drift from the trusted library count.
strataFragment <- renderSqlFile("subject_strata.sql",
  work_database_schema = settings$workDatabaseSchema,
  cohort_table         = settings$cohortTable,
  cdm_database_schema  = settings$cdmDatabaseSchema)
strataCounts <- querySqlFile(connection, "cohort_counts_stratified.sql",
  work_database_schema = settings$workDatabaseSchema,
  cohort_table         = settings$cohortTable,
  subject_strata_sql   = strataFragment)
names(strataCounts) <- tolower(names(strataCounts))
strataCounts$cohort_definition_id <- as.integer(strataCounts$cohort_definition_id)
# settings$strataColumns (run.R CONFIG, via activeStrataTypes()) controls
# which stratum views actually reach the CSV -- the SQL always computes all
# three (age_group/sex/age_sex; cheap), a site that wants fewer/none just
# filters here. "overall" isn't produced by this query at all (see its own
# header), so filtering by activeStrataTypes() (which always includes
# "overall") is harmless here -- it just never matches.
strataCounts <- strataCounts[strataCounts$stratum_type %in% activeStrataTypes(), ]

overallCounts <- tibble::tibble(
  stratum_type = "overall", stratum_value = "overall",
  cohort_definition_id = as.integer(cohortCounts$cohortId),
  n_entries = as.integer(cohortCounts$cohortEntries),
  n_subjects = as.integer(cohortCounts$cohortSubjects))

cohortCountsOut <- dplyr::bind_rows(overallCounts, strataCounts) |>
  dplyr::left_join(dplyr::select(fullSet, cohort_definition_id = "cohortId",
                                 cohort_name = "cohortName"),
                   by = "cohort_definition_id") |>
  dplyr::relocate("cohort_name", .after = "cohort_definition_id")

# Censor small cells (same rule as steps 05/06): subject counts of 1..(minCell-1)
# -> -minCell, and blank the paired entry count. A true 0 stays 0.
.small <- cohortCountsOut$n_subjects > 0 &
          cohortCountsOut$n_subjects < settings$minCellCount
cohortCountsOut$n_entries[.small]  <- NA_integer_
cohortCountsOut$n_subjects[.small] <- -settings$minCellCount
cohortCountsOut <- cohortCountsOut[order(cohortCountsOut$cohort_definition_id,
                                         cohortCountsOut$stratum_type,
                                         cohortCountsOut$stratum_value), ]

writeResultCsv(cohortCountsOut, "cohort_counts")
print(tibble::as_tibble(cohortCountsOut), n = Inf)

# --- standard OHDSI inclusion-rule attrition (01_Target JSON cohorts) -------
# Every JSON cohort under cohorts/01_Target/ (Target 1A: age>18; prior bladder
# cancer; no other cancer) was built with generateStats = TRUE above, so Circe
# already computed the rule stats during generation — just read them back.
# Cohorts with no InclusionRules simply produce no rows.
tableNames <- CohortGenerator::getCohortTableNames(cohortTable = settings$cohortTable)
CohortGenerator::insertInclusionRuleNames(
  connection = connection, cohortDefinitionSet = jsonSet,
  cohortDatabaseSchema = settings$workDatabaseSchema,
  cohortInclusionTable = tableNames$cohortInclusionTable)

stats <- CohortGenerator::getCohortStats(
  connection = connection, cohortDatabaseSchema = settings$workDatabaseSchema,
  cohortTableNames = tableNames)

# Circe computes stats twice per rule: mode_id 0 = event-level (every
# qualifying event, a person may contribute >1), mode_id 1 = person-level
# (the single best-matching event per person, i.e. actual cohort entry).
# cohort_counts.csv is person-level, so use mode 1 to match.
#
# personCount/gainCount (cohort_inclusion_stats) are MARGINAL, not a
# sequential/cumulative narrowing: personCount = persons who satisfy this
# rule alone (regardless of the others); gainCount = persons who'd be gained
# back if only this rule were dropped (i.e. they fail this rule and pass every
# other one). Rule order does not affect them — Circe rules are an unordered
# AND, so there is no inherent "sequence" to narrow through.
#
# `remaining` reconstructs the classic waterfall (cumulative N surviving
# rules 0..i together, in ruleSequence order) from cohort_inclusion_result:
# for each observed bitmask, POWER(2, ruleSequence) is one bit; summing
# person_count over every mask with bits 0..i ALL set gives "how many are
# still in after applying rules 0 through i". The last rule's `remaining`
# is therefore always exactly cohort_summary_stats$finalCount.
rules <- dplyr::filter(stats$cohortInclusionStatsTable, modeId == 1) |>
  dplyr::inner_join(stats$cohortInclusionTable,
                    by = c("cohortDefinitionId", "ruleSequence")) |>
  dplyr::transmute(cohortId = cohortDefinitionId, ruleSequence,
                   ruleName = name, personCount, gainCount, personTotal)

maskCounts <- dplyr::filter(stats$cohortInclusionResultTable, modeId == 1)
nRulesByCohort <- dplyr::count(stats$cohortInclusionTable, cohortDefinitionId,
                               name = "nRules")
remaining <- dplyr::bind_rows(lapply(seq_len(nrow(nRulesByCohort)), function(k) {
  cid    <- nRulesByCohort$cohortDefinitionId[k]
  nRules <- nRulesByCohort$nRules[k]
  masks  <- dplyr::filter(maskCounts, cohortDefinitionId == cid)
  data.frame(
    cohortId = cid, ruleSequence = seq_len(nRules) - 1L,
    remaining = vapply(seq_len(nRules) - 1L, function(i) {
      requiredMask <- bitwShiftL(1L, i + 1L) - 1L  # bits 0..i all set
      sum(masks$personCount[bitwAnd(masks$inclusionRuleMask, requiredMask) == requiredMask])
    }, numeric(1)))
}))

base <- dplyr::filter(stats$cohortSummaryStatsTable, modeId == 1) |>
  dplyr::transmute(cohortId = cohortDefinitionId, ruleSequence = -1L,
                   ruleName = "(qualifying event, before inclusion rules)",
                   personCount = baseCount, gainCount = NA_integer_,
                   personTotal = baseCount, remaining = baseCount)

attrition <- dplyr::left_join(rules, remaining, by = c("cohortId", "ruleSequence")) |>
  dplyr::bind_rows(base) |>
  dplyr::left_join(dplyr::select(jsonSet, cohortId, cohortName), by = "cohortId") |>
  dplyr::arrange(cohortId, ruleSequence) |>
  dplyr::relocate(cohortName, .after = cohortId)

# privacy: censor small cells (same rule as elsewhere)
.smallAttr <- attrition$personCount > 0 & attrition$personCount < settings$minCellCount
attrition$gainCount[.smallAttr]   <- NA_integer_
attrition$personCount[.smallAttr] <- -settings$minCellCount
.smallRem <- attrition$remaining > 0 & attrition$remaining < settings$minCellCount
attrition$remaining[.smallRem] <- -settings$minCellCount

writeResultCsv(attrition, "attrition_target_1a")
print(tibble::as_tibble(attrition), n = Inf)
