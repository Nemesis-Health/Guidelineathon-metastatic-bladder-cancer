# ===========================================================================
# sql.R  —  render, translate and run the files in sql/
# ===========================================================================
# Every step reads its SQL through these: parameters are checked before
# rendering, and the rendered text is checked for unfilled test-id
# placeholders before it is translated to the connection's dialect.
# ===========================================================================

# --- fail loudly on a NULL/missing SqlRender parameter, instead of letting
# SqlRender silently substitute it as an empty string (e.g. a NULL
# `settings$someKey` turning `-@some_param` into a bare `-`, which only
# surfaces later as a cryptic DBMS-specific syntax error) ------------------
.checkSqlRenderParams <- function(file, params) {
  bad <- names(params)[vapply(params, function(x) length(x) == 0L || is.na(x)[1], logical(1))]
  if (length(bad) > 0L)
    stop("querySqlFile/runSqlFile(\"", file, "\"): parameter(s) ",
         paste(bad, collapse = ", "), " are NULL/NA — check that `settings` ",
         "defines them (see run.R and R/study_settings.R) before sourcing this step.", call. = FALSE)
}

# Stop if rendered SQL still holds a test-id placeholder (param not passed).
.checkTestIdsRendered <- function(sql, file) {
  left <- regmatches(sql, gregexpr(
    "@(t_[a-z0-9_]+|ecog_ids|condition_window_ids|passthrough_ids|ecog_grade_cases)\\b",
    sql, perl = TRUE))[[1]]
  if (length(left))
    stop(file, ": unfilled test-id parameter(s) ", paste(unique(left), collapse = ", "),
         " (pass testIdParams() when rendering).", call. = FALSE)
  sql
}

# --- render + translate + execute a .sql file ------------------------------
runSqlFile <- function(connection, file, ...) {
  .checkSqlRenderParams(file, list(...))
  sql <- paste(readLines(file.path(sqlDir, file), warn = FALSE), collapse = "\n")
  sql <- SqlRender::render(sql, ..., warnOnMissingParameters = FALSE)
  .checkTestIdsRendered(sql, file)
  sql <- SqlRender::translate(sql, targetDialect = .getDbms(connection))
  DatabaseConnector::executeSql(connection, sql)
}

# --- render + translate + query a .sql file --------------------------------
querySqlFile <- function(connection, file, ...) {
  .checkSqlRenderParams(file, list(...))
  sql <- paste(readLines(file.path(sqlDir, file), warn = FALSE), collapse = "\n")
  sql <- SqlRender::render(sql, ..., warnOnMissingParameters = FALSE)
  .checkTestIdsRendered(sql, file)
  sql <- SqlRender::translate(sql, targetDialect = .getDbms(connection))
  DatabaseConnector::querySql(connection, sql)
}

# --- render (no translate, no execute) a .sql file --------------------------
# For assembling one file's fully-resolved text as a fragment injected into
# another template (e.g. subject_strata.sql's body becomes demographics.sql's
# `coh` CTE, or a stratifyTemplate's strata subquery) -- resolve the source
# fragment's own placeholders here FIRST, so the two files' parameters can't
# collide when the outer template is rendered.
renderSqlFile <- function(file, ...) {
  .checkSqlRenderParams(file, list(...))
  sql <- paste(readLines(file.path(sqlDir, file), warn = FALSE), collapse = "\n")
  .checkTestIdsRendered(SqlRender::render(sql, ..., warnOnMissingParameters = FALSE), file)
}
