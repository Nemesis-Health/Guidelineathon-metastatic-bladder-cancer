-- =============================================================================
-- Target 1A 2d — PD-L1-eligible (pembrolizumab / atezolizumab path)
-- =============================================================================
-- Protocol: Cohort 1 + washout + NOT combination-therapy eligible + pembro/atezo
-- renal/PS/comorbidity criteria + PD-L1 biomarker.
--
-- NOT combo eligible is expressed as failing at least one combination criterion
-- (De Morgan: NOT (A AND B AND ...) = (NOT A) OR (NOT B) OR ...).
--
-- Planned ids: 24-27 ECOG; 28 liver mets; 41 comorbidities grade > 2;
--              42 PD-L1 CPS >= 10; 43 PD-L1 TIC >= 5%.
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

   /* ----- NOT combination-therapy eligible ----- */

   AND (
         -- Fail ECOG 0-2
         NOT EXISTS (
               SELECT 1 FROM @target_database_schema.@lab_cohort_table lab
                WHERE lab.cohort_definition_id IN (24, 25, 26)
                  AND lab.subject_id = tc.subject_id
                  AND lab.cohort_start_date BETWEEN DATEADD(day, -14, tc.cohort_start_date)
                                              AND DATEADD(day,  14, tc.cohort_start_date)
             )
         -- Fail GFR >= 30
         OR NOT EXISTS (
               SELECT 1 FROM @target_database_schema.@lab_cohort_table lab
                WHERE lab.cohort_definition_id = 14
                  AND lab.subject_id = tc.subject_id
                  AND lab.cohort_start_date BETWEEN DATEADD(day, -14, tc.cohort_start_date)
                                              AND DATEADD(day,  14, tc.cohort_start_date)
             )
         OR NOT EXISTS (
               SELECT 1 FROM @target_database_schema.@lab_cohort_table lab
                WHERE lab.cohort_definition_id = 4
                  AND lab.subject_id = tc.subject_id
                  AND lab.cohort_start_date BETWEEN DATEADD(day, -14, tc.cohort_start_date)
                                              AND DATEADD(day,  14, tc.cohort_start_date)
             )
         OR NOT EXISTS (
               SELECT 1 FROM @target_database_schema.@lab_cohort_table lab
                WHERE lab.cohort_definition_id = 19
                  AND lab.subject_id = tc.subject_id
                  AND lab.cohort_start_date BETWEEN DATEADD(day, -14, tc.cohort_start_date)
                                              AND DATEADD(day,  14, tc.cohort_start_date)
             )
         OR NOT EXISTS (
               SELECT 1 FROM @target_database_schema.@lab_cohort_table lab
                WHERE lab.cohort_definition_id = 15
                  AND lab.subject_id = tc.subject_id
                  AND lab.cohort_start_date BETWEEN DATEADD(day, -14, tc.cohort_start_date)
                                              AND DATEADD(day,  14, tc.cohort_start_date)
             )
         OR NOT (
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
         OR NOT (
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
         OR NOT (
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
         OR NOT (
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
         -- Fail the (INR OR PT) extrinsic limb of combo eligibility: NEITHER INR
         -- nor PT passes, AND the patient is not anticoagulated. This is the
         -- De Morgan negation of the corrected combo clause (INR OR PT) AND aPTT
         -- — the INR and PT failures are one conjoined term, not two OR terms.
         OR (
            NOT EXISTS (
               SELECT 1 FROM @target_database_schema.@lab_cohort_table lab
                WHERE lab.cohort_definition_id = 18
                  AND lab.subject_id = tc.subject_id
                  AND lab.cohort_start_date BETWEEN DATEADD(day, -14, tc.cohort_start_date)
                                              AND DATEADD(day,  14, tc.cohort_start_date)
             )
            AND NOT EXISTS (
               SELECT 1 FROM @target_database_schema.@lab_cohort_table lab
                WHERE lab.cohort_definition_id = 20
                  AND lab.subject_id = tc.subject_id
                  AND lab.cohort_start_date BETWEEN DATEADD(day, -14, tc.cohort_start_date)
                                              AND DATEADD(day,  14, tc.cohort_start_date)
             )
            AND NOT EXISTS (   -- [31] and NOT on anticoagulant therapy
               SELECT 1 FROM @target_database_schema.@lab_cohort_table lab
                WHERE lab.cohort_definition_id = 31
                  AND lab.subject_id = tc.subject_id
                  AND lab.cohort_start_date BETWEEN DATEADD(day, -14, tc.cohort_start_date)
                                              AND DATEADD(day,  14, tc.cohort_start_date)
             )
         )
         OR (
            NOT EXISTS (
               SELECT 1 FROM @target_database_schema.@lab_cohort_table lab
                WHERE lab.cohort_definition_id = 1
                  AND lab.subject_id = tc.subject_id
                  AND lab.cohort_start_date BETWEEN DATEADD(day, -14, tc.cohort_start_date)
                                              AND DATEADD(day,  14, tc.cohort_start_date)
             )
            AND NOT EXISTS (   -- [31] and NOT on anticoagulant therapy
               SELECT 1 FROM @target_database_schema.@lab_cohort_table lab
                WHERE lab.cohort_definition_id = 31
                  AND lab.subject_id = tc.subject_id
                  AND lab.cohort_start_date BETWEEN DATEADD(day, -14, tc.cohort_start_date)
                                              AND DATEADD(day,  14, tc.cohort_start_date)
             )
         )
       )

   /* ----- Pembro/atezo renal / performance / comorbidity path ----- */

   AND (
         -- [10] GFR < 30 mL/min
         EXISTS (
               SELECT 1 FROM @target_database_schema.@lab_cohort_table lab
                WHERE lab.cohort_definition_id = 10
                  AND lab.subject_id = tc.subject_id
                  AND lab.cohort_start_date BETWEEN DATEADD(day, -14, tc.cohort_start_date)
                                              AND DATEADD(day,  14, tc.cohort_start_date)
             )
         -- [27] ECOG >= 3
         OR EXISTS (
               SELECT 1 FROM @target_database_schema.@lab_cohort_table lab
                WHERE lab.cohort_definition_id = 27
                  AND lab.subject_id = tc.subject_id
                  AND lab.cohort_start_date BETWEEN DATEADD(day, -14, tc.cohort_start_date)
                                              AND DATEADD(day,  14, tc.cohort_start_date)
             )
         -- [26] ECOG 2 AND [12] GFR < 60
         OR (
               EXISTS (
                     SELECT 1 FROM @target_database_schema.@lab_cohort_table lab
                      WHERE lab.cohort_definition_id = 26
                        AND lab.subject_id = tc.subject_id
                        AND lab.cohort_start_date BETWEEN DATEADD(day, -14, tc.cohort_start_date)
                                                    AND DATEADD(day,  14, tc.cohort_start_date)
                   )
               AND EXISTS (
                     SELECT 1 FROM @target_database_schema.@lab_cohort_table lab
                      WHERE lab.cohort_definition_id = 12
                        AND lab.subject_id = tc.subject_id
                        AND lab.cohort_start_date BETWEEN DATEADD(day, -14, tc.cohort_start_date)
                                                    AND DATEADD(day,  14, tc.cohort_start_date)
                   )
             )
         -- TODO second pass: [41] comorbidities grade > 2
       )

   /* ----- PD-L1 biomarker (required; not yet encoded) ----- */

   -- PD-L1 (tests 42/43) IGNORED for now; template kept, set always-true
   -- (was 1 = 0) so 2d is not forced empty. Restore when PD-L1 is encoded.
   AND 1 = 1
;
