library(tidyverse)
library(DatabaseConnector)
library(SqlRender)

censor <- 5

### USE SETUP FROM RUN.R HERE
executionSettings <- list(
  databaseName = "", ## This should be a unique identifier for your database. It is not used for database connectivity, only to identify results.
  server = "",
  port = "",
  user = "",
  password = "",
  cdmDatabaseSchema = "",
  vocabDatabaseSchema = ""
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
con <- DatabaseConnector::connect(connectionDetails)

base_cohort <- read_file("sql/base_cohort.sql")

sql <- SqlRender::render(
  base_cohort, 
  cdm_database_schema = executionSettings$cdmDatabaseSchema,
  vocabulary_database_schema = executionSettings$vocabDatabaseSchema
  )

sql <- SqlRender::translate(sql, connectionDetails$dbms)


## Running this will leave a temp table, 
DatabaseConnector::executeSql(connection = con, sql)


sql <- "
SELECT  condition_concept_id, concept_name, count(distinct P.person_id) as count
FROM #final_cohort CO
JOIN @cdm_database_schema.condition_occurrence P ON CO.person_id = P.person_id
JOIN #Codesets cs on (P.condition_concept_id = cs.concept_id and cs.codeset_id = 3)
JOIN @vocabulary_database_schema.concept C ON P.condition_concept_id = C.concept_id
WHERE P.condition_start_date >= DATEADD(day,-365,CO.start_date)
AND P.condition_start_date <= DATEADD(day,30,CO.start_date)
GROUP BY P.condition_concept_id, C.concept_name
ORDER BY count DESC
"

sql <- SqlRender::render(
  sql, 
  cdm_database_schema = executionSettings$cdmDatabaseSchema,
  vocabulary_database_schema = executionSettings$vocabDatabaseSchema
)

sql <- SqlRender::translate(sql, connectionDetails$dbms)

result <- DatabaseConnector::querySql(connection = con, sql)

head(result)

result %>%
   mutate(COUNT = case_when(COUNT < censor ~ censor, TRUE ~ COUNT)) %>%
   write_csv("excluded_concepts.csv")