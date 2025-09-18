CREATE TEMP TABLE isap3ti5Codesets  (codeset_id int NOT NULL,
  concept_id bigint NOT NULL
)
;
INSERT INTO isap3ti5Codesets (codeset_id, concept_id)
SELECT 0 as codeset_id, c.concept_id FROM (select distinct I.concept_id FROM
( 
  select concept_id from @vocabulary_database_schema.CONCEPT where (concept_id in (4245697,192735,3018082,3663237,4032806,36769180,4201930,432851))
UNION  select c.concept_id
  from @vocabulary_database_schema.CONCEPT c
  join @vocabulary_database_schema.CONCEPT_ANCESTOR ca on c.concept_id = ca.descendant_concept_id
  WHERE c.invalid_reason is null
  and (ca.ancestor_concept_id in (4032806,36769180,4201930,432851))
) I
LEFT JOIN
(
  select concept_id from @vocabulary_database_schema.CONCEPT where (concept_id in (35226041))
UNION  select c.concept_id
  from @vocabulary_database_schema.CONCEPT c
  join @vocabulary_database_schema.CONCEPT_ANCESTOR ca on c.concept_id = ca.descendant_concept_id
  WHERE c.invalid_reason is null
  and (ca.ancestor_concept_id in (35226041))
) E ON I.concept_id = E.concept_id
WHERE E.concept_id is null
) C UNION ALL 
SELECT 1 as codeset_id, c.concept_id FROM (select distinct I.concept_id FROM
( 
  select concept_id from @vocabulary_database_schema.CONCEPT where (concept_id in (4129897,37166150,197508,4131002,4131749,4112957,42709928,4131004,200680,4131003,42514485,4131750,4177067,4130527,4104155))
UNION  select c.concept_id
  from @vocabulary_database_schema.CONCEPT c
  join @vocabulary_database_schema.CONCEPT_ANCESTOR ca on c.concept_id = ca.descendant_concept_id
  WHERE c.invalid_reason is null
  and (ca.ancestor_concept_id in (197508,4112957))
) I
LEFT JOIN
(
  select concept_id from @vocabulary_database_schema.CONCEPT where (concept_id in (4280899,4289374,4280900,4283614,4289097,4280901,4289376))
UNION  select c.concept_id
  from @vocabulary_database_schema.CONCEPT c
  join @vocabulary_database_schema.CONCEPT_ANCESTOR ca on c.concept_id = ca.descendant_concept_id
  WHERE c.invalid_reason is null
  and (ca.ancestor_concept_id in (4280899,4289374,4280900,4283614,4289097,4280901,4289376))
) E ON I.concept_id = E.concept_id
WHERE E.concept_id is null
) C UNION ALL 
SELECT 4 as codeset_id, c.concept_id FROM (select distinct I.concept_id FROM
( 
  select concept_id from @vocabulary_database_schema.CONCEPT where (concept_id in (21601387))
UNION  select c.concept_id
  from @vocabulary_database_schema.CONCEPT c
  join @vocabulary_database_schema.CONCEPT_ANCESTOR ca on c.concept_id = ca.descendant_concept_id
  WHERE c.invalid_reason is null
  and (ca.ancestor_concept_id in (21601387))
) I
) C UNION ALL 
SELECT 5 as codeset_id, c.concept_id FROM (select distinct I.concept_id FROM
( 
  select concept_id from @vocabulary_database_schema.CONCEPT where (concept_id in (1397599))
UNION  select c.concept_id
  from @vocabulary_database_schema.CONCEPT c
  join @vocabulary_database_schema.CONCEPT_ANCESTOR ca on c.concept_id = ca.descendant_concept_id
  WHERE c.invalid_reason is null
  and (ca.ancestor_concept_id in (1397599))
) I
) C UNION ALL 
SELECT 6 as codeset_id, c.concept_id FROM (select distinct I.concept_id FROM
( 
  select concept_id from @vocabulary_database_schema.CONCEPT where (concept_id in (37498261))
UNION  select c.concept_id
  from @vocabulary_database_schema.CONCEPT c
  join @vocabulary_database_schema.CONCEPT_ANCESTOR ca on c.concept_id = ca.descendant_concept_id
  WHERE c.invalid_reason is null
  and (ca.ancestor_concept_id in (37498261))
) I
) C UNION ALL 
SELECT 7 as codeset_id, c.concept_id FROM (select distinct I.concept_id FROM
( 
  select concept_id from @vocabulary_database_schema.CONCEPT where (concept_id in (1344905))
UNION  select c.concept_id
  from @vocabulary_database_schema.CONCEPT c
  join @vocabulary_database_schema.CONCEPT_ANCESTOR ca on c.concept_id = ca.descendant_concept_id
  WHERE c.invalid_reason is null
  and (ca.ancestor_concept_id in (1344905))
) I
) C UNION ALL 
SELECT 8 as codeset_id, c.concept_id FROM (select distinct I.concept_id FROM
( 
  select concept_id from @vocabulary_database_schema.CONCEPT where (concept_id in (955128,42629079,1593273,35200783,1536789,1594034,45892628,45775965,36862604,1302024,36861273,36854773,747052))
UNION  select c.concept_id
  from @vocabulary_database_schema.CONCEPT c
  join @vocabulary_database_schema.CONCEPT_ANCESTOR ca on c.concept_id = ca.descendant_concept_id
  WHERE c.invalid_reason is null
  and (ca.ancestor_concept_id in (955128,42629079,1593273,35200783,1536789,1594034,45892628,45775965,36862604,1302024,36861273,36854773,747052))
) I
) C UNION ALL 
SELECT 9 as codeset_id, c.concept_id FROM (select distinct I.concept_id FROM
( 
  select concept_id from @vocabulary_database_schema.CONCEPT where (concept_id in (1635142,1633987))
UNION  select c.concept_id
  from @vocabulary_database_schema.CONCEPT c
  join @vocabulary_database_schema.CONCEPT_ANCESTOR ca on c.concept_id = ca.descendant_concept_id
  WHERE c.invalid_reason is null
  and (ca.ancestor_concept_id in (1635142,1633987))
) I
) C UNION ALL 
SELECT 10 as codeset_id, c.concept_id FROM (select distinct I.concept_id FROM
( 
  select concept_id from @vocabulary_database_schema.CONCEPT where (concept_id in (443392))
UNION  select c.concept_id
  from @vocabulary_database_schema.CONCEPT c
  join @vocabulary_database_schema.CONCEPT_ANCESTOR ca on c.concept_id = ca.descendant_concept_id
  WHERE c.invalid_reason is null
  and (ca.ancestor_concept_id in (443392))
) I
LEFT JOIN
(
  select concept_id from @vocabulary_database_schema.CONCEPT where (concept_id in (200680,4112878,4054839,4054503,4111921,4112752,432851,443392,40488919,4091486,4154630,79768,76349,4111019,4180915,73720,197508,4169598,37163865,37164585,37166263,36528947,37109929,36561281,37110270,37110269,36520384,36562638,36521801,36546495,36546489,36562880,36537757,44501785,44502866,36524925,36568323,36560271,37166564,37166563,36684472,197506,40492037,197804,4312698,4164740,4029008,4183317,4097305,4209587,4022895,4241843,36552731,4211683,36523889,4012173,4240952,4291452,44500970,4321558,443571,4224483,4321680,4148292,37116954,730578,44498962,4102135,4147383,4275876,4182528,4199584,4217518,4101758,45773097,4221403,4029013,36517154,44499562,44501446,44501854,44502178,44502547,36557659,44499447,44502954,44500147,4228806,4266203,4331315,4028699,4029971,4232456,45766411,43021852,4299429,443708,4178897,44500251,36535419,36402369,4319145,4268158,604497,37162300,37162050,40481908,763049,45773365,37165127,4301510,1244565,4281526,4029975,4247921,4253608,4221128,4131008,81251,36550728,44501954,44502632,36531549,44501955,4028533,42872899,4172953,46270937,4093456,4099473,4050004,4028727,44501338,44500010,44502929,44499431,36527543,44501258,4251325,3655266,761025,36715827,4219855,4215373,4236657,36403065,36402994,4227888,4252424,4252582,4078953,4097829,44503077,196758,36523595,4102460,4112744,36403050,36403028,36403071,135496,141816,140672,37160492,135762,764781,4138903,764782,4142105,4137687,36402997,36403059,36403077,36403012,36402991,36403070,36403044,36403007,36403014,36403066,36403006,36403031,36403020,36403061,36403004,36403009,36403056,36403010,36403042,36403046,36403036,36403143,36403115,36403083,36403138,36403141,36403128,36403152,36403107,36403090,36403132,36403091,36403142,36403134,36403148,36403120,36403095,36403112,36403093,36403139,36403145,36403109,36403026,36403058,42512800,42511869,42512038,42511724,42511824,42511643,36403149,42512747,42512286,42512532,42512028,36403081,36545056,36532752,36554769,36553777,36543155,36563666,36525540,36565403,36535725,36547839,36557552,36547549,44505878,36522119,36532141,36553815,36564400,36524646,42511669,604486,2107009,4138466,4142254,36545491,36526461,36550465,36552865,36552945,36545531,36521438,36532117,36553084,36565932,36403034,36402992,36403054,36403041,36403043,36528151,36529096,36555888,36524091,1244879,1244775,36403073,36538501,36534663,42511778,36518381,36543878,37312023,760943,36403030,36526817,36546376,36555572,36528068,36527432,36545388,36551901,36566304,36562112,36556046,36544786,36566999,36537652,36518488,36535897,36559125,36403024,36542467,36518058,36403117,36403102,36554746,36523953,36545327,36558390,36565429,36544770,36525938,36555784,36560013,36552727,36561130,36517482,36566425,36532347,3168654,1553469,134597,133438,132572,36402628,36547771,36565379,36555933,36540518,4112743,36546819,36555410,36519300,36550184,36550116,36565825,36531164,36523994,36533483,36528792,36561923,36547188,42512284,36402510,42512231,36402507,36402419,42512183,42512174,42512287,36402443,42512788,42511619,36402670,42512134,42512755,42511690,36554830,36525192,37018868,36537920,36545299,36544171,36560515,36561664,36552337,36558068,36522171,36532502,36560592,36403078,36531542,36533335,36565314,36541353,36534283,36532740,36565573,36530411,4139358,2106968,2106967,766258,37171452,36565757,36520974,36538047,36533991,36533539,36561811,36562645,36529738,36565742,36519422,36525362,36558760,36530134,36545208,36547208,36545443,36557040,36557150,606916,36541600,36560626,36554502,36544147,36544987,36530066,36555264,36518810,36531215,36558349,36402440,36533120,36554418,36560837,36541707,36543287,36552223,36551832,36519502,36540957,36548503,36540634,36545511,36522874,36563990,36533632,36560451,36556990,36520491,36537536,36530073,36534482,36540373,36542732,36546867,36548989,36536468,36540912,36518220,36518977,36561178,36533613,36550020,36523764,36530007,4144302,1553289,1553529,1553370,1553256,1553494,1553334,1553464,1553172,1553539,1553560,1553330,1553505,1553419,1553108,1553465,1553074,1553065,1553243,1553264,1553509,1553393,1553409,36564210,36541151,42512131,36403047,36564329,36526323,44500897,36538081,36538235,36524807,36524214,36554048,36564162,44500665,36528724,36559650,36567163,37311926,36520824,36549911,44504818,44503289,44503267,42511900,44505378,36537400,36544522,36520594,36565101,36522997,36543264,36551759,36529060,36522762,135766,36540487,36556112,36530365,36548560,36556770,36558329,36567853,36536446,134596,36559483,36531733,36543554,36552042,36538544,36555778,4142582,36528600,36546958,36526823,36546510,36538660,36523599,36548464,36565612,36539739,36542263,36565603,36520518,36542581,36565640,37172812,37172814,37175247,37168468,37172171,36518938,36561735,36541875,36537679,36529765,36518365,36544957,36529964,36526075,36553143,4177236,36554165,36543199,36518752,36535011,36533293,36560243,36524112,36566747,36518582,36527244,36520100,36553071,36567570,136930,36403129,36403013,36403049,36543046,36526230,36539935,36561799,36520116,36555117,36531324,36550168,36539172,36525345,36531809,36522266,36544326,36551405,36563125,36552501,36542944,36538812,36548229,36525456,36523697,36525542,36517375,36549242,36560799,36550351,44501017,36557063,36541126,36561726,36563603,36563808,36535174,36566627,36540030,36545730,36541573,36565834,36402466,436059,132850,36561185,36546057,36525486,36557453,132575,44503315,36558229,36547379,36527746,36524928,42512359,42512823,36536869,36539593,36539131,36561292,36532666,36549481,36560968,36537846,42514272,42514300,42514189,42514287,42514069,42514087,42514264,42513173,42513168,42514220,42514355,42514250,42514252,42514379,42514157,42513409,42514198,42514195,42514109,42514206,42514341,42514251,42514168,42514350,42514129,42514156,42514102,42514291,42514378,42514367,42514217,42514372,42514165,42513537,42514202,42513042,42514326,42514143,42514304,42514276,42514373,42514103,42514334,42514256,42514182,42513234,42514239,42514278,42514160,42514093,42513943,42514097,42513668,42514376,42514163,42514297,42514369,42514178,42514307,42514214,42514208,42514263,42514201,42514303,42513321,42514290,42514100,42514327,42514271,42514329,42513212,42514144,42514240,42514254,42514294,42514170,42514104,42514126,42514374,42514199,42514338,42514315,42514173,42514089,42514225,42514131,42514277,42514231,42514181,42514179,42513539,42514150,42514108,42514141,42514091,42514232,42514260,42514302,42514191,42513812,42514365,42514136,42514237,42514325,42514337,42514359,42514110,42514324,42514228,42514098,42514048,42514137,42514218,42514125,42514080,42514209,42514280,42514352,42514357,42514348,42514335,42514305,36526004,36532483,36555521,36534287,36535801,36528942,36544984,36560193,36533235,36547952,36553801,603291,3171629,36549766,36527554,36403017,36403027,42512152,36403025,36403064,42512981,42511959,42512883,42512099,36403029,36403032,36402451,36402490,36546981,42512086,36402624,36402560,42512559,42512191,36402476,36522309,36528652,36402509,36546874,36545970,1553098,1553371,1553190,1553376,1553489,1553474,1553411,1553279,1553313,1553215,1553337,1553089,1553513,1553049,1553360,1553431,1553392,1553433,1553245,1553507,1553160,1553040,1553086,1553485,1553187,1553324,36550535,36557657,133158,36539886,36554909,36402513,36561680,36526182,36402587,36535088,36565710,36525326,36561501,36517968,36550280,1245472,36529020,36557227,36564495,36532545,4138752,36538320,36528711,36524767,36539414,37166241,37166239,439392,198988,602119,609194,37169372,37169734,37168806,618470,608887,37174276,609127,605480,36712745,602162,605478,609042,608888,37172725,609128,602166,36717261,602170,602164,37166561,36552390,36556439,1553578,36536309,36555426,36557282,36559468,36553463,36545263,36526125,36562472,36564150,36546841,42512566,36403189,36534041,36564803,36541479,42512846,36557248,36563433,36523060,36545860,36551120,36544282,36560981,3180823,36527057,36541026,36554935,36529347,36548698,36531688,36532837,36560304,36563222,36551032,36565866,36553649,36543309,36526352,36403151,36403082,36403123,36403080,36531903,36533575,36520282,36567169,4111221,4295624,4298026,4298028,4109067,4308621,4300557,4115027,36402645,36551620,36547362,36557645,36553800,36554739,36548685,4143848,4139054,36566961,36555020,36403076,36403068,36403039,36403048,36403033,36403057,36403001,36403069,36403072,36403003,36524038,36538449,36566969,36562164,36548931,36545269,604487,36553770,36521100,36566028,36565741,36525376,36558855,36565707,36543458,4143997,36538692,36528687,37163176,36402417,36402373,36527363,36559938,36568060,36518999,36533611,42512691,36402391,36402644,36525107,36531413,36552712,36556673,36541346,36557800,4298029,37163178,36402629,42513101,42513095,42513384,42513012,42513618,42513203,42513027,42513188,42513329,42513158,42513181,42513030,42513308,42513034,42513045,42513046,42514138,42513091,3168024,37166559) or concept_id in (37166329,36712771,4300118,36402643,42514169,42514212,42514175,42514215,42514107,4163261,4183913,4289246,4283740,4280897,4289379))
UNION  select c.concept_id
  from @vocabulary_database_schema.CONCEPT c
  join @vocabulary_database_schema.CONCEPT_ANCESTOR ca on c.concept_id = ca.descendant_concept_id
  WHERE c.invalid_reason is null
  and (ca.ancestor_concept_id in (200680,4111921,4112752,432851,4091486,197508,4163261))
) E ON I.concept_id = E.concept_id
WHERE E.concept_id is null
) C;
CREATE TEMP TABLE isap3ti5qualified_events
AS
SELECT
event_id, person_id, start_date, end_date, op_start_date, op_end_date, visit_occurrence_id
FROM
(
  select pe.event_id, pe.person_id, pe.start_date, pe.end_date, pe.op_start_date, pe.op_end_date, row_number() over (partition by pe.person_id order by pe.start_date ASC) as ordinal, cast(pe.visit_occurrence_id as bigint) as visit_occurrence_id
  FROM (-- Begin Primary Events
select P.ordinal as event_id, P.person_id, P.start_date, P.end_date, op_start_date, op_end_date, cast(P.visit_occurrence_id as bigint) as visit_occurrence_id
FROM
(
  select E.person_id, E.start_date, E.end_date,
         row_number() OVER (PARTITION BY E.person_id ORDER BY E.sort_date ASC, E.event_id) ordinal,
         OP.observation_period_start_date as op_start_date, OP.observation_period_end_date as op_end_date, cast(E.visit_occurrence_id as bigint) as visit_occurrence_id
  FROM 
  (
  -- Begin Drug Exposure Criteria
select C.person_id, C.drug_exposure_id as event_id, C.start_date, C.end_date,
  C.visit_occurrence_id,C.start_date as sort_date
from 
(
  select de.person_id,de.drug_exposure_id,de.drug_concept_id,de.visit_occurrence_id,days_supply,quantity,refills,de.drug_exposure_start_date as start_date, COALESCE(de.drug_exposure_end_date, DATEADD(day,de.days_supply,de.drug_exposure_start_date), DATEADD(day,1,de.drug_exposure_start_date)) as end_date 
  FROM @cdm_database_schema.DRUG_EXPOSURE de
JOIN isap3ti5Codesets cs on (de.drug_concept_id = cs.concept_id and cs.codeset_id = 5)
) C
-- End Drug Exposure Criteria
  ) E
	JOIN @cdm_database_schema.observation_period OP on E.person_id = OP.person_id and E.start_date >=  OP.observation_period_start_date and E.start_date <= op.observation_period_end_date
  WHERE DATEADD(day,0,OP.OBSERVATION_PERIOD_START_DATE) <= E.START_DATE AND DATEADD(day,0,E.START_DATE) <= OP.OBSERVATION_PERIOD_END_DATE
) P
-- End Primary Events
) pe
) QE
;
--- Inclusion Rule Inserts
CREATE TEMP TABLE isap3ti5Inclusion_0
AS
SELECT
0 as inclusion_rule_id, person_id, event_id
FROM
(
  select pe.person_id, pe.event_id
  FROM isap3ti5qualified_events pe
JOIN (
-- Begin Criteria Group
select 0 as index_id, person_id, event_id
FROM
(
  select E.person_id, E.event_id 
  FROM isap3ti5qualified_events E
  INNER JOIN
  (
    -- Begin Demographic Criteria
SELECT 0 as index_id, e.person_id, e.event_id
FROM isap3ti5qualified_events E
JOIN @cdm_database_schema.PERSON P ON P.PERSON_ID = E.PERSON_ID
WHERE EXTRACT(YEAR FROM E.start_date) - P.year_of_birth >= 18
GROUP BY e.person_id, e.event_id
-- End Demographic Criteria
  ) CQ on E.person_id = CQ.person_id and E.event_id = CQ.event_id
  GROUP BY E.person_id, E.event_id
  HAVING COUNT(index_id) = 1
) G
-- End Criteria Group
) AC on AC.person_id = pe.person_id AND AC.event_id = pe.event_id
) Results
;
CREATE TEMP TABLE isap3ti5Inclusion_1
AS
SELECT
1 as inclusion_rule_id, person_id, event_id
FROM
(
  select pe.person_id, pe.event_id
  FROM isap3ti5qualified_events pe
JOIN (
-- Begin Criteria Group
select 0 as index_id, person_id, event_id
FROM
(
  select E.person_id, E.event_id 
  FROM isap3ti5qualified_events E
  INNER JOIN
  (
    -- Begin Correlated Criteria
select 0 as index_id, cc.person_id, cc.event_id
from (SELECT p.person_id, p.event_id 
FROM isap3ti5qualified_events P
JOIN (
  -- Begin Measurement Criteria
select C.person_id, C.measurement_id as event_id, C.start_date, C.end_date,
       C.visit_occurrence_id, C.start_date as sort_date
from 
(
  select m.person_id,m.measurement_id,m.measurement_concept_id,m.visit_occurrence_id,m.value_as_number,m.range_high,m.range_low,m.measurement_date as start_date, DATEADD(day,1,m.measurement_date) as end_date , row_number() over (PARTITION BY m.person_id ORDER BY m.measurement_date, m.measurement_id) as ordinal
  FROM @cdm_database_schema.MEASUREMENT m
JOIN isap3ti5Codesets cs on (m.measurement_concept_id = cs.concept_id and cs.codeset_id = 0)
) C
WHERE C.ordinal = 1
-- End Measurement Criteria
) A on A.person_id = P.person_id  AND A.START_DATE >= P.OP_START_DATE AND A.START_DATE <= P.OP_END_DATE AND A.START_DATE >= DATEADD(day,-90,P.START_DATE) AND A.START_DATE <= DATEADD(day,30,P.START_DATE) ) cc 
GROUP BY cc.person_id, cc.event_id
HAVING COUNT(cc.event_id) >= 1
-- End Correlated Criteria
UNION ALL
-- Begin Correlated Criteria
select 1 as index_id, cc.person_id, cc.event_id
from (SELECT p.person_id, p.event_id 
FROM isap3ti5qualified_events P
JOIN (
  -- Begin Condition Occurrence Criteria
SELECT C.person_id, C.condition_occurrence_id as event_id, C.start_date, C.end_date,
  C.visit_occurrence_id, C.start_date as sort_date
FROM 
(
  SELECT co.person_id,co.condition_occurrence_id,co.condition_concept_id,co.visit_occurrence_id,co.condition_start_date as start_date, COALESCE(co.condition_end_date, DATEADD(day,1,co.condition_start_date)) as end_date , row_number() over (PARTITION BY co.person_id ORDER BY co.condition_start_date, co.condition_occurrence_id) as ordinal
  FROM @cdm_database_schema.CONDITION_OCCURRENCE co
  JOIN isap3ti5Codesets cs on (co.condition_concept_id = cs.concept_id and cs.codeset_id = 0)
) C
WHERE C.ordinal = 1
-- End Condition Occurrence Criteria
) A on A.person_id = P.person_id  AND A.START_DATE >= P.OP_START_DATE AND A.START_DATE <= P.OP_END_DATE AND A.START_DATE >= DATEADD(day,-90,P.START_DATE) AND A.START_DATE <= DATEADD(day,30,P.START_DATE) ) cc 
GROUP BY cc.person_id, cc.event_id
HAVING COUNT(cc.event_id) >= 1
-- End Correlated Criteria
UNION ALL
-- Begin Correlated Criteria
select 2 as index_id, cc.person_id, cc.event_id
from (SELECT p.person_id, p.event_id 
FROM isap3ti5qualified_events P
JOIN (
  -- Begin Observation Criteria
select C.person_id, C.observation_id as event_id, C.start_date, C.END_DATE,
       C.visit_occurrence_id, C.start_date as sort_date
from 
(
  select o.person_id,o.observation_id,o.observation_concept_id,o.visit_occurrence_id,o.value_as_number,o.observation_date as start_date, DATEADD(day,1,o.observation_date) as end_date , row_number() over (PARTITION BY o.person_id ORDER BY o.observation_date, o.observation_id) as ordinal
  FROM @cdm_database_schema.OBSERVATION o
JOIN isap3ti5Codesets cs on (o.observation_concept_id = cs.concept_id and cs.codeset_id = 0)
) C
WHERE C.ordinal = 1
-- End Observation Criteria
) A on A.person_id = P.person_id  AND A.START_DATE >= P.OP_START_DATE AND A.START_DATE <= P.OP_END_DATE AND A.START_DATE >= DATEADD(day,-90,P.START_DATE) AND A.START_DATE <= DATEADD(day,30,P.START_DATE) ) cc 
GROUP BY cc.person_id, cc.event_id
HAVING COUNT(cc.event_id) >= 1
-- End Correlated Criteria
UNION ALL
-- Begin Correlated Criteria
select 3 as index_id, cc.person_id, cc.event_id
from (SELECT p.person_id, p.event_id 
FROM isap3ti5qualified_events P
JOIN (
  -- Begin Measurement Criteria
select C.person_id, C.measurement_id as event_id, C.start_date, C.end_date,
       C.visit_occurrence_id, C.start_date as sort_date
from 
(
  select m.person_id,m.measurement_id,m.measurement_concept_id,m.visit_occurrence_id,m.value_as_number,m.range_high,m.range_low,m.measurement_date as start_date, DATEADD(day,1,m.measurement_date) as end_date , row_number() over (PARTITION BY m.person_id ORDER BY m.measurement_date, m.measurement_id) as ordinal
  FROM @cdm_database_schema.MEASUREMENT m
JOIN isap3ti5Codesets cs on (m.measurement_concept_id = cs.concept_id and cs.codeset_id = 9)
) C
WHERE C.ordinal = 1
-- End Measurement Criteria
) A on A.person_id = P.person_id  AND A.START_DATE >= P.OP_START_DATE AND A.START_DATE <= P.OP_END_DATE AND A.START_DATE >= DATEADD(day,-90,P.START_DATE) AND A.START_DATE <= DATEADD(day,30,P.START_DATE) ) cc 
GROUP BY cc.person_id, cc.event_id
HAVING COUNT(cc.event_id) >= 1
-- End Correlated Criteria
  ) CQ on E.person_id = CQ.person_id and E.event_id = CQ.event_id
  GROUP BY E.person_id, E.event_id
  HAVING COUNT(index_id) > 0
) G
-- End Criteria Group
) AC on AC.person_id = pe.person_id AND AC.event_id = pe.event_id
) Results
;
CREATE TEMP TABLE isap3ti5Inclusion_2
AS
SELECT
2 as inclusion_rule_id, person_id, event_id
FROM
(
  select pe.person_id, pe.event_id
  FROM isap3ti5qualified_events pe
JOIN (
-- Begin Criteria Group
select 0 as index_id, person_id, event_id
FROM
(
  select E.person_id, E.event_id 
  FROM isap3ti5qualified_events E
  INNER JOIN
  (
    -- Begin Correlated Criteria
select 0 as index_id, cc.person_id, cc.event_id
from (SELECT p.person_id, p.event_id 
FROM isap3ti5qualified_events P
JOIN (
  -- Begin Condition Occurrence Criteria
SELECT C.person_id, C.condition_occurrence_id as event_id, C.start_date, C.end_date,
  C.visit_occurrence_id, C.start_date as sort_date
FROM 
(
  SELECT co.person_id,co.condition_occurrence_id,co.condition_concept_id,co.visit_occurrence_id,co.condition_start_date as start_date, COALESCE(co.condition_end_date, DATEADD(day,1,co.condition_start_date)) as end_date 
  FROM @cdm_database_schema.CONDITION_OCCURRENCE co
  JOIN isap3ti5Codesets cs on (co.condition_concept_id = cs.concept_id and cs.codeset_id = 1)
) C
-- End Condition Occurrence Criteria
) A on A.person_id = P.person_id  AND A.START_DATE >= P.OP_START_DATE AND A.START_DATE <= P.OP_END_DATE AND A.START_DATE >= DATEADD(day,-180,P.START_DATE) AND A.START_DATE <= DATEADD(day,30,P.START_DATE) ) cc 
GROUP BY cc.person_id, cc.event_id
HAVING COUNT(cc.event_id) >= 1
-- End Correlated Criteria
  ) CQ on E.person_id = CQ.person_id and E.event_id = CQ.event_id
  GROUP BY E.person_id, E.event_id
  HAVING COUNT(index_id) = 1
) G
-- End Criteria Group
) AC on AC.person_id = pe.person_id AND AC.event_id = pe.event_id
) Results
;
CREATE TEMP TABLE isap3ti5Inclusion_3
AS
SELECT
3 as inclusion_rule_id, person_id, event_id
FROM
(
  select pe.person_id, pe.event_id
  FROM isap3ti5qualified_events pe
JOIN (
-- Begin Criteria Group
select 0 as index_id, person_id, event_id
FROM
(
  select E.person_id, E.event_id 
  FROM isap3ti5qualified_events E
  INNER JOIN
  (
    -- Begin Correlated Criteria
select 0 as index_id, p.person_id, p.event_id
from isap3ti5qualified_events p
LEFT JOIN (
SELECT p.person_id, p.event_id 
FROM isap3ti5qualified_events P
JOIN (
  -- Begin Condition Occurrence Criteria
SELECT C.person_id, C.condition_occurrence_id as event_id, C.start_date, C.end_date,
  C.visit_occurrence_id, C.start_date as sort_date
FROM 
(
  SELECT co.person_id,co.condition_occurrence_id,co.condition_concept_id,co.visit_occurrence_id,co.condition_start_date as start_date, COALESCE(co.condition_end_date, DATEADD(day,1,co.condition_start_date)) as end_date 
  FROM @cdm_database_schema.CONDITION_OCCURRENCE co
  JOIN isap3ti5Codesets cs on (co.condition_concept_id = cs.concept_id and cs.codeset_id = 10)
) C
-- End Condition Occurrence Criteria
) A on A.person_id = P.person_id  AND A.START_DATE >= P.OP_START_DATE AND A.START_DATE <= P.OP_END_DATE AND A.START_DATE >= DATEADD(day,-365,P.START_DATE) AND A.START_DATE <= DATEADD(day,30,P.START_DATE) ) cc on p.person_id = cc.person_id and p.event_id = cc.event_id
GROUP BY p.person_id, p.event_id
HAVING COUNT(cc.event_id) = 0
-- End Correlated Criteria
  ) CQ on E.person_id = CQ.person_id and E.event_id = CQ.event_id
  GROUP BY E.person_id, E.event_id
  HAVING COUNT(index_id) = 1
) G
-- End Criteria Group
) AC on AC.person_id = pe.person_id AND AC.event_id = pe.event_id
) Results
;
CREATE TEMP TABLE isap3ti5Inclusion_4
AS
SELECT
4 as inclusion_rule_id, person_id, event_id
FROM
(
  select pe.person_id, pe.event_id
  FROM isap3ti5qualified_events pe
JOIN (
-- Begin Criteria Group
select 0 as index_id, person_id, event_id
FROM
(
  select E.person_id, E.event_id 
  FROM isap3ti5qualified_events E
  INNER JOIN
  (
    -- Begin Correlated Criteria
select 0 as index_id, p.person_id, p.event_id
from isap3ti5qualified_events p
LEFT JOIN (
SELECT p.person_id, p.event_id 
FROM isap3ti5qualified_events P
JOIN (
  -- Begin Drug Exposure Criteria
select C.person_id, C.drug_exposure_id as event_id, C.start_date, C.end_date,
  C.visit_occurrence_id,C.start_date as sort_date
from 
(
  select de.person_id,de.drug_exposure_id,de.drug_concept_id,de.visit_occurrence_id,days_supply,quantity,refills,de.drug_exposure_start_date as start_date, COALESCE(de.drug_exposure_end_date, DATEADD(day,de.days_supply,de.drug_exposure_start_date), DATEADD(day,1,de.drug_exposure_start_date)) as end_date 
  FROM @cdm_database_schema.DRUG_EXPOSURE de
JOIN isap3ti5Codesets cs on (de.drug_concept_id = cs.concept_id and cs.codeset_id = 4)
) C
-- End Drug Exposure Criteria
) A on A.person_id = P.person_id  AND A.START_DATE >= P.OP_START_DATE AND A.START_DATE <= P.OP_END_DATE AND A.START_DATE >= DATEADD(day,-365,P.START_DATE) AND A.START_DATE <= DATEADD(day,-1,P.START_DATE) ) cc on p.person_id = cc.person_id and p.event_id = cc.event_id
GROUP BY p.person_id, p.event_id
HAVING COUNT(cc.event_id) = 0
-- End Correlated Criteria
  ) CQ on E.person_id = CQ.person_id and E.event_id = CQ.event_id
  GROUP BY E.person_id, E.event_id
  HAVING COUNT(index_id) = 1
) G
-- End Criteria Group
) AC on AC.person_id = pe.person_id AND AC.event_id = pe.event_id
) Results
;
CREATE TEMP TABLE isap3ti5inclusion_events
AS
SELECT
inclusion_rule_id, person_id, event_id
FROM
(select inclusion_rule_id, person_id, event_id from isap3ti5Inclusion_0
UNION ALL
select inclusion_rule_id, person_id, event_id from isap3ti5Inclusion_1
UNION ALL
select inclusion_rule_id, person_id, event_id from isap3ti5Inclusion_2
UNION ALL
select inclusion_rule_id, person_id, event_id from isap3ti5Inclusion_3
UNION ALL
select inclusion_rule_id, person_id, event_id from isap3ti5Inclusion_4) I;
TRUNCATE TABLE isap3ti5Inclusion_0;
DROP TABLE isap3ti5Inclusion_0;
TRUNCATE TABLE isap3ti5Inclusion_1;
DROP TABLE isap3ti5Inclusion_1;
TRUNCATE TABLE isap3ti5Inclusion_2;
DROP TABLE isap3ti5Inclusion_2;
TRUNCATE TABLE isap3ti5Inclusion_3;
DROP TABLE isap3ti5Inclusion_3;
TRUNCATE TABLE isap3ti5Inclusion_4;
DROP TABLE isap3ti5Inclusion_4;
CREATE TEMP TABLE isap3ti5included_events
AS
SELECT
event_id, person_id, start_date, end_date, op_start_date, op_end_date
FROM
(
  SELECT event_id, person_id, start_date, end_date, op_start_date, op_end_date, row_number() over (partition by person_id order by start_date ASC) as ordinal
  from
  (
    select Q.event_id, Q.person_id, Q.start_date, Q.end_date, Q.op_start_date, Q.op_end_date, SUM(coalesce(POWER(cast(2 as bigint), I.inclusion_rule_id), 0)) as inclusion_rule_mask
    from isap3ti5qualified_events Q
    LEFT JOIN isap3ti5inclusion_events I on I.person_id = Q.person_id and I.event_id = Q.event_id
    GROUP BY Q.event_id, Q.person_id, Q.start_date, Q.end_date, Q.op_start_date, Q.op_end_date
  ) MG -- matching groups
{5 != 0}?{
  -- the matching group with all bits set ( POWER(2,# of inclusion rules) - 1 = inclusion_rule_mask
  WHERE (MG.inclusion_rule_mask = POWER(cast(2 as bigint),5)-1)
}
) Results
WHERE Results.ordinal = 1
;
-- generate cohort periods into #final_cohort
CREATE TEMP TABLE isap3ti5cohort_rows
AS
SELECT
person_id, start_date, end_date
FROM
( -- first_ends
	select F.person_id, F.start_date, F.end_date
	FROM (
	  select I.event_id, I.person_id, I.start_date, CE.end_date, row_number() over (partition by I.person_id, I.event_id order by CE.end_date) as ordinal
	  from isap3ti5included_events I
	  join ( -- cohort_ends
-- cohort exit dates
-- By default, cohort exit at the event's op end date
select event_id, person_id, op_end_date as end_date from isap3ti5included_events
UNION ALL
-- Censor Events
select i.event_id, i.person_id, MIN(c.start_date) as end_date
FROM isap3ti5included_events i
JOIN
(
-- Begin Condition Occurrence Criteria
SELECT C.person_id, C.condition_occurrence_id as event_id, C.start_date, C.end_date,
  C.visit_occurrence_id, C.start_date as sort_date
FROM 
(
  SELECT co.person_id,co.condition_occurrence_id,co.condition_concept_id,co.visit_occurrence_id,co.condition_start_date as start_date, COALESCE(co.condition_end_date, DATEADD(day,1,co.condition_start_date)) as end_date 
  FROM @cdm_database_schema.CONDITION_OCCURRENCE co
  JOIN isap3ti5Codesets cs on (co.condition_concept_id = cs.concept_id and cs.codeset_id = 10)
) C
-- End Condition Occurrence Criteria
) C on C.person_id = I.person_id and C.start_date >= I.start_date and C.START_DATE <= I.op_end_date
GROUP BY i.event_id, i.person_id
    ) CE on I.event_id = CE.event_id and I.person_id = CE.person_id and CE.end_date >= I.start_date
	) F
	WHERE F.ordinal = 1
) FE;
CREATE TEMP TABLE isap3ti5final_cohort
AS
SELECT
person_id, min(start_date) as start_date, DATEADD(day,-1 * 0, max(end_date)) as end_date
FROM
(
  select person_id, start_date, end_date, sum(is_start) over (partition by person_id order by start_date, is_start desc rows unbounded preceding) group_idx
  from (
    select person_id, start_date, end_date, 
      case when max(end_date) over (partition by person_id order by start_date rows between unbounded preceding and 1 preceding) >= start_date then 0 else 1 end is_start
    from (
      select person_id, start_date, DATEADD(day,0,end_date) as end_date
      from isap3ti5cohort_rows
    ) CR
  ) ST
) GR
group by person_id, group_idx;
SELECT count(distinct person_id) FROM
FROM isap3ti5final_cohort CO
;