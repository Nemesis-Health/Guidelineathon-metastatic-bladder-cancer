# ===========================================================================
# fix_cohort_counts.R — repair a malformed cohort_counts.csv
# ===========================================================================
# Older runs (CohortGenerator whose getCohortCounts() merged the whole
# cohortDefinitionSet) wrote cohort_counts.csv with a duplicated name column
# and the full SQL/JSON dumped in:
#   cohortId, cohortName.x, cohortEntries, cohortSubjects, cohortName.y, sql, json
# This rewrites it to the intended 4-column schema:
#   cohortId, cohortName, cohortEntries, cohortSubjects
#
# The counts themselves were always correct — this only trims columns, so no
# re-run is needed. Pure post-processing: NO database connection required.
# Idempotent: running it on an already-clean file leaves it unchanged.
#
# Usage: set the paths below, then  source("fix_cohort_counts.R")
# ===========================================================================

if (!requireNamespace("readr", quietly = TRUE))
  stop("Required package not installed: readr", call. = FALSE)

# --- paths [EDIT HERE] -----------------------------------------------------
inputPath  <- file.path("results", "csv", "cohort_counts.csv")
outputPath <- inputPath            # overwrite in place; set elsewhere to keep the original

# ---------------------------------------------------------------------------
if (!file.exists(inputPath))
  stop("cohort_counts.csv not found at: ", inputPath, call. = FALSE)

df <- readr::read_csv(inputPath, show_col_types = FALSE, progress = FALSE)

# the real name is cohortName (clean file) or cohortName.x (post-merge file)
nameCol <- intersect(c("cohortName", "cohortName.x"), names(df))[1]
required <- c("cohortId", "cohortEntries", "cohortSubjects")
missingCols <- setdiff(required, names(df))
if (is.na(nameCol) || length(missingCols) > 0L)
  stop("unexpected columns in ", inputPath, " — have: ",
       paste(names(df), collapse = ", "), call. = FALSE)

clean <- data.frame(
  cohortId       = as.integer(df[["cohortId"]]),
  cohortName     = as.character(df[[nameCol]]),
  cohortEntries  = as.integer(df[["cohortEntries"]]),
  cohortSubjects = as.integer(df[["cohortSubjects"]]),
  stringsAsFactors = FALSE
)

readr::write_csv(clean, outputPath, na = "")
message("Fixed cohort_counts: ", nrow(clean), " rows x 4 cols -> ", outputPath,
        if (identical(inputPath, outputPath)) "  (overwritten in place)" else "")
