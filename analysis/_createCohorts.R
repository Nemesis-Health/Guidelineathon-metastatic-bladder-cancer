# A. File Info -----------------------

# Task: Build Cohorts
# Description: The purpose of the _buildCohorts.R script is to build cohort functions


# B. Functions ------------------------

initializeCohortTables <- function(executionSettings,
                                   con,
                                   dropTables = FALSE) {

  name <- executionSettings$cohortTable

  cohortTableNames <- list(cohortTable = paste0(name),
                           cohortInclusionTable = paste0(name, "_inclusion"),
                           cohortInclusionResultTable = paste0(name, "_inclusion_result"),
                           cohortInclusionStatsTable = paste0(name, "_inclusion_stats"),
                           cohortSummaryStatsTable = paste0(name, "_summary_stats"),
                           cohortCensorStatsTable = paste0(name, "_censor_stats"))


  ## Drop cohort tables
  if (dropTables == TRUE) {

    ## Delete csv files from "01_buildCohorts" folder
    manifestPath <- here::here("results", executionSettings$databaseName, "01_buildCohorts")
    pathFiles <- list.files(manifestPath,  full.names = TRUE)
    sapply(pathFiles, unlink)


    ## Drop cohort tables
    for (i in 1:length(cohortTableNames)) {

      sql <- "DROP TABLE IF EXISTS @writeSchema.@tableName;"

      dropSql <- SqlRender::render(
        sql,
        writeSchema = executionSettings$workDatabaseSchema,
        tableName = cohortTableNames[i]
      ) %>%
        SqlRender::translate(targetDialect = "snowflake")

      DatabaseConnector::executeSql(connection = con, dropSql, progressBar = FALSE)

    }
  }

  ## Create cohort tables
  CohortGenerator::createCohortTables(connection = con,
                                      cohortDatabaseSchema = executionSettings$workDatabaseSchema,
                                      cohortTableNames = cohortTableNames,
                                      incremental = TRUE)
  invisible(cohortTableNames)
}

getCohortManifest <- function(inputPath = here::here("cohortsToCreate")) {

  #get cohort file paths
  cohortFiles <- fs::dir_ls(inputPath, recurse = TRUE, type = "file", glob = "*.json")
  #get cohort names
  cohortNames <- fs::path_file(cohortFiles) %>%
    fs::path_ext_remove()
  #get cohort type
  cohortType <- fs::path_dir(cohortFiles) %>%
    basename() %>%
    gsub(".*_", "", .)

  #future addition of hash
  hash <- purrr::map(cohortFiles, ~readr::read_file(.x)) %>%
    purrr::map_chr(~digest::digest(.x, algo = "sha1")) %>%
    unname()

  #return tibble with info
  tb <- tibble::tibble(
    name = cohortNames,
    type = cohortType,
    hash = hash,
    file = cohortFiles %>% as.character()
  ) %>%
    dplyr::mutate(
      id = dplyr::row_number(), .before = 1
    )

  return(tb)
}


prepManifestForCohortGenerator <- function(cohortManifest) {

  cohortsToCreate <- cohortManifest %>%
    dplyr::mutate(
      json = purrr::map_chr(file, ~readr::read_file(.x))
    ) %>%
    dplyr::select(id, name, json) %>%
    dplyr::rename(cohortId = id, cohortName = name)

  cohortsToCreate$sql <- purrr::map_chr(
    cohortsToCreate$json,
    ~CirceR::buildCohortQuery(CirceR::cohortExpressionFromJson(.x),
                              CirceR::createGenerateOptions(generateStats = TRUE)))

  return(cohortsToCreate)
}


generateCohorts <- function(executionSettings,
                            con,
                            cohortsToCreate,
                            outputFolder,
                            incremental = FALSE,
                            type = "analysis") {

  #path for incremental
  incrementalFolder <- fs::path(outputFolder)

  ## Ensure correct vocab database schema is used
  cohortsToCreate$sql <- map_chr(cohortsToCreate$sql, ~SqlRender::render(.x, vocabulary_database_schema = executionSettings$vocabDatabaseSchema))

  name <- executionSettings$cohortTable

  cohortTableNames <- list(cohortTable = paste0(name),
                           cohortInclusionTable = paste0(name, "_inclusion"),
                           cohortInclusionResultTable = paste0(name, "_inclusion_result"),
                           cohortInclusionStatsTable = paste0(name, "_inclusion_stats"),
                           cohortSummaryStatsTable = paste0(name, "_summary_stats"),
                           cohortCensorStatsTable = paste0(name, "_censor_stats"))

  #generate cohorts
  CohortGenerator::generateCohortSet(
    connection = con,
    cdmDatabaseSchema = executionSettings$cdmDatabaseSchema,
    cohortDatabaseSchema =  executionSettings$workDatabaseSchema,
    cohortTableNames = cohortTableNames,
    cohortDefinitionSet = cohortsToCreate,
    incremental = incremental,
    incrementalFolder = incrementalFolder
  )

  #get cohort counts
  cohortCounts <- CohortGenerator::getCohortCounts(
    connection = con,
    cohortDatabaseSchema = executionSettings$workDatabaseSchema,
    cohortTable = cohortTableNames$cohortTable,
    cohortDefinitionSet = cohortsToCreate
  ) %>%
    dplyr::select(cohortId, cohortName, cohortEntries, cohortSubjects)

  # save generated cohorts
  tb <- cohortsToCreate %>%
    dplyr::left_join(cohortCounts %>%
                       dplyr::select(cohortId, cohortEntries, cohortSubjects),
                     by = c("cohortId" = "cohortId")) %>%
    dplyr::select(
      cohortId, cohortName, cohortEntries, cohortSubjects
    )

  #savePath <- fs::path(outputFolder, "cohortManifest.csv")
  #readr::write_csv(x = tb, file = savePath)
  #cli::cat_bullet("Saving Generated Cohorts to ", crayon::cyan(savePath),
  #                bullet = "tick", bullet_col = "green")

  return(cohortCounts)
}

# Run Cohort Diagnostis
# Description: this function is used to run cohort diagnostics. preps cohorts for run
# and then executes cohort diagnostics
# inputs:
# con -> the connection objection accessing the dbms storing the omop data
# executionSettings -> the DatabaseSchema information required to run the study
# cohortManifest -> the set of cohorts used to run diagnostics
# outputFolder -> the save location of the cohort diagnostics run
# return:
# invisible return of the cohortsToRun for diagnostics. The output of this function
# is a folder with cohort diagnostics run.

runCohortDiagnostics <- function(con,
                                 executionSettings,
                                 cohortsToRun,
                                 outputFolder,
                                 minCellCount = 5) {

  name <- executionSettings$cohortTable

  cohortTableNames <- list(cohortTable = paste0(name),
                           cohortInclusionTable = paste0(name, "_inclusion"),
                           cohortInclusionResultTable = paste0(name, "_inclusion_result"),
                           cohortInclusionStatsTable = paste0(name, "_inclusion_stats"),
                           cohortSummaryStatsTable = paste0(name, "_summary_stats"),
                           cohortCensorStatsTable = paste0(name, "_censor_stats"))


  #Run cohort diagnostics
  CohortDiagnostics::executeDiagnostics(
    cohortDefinitionSet = cohortsToRun,
    exportFolder = outputFolder,
    cohortTableNames = cohortTableNames,
    cohortDatabaseSchema = executionSettings$workDatabaseSchema,
    cdmDatabaseSchema = executionSettings$cdmDatabaseSchema,
    vocabularyDatabaseSchema = executionSettings$vocabDatabaseSchema,
    databaseId = executionSettings$databaseName,
    connection = con,
    incremental = TRUE,
    minCellCount = minCellCount
  )

  cli::cat_bullet("Saving Cohort Diagnostics to ", crayon::cyan(outputFolder),
                  bullet = "tick", bullet_col = "green")

  invisible(cohortsToRun)
}