-- Generated from bladder_cancer_provenance.sql by translate.R for bigquery.
-- Replace @cdm_database_schema and @vocabulary_database_schema
-- before running.

-- Bladder cancer condition records for patients with metastatic bladder
-- cancer, split by provenance (condition_type_concept_id: EHR, claims,
-- registry, ...).
-- Concept set is [GDE] Bladder Cancer (codeset 5 in Target_1A.json).
-- One row per condition_type_concept_id, plus an 'ALL' row (NULL type id).
-- Counts every record for a population patient, not only those near index.
-- Population: first metastasis record per patient, measurement or condition
-- ([GDE] metastasis (measurement), codeset 0 in Target_1A.json), limited to
-- patients with a bladder cancer code ([GDE] Bladder Cancer, codeset 5) from
-- 180 days before to 30 days after it. T1A's age and other-cancer rules are not applied.
--
-- SqlRender parameters: cdm_database_schema, vocabulary_database_schema
-- Concept sets below are generated from Target_1A.json and expanded as Atlas
-- does: included concepts (with descendants where flagged), minus excluded
-- ones. Regenerate them when the Target 1A concept sets change.
with bc_concepts as (
  select i.concept_id
    from (
      select concept_id
        from @vocabulary_database_schema.concept
       where concept_id in (197508)
      union distinct select c.concept_id
        from @vocabulary_database_schema.concept c
        join @vocabulary_database_schema.concept_ancestor ca
          on ca.descendant_concept_id = c.concept_id
       where ca.ancestor_concept_id in (197508)
         and c.invalid_reason is null
    ) i
   where i.concept_id not in (4200889, 4280899, 4280900, 4280901, 4283614, 4289097, 4289374, 4312566)
     and i.concept_id not in (
       select c.concept_id
         from @vocabulary_database_schema.concept c
         join @vocabulary_database_schema.concept_ancestor ca
           on ca.descendant_concept_id = c.concept_id
        where ca.ancestor_concept_id in (4200889, 4280899, 4280900, 4280901, 4283614, 4289097, 4289374, 4312566)
          and c.invalid_reason is null)
),
-- [GDE] metastasis (measurement)
met_concepts as (
  select i.concept_id
    from (
      select concept_id
        from @vocabulary_database_schema.concept
       where concept_id in (192735, 1340420, 1346178, 1346230, 1633308, 1635142, 36769180, 37019862)
      union distinct select c.concept_id
        from @vocabulary_database_schema.concept c
        join @vocabulary_database_schema.concept_ancestor ca
          on ca.descendant_concept_id = c.concept_id
       where ca.ancestor_concept_id in (1633308, 1635142, 36769180)
         and c.invalid_reason is null
    ) i
   where i.concept_id not in (35225577, 35225579, 35225625, 35226025, 35226028, 35226041, 35226264,
                         35226304)
),
-- First metastasis record per patient, from measurements or conditions, as
-- Target 1A's entry event.
met_index as (
   select r.person_id, min(r.event_date) as index_date
     from (
      select m.person_id, m.measurement_date as event_date
        from @cdm_database_schema.measurement m
        join met_concepts mc on mc.concept_id = m.measurement_concept_id
      union all
      select co.person_id, co.condition_start_date as event_date
        from @cdm_database_schema.condition_occurrence co
        join met_concepts mc on mc.concept_id = co.condition_concept_id
    ) r
    group by  r.person_id
 ),
population as (
  select distinct mi.person_id
    from met_index mi
    join @cdm_database_schema.condition_occurrence co on co.person_id = mi.person_id
    join bc_concepts c on c.concept_id = co.condition_concept_id
   where co.condition_start_date >= DATE_ADD(IF(SAFE_CAST(mi.index_date  AS DATE) IS NULL,PARSE_DATE('%Y%m%d', cast(mi.index_date  AS STRING)),SAFE_CAST(mi.index_date  AS DATE)), INTERVAL -180 DAY)
     and co.condition_start_date <= DATE_ADD(IF(SAFE_CAST(mi.index_date  AS DATE) IS NULL,PARSE_DATE('%Y%m%d', cast(mi.index_date  AS STRING)),SAFE_CAST(mi.index_date  AS DATE)), INTERVAL 30 DAY)
),
bc as (
  select co.person_id, coalesce(cast(co.condition_type_concept_id as int64), 0) as type_concept_id
    from @cdm_database_schema.condition_occurrence co
    join bc_concepts c on c.concept_id = co.condition_concept_id
    join population p on p.person_id = co.person_id
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
