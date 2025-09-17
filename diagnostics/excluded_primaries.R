library(tidyverse)
library(DatabaseConnector)
library(SqlRender)

### USE SETUP FROM RUN.R HERE
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
JOIN @cdm_database_schema.concept C ON P.condition_concept_id = C.concept_id
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
