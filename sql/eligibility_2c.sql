-- =============================================================================
-- Target 1A 2c — Carboplatin-eligible (cisplatin-ineligible)
-- =============================================================================
-- Protocol: Cohort 1 + washout + combination-therapy eligible + NOT enfortumab-
-- eligible + NOT cisplatin-eligible + carboplatin-eligible.
--
-- See eligibility_2a.sql for full test_id reference.
-- Planned ids: 24-26 ECOG; 28 liver mets; 33 neuropathy >= 2; 38 NYHA >= III;
--              40 hearing loss grade >= 2.
-- =============================================================================

DELETE FROM @target_database_schema.@target_cohort_table
 WHERE cohort_definition_id = @target_cohort_id;

INSERT INTO @target_database_schema.@target_cohort_table
  (cohort_definition_id, subject_id, cohort_start_date, cohort_end_date)
SELECT @target_cohort_id AS cohort_definition_id,
       tc.subject_id,
       tc.cohort_start_date,
       tc.cohort_end_date
  FROM @target_database_schema.@target_cohort_table tc
 WHERE tc.cohort_definition_id = @cohort1_id

   /* ----- Washout ----- */
   AND NOT EXISTS (
         SELECT 1
           FROM @target_database_schema.@regimen_episode_table re
          WHERE CAST(re.person_id AS BIGINT) = tc.subject_id
            AND re.episode_start_date <  DATEADD(day, -30, tc.cohort_start_date)
            AND re.episode_end_date   >= DATEADD(day, -365, tc.cohort_start_date)
       )

   /* ----- Combination-therapy eligible (same criteria as 2a) ----- */

   AND EXISTS (
         SELECT 1 FROM @target_database_schema.@lab_cohort_table lab
          WHERE lab.cohort_definition_id IN (24, 25, 26)
            AND lab.subject_id = tc.subject_id
            AND lab.cohort_start_date BETWEEN DATEADD(day, -14, tc.cohort_start_date)
                                        AND DATEADD(day,  14, tc.cohort_start_date)
       )
   AND EXISTS (
         SELECT 1 FROM @target_database_schema.@lab_cohort_table lab
          WHERE lab.cohort_definition_id = 14
            AND lab.subject_id = tc.subject_id
            AND lab.cohort_start_date BETWEEN DATEADD(day, -14, tc.cohort_start_date)
                                        AND DATEADD(day,  14, tc.cohort_start_date)
       )
   AND EXISTS (
         SELECT 1 FROM @target_database_schema.@lab_cohort_table lab
          WHERE lab.cohort_definition_id = 4
            AND lab.subject_id = tc.subject_id
            AND lab.cohort_start_date BETWEEN DATEADD(day, -14, tc.cohort_start_date)
                                        AND DATEADD(day,  14, tc.cohort_start_date)
       )
   AND EXISTS (
         SELECT 1 FROM @target_database_schema.@lab_cohort_table lab
          WHERE lab.cohort_definition_id = 19
            AND lab.subject_id = tc.subject_id
            AND lab.cohort_start_date BETWEEN DATEADD(day, -14, tc.cohort_start_date)
                                        AND DATEADD(day,  14, tc.cohort_start_date)
       )
   AND EXISTS (
         SELECT 1 FROM @target_database_schema.@lab_cohort_table lab
          WHERE lab.cohort_definition_id = 15
            AND lab.subject_id = tc.subject_id
            AND lab.cohort_start_date BETWEEN DATEADD(day, -14, tc.cohort_start_date)
                                        AND DATEADD(day,  14, tc.cohort_start_date)
       )
   AND (
         EXISTS (
               SELECT 1 FROM @target_database_schema.@lab_cohort_table lab
                WHERE lab.cohort_definition_id = 8
                  AND lab.subject_id = tc.subject_id
                  AND lab.cohort_start_date BETWEEN DATEADD(day, -14, tc.cohort_start_date)
                                              AND DATEADD(day,  14, tc.cohort_start_date)
             )
         OR EXISTS (
               SELECT 1 FROM @target_database_schema.@lab_cohort_table lab
                WHERE lab.cohort_definition_id = 7
                  AND lab.subject_id = tc.subject_id
                  AND lab.cohort_start_date BETWEEN DATEADD(day, -14, tc.cohort_start_date)
                                              AND DATEADD(day,  14, tc.cohort_start_date)
             )
       )
   AND (
         EXISTS (
               SELECT 1 FROM @target_database_schema.@lab_cohort_table lab
                WHERE lab.cohort_definition_id = 22
                  AND lab.subject_id = tc.subject_id
                  AND lab.cohort_start_date BETWEEN DATEADD(day, -14, tc.cohort_start_date)
                                              AND DATEADD(day,  14, tc.cohort_start_date)
             )
         OR (
               EXISTS (
                     SELECT 1 FROM @target_database_schema.@lab_cohort_table lab
                      WHERE lab.cohort_definition_id = 23
                        AND lab.subject_id = tc.subject_id
                        AND lab.cohort_start_date BETWEEN DATEADD(day, -14, tc.cohort_start_date)
                                                    AND DATEADD(day,  14, tc.cohort_start_date)
                   )
               AND EXISTS (
                     SELECT 1 FROM @target_database_schema.@lab_cohort_table lab
                      WHERE lab.cohort_definition_id = 9
                        AND lab.subject_id = tc.subject_id
                        AND lab.cohort_start_date BETWEEN DATEADD(day, -14, tc.cohort_start_date)
                                                    AND DATEADD(day,  14, tc.cohort_start_date)
                   )
             )
         OR ( EXISTS (
               SELECT 1 FROM @target_database_schema.@lab_cohort_table lab
                WHERE lab.cohort_definition_id = 21
                  AND lab.subject_id = tc.subject_id
                  AND lab.cohort_start_date BETWEEN DATEADD(day, -14, tc.cohort_start_date)
                                              AND DATEADD(day,  14, tc.cohort_start_date)
             )
               AND EXISTS (   -- [29] Gilbert's syndrome gates the TBil <= 3x ULN branch
                     SELECT 1 FROM @target_database_schema.@lab_cohort_table lab
                      WHERE lab.cohort_definition_id = 29
                        AND lab.subject_id = tc.subject_id
                        AND lab.cohort_start_date <= DATEADD(day, 14, tc.cohort_start_date)
                   )
             )
       )
   AND (
         EXISTS (
               SELECT 1 FROM @target_database_schema.@lab_cohort_table lab
                WHERE lab.cohort_definition_id = 5
                  AND lab.subject_id = tc.subject_id
                  AND lab.cohort_start_date BETWEEN DATEADD(day, -14, tc.cohort_start_date)
                                              AND DATEADD(day,  14, tc.cohort_start_date)
             )
         OR (
               EXISTS (
                     SELECT 1 FROM @target_database_schema.@lab_cohort_table lab
                      WHERE lab.cohort_definition_id = 6
                        AND lab.subject_id = tc.subject_id
                        AND lab.cohort_start_date BETWEEN DATEADD(day, -14, tc.cohort_start_date)
                                                    AND DATEADD(day,  14, tc.cohort_start_date)
                   )
               AND EXISTS (
                     SELECT 1 FROM @target_database_schema.@lab_cohort_table lab
                      WHERE lab.cohort_definition_id = 28
                        AND lab.subject_id = tc.subject_id
                        AND lab.cohort_start_date <= DATEADD(day, 14, tc.cohort_start_date)
                   )
             )
       )
   AND (
         EXISTS (
               SELECT 1 FROM @target_database_schema.@lab_cohort_table lab
                WHERE lab.cohort_definition_id = 2
                  AND lab.subject_id = tc.subject_id
                  AND lab.cohort_start_date BETWEEN DATEADD(day, -14, tc.cohort_start_date)
                                              AND DATEADD(day,  14, tc.cohort_start_date)
             )
         OR (
               EXISTS (
                     SELECT 1 FROM @target_database_schema.@lab_cohort_table lab
                      WHERE lab.cohort_definition_id = 3
                        AND lab.subject_id = tc.subject_id
                        AND lab.cohort_start_date BETWEEN DATEADD(day, -14, tc.cohort_start_date)
                                                    AND DATEADD(day,  14, tc.cohort_start_date)
                   )
               AND EXISTS (
                     SELECT 1 FROM @target_database_schema.@lab_cohort_table lab
                      WHERE lab.cohort_definition_id = 28
                        AND lab.subject_id = tc.subject_id
                        AND lab.cohort_start_date <= DATEADD(day, 14, tc.cohort_start_date)
                   )
             )
       )
   -- Coag extrinsic limb — protocol: (INR <= 1.5 ULN OR PT <= 1.5 ULN).
   -- INR is the normalised form of PT (same pathway); either satisfies. aPTT
   -- is a separate AND (below). Anticoagulant therapy (test 31) waives it.
   AND (
       ( -- [18] INR <= 1.5 ULN
         EXISTS (
         SELECT 1 FROM @target_database_schema.@lab_cohort_table lab
          WHERE lab.cohort_definition_id = 18
            AND lab.subject_id = tc.subject_id
            AND lab.cohort_start_date BETWEEN DATEADD(day, -14, tc.cohort_start_date)
                                        AND DATEADD(day,  14, tc.cohort_start_date)
       )
      OR EXISTS (   -- [31] on anticoagulant therapy waives this coag criterion
               SELECT 1 FROM @target_database_schema.@lab_cohort_table lab
                WHERE lab.cohort_definition_id = 31
                  AND lab.subject_id = tc.subject_id
                  AND lab.cohort_start_date BETWEEN DATEADD(day, -14, tc.cohort_start_date)
                                              AND DATEADD(day,  14, tc.cohort_start_date)
             )
       )
      OR
       ( -- [20] PT <= 1.5 ULN
         EXISTS (
         SELECT 1 FROM @target_database_schema.@lab_cohort_table lab
          WHERE lab.cohort_definition_id = 20
            AND lab.subject_id = tc.subject_id
            AND lab.cohort_start_date BETWEEN DATEADD(day, -14, tc.cohort_start_date)
                                        AND DATEADD(day,  14, tc.cohort_start_date)
       )
      OR EXISTS (   -- [31] on anticoagulant therapy waives this coag criterion
               SELECT 1 FROM @target_database_schema.@lab_cohort_table lab
                WHERE lab.cohort_definition_id = 31
                  AND lab.subject_id = tc.subject_id
                  AND lab.cohort_start_date BETWEEN DATEADD(day, -14, tc.cohort_start_date)
                                              AND DATEADD(day,  14, tc.cohort_start_date)
             )
       )
   )
   AND (
         EXISTS (
         SELECT 1 FROM @target_database_schema.@lab_cohort_table lab
          WHERE lab.cohort_definition_id = 1
            AND lab.subject_id = tc.subject_id
            AND lab.cohort_start_date BETWEEN DATEADD(day, -14, tc.cohort_start_date)
                                        AND DATEADD(day,  14, tc.cohort_start_date)
       )
      OR EXISTS (   -- [31] on anticoagulant therapy waives this coag criterion
               SELECT 1 FROM @target_database_schema.@lab_cohort_table lab
                WHERE lab.cohort_definition_id = 31
                  AND lab.subject_id = tc.subject_id
                  AND lab.cohort_start_date BETWEEN DATEADD(day, -14, tc.cohort_start_date)
                                              AND DATEADD(day,  14, tc.cohort_start_date)
             )
   )

   /* ----- NOT enfortumab-eligible: exact anti-join on cohort 2a ----- */
   -- 2a is generated before this cohort, so we exclude anyone already claimed by
   -- the EV arm (captures the full EV definition: HbA1c AND neuropathy AND skin).

   AND NOT EXISTS (
         SELECT 1 FROM @target_database_schema.@target_cohort_table ev
          WHERE ev.subject_id = tc.subject_id
            AND ev.cohort_definition_id = @cohort2a_id
       )

   /* ----- NOT cisplatin-eligible: exact anti-join on cohort 2b ----- */
   -- 2b is generated before this cohort; excludes anyone already on the cisplatin
   -- arm (captures the full cisplatin definition, not just ECOG/GFR).

   AND NOT EXISTS (
         SELECT 1 FROM @target_database_schema.@target_cohort_table cis
          WHERE cis.subject_id = tc.subject_id
            AND cis.cohort_definition_id = @cohort2b_id
       )

   /* ----- Carboplatin-eligible (any one) ----- */

   AND (
         -- [26] ECOG 2
         EXISTS (
               SELECT 1 FROM @target_database_schema.@lab_cohort_table lab
                WHERE lab.cohort_definition_id = 26
                  AND lab.subject_id = tc.subject_id
                  AND lab.cohort_start_date BETWEEN DATEADD(day, -14, tc.cohort_start_date)
                                              AND DATEADD(day,  14, tc.cohort_start_date)
             )
         -- [11] GFR 30-60 mL/min
         OR EXISTS (
               SELECT 1 FROM @target_database_schema.@lab_cohort_table lab
                WHERE lab.cohort_definition_id = 11
                  AND lab.subject_id = tc.subject_id
                  AND lab.cohort_start_date BETWEEN DATEADD(day, -14, tc.cohort_start_date)
                                              AND DATEADD(day,  14, tc.cohort_start_date)
             )
         -- NYHA class >= III: IGNORED for now (no NYHA concept set).
         -- [40] audiometric hearing loss present (grade >= 2 proxy)
         OR EXISTS (
               SELECT 1 FROM @target_database_schema.@lab_cohort_table lab
                WHERE lab.cohort_definition_id = 40
                  AND lab.subject_id = tc.subject_id
                  AND lab.cohort_start_date <= DATEADD(day, 14, tc.cohort_start_date)
             )
         -- [33] peripheral neuropathy present (grade >= 2 proxy)
         OR EXISTS (
               SELECT 1 FROM @target_database_schema.@lab_cohort_table lab
                WHERE lab.cohort_definition_id = 33
                  AND lab.subject_id = tc.subject_id
                  AND lab.cohort_start_date <= DATEADD(day, 14, tc.cohort_start_date)
             )
       )
;
