-- Target 1A denominator. SqlRender params: @work_database_schema, @cohort_table, @cohort1_id
SELECT COUNT(DISTINCT subject_id) AS n
  FROM @work_database_schema.@cohort_table
 WHERE cohort_definition_id = @cohort1_id;
