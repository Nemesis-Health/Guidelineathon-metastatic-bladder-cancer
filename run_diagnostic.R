library(tidyverse)
library(CohortGenerator)
library(DatabaseConnector)
library(SqlRender)

source("analysis/_createCohorts.R")
source("analysis/_cohortAttritionFns.R")

################################ 
## 1. STUDY SETUP - PLEASE COMPELTE
################################  

### If not already set, set file path to DB JAR FIles
#Sys.getenv("DATABASECONNECTOR_JAR_FOLDER")
#Sys.setenv(DATABASECONNECTOR_JAR_FOLDER = "∼/JDBC/")

outputFolder <- "results_preliminary"
dir.create(outputFolder)

minCellCount <- 5

executionSettings <- list(
  server = "",
  port = "",
  user = "",
  password = "",
  cdmDatabaseSchema = "",
  vocabDatabaseSchema = "",
  workDatabaseSchema = "",
  cohortTable = ""
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

preparedCohortManifest <- prepManifestForCohortGenerator(getCohortManifest()) %>%
  filter(str_detect(cohortName, "^Target|ARTEMIS"))

################################  
## 3. BUILD COHORTS AND WRITE COUNTS TO FILE
################################ 
# Create all study cohorts and write censored counts to file.
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
  
write_csv(cohortCounts, file.path(outputFolder, "main_cohort_counts.csv"))
  

################################ 
## 4. GET ATTRITION AND WRITE TO FILE
################################ 
sql <- "select * from @work_database_schema.@cohort_table_inclusion_result;"
sql <- SqlRender::render(sql, work_database_schema = executionSettings$workDatabaseSchema, cohort_table = executionSettings$cohortTable)
sql <- SqlRender::translate(sql, connectionDetails$dbms)

inclusionResult <- querySql(con, sql) %>%
  dplyr::rename_all(tolower) %>%
  dplyr::mutate(inclusion_rule_mask = as.numeric(.data$inclusion_rule_mask)) %>%
  tibble()

attrition <- map_df(unique(inclusionResult$cohort_definition_id), function(cohortId) {

  example <- inclusionResult %>%
    filter(cohort_definition_id == cohortId, mode_id == 1)
  
  colnames(example) <- SqlRender::snakeCaseToCamelCase(colnames(example))
  
  getCohortAttritionViewResults(
    example,
    5
  ) 
}) 

attrition <- attrition %>%
    mutate(personCount = case_when(personCount < minCellCount ~ -minCellCount, TRUE ~ personCount))

write_csv(attrition, file.path(outputFolder, "attrition.csv"))

################################ 
## 5. RUN DIAGNOSTIC QUERY 1: FINDS OUT WHICH CONCEPTS ARE EXCLUDING PATIENTS FOR HAVING OTHER PRIOR CANCER
################################ 
sql <- SqlRender::readSql("sql/diagnostic_query_1.sql")

cohortId <- preparedCohortManifest %>%
  filter(cohortName == "Target_0_mBC") %>%
  .$cohortId

sql <- SqlRender::render(sql, work_database_schema = executionSettings$workDatabaseSchema, cohort_table = executionSettings$cohortTable, cohort_definition_id = cohortId, vocabulary_database_schema = executionSettings$vocabDatabaseSchema, cdm_database_schema = executionSettings$cdmDatabaseSchema)

sql <- SqlRender::translate(sql, connectionDetails$dbms)

result <- DatabaseConnector::querySql(connection = con, sql)

head(result)

result %>%
   rename_all(tolower) %>%
   mutate(count = case_when(count < minCellCount ~ -minCellCount, TRUE ~ count)) %>%
   write_csv(file.path(outputFolder, "excluded_concepts.csv"))
