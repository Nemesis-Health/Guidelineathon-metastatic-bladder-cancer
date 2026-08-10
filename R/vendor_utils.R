# Small internal helpers the vendored artemis.R depends on (copied from
# OncoStudyModules R/cohortGeneration.R + a base-R null-coalesce fallback).

.getDbms <- function(connection) {
  dbms <- tryCatch(connection@dbms, error = function(e) NULL)
  if (is.null(dbms)) dbms <- attr(connection, "dbms")
  if (is.null(dbms) || !nzchar(dbms))
    stop("Cannot determine DBMS dialect from connection.", call. = FALSE)
  dbms
}

# base R gained %||% in 4.4.0; define for older Rs / safety.
if (!exists("%||%")) {
  `%||%` <- function(x, y) if (is.null(x)) y else x
}

# DatabaseConnector::getTableNames() ignores the schema argument for DBI
# connections backed by RPostgres specifically (OHDSI/DatabaseConnector#339):
# RPostgres's dbListTables() has no schema parameter, so it lists whatever is
# on the session's search_path instead of `databaseSchema`. That makes
# CohortGenerator's post-creation table check report every cohort table as
# missing even though CREATE TABLE succeeded. Other DBI drivers (e.g. odbc,
# used for SQL Server / Azure AD in this repo's README example) correctly
# honor the schema and are unaffected — this checks the underlying driver via
# the `dbiConnection` slot, not just dbms == "postgresql", so it doesn't
# false-positive on a working odbc+Postgres setup.
.checkDbiPostgresBug <- function(connection) {
  isBroken <- inherits(connection, "DatabaseConnectorDbiConnection") &&
    .getDbms(connection) == "postgresql" &&
    tryCatch(inherits(connection@dbiConnection, "PqConnection"),
             error = function(e) FALSE)
  if (isBroken) {
    stop(
      "This connection uses DBI/RPostgres for PostgreSQL, which this pipeline ",
      "cannot run on: DatabaseConnector::getTableNames() ignores the schema ",
      "for RPostgres connections (OHDSI/DatabaseConnector#339), so ",
      "CohortGenerator wrongly reports the cohort tables as never created. ",
      "Use a JDBC connection instead: DatabaseConnector::createConnectionDetails(",
      "dbms = \"postgresql\", ...).",
      call. = FALSE)
  }
}
