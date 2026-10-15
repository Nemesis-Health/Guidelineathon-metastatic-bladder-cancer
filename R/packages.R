# Every package the pipeline uses. Each run script calls
# loadRequiredPackages() before anything else: it loads every package (not just
# checks it is installed) and stops listing all that are missing or fail to load,
# so a run never starts with a package that would fail later.
requiredPackages <- c(
  "DatabaseConnector", "SqlRender", "CohortGenerator", "CirceR", "ARTEMIS", "DBI",
  "dplyr", "tibble", "readr", "cli", "rlang", "stringr", "jsonlite",
  "ggplot2", "scales", "survival", "broom")

loadRequiredPackages <- function(pkgs = requiredPackages) {
  failed <- character(0)
  for (p in pkgs) {
    tryCatch(suppressPackageStartupMessages(loadNamespace(p)),
             error = function(e) failed[[p]] <<- conditionMessage(e))
  }
  if (length(failed))
    stop("Required package(s) missing or failing to load:\n",
         paste0("  - ", names(failed), ": ", failed, collapse = "\n"),
         "\nInstall them (renv::restore()) and re-run.", call. = FALSE)
  invisible(TRUE)
}
