-- Generated from other_malignancy_provenance.sql by translate.R for bigquery.
-- Replace @cdm_database_schema and @vocabulary_database_schema
-- before running.

-- "Other malignancy" condition records for patients with metastatic bladder
-- cancer, split by provenance (condition_type_concept_id: EHR, claims,
-- registry, ...).
-- Concept set is [GDE] Excluded primaries (codeset 3 in Target_1A.json), the
-- set T1A's "no other cancer" rule excludes on.
-- One row per condition_type_concept_id, plus an 'ALL' row (NULL type id).
-- Counts every record for a population patient, not only those near index.
-- Population: first metastasis measurement per patient ([GDE] metastasis
-- (measurement), codeset 0 in Target_1A.json), limited to patients with a
-- bladder cancer code ([GDE] Bladder Cancer, codeset 5) from 180 days before
-- to 30 days after it. T1A's age and other-cancer rules are not applied.
--
-- SqlRender parameters: cdm_database_schema, vocabulary_database_schema
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
met_index as (
   select m.person_id, min(m.measurement_date) as index_date
     from @cdm_database_schema.measurement m
   where m.measurement_concept_id in (
     select descendant_concept_id
       from @vocabulary_database_schema.concept_ancestor
      where ancestor_concept_id in (1633308, 1635142, 36769180))
    group by  m.person_id
 ),
population as (
  select distinct mi.person_id
    from met_index mi
    join @cdm_database_schema.condition_occurrence co on co.person_id = mi.person_id
    join bc_concepts c on c.concept_id = co.condition_concept_id
   where co.condition_start_date >= DATE_ADD(IF(SAFE_CAST(mi.index_date  AS DATE) IS NULL,PARSE_DATE('%Y%m%d', cast(mi.index_date  AS STRING)),SAFE_CAST(mi.index_date  AS DATE)), INTERVAL -180 DAY)
     and co.condition_start_date <= DATE_ADD(IF(SAFE_CAST(mi.index_date  AS DATE) IS NULL,PARSE_DATE('%Y%m%d', cast(mi.index_date  AS STRING)),SAFE_CAST(mi.index_date  AS DATE)), INTERVAL 30 DAY)
),
om_concepts as (
  select i.concept_id
    from (
      select descendant_concept_id as concept_id
        from @vocabulary_database_schema.concept_ancestor
       where ancestor_concept_id = 443392
      union distinct select concept_id
        from @vocabulary_database_schema.concept
       where concept_id in (4200889, 4280899, 4289374, 4280900, 4283614,
                            4289097, 4280901, 4312566)
    ) i
   where i.concept_id not in (443392, 1244789, 4180915, 40488919, 40492037,
                              4177236, 200680, 37164585, 37163865, 37163178,
                              42513090, 42513091, 42513085, 44500641, 37166564,
                              37166563, 37166559, 37110270, 36563190, 36537757,
                              36402643)
     and i.concept_id not in (
       select descendant_concept_id
         from @vocabulary_database_schema.concept_ancestor
        where ancestor_concept_id in (197508, 4112752, 4111921))
),
om as (
  select co.person_id, coalesce(cast(co.condition_type_concept_id as int64), 0) as type_concept_id
    from @cdm_database_schema.condition_occurrence co
    join om_concepts c on c.concept_id = co.condition_concept_id
    join population p on p.person_id = co.person_id
),
counts as (
   select type_concept_id,
         count(distinct person_id) as n_patients, count(*) as n_records
     from om
    group by  om.type_concept_id
  union all
  select cast(null  as int64) as type_concept_id, count(distinct person_id) as n_patients, count(*) as n_records
    from om
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
