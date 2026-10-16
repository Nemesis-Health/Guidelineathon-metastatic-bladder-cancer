-- =============================================================================
-- lab_unit_resolution.sql
-- Export of @resolved_table (written by lab_cohorts.sql step 3). One row per
-- unit-resolution group (cat, measurement_concept_id, unit_concept_id,
-- range_low, range_high): the reference range recorded in the measurement
-- table, the spread of the values as recorded (before conversion), the factor
-- applied and how it was chosen. Use it to see why a group got its factor —
-- every score can be recomputed from the range and percentiles here.
--
-- range_low / range_high are the recorded bounds when > 0, else NULL (as
-- lab_cohorts.sql groups them). p03..p97 are value_as_number, unconverted.
-- Scores are in decades from the category's normal range; NULL where a scale
-- could not be scored (concept_unit_score is NULL for concepts that state no
-- unit).
--
-- Privacy: groups with fewer than @min_cell_count DISTINCT patients are
-- censored — n_patients -> -@min_cell_count; n_records, the percentiles and
-- the scores -> NULL. The range, factor and status are kept: they describe the
-- lab's reference range and the resolver's choice, not patient values.
--
-- SqlRender parameters:
--   @work_database_schema
--   @resolved_table
--   @vocabulary_database_schema   (for concept names; LEFT JOIN, optional)
--   @min_cell_count               integer (e.g. 5)
-- =============================================================================

SELECT r.cat,
       r.m_id          AS measurement_concept_id,
       mc.concept_name AS measurement_concept_name,
       r.u_id          AS unit_concept_id,
       uc.concept_name AS unit_concept_name,
       r.rlo           AS range_low,
       r.rhi           AS range_high,
       CASE WHEN r.n_patients < @min_cell_count THEN -1 * @min_cell_count ELSE r.n_patients END AS n_patients,
       CASE WHEN r.n_patients < @min_cell_count THEN NULL ELSE r.records END                  AS n_records,
       CASE WHEN r.n_patients < @min_cell_count THEN NULL ELSE r.p03 END                      AS p03_value,
       CASE WHEN r.n_patients < @min_cell_count THEN NULL ELSE r.p25 END                      AS p25_value,
       CASE WHEN r.n_patients < @min_cell_count THEN NULL ELSE r.p75 END                      AS p75_value,
       CASE WHEN r.n_patients < @min_cell_count THEN NULL ELSE r.p97 END                      AS p97_value,
       r.factor,
       r.val_offset,
       r.status,
       r.is_ambiguous,
       CASE WHEN r.n_patients < @min_cell_count THEN NULL ELSE r.prov_score END               AS recorded_unit_score,
       CASE WHEN r.n_patients < @min_cell_count THEN NULL ELSE r.concept_score END            AS concept_unit_score,
       CASE WHEN r.n_patients < @min_cell_count THEN NULL ELSE r.best_score END               AS best_score
  FROM @work_database_schema.@resolved_table r
  LEFT JOIN @vocabulary_database_schema.concept mc ON mc.concept_id = r.m_id
  LEFT JOIN @vocabulary_database_schema.concept uc ON uc.concept_id = r.u_id
 ORDER BY r.cat, r.m_id, r.u_id, r.rlo, r.rhi;
