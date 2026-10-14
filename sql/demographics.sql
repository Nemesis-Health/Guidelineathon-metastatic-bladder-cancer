-- =============================================================================
-- demographics.sql — per-cohort demographic strata counts
-- =============================================================================
-- For every cohort in @cohort_table, count subjects by:
--   * age group at index   (>65 / <=65, age = year(index) - year_of_birth)
--   * sex                  (Male / Female / Other-Unknown)
--   * age band             (<=65 / 66-80 / >80)
--   * index period         (2015-2020 / 2021-2023 / 2024+, and 2015-2020 / 2021+)
--   * index year           (year of cohort_start_date)
--
-- Emitted long/tidy so one template covers all of them:
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
-- age band at index (<=65 / 66-80 / >80)
SELECT cohort_definition_id,
       'age_band' AS characteristic,
       coh.age_band AS stratum,
       CASE coh.age_band WHEN '<=65' THEN 1 WHEN '66-80' THEN 2 ELSE 3 END AS sort_key,
       COUNT(*) AS n_subjects
  FROM coh
 GROUP BY cohort_definition_id,
          coh.age_band,
          CASE coh.age_band WHEN '<=65' THEN 1 WHEN '66-80' THEN 2 ELSE 3 END

UNION ALL
-- index period (2015-2020 / 2021-2023 / 2024+)
SELECT cohort_definition_id,
       'index_period' AS characteristic,
       coh.index_period AS stratum,
       CASE coh.index_period WHEN '<2015' THEN 0 WHEN '2015-2020' THEN 1 WHEN '2021-2023' THEN 2 ELSE 3 END AS sort_key,
       COUNT(*) AS n_subjects
  FROM coh
 GROUP BY cohort_definition_id,
          coh.index_period,
          CASE coh.index_period WHEN '<2015' THEN 0 WHEN '2015-2020' THEN 1 WHEN '2021-2023' THEN 2 ELSE 3 END

UNION ALL
-- index period, 2021 split (2015-2020 / 2021+)
SELECT cohort_definition_id,
       'index_period_2021' AS characteristic,
       coh.index_period_2021 AS stratum,
       CASE coh.index_period_2021 WHEN '<2015' THEN 0 WHEN '2015-2020' THEN 1 ELSE 2 END AS sort_key,
       COUNT(*) AS n_subjects
  FROM coh
 GROUP BY cohort_definition_id,
          coh.index_period_2021,
          CASE coh.index_period_2021 WHEN '<2015' THEN 0 WHEN '2015-2020' THEN 1 ELSE 2 END

UNION ALL
-- index year
-- coh.index_year (qualified) rather than bare `index_year`: BigQuery-only
-- fix -- SqlRender's ordinal-GROUP-BY rewrite for this dialect resolves a
-- bare GROUP BY column by a plain substring search over the SELECT list --
-- since the bare column's own name is also a substring of the CAST(...)
-- expression earlier in the same SELECT list, it matched that expression's
-- position instead of its own, producing `GROUP BY 1, 3, 3` (duplicated,
-- dropping the real 4th grouping column) instead of `1, 3, 4`. Qualifying
-- makes it a dotted `alias.column` reference, which the rewrite copies
-- straight through untouched instead of searching for it.
SELECT cohort_definition_id,
       'index_year' AS characteristic,
       CAST(coh.index_year AS VARCHAR(4)) AS stratum,
       coh.index_year                     AS sort_key,
       COUNT(*)                           AS n_subjects
  FROM coh
 GROUP BY cohort_definition_id,
          CAST(coh.index_year AS VARCHAR(4)),
          coh.index_year
;
