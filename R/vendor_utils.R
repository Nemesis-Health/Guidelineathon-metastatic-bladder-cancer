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

# Swap a package function in place: its namespace binding, the attached
# package environment's copy if any, and, for a registered S3 method, the S3
# methods table dispatch reads from. (utils::assignInNamespace() looks the S3
# generic up in the caller's frame, so it fails unless the package is
# attached.)
.replaceInNamespace <- function(pkg, fn, f) {
  ns <- asNamespace(pkg)
  unlockBinding(fn, ns)
  assign(fn, f, envir = ns)
  lockBinding(fn, ns)
  s3 <- get(".__S3MethodsTable__.", envir = ns)
  if (exists(fn, envir = s3, inherits = FALSE)) assign(fn, f, envir = s3)
  attached <- paste0("package:", pkg)
  if (attached %in% search()) {
    env <- as.environment(attached)
    if (exists(fn, envir = env, inherits = FALSE)) {
      unlockBinding(fn, env)
      assign(fn, f, envir = env)
      lockBinding(fn, env)
    }
  }
}

# Replace every occurrence of the call `target` in `expr` with `replacement`,
# leaving an existing `replacement` alone (so re-patching is a no-op).
.rewriteCall <- function(expr, target, replacement) {
  if (identical(expr, replacement)) return(expr)
  if (identical(expr, target)) return(replacement)
  if (is.call(expr)) {
    for (i in seq_along(expr)[-1]) {
      el <- expr[[i]]
      if (!missing(el) && !is.null(el)) expr[[i]] <- .rewriteCall(el, target, replacement)
    }
  }
  expr
}

# Rewrite `target` -> `replacement` in each of `fns` in `pkg`. Returns the
# original functions that changed, for .restorePatchedFunctions().
.patchFunctions <- function(pkg, fns, target, replacement, what) {
  ns <- asNamespace(pkg)
  originals <- list()
  for (fn in fns) {
    f <- get0(fn, envir = ns, inherits = FALSE)
    if (!is.function(f)) next
    newBody <- .rewriteCall(body(f), target, replacement)
    if (identical(newBody, body(f))) next
    originals[[fn]] <- f
    body(f) <- newBody
    .replaceInNamespace(pkg, fn, f)
  }
  if (length(originals))
    message("Patched ", pkg, "::", paste(names(originals), collapse = ", "), " ", what)
  attr(originals, "pkg") <- pkg
  invisible(originals)
}

.restorePatchedFunctions <- function(originals) {
  pkg <- attr(originals, "pkg")
  for (fn in names(originals)) .replaceInNamespace(pkg, fn, originals[[fn]])
  if (length(originals))
    message("Restored ", pkg, "::", paste(names(originals), collapse = ", "))
  invisible(NULL)
}

# DatabaseConnector's DBI insertTable() strips the leading "#" from temp table
# names before calling DBI::dbWriteTable(temporary = TRUE). odbc's SQL Server
# backend ignores `temporary` and only creates a temp table when the name
# itself starts with "#", so the insert lands in a permanent table and later
# SQL referencing "#name" fails (hit by CohortDiagnostics' incidence-rate and
# temporal-characterization steps). The strip lives in
# insertTable.DatabaseConnectorDbiConnection (6.x) or insertTable.default
# (7.x); this rewrites that one statement in place so the "#" is kept when
# the underlying DBI connection is odbc's "Microsoft SQL Server" class.
# Only applied for such a connection, and the rewritten statement re-checks
# the class per call, so other connections in the same session are
# unaffected. No-op if the statement isn't found (a DatabaseConnector build
# that already keeps the "#", or a restructured one). Returns the original
# functions; pass them to .restorePatchedFunctions() to undo the patch.
.patchDbiTempTableInsert <- function(connection) {
  needed <- inherits(connection, "DatabaseConnectorDbiConnection") &&
    inherits(connection@dbiConnection, "Microsoft SQL Server")
  if (!needed) return(invisible(list()))
  # `connection` is the DatabaseConnector wrapper in 6.x, the raw DBI
  # connection in 7.x.
  .patchFunctions(
    "DatabaseConnector",
    c("insertTable.DatabaseConnectorDbiConnection", "insertTable.default"),
    target = quote(tableName <- gsub("^#", "", tableName)),
    replacement = quote(
      if (!inherits(if (methods::.hasSlot(connection, "dbiConnection"))
                      connection@dbiConnection else connection,
                    "Microsoft SQL Server"))
        tableName <- gsub("^#", "", tableName)),
    what = "to keep '#' on odbc SQL Server temp table names")
}

# CohortGenerator::getCohortInclusionRules() builds cohortDefinitionId with
# as.numeric(), and insertInclusionRuleNames() inserts that double into an
# INT64 column. BigQuery's JDBC driver rejects it ("Bad int64 value: 2.0");
# every other dialect's driver coerces it. The main pipeline avoids this by
# inserting the rows itself (R/03_main_cohorts.R), but CohortDiagnostics
# calls insertInclusionRuleNames() internally, so this rewrites that one
# as.numeric() to as.integer(). Only applied on BigQuery. No-op if the call
# isn't found (fixed upstream, or restructured). Returns the original
# functions; pass them to .restorePatchedFunctions() to undo the patch.
.patchBigQueryInclusionRuleIds <- function(connection) {
  if (.getDbms(connection) != "bigquery") return(invisible(list()))
  .patchFunctions(
    "CohortGenerator", "getCohortInclusionRules",
    target = quote(as.numeric(cohortDefinitionSet$cohortId[i])),
    replacement = quote(as.integer(cohortDefinitionSet$cohortId[i])),
    what = "to insert integer cohortDefinitionId on BigQuery")
}
