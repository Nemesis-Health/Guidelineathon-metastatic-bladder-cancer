### Ensure renv is loaded and up to date with new version of ARTEMIS installed. 
### If you cannot use renv because of environment restrictions, please install the below version of ARTEMIS along with other dependencies:
### remotes::install_github("OHDSI/ARTEMIS@fe31707b5fe2aeda896ee5d2399852a6a8dd4def")
### If you encounter issues installing ARTEMIS consider using a python virtual environment for the project. See setup.R for details or contact the study team.
source("renv/activate.R") ## Choose to restore project from lockfile
renv::restore()

library(tidyverse)
library(CohortGenerator)
library(ARTEMIS)

source("analysis/_createCohorts.R")
source("analysis/_runARTEMIS.R")
source("extras/source_without_messages.R")

################################ 
## 1. STUDY SETUP - PLEASE COMPELTE
################################  

### If not already set, set file path to DB JAR FIles
#Sys.getenv("DATABASECONNECTOR_JAR_FOLDER")
#Sys.setenv(DATABASECONNECTOR_JAR_FOLDER = "∼/JDBC/")

outputFolder <- "results"
dir.create(outputFolder)
dir.create(file.path(outputFolder, "study_results"))

minCellCount <- 5
run_ARTEMIS <- TRUE
run_cohort_diagnostics_for_target_cohorts <- TRUE
run_cohort_diagnostics_for_all_cohorts <- FALSE
create_cohorts <- TRUE

executionSettings <- list(
  databaseName = "", ## This should be a unique identifier for your database. It is not used for database connectivity, only to identify results.
  dbms = "",
  server = "",
  port = "",
  user = "",
  password = "",
  cdmDatabaseSchema = "",
  vocabDatabaseSchema = "",
  workDatabaseSchema = "",
  cohortTable = "",
  ARTEMISCohortTable = "",
  ARTEMISEpisodeTableName = "" , 
  regimen_classification_table = "bc_regimen_classifcations"
)


#####
## NOTE: If you require a DBI database connection, use edit the below example. Please contact the study team for assistance.
# connectionDetails <- DatabaseConnector::createDbiConnectionDetails(
#   dbms = "sql server",
#   drv = odbc::odbc(),
#   Driver = "ODBC Driver 18 for SQL Server",
#   Server = "server.database.windows.net",
#   Database = "dsfsd8980sddfsd",
#   Authentication = "ActiveDirectoryPassword", 
#   UID = "",
#   PWD = rstudioapi::askForPassword("Database password")
# )
#####

connectionDetails <- DatabaseConnector::createConnectionDetails(
  dbms = executionSettings$dbms,
  server = executionSettings$server,
  user= executionSettings$user,
  port = executionSettings$port,
  password = executionSettings$password,
)

################################  
## 2. PREPARE COHORTS
################################  
## This code prepares the cohort manifest file. SQL is written in SQL Server but will be translated before execution. No action is needed.
## The SQL for Target Cohort 3B is substituted to make use of data written to the ARTEMISEpisodeTableName defined in the executionSettings object.

preparedCohortManifest <- prepManifestForCohortGenerator(getCohortManifest())

for(target_cohort in c("1A")){
  sql_template <- readLines(str_c("sql/Target_",target_cohort,"_initiated_template.sql"))
  sql_template <- paste(sql_template, collapse = "\n")  # Combine into one string
  base_cohort_id <- max(preparedCohortManifest$cohortId) + 1

  sql <- SqlRender::render(sql_template, regimen_episode_table = executionSettings$ARTEMISEpisodeTableName, regimen_classification_table = executionSettings$regimen_classification_table)
  preparedCohortManifest <- add_row(
    preparedCohortManifest,
    cohortId = base_cohort_id,
    cohortName = str_c("Target_",target_cohort,"_initiated_base"),
    json = preparedCohortManifest$json[preparedCohortManifest$cohortName == str_c("Target_",target_cohort,"_initiated_L01")],
    sql = sql
  )

  sql_template <- "
  DELETE FROM @target_database_schema.@target_cohort_table where cohort_definition_id = @target_cohort_id;
  INSERT INTO @target_database_schema.@target_cohort_table (cohort_definition_id, subject_id, cohort_start_date, cohort_end_date)
  SELECT @target_cohort_id as cohort_definition_id, tc.subject_id, tc.cohort_start_date, tc.cohort_end_date
  FROM @target_database_schema.@target_cohort_table tc
  JOIN @target_database_schema.@regimen_episode_table re
    ON tc.subject_id = re.person_id
  JOIN @target_database_schema.@regimen_classification_table rc
    ON re.episode_source_value = rc.regName
    AND re.episode_start_date = tc.cohort_start_date
  @classification_expression
  AND cohort_definition_id = @base_cohort_id
  "

  for(cohort_set in c("4","5","6")){
    for(classification in c("a","b","c","d","e","f")){
      classification_expression <- str_c("WHERE cohort_T" ,cohort_set,"  = ", "'",classification,"'")
      sql <- SqlRender::render(sql_template, regimen_episode_table = executionSettings$ARTEMISEpisodeTableName, regimen_classification_table = executionSettings$regimen_classification_table, classification_expression = classification_expression, base_cohort_id = base_cohort_id)
      preparedCohortManifest <- add_row(
        preparedCohortManifest,
        cohortId = max(preparedCohortManifest$cohortId) + 1,
        cohortName = str_c("Target_",target_cohort,"_",cohort_set,classification),
        json = preparedCohortManifest$json[preparedCohortManifest$cohortName == str_c("Target_",target_cohort,"_initiated_L01")],
        sql = sql
      )
    }
  }
}

################################  
## 3. RUN ARTEMIS AND WRITE EPISODES - SKIP IF ALREADY RUN
################################ 

if(run_ARTEMIS){

  con <- DatabaseConnector::connect(connectionDetails)

  l02 <- dbGetQuery(con, SqlRender::render("SELECT descendant_concept_id 
              FROM @cdm_database_schema.concept_ancestor 
              WHERE ancestor_concept_id = 21603812 ", cdm_database_schema = executionSettings$cdmDatabaseSchema))
    
  validDrugs_input <- ARTEMIS::loadDrugs(
    #absolute = file.path(getwd(), "data", "validDrugs.rda")
  ) %>%
    mutate(valid_concept_id = case_when(name == "Methotrexate" ~ "1305058", 
           TRUE ~ valid_concept_id)) %>% 
    filter(!valid_concept_id %in% l02$descendant_concept_id)
 
  regimens_input <- ARTEMIS::loadRegimens(
    condition = "all",
    #absolute = file.path(getwd(), "data", "regimens.rda")
  )
  ARTEMIS_outputs <- runARTEMIS(
    connectionDetails = connectionDetails ,
    cdmSchema = executionSettings$cdmDatabaseSchema,
    cohortTable = executionSettings$ARTEMISCohortTable,
    cohortSchema = executionSettings$workDatabaseSchema,
    cohortManifestRow = filter(preparedCohortManifest,cohortName=="ARTEMIS_bladder_cohort"),
    regimens =  regimens_input,
    validDrugs = validDrugs_input
  )
    
  insertTable(connection = con, 
              databaseSchema = executionSettings$workDatabaseSchema,
              tableName = executionSettings$ARTEMISEpisodeTableName,
              dropTableIfExists = TRUE,
              data = mutate(ARTEMIS_outputs$episodes, person_id = as.integer(person_id))
  )

  regimen_classifications <- read_csv("extras/regimen_classifications.csv")

  insertTable(connection = con, 
              databaseSchema = executionSettings$workDatabaseSchema,
              tableName = executionSettings$regimen_classification_table,
              dropTableIfExists = TRUE,
              data = regimen_classifications
  )
  
  DatabaseConnector::disconnect(con)
  
}

################################  
## 4. BUILD COHORTS
################################ 
# Create all study cohorts and write censored counts to file.

if(create_cohorts){
  
  con <- DatabaseConnector::connect(connectionDetails)
  
  initializeCohortTables(executionSettings = executionSettings, con = con, dropTables = TRUE)
  
  cohortCounts <- generateCohorts(
    executionSettings = executionSettings ,
    con = con,
    cohortsToCreate = preparedCohortManifest,
    outputFolder = outputFolder,
    type = "analysis"
  )
  
  cohortCounts <-  mutate(cohortCounts, across(c(cohortEntries,cohortSubjects), ~case_when(.x > 0 & .x < minCellCount ~ -minCellCount, TRUE ~ .x)))
  
  write_csv(cohortCounts, file.path(outputFolder, "study_results","main_cohort_counts.csv"))
  
  DatabaseConnector::disconnect(con)
  
}

################################  
## 5. RUN COHORT DIAGNOSTICS 
################################      

if(run_cohort_diagnostics_for_target_cohorts | run_cohort_diagnostics_for_all_cohorts){

  con <- DatabaseConnector::connect(connectionDetails)

  manifest_to_run <- preparedCohortManifest

  if(!run_cohort_diagnostics_for_all_cohorts) manifest_to_run <-  filter(manifest_to_run, cohortName %in% c("Target_1A", "Target_1A_initiated_base", "Target_1A_initiated_L01", "ARTEMIS_bladder_cohort") | str_detect(cohortName, "Target_1A_"))

  runCohortDiagnostics(
    con = con,
    executionSettings = executionSettings,
    cohortsToRun = manifest_to_run,
    outputFolder = outputFolder,
    minCellCount = minCellCount
  )

  source("analysis/_cohortAttrition.R")

  DatabaseConnector::disconnect(con)

}

################################  
## 6. RUN MAIN STUDY
################################   

con <- DatabaseConnector::connect(connectionDetails)

source_without_messages("analysis/_cohortDemographics.R")
source_without_messages("analysis/_cohortComorbidities.R")
source_without_messages("analysis/_rollupCounts.R")
source_without_messages("analysis/_therapyAnalysis.R")
source_without_messages("analysis/_timeToEvent.R")

DatabaseConnector::disconnect(con)

zip(file.path(outputFolder, "study_results.zip"), file.path(outputFolder, "study_results"))
