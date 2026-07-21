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
