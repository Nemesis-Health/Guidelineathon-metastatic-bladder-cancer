-- =============================================================================
-- demographics.sql — per-cohort demographic strata counts
-- =============================================================================
-- For every cohort in @cohort_table, count subjects by:
--   * age group at index   (>65 / <=65, age = year(index) - year_of_birth)
--   * sex                  (Male / Female / Other-Unknown)
--   * index year           (year of cohort_start_date)
--
-- Emitted long/tidy so one template covers all three:
--   (cohort_definition_id, characteristic, stratum, sort_key, n_subjects)
-- Percentages are computed in R (within cohort x characteristic; denominator =
-- cohort N) and small cells are censored there.
--
-- The `coh` CTE body below is sql/subject_strata.sql's own query text,
-- already fully rendered (its own schema/table placeholders resolved) and
-- injected verbatim by R/07_demographics.R, so the age_group/sex bucketing
-- has exactly one source of truth -- see subject_strata.sql's own header
-- for the full list of consumers.
--
-- SqlRender parameter (pre-rendered fragment, not a plain schema/table
-- name -- see above): subject_strata_sql
-- =============================================================================

WITH coh AS (
  @subject_strata_sql
)
-- age group at index
SELECT cohort_definition_id,
       'age_group' AS characteristic,
       age_group   AS stratum,
       CASE WHEN age_group = '>65' THEN 2 ELSE 1 END AS sort_key,
       COUNT(*)                                      AS n_subjects
  FROM coh
 GROUP BY cohort_definition_id,
          age_group,
          CASE WHEN age_group = '>65' THEN 2 ELSE 1 END

UNION ALL
-- sex
SELECT cohort_definition_id,
       'sex' AS characteristic,
       sex   AS stratum,
       CASE sex WHEN 'Male' THEN 1 WHEN 'Female' THEN 2 ELSE 3 END AS sort_key,
       COUNT(*)                                                    AS n_subjects
  FROM coh
 GROUP BY cohort_definition_id,
          sex,
          CASE sex WHEN 'Male' THEN 1 WHEN 'Female' THEN 2 ELSE 3 END

UNION ALL
-- index year
SELECT cohort_definition_id,
       'index_year' AS characteristic,
       CAST(index_year AS VARCHAR(4)) AS stratum,
       index_year                     AS sort_key,
       COUNT(*)                       AS n_subjects
  FROM coh
 GROUP BY cohort_definition_id,
          CAST(index_year AS VARCHAR(4)),
          index_year
;
