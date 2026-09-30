-- Generated from bladder_cancer_provenance.sql by translate.R for bigquery.
-- Replace @cdm_database_schema, @vocabulary_database_schema and
-- @cohort_database_schema before running.

-- Bladder cancer condition records for patients in an already generated
-- cohort (e.g. Target 1A), split by provenance
-- (condition_type_concept_id: EHR, claims, registry, ...).
-- Concept set is [GDE] Bladder Cancer (codeset 5 in Target_1A.json).
-- One row per condition_type_concept_id, plus an 'ALL' row (NULL type id).
-- Counts every record for a cohort patient, not only those near index.
--
-- SqlRender parameters: cdm_database_schema, vocabulary_database_schema,
--   cohort_database_schema, cohort_table, cohort_id
-- Defaults: run.R's cohort table, and Target 1A's id (JSON cohorts are
-- numbered from 1 in sorted file order; Target_1A.json sorts first).
with bc_concepts as (
  select ca.descendant_concept_id as concept_id
    from @vocabulary_database_schema.concept_ancestor ca
   where ca.ancestor_concept_id = 197508
     and ca.descendant_concept_id not in (
       select descendant_concept_id
         from @vocabulary_database_schema.concept_ancestor
        where ancestor_concept_id in (4200889, 4280899, 4289374, 4280900,
                                      4283614, 4289097, 4280901, 4312566))
),
bc as (
  select co.person_id, coalesce(cast(co.condition_type_concept_id as int64), 0) as type_concept_id
    from @cdm_database_schema.condition_occurrence co
    join bc_concepts c on c.concept_id = co.condition_concept_id
    join (select distinct subject_id
            from @cohort_database_schema.bc_cohort
           where cohort_definition_id = 1) coh
      on coh.subject_id = co.person_id
),
counts as (
   select type_concept_id,
         count(distinct person_id) as n_patients, count(*) as n_records
     from bc
    group by  bc.type_concept_id
  union all
  select cast(null  as int64) as type_concept_id, count(distinct person_id) as n_patients, count(*) as n_records
    from bc
 )
 select t.type_concept_id,
       case when t.type_concept_id is null then 'ALL'
            else coalesce(c.concept_name, 'Not in vocabulary') end as type_concept_name,
       t.n_patients,
       t.n_records
   from counts t
  left join @vocabulary_database_schema.concept c
    on c.concept_id = t.type_concept_id
  order by  t.n_records desc ;
