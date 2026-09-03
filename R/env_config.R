# ===========================================================================
# env_config.R  —  build connectionDetails + settings from a .env file
# ===========================================================================
# The CONFIG blocks in run.R / run_diagnostics_only.R / run_feasibility_only.R
# are meant to be edited by hand. This helper is the alternative for sites that
# already keep their credentials in a .env file: it fills the same two objects
# from environment variables, so nothing secret is ever typed into a tracked
# file.
#
#   source("R/env_config.R")
#   cfg <- configureFromEnv()          # reads ./.env
#   connectionDetails <- cfg$connectionDetails
#   settings          <- cfg$settings
#
# TABLE NAMES ARE DELIBERATELY *NOT* TAKEN FROM .env.  A .env written for
# OncoStudyModules carries OSM_COHORT_TABLE (e.g. "osm_cohorts"), which is a
# DIFFERENT study's cohort table living in the same work schema. Honouring it
# here would make this study generate its bladder cohorts straight over that
# table. The study's own table names (bc_cohort, bc_lab_cohort, ...) are fixed
# defaults below; pass `overrides` if you really need to change one.
#
# Variables read (schemas/ids are required, the rest have defaults):
#   OSM_DBMS, OSM_CONNECTION_STRING, OSM_USER, OSM_PASSWORD
#   OSM_SNOWFLAKE_WAREHOUSE          appended to the connection string if absent
#   DATABASECONNECTOR_JAR_FOLDER     JDBC driver folder ("~" is expanded)
#   OSM_CDM_SCHEMA, OSM_VOCAB_SCHEMA, OSM_WORK_SCHEMA
#   OSM_DATABASE_ID, OSM_MIN_CELL_COUNT, OSM_OUTPUT_FOLDER
#
# JAVA NOTE: Snowflake's JDBC driver bundles Apache Arrow, which on Java 17+
# fails ("Failed to initialize MemoryUtil") unless java.nio is opened. That must
# be set BEFORE the JVM starts, i.e. before DatabaseConnector is loaded, so it
# cannot be done from here — see setJavaOptions() below and the note at the top
# of run.R.
# ===========================================================================

#' Set the JVM options the Snowflake JDBC driver needs
#'
#' MUST be called before DatabaseConnector/rJava load, i.e. as the very first
#' statement of a fresh R session. Safe on every dialect and Java version: the
#' flag is ignored by JVMs that do not need it. A no-op (with a warning) if the
#' JVM is already running, since the options can no longer take effect.
#'
#' @param maxHeap optional heap cap, e.g. "4g". NULL (default) leaves it to the JVM.
setJavaOptions <- function(maxHeap = NULL) {
  if (isTRUE(requireNamespace("rJava", quietly = TRUE)) &&
      !is.null(getOption("java.parameters")) &&
      length(getLoadedDLLs()[["rJava"]]) > 0L) {
    warning("The JVM is already running — java.parameters can no longer be ",
            "changed. Restart R and call setJavaOptions() first.", call. = FALSE)
    return(invisible(FALSE))
  }
  opts <- "--add-opens=java.base/java.nio=ALL-UNNAMED"
  if (!is.null(maxHeap)) opts <- c(opts, paste0("-Xmx", maxHeap))
  options(java.parameters = opts)
  invisible(TRUE)
}

#' Build connectionDetails + settings from a .env file
#'
#' @param envFile   path to the .env file (default ".env"). Read with
#'   [readRenviron()], so `KEY=value` lines and `#` comments both work.
#' @param overrides named list merged over the derived `settings` (e.g.
#'   `list(minCellCount = 1L)`).
#' @return list with `connectionDetails` and `settings`, shaped exactly like the
#'   CONFIG block of run.R.
configureFromEnv <- function(envFile = ".env", overrides = list()) {
  if (!file.exists(envFile))
    stop("No .env file at '", envFile, "'. Copy .env.example and fill it in, ",
         "or edit the CONFIG block in run.R by hand.", call. = FALSE)
  readRenviron(envFile)

  need <- function(key) {
    v <- Sys.getenv(key)
    if (!nzchar(v)) stop("Missing required variable '", key, "' in ", envFile,
                         call. = FALSE)
    v
  }

  jar <- path.expand(Sys.getenv("DATABASECONNECTOR_JAR_FOLDER", "~/.jdbc_drivers"))
  Sys.setenv(DATABASECONNECTOR_JAR_FOLDER = jar)

  dbms <- need("OSM_DBMS")
  cs   <- need("OSM_CONNECTION_STRING")
  # Snowflake needs a warehouse; fold it into the connection string if the URL
  # does not already name one.
  wh <- Sys.getenv("OSM_SNOWFLAKE_WAREHOUSE")
  if (nzchar(wh) && !grepl("warehouse=", cs, ignore.case = TRUE))
    cs <- paste0(cs, if (grepl("\\?", cs)) "&" else "?", "warehouse=", wh)

  connectionDetails <- DatabaseConnector::createConnectionDetails(
    dbms = dbms, connectionString = cs,
    user = need("OSM_USER"), password = need("OSM_PASSWORD"),
    pathToDriver = jar)

  cdmSchema <- need("OSM_CDM_SCHEMA")
  settings <- list(
    databaseId          = Sys.getenv("OSM_DATABASE_ID", "UNKNOWN"),
    cdmDatabaseSchema   = cdmSchema,
    vocabDatabaseSchema = Sys.getenv("OSM_VOCAB_SCHEMA", cdmSchema),
    workDatabaseSchema  = need("OSM_WORK_SCHEMA"),

    # --- study-owned work tables: fixed, NOT read from .env (see header) -----
    cohortTable          = "bc_cohort",
    labCohortTable       = "bc_lab_cohort",
    rawLabResultsTable   = "bc_raw_lab_results",
    covariateCohortTable = "bc_covariate_cohort",
    artemisCohortName    = "ARTEMIS bladder cohort",
    episodeTable         = "bc_artemis_episodes",
    regimenClassTable    = "bc_regimen_classifications",

    # --- run settings: same defaults as run.R's CONFIG block -----------------
    minCellCount        = as.integer(Sys.getenv("OSM_MIN_CELL_COUNT", "5")),
    labWindowBeforeDays = 14L,
    labWindowAfterDays  = 7L,
    stripEndocrineTherapy       = TRUE,
    validDrugsRegimenComponents = TRUE,
    validDrugsAtcClasses        = c("L01", "L02", "L03", "L04"),
    assessmentAtcClasses        = NULL,
    outputFolder        = Sys.getenv("OSM_OUTPUT_FOLDER", "results"))

  if (length(overrides)) {
    stopifnot(!is.null(names(overrides)), all(nzchar(names(overrides))))
    settings[names(overrides)] <- overrides
  }

  message("Config from ", envFile, ": dbms=", dbms,
          ", cdm=", settings$cdmDatabaseSchema,
          ", work=", settings$workDatabaseSchema,
          ", cohortTable=", settings$cohortTable,
          ", minCellCount=", settings$minCellCount)
  list(connectionDetails = connectionDetails, settings = settings)
}
