library(tidyverse)
library(SqlRender)

# Function to process SQL content for cohort analysis
process_sql_for_cohort <- function(sql_content) {
  # Convert to character if it's not already
  sql_lines <- as.character(sql_content)
  
  # Split into lines for easier processing
  lines <- strsplit(sql_lines, "\n")[[1]]
  
  # Find the pattern to replace (lines with DELETE and INSERT statements)
  # Look for the specific pattern: DELETE FROM ... INSERT INTO ... select ...
  delete_pattern <- "DELETE FROM @target_database_schema.@target_cohort_table where cohort_definition_id = @target_cohort_id;"
  insert_pattern <- "INSERT INTO @target_database_schema.@target_cohort_table (cohort_definition_id, subject_id, cohort_start_date, cohort_end_date)"
  select_pattern <- "select @target_cohort_id as cohort_definition_id, person_id, start_date, end_date"
  
  # Find lines containing these patterns
  delete_line_idx <- which(grepl(delete_pattern, lines, fixed = TRUE))
  insert_line_idx <- which(grepl(insert_pattern, lines, fixed = TRUE))
  select_line_idx <- which(grepl(select_pattern, lines, fixed = TRUE))
  
  if (length(delete_line_idx) > 0 && length(insert_line_idx) > 0 && length(select_line_idx) > 0) {
    # Replace the INSERT line with the count query
    lines[insert_line_idx] <- "SELECT count(distinct person_id) FROM"
    
    # Remove the DELETE line
    lines <- lines[-delete_line_idx]
    
    # Remove the SELECT line (since we replaced the INSERT line)
    # Adjust indices after removing DELETE line
    if (select_line_idx > delete_line_idx) {
      select_line_idx <- select_line_idx - 1
    }
    lines <- lines[-select_line_idx]
  }
  
  # Find the first occurrence of {0 != 0}?{ and remove everything from that point onwards
  conditional_pattern <- "\\{0 != 0\\}\\?\\{"
  conditional_line_idx <- which(grepl(conditional_pattern, lines))
  
  if (length(conditional_line_idx) > 0) {
    # Keep only lines before the first occurrence
    lines <- lines[1:(conditional_line_idx[1] - 1)]
  }
  
  # Join lines back together
  result <- paste(lines, collapse = "\n")
  
  return(result)
}

for(i in list.files("cohortsToCreate/01_Target",full.names = TRUE)){
    json <- read_file(i)
    sql <- CirceR::buildCohortQuery(CirceR::cohortExpressionFromJson(json), CirceR::createGenerateOptions(generateStats = FALSE))
    sql <- SqlRender::translate(sql, targetDialect = "snowflake")
    
    # Process the SQL for cohort analysis
    sql <- process_sql_for_cohort(sql)

    write_file(sql, file.path("sql","snowflake", str_c(tools::file_path_sans_ext(basename(i)),".sql")))
}

