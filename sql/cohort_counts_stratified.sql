-- For every cohort in @cohort_table, distinct-subject counts split by
-- subject_strata.sql's age_group / sex / age_sex (subject_strata.sql --
-- see that file's header for the standard consumption pattern this
-- follows). The "overall" view is NOT computed here -- R/03_main_cohorts.R
-- already has it from CohortGenerator::getCohortCounts() and reshapes that
-- into the same long format instead of re-deriving it, so the two stay
-- consistent by construction rather than by cross-checking two counts.
--
-- Output columns: stratum_type, stratum_value, cohort_definition_id,
--                  n_entries, n_subjects
--
-- SqlRender parameters:
--   @work_database_schema @cohort_table
--   subject_strata_sql (pre-rendered fragment, not a plain schema/table
--   name -- see the `strata` CTE below): subject_strata.sql's own output,
--   age_group/sex/age_sex per (cohort_definition_id, subject_id)
-- =============================================================================

WITH strata AS (
  @subject_strata_sql
),
tagged AS (
  SELECT 'age_group' AS stratum_type, age_group AS stratum_value, cohort_definition_id, subject_id
    FROM strata
  UNION ALL
  SELECT 'sex' AS stratum_type, sex AS stratum_value, cohort_definition_id, subject_id
    FROM strata
  UNION ALL
  SELECT 'age_sex' AS stratum_type, age_sex AS stratum_value, cohort_definition_id, subject_id
    FROM strata
)
SELECT stratum_type,
       stratum_value,
       cohort_definition_id,
       COUNT(*)                   AS n_entries,
       COUNT(DISTINCT subject_id) AS n_subjects
  FROM tagged
-- Qualified with the `tagged` CTE name rather than bare column names:
-- BigQuery-only fix, see docs/BIGQUERY.md (SqlRender's ordinal-GROUP-BY
-- rewrite for this dialect can mis-resolve bare GROUP BY columns onto an
-- aggregate expression's position, which BigQuery then rejects outright).
 GROUP BY tagged.stratum_type, tagged.stratum_value, tagged.cohort_definition_id
 ORDER BY cohort_definition_id, stratum_type, stratum_value;
