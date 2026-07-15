-- Whole-population counts of the unified eligibility table (labs 1-23/44-48 +
-- ECOG 24-27 + conditions 33-40), per test-id slot. NOT crossed with any target
-- cohort — this is the raw content of @lab_cohort_table.
--
-- SqlRender params: @work_database_schema, @lab_cohort_table
SELECT cohort_definition_id       AS test_id,
       COUNT(DISTINCT subject_id) AS n_subjects,
       COUNT(*)                   AS n_records
  FROM @work_database_schema.@lab_cohort_table
 GROUP BY cohort_definition_id
 ORDER BY cohort_definition_id;
