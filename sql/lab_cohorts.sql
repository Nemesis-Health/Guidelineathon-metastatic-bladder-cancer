/* ============================================================================
   lab_cohorts.sql
   1st-line metastatic bladder cancer  --  lab-eligibility cohorts (Tests #1-23)
   OMOP CDM.  Generated from "Lab input.xlsx" on 2026-06-28.
   Rendered with SqlRender (parameters below) and translated per dialect.

   SqlRender PARAMETERS (all rendered before execution):
     @cdm_database_schema   -- OMOP CDM tables (measurement, person, ...)
     @work_database_schema  -- schema that holds every table written below
     @raw_lab_results_table -- persisted normalised evaluations (was @work_database_schema.@raw_lab_results_table);
                               feeds Section 5 lab-value distributions
     @lab_cohort_table      -- persisted pass/fail rows (cohort_definition_id =
                               test_id) consumed by eligibility_2*.sql
     -- scratch/reference tables (persisted, not #temp — survive across the
     --   statement batches DatabaseConnector runs, and stay inspectable):
     @cat_concept_table  @unit_factor_table  @normals_table  @criteria_table
     @grp_table  @scales_table  @scored_table  @resolved_table  @debug_table

   All work tables are DROP TABLE IF EXISTS'd first, so the script is
   re-runnable. The scratch/reference tables are left in @work_database_schema
   for auditing; drop them manually once results are validated.

   PORTABILITY: logic is otherwise ANSI SQL (window fns, CASE); percentiles
     use a ROW_NUMBER/COUNT/FLOOR interpolation (see step 1) because SqlRender
     does not translate PERCENTILE_CONT.
     Remaining dialect-specific bits, flagged inline: LOG10() and the
     GREATEST-via-VALUES trick (SQL Server <2022).
   ============================================================================ */

/* ---------------------------------------------------------------------------
   0.  REFERENCE DATA  (from the workbook -- the part you validate)
   --------------------------------------------------------------------------- */

-- Table for test concepts in each category
DROP TABLE IF EXISTS @work_database_schema.@cat_concept_table;
CREATE TABLE @work_database_schema.@cat_concept_table (cat varchar(40), measurement_concept_id int);
INSERT INTO @work_database_schema.@cat_concept_table (cat, measurement_concept_id) VALUES
 ('ALT',3955919),
 ('ALT',35814378),
 ('ALT',40782579),
 ('ALT',46235106),
 ('ALT',3015912),
 ('ALT',3006923),
 ('ALT',3027388),
 ('ALT',3005755),
 ('ALT',46236949),
 ('ALT',40796722),
 ('ALT',37071721),
 ('ALT',36033592),
 ('ALT',37047736),
 ('ALT',37074219),
 ('ALT',37208490),
 ('ALT',37208513),
 ('ALT',37151648),
 ('ALT',4146380),
 ('ALT',3019056),
 ('ALT',40652525),
 ('ALT',37070195),
 ('ALT',44810789),
 ('ALT',1247076),
 ('ALT',40462059),
 ('ALT',4095055),
 ('ALT',4019440),
 ('ALT',4018061),
 ('ALT',40315363),
 ('ALT',3022893),
 ('ALT',40328375),
 ('ALT',40315359),
 ('ALT',4190899),
 ('ALT',37393142),
 ('ALT',40558873),
 ('ALT',40563834),
 ('ALT',44788835),
 ('ALT',3554168),
 ('ALT',37393531),
 ('ALT',3554167),
 ('ALT',45525616),
 ('ALT',4096233),
 ('ALT',2212598),
 ('ANC',36203200),
 ('ANC',3017732),
 ('ANC',3013650),
 ('ANC',40768822),
 ('ANC',3027270),
 ('ANC',3017501),
 ('ANC',3012533),
 ('ANC',37393856),
 ('ANC',37208698),
 ('ANC',37208699),
 ('ANC',4148615),
 ('ANC',40301798),
 ('ANC',40301792),
 ('ANC',40332452),
 ('ANC',4306441),
 ('ANC',3557382),
 ('aPTT',44809202),
 ('aPTT',40301851),
 ('aPTT',40775569),
 ('aPTT',40792130),
 ('aPTT',40785560),
 ('aPTT',40792131),
 ('aPTT',40772301),
 ('aPTT',40778897),
 ('aPTT',40792133),
 ('aPTT',3041944),
 ('aPTT',40775918),
 ('aPTT',21497369),
 ('aPTT',37037324),
 ('aPTT',21497432),
 ('aPTT',21496554),
 ('aPTT',37022168),
 ('aPTT',37043668),
 ('aPTT',21497370),
 ('aPTT',37067246),
 ('aPTT',37075315),
 ('aPTT',21495977),
 ('aPTT',37041593),
 ('aPTT',3016529),
 ('aPTT',3013466),
 ('aPTT',3010800),
 ('aPTT',3016290),
 ('aPTT',3038102),
 ('aPTT',3018677),
 ('aPTT',3031305),
 ('aPTT',37032508),
 ('aPTT',3009363),
 ('aPTT',3000944),
 ('aPTT',3551002),
 ('aPTT',3576046),
 ('aPTT',40575044),
 ('aPTT',4175016),
 ('AST',40785861),
 ('AST',35814399),
 ('AST',36031681),
 ('AST',3013721),
 ('AST',36305398),
 ('AST',3037081),
 ('AST',3010587),
 ('AST',40787003),
 ('AST',36033545),
 ('AST',37059000),
 ('AST',37208565),
 ('AST',37208512),
 ('AST',37394375),
 ('AST',4263457),
 ('AST',40652640),
 ('AST',3956411),
 ('AST',44810795),
 ('AST',40315377),
 ('AST',40328399),
 ('AST',40315384),
 ('AST',40328409),
 ('AST',40462064),
 ('AST',4094595),
 ('AST',40315385),
 ('AST',37398463),
 ('AST',40328410),
 ('AST',4197974),
 ('AST',37392189),
 ('AST',45531649),
 ('AST',2212597),
 ('CrCl',40761547),
 ('CrCl',3044031),
 ('CrCl',37068680),
 ('CrCl',40308899),
 ('CrCl',40354584),
 ('CrCl',1011112),
 ('CrCl',42869901),
 ('CrCl',4253380),
 ('CrCl',40308904),
 ('CrCl',37393360),
 ('CrCl',40330755),
 ('CrCl',45532639),
 ('CrCl',4010651),
 ('CrCl',37071451),
 ('CrCl',37024397),
 ('CrCl',37038087),
 ('CrCl',37071858),
 ('CrCl',3006873),
 ('CrCl',3022988),
 ('CrCl',3005770),
 ('CrCl',37208556),
 ('CrCl',3018252),
 ('CrCl',3018775),
 ('CrCl',3004917),
 ('CrCl',3047148),
 ('CrCl',4019552),
 ('CrCl',37076262),
 ('CrCl',37044136),
 ('CrCl',1091718),
 ('CrCl',3035529),
 ('CrCl',37027339),
 ('CrCl',37045863),
 ('CrCl',1094424),
 ('CrCl',37047104),
 ('CrCl',37034723),
 ('CrCl',3007659),
 ('CrCl',3034605),
 ('CrCl',3027108),
 ('CrCl',3022053),
 ('CrCl',3025137),
 ('CrCl',3026583),
 ('CrCl',3035532),
 ('CrCl',37044930),
 ('CrCl',37075417),
 ('CrCl',37058458),
 ('CrCl',37078988),
 ('CrCl',3032720),
 ('CrCl',37041867),
 ('CrCl',37060719),
 ('CrCl',3029545),
 ('CrCl',3033962),
 ('CrCl',2212296),
 ('CrCl',3006240),
 ('CrCl',37205200),
 ('CrCl',3561311),
 ('CrCl',46285249),
 ('CrCl',37169169),
 ('CrCl',37169171),
 ('CrCl',37169170),
 ('CrCl',40483173),
 ('CrCl',4042762),
 ('Creatinine',37398464),
 ('Creatinine',40307223),
 ('Creatinine',40328935),
 ('Creatinine',4195331),
 ('Creatinine',40328936),
 ('Creatinine',37392198),
 ('Creatinine',40307224),
 ('Creatinine',4197967),
 ('Creatinine',45888378),
 ('Creatinine',42357149),
 ('Creatinine',40775801),
 ('Creatinine',35814434),
 ('Creatinine',42357141),
 ('Creatinine',3032033),
 ('Creatinine',3007760),
 ('Creatinine',3051825),
 ('Creatinine',3016723),
 ('Creatinine',40762887),
 ('Creatinine',3020564),
 ('Creatinine',3041735),
 ('Creatinine',1260102),
 ('Creatinine',46235076),
 ('Creatinine',3964702),
 ('Creatinine',40796376),
 ('Creatinine',40793622),
 ('Creatinine',4077513),
 ('Creatinine',3552485),
 ('Creatinine',37394438),
 ('Creatinine',3552681),
 ('Creatinine',4275203),
 ('Creatinine',4324383),
 ('Creatinine',4013964),
 ('Creatinine',35917168),
 ('Creatinine',42086413),
 ('Creatinine',19688918),
 ('Creatinine',42349688),
 ('Creatinine',2212294),
 ('Creatinine',2212295),
 ('Creatinine',1021276),
 ('Creatinine',37079906),
 ('Creatinine',3035064),
 ('Creatinine',40307226),
 ('Creatinine',37392200),
 ('Creatinine',40328938),
 ('Creatinine',4199025),
 ('Creatinine',40307212),
 ('Creatinine',40328452),
 ('Creatinine',37392176),
 ('Creatinine',4276437),
 ('Creatinine',3557578),
 ('Creatinine',4055580),
 ('Direct bilirubin',3558502),
 ('Direct bilirubin',37398377),
 ('Direct bilirubin',4216632),
 ('Direct bilirubin',3019676),
 ('Direct bilirubin',3005772),
 ('Direct bilirubin',3032335),
 ('Direct bilirubin',3027597),
 ('Direct bilirubin',3028638),
 ('Direct bilirubin',3043347),
 ('Direct bilirubin',40775879),
 ('Direct bilirubin',40783493),
 ('Direct bilirubin',37027118),
 ('Direct bilirubin',2212227),
 ('Direct bilirubin',37392379),
 ('Direct bilirubin',3558551),
 ('Direct bilirubin',40315331),
 ('Direct bilirubin',44805650),
 ('Direct bilirubin',37208552),
 ('Direct bilirubin',37208553),
 ('Direct bilirubin',3018682),
 ('Direct bilirubin',3021680),
 ('Direct bilirubin',37394191),
 ('Direct bilirubin',35814406),
 ('Direct bilirubin',3558503),
 ('Direct bilirubin',40315335),
 ('Direct bilirubin',40328350),
 ('Direct bilirubin',37398232),
 ('Direct bilirubin',4195339),
 ('Direct bilirubin',37398235),
 ('Direct bilirubin',40328354),
 ('Direct bilirubin',40315339),
 ('Direct bilirubin',4198887),
 ('GFR',40478963),
 ('GFR',40483219),
 ('GFR',40485075),
 ('GFR',3043621),
 ('GFR',1617023),
 ('GFR',37393011),
 ('GFR',37393012),
 ('GFR',37208635),
 ('GFR',44808279),
 ('GFR',3559661),
 ('GFR',46285137),
 ('GFR',3561268),
 ('GFR',3561269),
 ('GFR',1008434),
 ('GFR',40769275),
 ('GFR',44806420),
 ('GFR',37393690),
 ('GFR',37399046),
 ('GFR',42235776),
 ('GFR',4338520),
 ('GFR',45766361),
 ('GFR',4213477),
 ('GFR',3523671),
 ('GFR',1029770),
 ('GFR',3577339),
 ('GFR',3577386),
 ('GFR',759544),
 ('GFR',759545),
 ('GFR',37169597),
 ('GFR',37168979),
 ('GFR',44788275),
 ('GFR',3552636),
 ('GFR',3552918),
 ('GFR',44790060),
 ('GFR',3554357),
 ('GFR',3554521),
 ('GFR',42537612),
 ('GFR',44514146),
 ('GFR',3554610),
 ('GFR',44790183),
 ('GFR',1018491),
 ('GFR',37075065),
 ('GFR',36033091),
 ('GFR',37077746),
 ('GFR',37030256),
 ('GFR',37068907),
 ('GFR',37078272),
 ('GFR',37052213),
 ('GFR',37041591),
 ('GFR',36033624),
 ('GFR',37045756),
 ('GFR',37041188),
 ('GFR',37055720),
 ('GFR',3030354),
 ('GFR',40771922),
 ('GFR',1619026),
 ('GFR',36660257),
 ('GFR',3965919),
 ('GFR',1619025),
 ('GFR',40764999),
 ('GFR',46236952),
 ('GFR',3030104),
 ('GFR',3029859),
 ('GFR',36031320),
 ('GFR',36306178),
 ('GFR',3053283),
 ('GFR',3029829),
 ('GFR',42869913),
 ('GFR',36031846),
 ('GFR',36303797),
 ('GFR',3049187),
 ('GFR',46235172),
 ('GFR',36662614),
 ('GFR',1619800),
 ('GFR',1618558),
 ('GFR',46236975),
 ('GFR',40478895),
 ('GFR',40771924),
 ('GFR',1010106),
 ('GFR',37061620),
 ('GFR',37027780),
 ('GFR',37024736),
 ('GFR',37033687),
 ('GFR',45768505),
 ('GFR',44792172),
 ('GFR',42364981),
 ('GFR',42785722),
 ('GFR',42783791),
 ('GFR',42791039),
 ('GFR',42786462),
 ('GFR',42787952),
 ('GFR',4346613),
 ('Hb',3034666),
 ('Hb',3955933),
 ('Hb',45889912),
 ('Hb',40795725),
 ('Hb',3030854),
 ('Hb',3002173),
 ('Hb',3006239),
 ('Hb',3027901),
 ('Hb',3029461),
 ('Hb',3000963),
 ('Hb',3027484),
 ('Hb',40758903),
 ('Hb',40757420),
 ('Hb',3048275),
 ('Hb',3006184),
 ('Hb',1616317),
 ('Hb',1617122),
 ('Hb',1617021),
 ('Hb',3003675),
 ('Hb',3007302),
 ('Hb',1091111),
 ('Hb',46235391),
 ('Hb',3004119),
 ('Hb',1091321),
 ('Hb',46235392),
 ('Hb',21490721),
 ('Hb',40762351),
 ('Hb',1092194),
 ('Hb',1002216),
 ('Hb',1259766),
 ('Hb',3005872),
 ('Hb',40789986),
 ('Hb',40793300),
 ('Hb',40787384),
 ('Hb',40793915),
 ('Hb',40774048),
 ('Hb',37037081),
 ('Hb',40784444),
 ('Hb',2106864),
 ('Hb',4153000),
 ('Hb',2106862),
 ('Hb',2106867),
 ('Hb',3040522),
 ('Hb',40786237),
 ('Hb',45889532),
 ('Hb',2212396),
 ('Hb',40480067),
 ('Hb',4288754),
 ('Hb',4015178),
 ('Hb',4016242),
 ('Hb',40484519),
 ('Hb',43533195),
 ('Hb',40664705),
 ('Hb',43533230),
 ('Hb',40664666),
 ('HbA1c',40478875),
 ('HbA1c',36033143),
 ('HbA1c',3035097),
 ('HbA1c',40758583),
 ('HbA1c',2617505),
 ('HbA1c',2617506),
 ('HbA1c',40654761),
 ('HbA1c',1029009),
 ('HbA1c',45765893),
 ('HbA1c',35814469),
 ('HbA1c',3956570),
 ('HbA1c',37392408),
 ('HbA1c',37170188),
 ('HbA1c',3557553),
 ('HbA1c',37392407),
 ('HbA1c',3556806),
 ('HbA1c',37398434),
 ('HbA1c',37173523),
 ('HbA1c',44793001),
 ('HbA1c',40302404),
 ('HbA1c',4306439),
 ('HbA1c',40333052),
 ('HbA1c',40302398),
 ('HbA1c',37171451),
 ('HbA1c',37208641),
 ('HbA1c',40324145),
 ('HbA1c',40302403),
 ('HbA1c',37393623),
 ('HbA1c',3556272),
 ('HbA1c',3556271),
 ('HbA1c',4197971),
 ('HbA1c',40779306),
 ('HbA1c',40797575),
 ('HbA1c',40307814),
 ('HbA1c',40329570),
 ('HbA1c',4147407),
 ('HbA1c',37024125),
 ('HbA1c',3005446),
 ('HbA1c',42236091),
 ('HbA1c',42359964),
 ('HbA1c',40789263),
 ('HbA1c',42363150),
 ('HbA1c',42236090),
 ('HbA1c',4276582),
 ('HbA1c',3034639),
 ('HbA1c',40775446),
 ('HbA1c',4306587),
 ('HbA1c',764124),
 ('HbA1c',4306250),
 ('HbA1c',764125),
 ('HbA1c',4306438),
 ('HbA1c',40329569),
 ('HbA1c',40307813),
 ('HbA1c',4184637),
 ('HbA1c',3033145),
 ('HbA1c',42335889),
 ('HbA1c',42335885),
 ('HbA1c',42335400),
 ('HbA1c',42335758),
 ('HbA1c',19688978),
 ('HbA1c',42338868),
 ('HbA1c',42338568),
 ('HbA1c',42338928),
 ('HbA1c',42086333),
 ('HbA1c',19688976),
 ('HbA1c',42341767),
 ('HbA1c',42342037),
 ('HbA1c',42341745),
 ('HbA1c',42086356),
 ('HbA1c',19688975),
 ('HbA1c',42345168),
 ('HbA1c',42344959),
 ('HbA1c',42344961),
 ('HbA1c',42344652),
 ('HbA1c',19688974),
 ('HbA1c',42349808),
 ('HbA1c',42349981),
 ('HbA1c',42349928),
 ('HbA1c',42349915),
 ('HbA1c',19688979),
 ('HbA1c',37056065),
 ('HbA1c',42869630),
 ('HbA1c',1017437),
 ('HbA1c',36304734),
 ('HbA1c',3004410),
 ('HbA1c',3007263),
 ('HbA1c',3005673),
 ('HbA1c',40762352),
 ('HbA1c',40765129),
 ('HbA1c',36032094),
 ('HbA1c',1621295),
 ('HbA1c',42335746),
 ('HbA1c',42338757),
 ('HbA1c',42341735),
 ('HbA1c',42344940),
 ('HbA1c',42349751),
 ('HbA1c',42363144),
 ('HbA1c',42360997),
 ('HbA1c',42335718),
 ('HbA1c',42338718),
 ('HbA1c',42341815),
 ('HbA1c',42344932),
 ('HbA1c',42349676),
 ('HbA1c',1018498),
 ('HbA1c',2212392),
 ('HbA1c',2212393),
 ('HbA1c',1133964),
 ('HbA1c',1552826),
 ('HbA1c',1133965),
 ('HbA1c',1133966),
 ('HbA1c',40217293),
 ('HbA1c',2106238),
 ('HbA1c',709959),
 ('HbA1c',709960),
 ('HbA1c',2106236),
 ('HbA1c',2106252),
 ('HbA1c',40483736),
 ('INR',4261078),
 ('INR',40787533),
 ('INR',37074906),
 ('INR',40790995),
 ('INR',37042344),
 ('INR',37061141),
 ('INR',40784503),
 ('INR',37057823),
 ('INR',40785749),
 ('INR',37072728),
 ('INR',35927368),
 ('INR',3032080),
 ('INR',3051593),
 ('INR',3022217),
 ('INR',3039326),
 ('INR',3042605),
 ('INR',3528525),
 ('INR',3528565),
 ('INR',40301860),
 ('INR',4306239),
 ('INR',45757550),
 ('INR',35917345),
 ('INR',35918755),
 ('Platelets',2212657),
 ('Platelets',37054046),
 ('Platelets',46235211),
 ('Platelets',21497408),
 ('Platelets',37073482),
 ('Platelets',3955946),
 ('Platelets',40779159),
 ('Platelets',1033653),
 ('Platelets',36310193),
 ('Platelets',3007461),
 ('Platelets',3024929),
 ('Platelets',1616298),
 ('Platelets',3031586),
 ('Platelets',3010834),
 ('Platelets',40765005),
 ('Platelets',44787107),
 ('Platelets',3006297),
 ('Platelets',3016682),
 ('Platelets',1092269),
 ('Platelets',40786570),
 ('Platelets',37037425),
 ('Platelets',44787167),
 ('Platelets',37071943),
 ('Platelets',37058547),
 ('Platelets',37045092),
 ('Platelets',3050583),
 ('Platelets',37044407),
 ('Platelets',40654106),
 ('Platelets',40654107),
 ('Platelets',40654108),
 ('Platelets',42872952),
 ('Platelets',766004),
 ('Platelets',35918846),
 ('Platelets',40301839),
 ('Platelets',40332931),
 ('PT',44809199),
 ('PT',2212731),
 ('PT',4245261),
 ('PT',45889638),
 ('PT',40645225),
 ('PT',45532440),
 ('PT',3034426),
 ('PT',40792548),
 ('PT',40794336),
 ('PT',37044890),
 ('PT',40794295),
 ('PT',37070720),
 ('PT',37043621),
 ('PT',40798144),
 ('PT',37051085),
 ('PT',40787645),
 ('PT',37041470),
 ('PT',40788142),
 ('PT',40781659),
 ('PT',40788269),
 ('PT',3002417),
 ('PT',3053181),
 ('PT',3033891),
 ('PT',4213658),
 ('Total bilirubin',45890528),
 ('Total bilirubin',40779224),
 ('Total bilirubin',40796605),
 ('Total bilirubin',37046070),
 ('Total bilirubin',40778755),
 ('Total bilirubin',37073886),
 ('Total bilirubin',1618049),
 ('Total bilirubin',40795310),
 ('Total bilirubin',37030091),
 ('Total bilirubin',37038273),
 ('Total bilirubin',37029216),
 ('Total bilirubin',4094445),
 ('Total bilirubin',44788714),
 ('Total bilirubin',4076936),
 ('Total bilirubin',3558550),
 ('Total bilirubin',4269845),
 ('Total bilirubin',4118986),
 ('Total bilirubin',37151723),
 ('Total bilirubin',37151727),
 ('Total bilirubin',40353086),
 ('Total bilirubin',4230543),
 ('Total bilirubin',3043744),
 ('Total bilirubin',3043995),
 ('Total bilirubin',40789192),
 ('Total bilirubin',40788343),
 ('Total bilirubin',40798220),
 ('Total bilirubin',37064590),
 ('Total bilirubin',37028490),
 ('Total bilirubin',40652706),
 ('Total bilirubin',40654437),
 ('Total bilirubin',37051609),
 ('Total bilirubin',40794914),
 ('Total bilirubin',37027562),
 ('Total bilirubin',40654438),
 ('Total bilirubin',3032945),
 ('Total bilirubin',40762888),
 ('Total bilirubin',3028833),
 ('Total bilirubin',3024128),
 ('Total bilirubin',40762889),
 ('Total bilirubin',1175183),
 ('Total bilirubin',40757494),
 ('Total bilirubin',1616780),
 ('Total bilirubin',3006140),
 ('Total bilirubin',46235782),
 ('Total bilirubin',1175191),
 ('Total bilirubin',37064827),
 ('Total bilirubin',2212226),
 ('Total bilirubin',40315336),
 ('Total bilirubin',40328351),
 ('Total bilirubin',37398233),
 ('Total bilirubin',4210860),
 ('Total bilirubin',40354563),
 ('Total bilirubin',40315326),
 ('Total bilirubin',37398424),
 ('Total bilirubin',4269846),
 ('Total bilirubin',4041529),
 ('Total bilirubin',4041186),
 ('Total bilirubin',40315342),
 ('Total bilirubin',3557609),
 ('Total bilirubin',40315329),
 ('Total bilirubin',40328355),
 ('Total bilirubin',37399653),
 ('Total bilirubin',40315340),
 ('Total bilirubin',4195338),
 ('Total bilirubin',35814530),
 ('Total bilirubin',40315330),
 ('Total bilirubin',40328347),
 ('Total bilirubin',37394117),
 ('Total bilirubin',37208619),
 ('Total bilirubin',37208618);

-- table for unit conversion, including non-UCUM units
DROP TABLE IF EXISTS @work_database_schema.@unit_factor_table;
-- standard_value = value_as_number * factor + val_offset   (val_offset<>0 only for HbA1c mmol/mol, which is affine)
-- is_std: 'bit' isn't a portable ANSI type (unsupported on Snowflake); using int since every
-- reference to this column compares against literal 1 (see is_std=1 in the comment below).
CREATE TABLE @work_database_schema.@unit_factor_table (cat varchar(40), unit_concept_id int, factor float, val_offset float, is_std int);
INSERT INTO @work_database_schema.@unit_factor_table (cat, unit_concept_id, factor, val_offset, is_std) VALUES
 ('ALT',8645,1.0,0.0,1),
 ('ALT',8923,1.0,0.0,0),
 ('ALT',4118000,1.0,0.0,0),
 ('ALT',8719,1.0,0.0,0),
 ('ANC',8848,1.0,0.0,1),
 ('ANC',9444,1.0,0.0,0),
 ('ANC',33117,1.0,0.0,0),
 ('ANC',8961,1.0,0.0,0),
 ('ANC',8647,0.001,0.0,0),
 ('ANC',8784,0.001,0.0,0),
 ('ANC',8785,0.001,0.0,0),
 ('aPTT',8555,1.0,0.0,1),
 ('aPTT',9212,1.0,0.0,0),
 ('AST',8645,1.0,0.0,1),
 ('AST',8923,1.0,0.0,0),
 ('AST',4118000,1.0,0.0,0),
 ('AST',8719,1.0,0.0,0),
 ('AST',3169472,1.0,0.0,0),
 ('CrCl',8795,1.0,0.0,1),
 ('CrCl',720870,1.0,0.0,0),
 ('CrCl',9117,1.0,0.0,0),
 ('CrCl',4118155,1.0,0.0,0),
 ('CrCl',32710,1730.0,0.0,0),
 ('Creatinine',8840,1.0,0.0,1),
 ('Creatinine',8749,0.01131,0.0,0),
 ('Creatinine',4121396,1.0,0.0,0),
 ('Creatinine',8751,0.1,0.0,0),
 ('Creatinine',8636,100.0,0.0,0),
 ('Creatinine',8753,11.312,0.0,0),
 ('Creatinine',8954,1.0,0.0,0),
 ('Creatinine',8843,0.01131,0.0,0),
 ('Creatinine',8861,100.0,0.0,0),
 ('Creatinine',8713,1000.0,0.0,0),
 ('Creatinine',8837,0.001,0.0,0),
 ('Creatinine',8748,0.0001,0.0,0),
 ('Direct bilirubin',8840,1.0,0.0,1),
 ('Direct bilirubin',8749,0.05848,0.0,0),
 ('Direct bilirubin',8837,0.001,0.0,0),
 ('Direct bilirubin',8713,1000.0,0.0,0),
 ('GFR',8795,1.0,0.0,1),
 ('GFR',720870,1.0,0.0,0),
 ('GFR',9117,1.0,0.0,0),
 ('GFR',32710,1730.0,0.0,0),
 ('GFR',710208,1.73,0.0,0),
 ('GFR',3029859,1.0,0.0,0),
 ('GFR',4170408,1.0,0.0,0),
 ('HbA1c',8554,1.0,0.0,1),
 ('HbA1c',8737,1.0,0.0,0),
 ('HbA1c',8632,1.0,0.0,0),
 ('HbA1c',9579,0.09148,2.152,0),
 ('HbA1c',9225,1.0,0.0,0),
 ('HbA1c',44777555,1.0,0.0,0),
 ('HbA1c',720868,100.0,0.0,0),
 ('HbA1c',9234,1.0,0.0,0),
 ('Hb',8713,1.0,0.0,1),
 ('Hb',8636,0.1,0.0,0),
 ('Hb',8554,1.0,0.0,0),
 ('Hb',8753,1.6113,0.0,0),
 ('Hb',8840,0.001,0.0,0),
 ('Hb',9514,100.0,0.0,0),
 ('Hb',4121395,1.0,0.0,0),
 ('Hb',9503,1.0,0.0,0),
 ('INR',8523,1.0,0.0,1),
 ('INR',8524,1.0,0.0,0),
 ('Platelets',8961,1.0,0.0,1),
 ('Platelets',32706,10.0,0.0,0),
 ('Platelets',8848,1.0,0.0,0),
 ('Platelets',9444,1.0,0.0,0),
 ('Platelets',8888,0.001,0.0,0),
 ('Platelets',8647,0.001,0.0,0),
 ('Platelets',8785,0.001,0.0,0),
 ('Platelets',9436,0.001,0.0,0),
 ('PT',8555,1.0,0.0,1),
 ('PT',9212,1.0,0.0,0),
 ('Total bilirubin',8840,1.0,0.0,1),
 ('Total bilirubin',8749,0.05848,0.0,0),
 ('Total bilirubin',4121396,1.0,0.0,0),
 ('Total bilirubin',8713,1000.0,0.0,0),
 ('Total bilirubin',8753,58.48,0.0,0),
 ('Total bilirubin',8837,0.001,0.0,0);

-- lab normals table in the standard (used mostly) unit
DROP TABLE IF EXISTS @work_database_schema.@normals_table;
-- std_unit_concept_id = the unit_concept_id of the standard unit (the @work_database_schema.@unit_factor_table row where is_std=1)
CREATE TABLE @work_database_schema.@normals_table (cat varchar(40), std_unit_concept_id int, range_low float, range_high float, matching varchar(10));
INSERT INTO @work_database_schema.@normals_table (cat, std_unit_concept_id, range_low, range_high, matching) VALUES
 ('ANC',             8848, 2.5,  8.0,  'both'),
 ('Hb',              8713, 12.0, 17.5, 'both'),
 ('Platelets',       8961, 150,  450,  'both'),
 ('HbA1c',           8554, NULL, 5.7,  'upper'),
 ('Creatinine',      8840, 0.6,  1.3,  'both'),
 ('CrCl',            8795, 88,   137,  'both'),
 ('GFR',             8795, 90,   NULL, 'lower'),
 ('PT',              8555, 11,   13.5, 'both'),
 ('aPTT',            8555, 25,   35,   'both'),
 ('INR',             8523, 0.8,  1.2,  'both'),
 ('ALT',             8645, NULL, 56,   'upper'),
 ('AST',             8645, NULL, 40,   'upper'),
 ('Direct bilirubin',8840, NULL, 0.3,  'upper'),
 ('Total bilirubin', 8840, 0.3,  1.2,  'both');


DROP TABLE IF EXISTS @work_database_schema.@criteria_table;
-- basis: 'ULN' => bound = mult * upper-normal ;  'ABS' => bound is a fixed value already in standard units
--
-- TEST-ID ALLOCATION (keep this in sync when adding tests — see below):
--   1-23   original eligibility panel (unit-normalised thresholds).
--   24-43  RESERVED for clinical / biomarker tests not yet encoded:
--          24-27 ECOG 0/1/2/>=3, 28 liver metastasis, 29 Gilbert's,
--          30 Hb mmol/L (redundant — normalisation handles it, do not add),
--          31 anticoag exception, 32/33 neuropathy, 34 skin, 35 polyuria,
--          36 polydipsia, 37/38 NYHA, 39/40 hearing, 41 comorbidity grade,
--          42 PD-L1 CPS, 43 PD-L1 TIC.
--   44-48  Diagnostic-strata thresholds added 2026-07-09 (this file, below).
--   ->     Allocate NEW tests at 49+ to avoid collisions.
CREATE TABLE @work_database_schema.@criteria_table (test_id int, cat varchar(40), basis char(3),
   min_op varchar(2), min_val float, max_op varchar(2), max_val float, note varchar(120));
INSERT INTO @work_database_schema.@criteria_table (test_id, cat, basis, min_op, min_val, max_op, max_val, note) VALUES
 (1,  'aPTT',            'ULN', NULL, NULL, '<=', 1.5,  'aPTT <= 1.5 ULN'),
 (2,  'ALT',             'ULN', NULL, NULL, '<=', 2.5,  'ALT <= 2.5 ULN'),
 (3,  'ALT',             'ULN', NULL, NULL, '<=', 5.0,  'ALT <= 5 ULN'),
 (4,  'ANC',             'ABS', '>=', 1.5,  NULL, NULL, '1500/uL = 1.5 thousand/uL'),
 (5,  'AST',             'ULN', NULL, NULL, '<=', 2.5,  'AST <= 2.5 ULN'),
 (6,  'AST',             'ULN', NULL, NULL, '<=', 5.0,  'AST <= 5 ULN'),
 (7,  'CrCl',            'ABS', '>=', 30,   NULL, NULL, 'CrCl >= 30 mL/min'),
 (8,  'Creatinine',      'ULN', NULL, NULL, '<=', 1.5,  'Cr <= 1.5 ULN'),
 (9,  'Direct bilirubin','ULN', NULL, NULL, '<=', 1.0,  'DBil <= ULN'),
 (10, 'GFR',             'ABS', NULL, NULL, '<',  30,   'GFR < 30'),
 (11, 'GFR',             'ABS', '>=', 30,   '<=', 60,   'GFR 30-60 (inclusive)'),
 (12, 'GFR',             'ABS', NULL, NULL, '<',  60,   'GFR < 60'),
 (13, 'GFR',             'ABS', '>',  60,   NULL, NULL, 'GFR > 60'),
 (14, 'GFR',             'ABS', '>=', 30,   NULL, NULL, 'GFR >= 30'),
 (15, 'Hb',              'ABS', '>=', 9.0,  NULL, NULL, 'Hb >= 9.0 g/dL'),
 (16, 'HbA1c',           'ABS', '>=', 7.0,  '<=', 8.0,  'HbA1c 7-8% (inclusive)'),
 (17, 'HbA1c',           'ABS', NULL, NULL, '<',  6.0,  'HbA1c < 6%'),
 (18, 'INR',             'ULN', NULL, NULL, '<=', 1.5,  'INR <= 1.5 ULN'),
 (19, 'Platelets',       'ABS', '>=', 100,  NULL, NULL, '100000/uL = 100 thousand/uL'),
 (20, 'PT',              'ULN', NULL, NULL, '<=', 1.5,  'PT <= 1.5 ULN'),
 (21, 'Total bilirubin', 'ULN', NULL, NULL, '<=', 3.0,  'TBil <= 3 ULN'),
 (22, 'Total bilirubin', 'ULN', NULL, NULL, '<=', 1.5,  'TBil <= 1.5 ULN'),
 (23, 'Total bilirubin', 'ULN', '>',  1.5,  NULL, NULL, 'TBil > 1.5 ULN'),
 -- Diagnostic-strata thresholds (ids 44+; ids 24-43 reserved for ECOG / liver
 -- mets / neuropathy / NYHA / hearing / PD-L1 etc.). Values in standard units.
 -- The mmol/L Hb path needs no separate test: Hb is normalised to g/dL, so
 -- Hb >= 5.6 mmol/L == test 15 (>= 9 g/dL) post-conversion.
 (44, 'ANC',             'ABS', NULL, NULL, '<',  1.5,  'ANC < 1500/uL'),
 (45, 'Platelets',       'ABS', NULL, NULL, '<',  100,  'PLT < 100k/uL'),
 (46, 'HbA1c',           'ABS', '>=', 8.0,  NULL, NULL, 'HbA1c >= 8%'),
 (47, 'Hb',              'ABS', NULL, NULL, '<',  9.0,  'Hb < 9.0 g/dL'),
 (48, 'GFR',             'ABS', '>',  30,   '<',  60,   'GFR 30-60 (exclusive)');

/* ---------------------------------------------------------------------------
   1.  AGGREGATE measurements per (measurement_concept_id, unit_concept_id,
       provided range_low, provided range_high).
       The provided range is the lab/device reference -- a different range set
       usually means a different lab/device (maybe a different unit), so each is
       scored on its own.  No averaging.  Positive values only.

       Percentiles use ROW_NUMBER()/COUNT(*)/FLOOR instead of
       PERCENTILE_CONT ... WITHIN GROUP ... OVER, which SqlRender leaves
       untranslated (breaks PostgreSQL/BigQuery/SQLite/Spark/Hive/Impala).
       Interpolation reproduces PERCENTILE_CONT exactly (R quantile type 7):
         pos = p * (n - 1)  (zero-based), k = FLOOR(pos), frac = pos - k
         percentile = v[k] * (1 - frac) + v[k+1] * frac
       so ranked rows rn = k+1 and rn = k+2 contribute weights (1-frac), frac.
       (cat is 1:1 with measurement_concept_id in @cat_concept_table, so adding
       it to the partition/grouping changes nothing.)
   --------------------------------------------------------------------------- */
DROP TABLE IF EXISTS @work_database_schema.@grp_table;

WITH grp_base AS (
  SELECT cc.cat,
         m.measurement_concept_id                         AS m_id,
         m.unit_concept_id                                AS u_id,
         CASE WHEN m.range_low  > 0 THEN m.range_low  END AS rlo,
         CASE WHEN m.range_high > 0 THEN m.range_high END AS rhi,
         -- rlo_key/rhi_key: BigQuery-only fix, see docs/BIGQUERY.md
         -- ("Partitioning by expressions of type FLOAT64 is not allowed",
         -- found live, 2026-09-06) -- rlo/rhi (measurement.range_low/
         -- range_high) are FLOAT, which every other dialect here happily
         -- partitions by directly. Casting to VARCHAR only changes the
         -- partition KEY's representation, not any value returned; two
         -- floats partition together under this cast exactly when they
         -- would have partitioned together as floats (same value -> same
         -- string), so this is a no-op on every dialect's actual grouping.
         -- Computed once here rather than repeated in every PARTITION BY
         -- clause below.
         CASE WHEN m.range_low  > 0 THEN CAST(m.range_low  AS VARCHAR(50)) END AS rlo_key,
         CASE WHEN m.range_high > 0 THEN CAST(m.range_high AS VARCHAR(50)) END AS rhi_key,
         m.value_as_number                                AS val
    FROM @cdm_database_schema.measurement m
    JOIN @work_database_schema.@cat_concept_table cc
      ON cc.measurement_concept_id = m.measurement_concept_id
   WHERE m.value_as_number > 0
),
grp_ranked AS (
  SELECT cat, m_id, u_id, rlo, rhi, val,
         ROW_NUMBER() OVER (PARTITION BY cat, m_id, u_id, rlo_key, rhi_key ORDER BY val) AS rn,
         COUNT(*)     OVER (PARTITION BY cat, m_id, u_id, rlo_key, rhi_key)              AS n
    FROM grp_base
)
SELECT cat, m_id, u_id, rlo, rhi,
       COUNT(*) AS records,
       SUM(CASE WHEN rn = FLOOR(0.03 * (n - 1)) + 1
                THEN val * (1.0 - (0.03 * (n - 1) - FLOOR(0.03 * (n - 1))))
                WHEN rn = FLOOR(0.03 * (n - 1)) + 2
                THEN val * (0.03 * (n - 1) - FLOOR(0.03 * (n - 1)))
                ELSE 0 END) AS p03,
       SUM(CASE WHEN rn = FLOOR(0.25 * (n - 1)) + 1
                THEN val * (1.0 - (0.25 * (n - 1) - FLOOR(0.25 * (n - 1))))
                WHEN rn = FLOOR(0.25 * (n - 1)) + 2
                THEN val * (0.25 * (n - 1) - FLOOR(0.25 * (n - 1)))
                ELSE 0 END) AS p25,
       SUM(CASE WHEN rn = FLOOR(0.75 * (n - 1)) + 1
                THEN val * (1.0 - (0.75 * (n - 1) - FLOOR(0.75 * (n - 1))))
                WHEN rn = FLOOR(0.75 * (n - 1)) + 2
                THEN val * (0.75 * (n - 1) - FLOOR(0.75 * (n - 1)))
                ELSE 0 END) AS p75,
       SUM(CASE WHEN rn = FLOOR(0.97 * (n - 1)) + 1
                THEN val * (1.0 - (0.97 * (n - 1) - FLOOR(0.97 * (n - 1))))
                WHEN rn = FLOOR(0.97 * (n - 1)) + 2
                THEN val * (0.97 * (n - 1) - FLOOR(0.97 * (n - 1)))
                ELSE 0 END) AS p97
  INTO @work_database_schema.@grp_table
  FROM grp_ranked
 GROUP BY cat, m_id, u_id, rlo, rhi;

/* ---------------------------------------------------------------------------
   2.  SCORE every candidate scale (distinct factor+val_offset for the cat).
       range_decade: provided range vs normal range -- PRIMARY (device's own reference)
       dist_decade : percentile distribution vs normal range (only if records>20)
       score       : range_decade if a range is present, else dist_decade.
                     The distribution is the lesser method: it is bias-prone
                     (mixed healthy/sick population, bimodal, skewed), so it is
                     only a fallback when the group has no provided range.
   --------------------------------------------------------------------------- */
-- @work_database_schema.@scales_table = the DISTINCT factor+val_offset per cat. NOT a copy of @work_database_schema.@unit_factor_table: many
-- unit_concept_ids share one factor (e.g. ALT has 4 units but 1 factor), so this
-- collapses synonyms to one scale each -- otherwise that scale would be scored N
-- times, inflating grp_npass (is_ambiguous) and giving ROW_NUMBER duplicate winners.
DROP TABLE IF EXISTS @work_database_schema.@scales_table;
SELECT DISTINCT cat, factor, val_offset INTO @work_database_schema.@scales_table FROM @work_database_schema.@unit_factor_table;

DROP TABLE IF EXISTS @work_database_schema.@scored_table;
SELECT
  g.m_id, g.u_id, g.rlo, g.rhi, g.cat, g.records, s.factor, s.val_offset,
  -- range_decade: bound-to-bound vs the standard normal, gated on the normal's matching.
  --   'both'  -> data must supply BOTH bounds (else NULL -> distribution)
  --   'upper' -> data must supply the high bound (else NULL -> distribution)
  --   'lower' -> data must supply the low bound  (else NULL -> distribution)
  -- A future 'lower'-only-high (or any matching/data mismatch) falls to NULL by design.
  CASE n.matching
    WHEN 'both'  THEN CASE WHEN g.rlo > 0 AND g.rhi > 0 AND n.range_low > 0 AND n.range_high > 0
        THEN ABS( (LOG10(n.range_low)+LOG10(n.range_high))/2
                - (LOG10(g.rlo*s.factor+s.val_offset)+LOG10(g.rhi*s.factor+s.val_offset))/2 ) END
    WHEN 'upper' THEN CASE WHEN g.rhi > 0 AND n.range_high > 0
        THEN ABS( LOG10(n.range_high) - LOG10(g.rhi*s.factor+s.val_offset) ) END
    WHEN 'lower' THEN CASE WHEN g.rlo > 0 AND n.range_low > 0
        THEN ABS( LOG10(n.range_low)  - LOG10(g.rlo*s.factor+s.val_offset) ) END
  END AS range_decade,
  -- distribution decade: bound-to-bound with p25-p75 for both, and similarly for upper and lower
  CASE WHEN g.records > 20 THEN
    CASE n.matching
      WHEN 'both'  THEN CASE WHEN g.p25 > 0 AND g.p75 > 0 AND n.range_low > 0 AND n.range_high > 0
          THEN ABS( (LOG10(n.range_low)+LOG10(n.range_high))/2
                  - (LOG10(g.p25*s.factor+s.val_offset)+LOG10(g.p75*s.factor+s.val_offset))/2 ) END
      -- GREATEST-via-VALUES (the SQL Server <2022 compatibility trick this file's header
      -- flags) fails on Snowflake specifically: a VALUES()-clause derived table there can't
      -- reference outer-query columns ("Invalid expression [CORRELATION(...)] in VALUES
      -- clause" -- confirmed via a minimal repro against live Snowflake). Native GREATEST()
      -- works on Snowflake, Postgres, Redshift, Oracle, and SQL Server 2022+ (verified
      -- SqlRender has no dialect-specific translation rule for GREATEST -- passes through
      -- unchanged everywhere); only pre-2022 SQL Server loses compatibility here.
      WHEN 'upper' THEN CASE WHEN g.p03 > 0 AND g.p97 > 0 AND n.range_high > 0
          THEN GREATEST(0.0,
                   (LOG10(n.range_high) - LOG10(g.p97*s.factor+s.val_offset)),
                   (LOG10(g.p03*s.factor+s.val_offset) - LOG10(n.range_high)) ) END
      WHEN 'lower' THEN CASE WHEN g.p03 > 0 AND g.p97 > 0 AND n.range_low > 0
          THEN GREATEST(0.0,
                   (LOG10(n.range_low) - LOG10(g.p97*s.factor+s.val_offset)),
                   (LOG10(g.p03*s.factor+s.val_offset) - LOG10(n.range_low)) ) END
    END
  END AS dist_decade
INTO @work_database_schema.@scored_table
FROM @work_database_schema.@grp_table g
JOIN @work_database_schema.@scales_table  s ON s.cat = g.cat
JOIN @work_database_schema.@normals_table n ON n.cat = g.cat;

/* ---------------------------------------------------------------------------
   3.  RESOLVE the unit/factor per group.
       The single best scale wins (ORDER BY score, rn=1); 0.7 is only a floor.
       Policy: verify the recorded unit first -> if it passes use it;
               else override with the best; else (no signal) trust recorded;
               else unresolved.  is_ambiguous = more than one scale cleared 0.7
               (e.g. Hb g/dL vs mmol/L are ~0.21 decades apart).
   --------------------------------------------------------------------------- */
DROP TABLE IF EXISTS @work_database_schema.@resolved_table;
SELECT m_id, u_id, rlo, rhi, cat,
-- conversion factor for best match
   CASE WHEN prov_score < 0.7 THEN prov_factor
        WHEN grp_best   < 0.7 THEN factor
        WHEN grp_best IS NULL AND prov_factor IS NOT NULL THEN prov_factor
        ELSE NULL END AS factor,
-- val_offset for best match
   CASE WHEN prov_score < 0.7 THEN prov_offset
        WHEN grp_best   < 0.7 THEN val_offset
        WHEN grp_best IS NULL AND prov_factor IS NOT NULL THEN prov_offset
        ELSE NULL END AS val_offset,
-- assessement for match:
-- verified if provided unit=best match unit, overridden with best if they don't match
-- unverified if unit provided but no match, unresolved if nothing
   CASE WHEN prov_score < 0.7 THEN 'verified'
        WHEN grp_best   < 0.7 THEN 'overridden'
        WHEN grp_best IS NULL AND prov_factor IS NOT NULL THEN 'unverified'
        ELSE 'unresolved' END AS status,
   CASE WHEN grp_npass > 1 THEN 1 ELSE 0 END AS is_ambiguous,
   grp_best AS best_score, prov_score
INTO @work_database_schema.@resolved_table
FROM (
   SELECT i.*,
      MIN(score)                                   OVER (PARTITION BY m_id, u_id, rlo_key, rhi_key) AS grp_best,
      SUM(CASE WHEN score < 0.7 THEN 1 ELSE 0 END) OVER (PARTITION BY m_id, u_id, rlo_key, rhi_key) AS grp_npass,
      MAX(CASE WHEN is_provided = 1 THEN score  END) OVER (PARTITION BY m_id, u_id, rlo_key, rhi_key) AS prov_score,
      MAX(CASE WHEN is_provided = 1 THEN factor END) OVER (PARTITION BY m_id, u_id, rlo_key, rhi_key) AS prov_factor,
      MAX(CASE WHEN is_provided = 1 THEN val_offset END) OVER (PARTITION BY m_id, u_id, rlo_key, rhi_key) AS prov_offset,
      ROW_NUMBER() OVER (PARTITION BY m_id, u_id, rlo_key, rhi_key ORDER BY CASE WHEN score IS NULL THEN 1 ELSE 0 END, score) AS rn
   FROM (
      -- rlo_key/rhi_key: BigQuery-only fix, see the matching NB above
      -- grp_ranked's definition earlier in this file / docs/BIGQUERY.md.
      -- Computed once here rather than repeated in every PARTITION BY
      -- clause above.
      SELECT sc.m_id, sc.u_id, sc.rlo, sc.rhi,
             CAST(sc.rlo AS VARCHAR(50)) AS rlo_key, CAST(sc.rhi AS VARCHAR(50)) AS rhi_key,
             sc.cat, sc.factor, sc.val_offset,
             COALESCE(sc.range_decade, sc.dist_decade) AS score,   -- range first, distribution only as fallback
             CASE WHEN uf.unit_concept_id IS NOT NULL THEN 1 ELSE 0 END AS is_provided
      FROM @work_database_schema.@scored_table sc
      LEFT JOIN @work_database_schema.@unit_factor_table uf
             ON uf.cat = sc.cat AND uf.unit_concept_id = sc.u_id
            AND uf.factor = sc.factor AND uf.val_offset = sc.val_offset
   ) i
) z
WHERE rn = 1;

/* ---------------------------------------------------------------------------
   4.  EVALUATE thresholds  ->  standardized value, ULN, and the test bounds
   --------------------------------------------------------------------------- */
DROP TABLE IF EXISTS @work_database_schema.@raw_lab_results_table;
SELECT
   t.test_id, m.person_id, m.measurement_date, t.cat, m.measurement_concept_id, m.unit_concept_id,
   t.basis, t.min_op, t.max_op,
   (m.value_as_number * r.factor + r.val_offset)                                   AS std_value,
   COALESCE(NULLIF(m.range_high,0) * r.factor + r.val_offset, n.range_high)         AS uln_std,
   CASE WHEN t.basis = 'ULN'
        THEN t.min_val * COALESCE(NULLIF(m.range_high,0)*r.factor+r.val_offset, n.range_high)
        ELSE t.min_val END                                                      AS min_bound,
   CASE WHEN t.basis = 'ULN'
        THEN t.max_val * COALESCE(NULLIF(m.range_high,0)*r.factor+r.val_offset, n.range_high)
        ELSE t.max_val END                                                      AS max_bound,
   r.status, r.is_ambiguous
INTO @work_database_schema.@raw_lab_results_table
FROM @cdm_database_schema.measurement m
JOIN @work_database_schema.@cat_concept_table cc ON cc.measurement_concept_id = m.measurement_concept_id
JOIN @work_database_schema.@resolved_table    r  ON r.m_id = m.measurement_concept_id AND r.u_id = m.unit_concept_id
    AND COALESCE(r.rlo,-1) = COALESCE(CASE WHEN m.range_low>0  THEN m.range_low  END,-1)
    AND COALESCE(r.rhi,-1) = COALESCE(CASE WHEN m.range_high>0 THEN m.range_high END,-1)
JOIN @work_database_schema.@criteria_table  t  ON t.cat = cc.cat
JOIN @work_database_schema.@normals_table     n  ON n.cat = cc.cat
WHERE m.value_as_number > 0
  AND r.factor IS NOT NULL;          -- unit must be resolvable to convert

/* ---------------------------------------------------------------------------
   5.  COHORT  (one row per qualifying measurement)
   --------------------------------------------------------------------------- */
DROP TABLE IF EXISTS @work_database_schema.@lab_cohort_table;
CREATE TABLE @work_database_schema.@lab_cohort_table (
   cohort_definition_id INT,
   subject_id           BIGINT,
   cohort_start_date    DATE,
   cohort_end_date      DATE
);
INSERT INTO @work_database_schema.@lab_cohort_table (cohort_definition_id, subject_id, cohort_start_date, cohort_end_date)
SELECT DISTINCT e.test_id, e.person_id, e.measurement_date, e.measurement_date
FROM @work_database_schema.@raw_lab_results_table e
WHERE (e.basis = 'ABS' OR e.uln_std IS NOT NULL)            -- ULN tests need a usable ULN
  AND ( e.min_op IS NULL
        OR (e.min_op = '>=' AND e.std_value >= e.min_bound)
        OR (e.min_op = '>'  AND e.std_value >  e.min_bound) )
  AND ( e.max_op IS NULL
        OR (e.max_op = '<=' AND e.std_value <= e.max_bound)
        OR (e.max_op = '<'  AND e.std_value <  e.max_bound) );

/* ---------------------------------------------------------------------------
   6.  DEBUG  -- combinations that could not be evaluated, with the reason
   --------------------------------------------------------------------------- */
DROP TABLE IF EXISTS @work_database_schema.@debug_table;
SELECT test_id, cat, measurement_concept_id, unit_concept_id, reason, COUNT(*) AS record_count
INTO @work_database_schema.@debug_table
FROM (
   SELECT e.test_id, e.cat, e.measurement_concept_id, e.unit_concept_id,
          'ULN missing (no provided range_high, no normal high)' AS reason
   FROM @work_database_schema.@raw_lab_results_table e
   WHERE e.basis = 'ULN' AND e.uln_std IS NULL
   UNION ALL
   SELECT t.test_id, cc.cat, m.measurement_concept_id, m.unit_concept_id,
          'unit unresolved (no scale within 0.7 decades)' AS reason
   FROM @cdm_database_schema.measurement m
   JOIN @work_database_schema.@cat_concept_table cc ON cc.measurement_concept_id = m.measurement_concept_id
   JOIN @work_database_schema.@criteria_table  t  ON t.cat = cc.cat
   LEFT JOIN @work_database_schema.@resolved_table r ON r.m_id = m.measurement_concept_id AND r.u_id = m.unit_concept_id
    AND COALESCE(r.rlo,-1) = COALESCE(CASE WHEN m.range_low>0  THEN m.range_low  END,-1)
    AND COALESCE(r.rhi,-1) = COALESCE(CASE WHEN m.range_high>0 THEN m.range_high END,-1)
   WHERE m.value_as_number > 0 AND r.factor IS NULL
) d
GROUP BY test_id, cat, measurement_concept_id, unit_concept_id, reason;

-- Audit helpers:
--   SELECT * FROM @work_database_schema.@resolved_table WHERE status IN ('overridden','unresolved','unverified') OR is_ambiguous = 1;
--   SELECT * FROM @work_database_schema.@debug_table ORDER BY record_count DESC;


