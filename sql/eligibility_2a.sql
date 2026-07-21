-- =============================================================================
-- Target 1A 2a — Enfortumab-eligible
-- =============================================================================
-- Protocol: Cohort 1 + washout + combination-therapy eligible + enfortumab-
-- eligible. Index/end dates inherited from Cohort 1 (metastasis).
--
-- SqlRender parameters:
--   @target_database_schema, @target_cohort_table, @target_cohort_id
--   @lab_cohort_table   — eligibility measurement table (lab_cohorts.sql output)
--   @regimen_episode_table
--   @cohort1_id
--
-- Eligibility rows: cohort_definition_id = test_id in @lab_cohort_table.
-- Each qualifying measurement must fall within [index - 14, index + 14] days
-- unless noted otherwise.
--
-- test_id reference (lab_cohorts.sql #criteria, ids 1-23):
--   1  aPTT <= 1.5 ULN          14 GFR >= 30 mL/min
--   2  ALT <= 2.5 ULN            15 Hb >= 9.0 g/dL
--   3  ALT <= 5 ULN              16 HbA1c 7-8%
--   4  ANC >= 1500/uL            17 HbA1c < 6%
--   5  AST <= 2.5 ULN            18 INR <= 1.5 ULN
--   6  AST <= 5 ULN              19 Platelets >= 100k/uL
--   7  CrCl >= 30 mL/min         20 PT <= 1.5 ULN
--   8  Creatinine <= 1.5 ULN     21 TBil <= 3 ULN (Gilbert's; needs test 29)
--   9  DBil <= ULN               22 TBil <= 1.5 ULN
--                              23 TBil > 1.5 ULN
--
-- Planned test_ids (not yet in lab_cohorts.sql):
--   24 ECOG 0   25 ECOG 1   26 ECOG 2   28 Liver metastasis
--   30 Hb >= 5.6 mmol/L   32 Neuropathy grade < 2   34 No skin disorder
--   35 No polyuria   36 No polydipsia (for HbA1c 7-8% path with test 16)
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

   /* ----- Washout: no systemic regimen in [index - 365, index - 30) ----- */
   AND NOT EXISTS (
         SELECT 1
           FROM @target_database_schema.@regimen_episode_table re
          WHERE CAST(re.person_id AS BIGINT) = tc.subject_id
            AND re.episode_start_date <  DATEADD(day, -30, tc.cohort_start_date)
            AND re.episode_end_date   >= DATEADD(day, -365, tc.cohort_start_date)
       )

   /* ----- Combination-therapy eligible ----- */

   -- [24-26] ECOG 0-2 at index
   AND EXISTS (
         SELECT 1
           FROM @target_database_schema.@lab_cohort_table lab
          WHERE lab.cohort_definition_id IN (24, 25, 26)
            AND lab.subject_id = tc.subject_id
            AND lab.cohort_start_date BETWEEN DATEADD(day, -@lab_window_before_days, tc.cohort_start_date)
                                        AND DATEADD(day, @lab_window_after_days, tc.cohort_start_date)
       )

   -- [14] GFR >= 30 mL/min
   AND EXISTS (
         SELECT 1
           FROM @target_database_schema.@lab_cohort_table lab
          WHERE lab.cohort_definition_id = 14
            AND lab.subject_id = tc.subject_id
            AND lab.cohort_start_date BETWEEN DATEADD(day, -@lab_window_before_days, tc.cohort_start_date)
                                        AND DATEADD(day, @lab_window_after_days, tc.cohort_start_date)
       )

   -- [4] ANC >= 1500/uL
   AND EXISTS (
         SELECT 1
           FROM @target_database_schema.@lab_cohort_table lab
          WHERE lab.cohort_definition_id = 4
            AND lab.subject_id = tc.subject_id
            AND lab.cohort_start_date BETWEEN DATEADD(day, -@lab_window_before_days, tc.cohort_start_date)
                                        AND DATEADD(day, @lab_window_after_days, tc.cohort_start_date)
       )

   -- [19] Platelets >= 100,000/uL
   AND EXISTS (
         SELECT 1
           FROM @target_database_schema.@lab_cohort_table lab
          WHERE lab.cohort_definition_id = 19
            AND lab.subject_id = tc.subject_id
            AND lab.cohort_start_date BETWEEN DATEADD(day, -@lab_window_before_days, tc.cohort_start_date)
                                        AND DATEADD(day, @lab_window_after_days, tc.cohort_start_date)
       )

   -- [15] Hb >= 9.0 g/dL  (mmol/L folds in via unit normalisation)
   AND EXISTS (
         SELECT 1
           FROM @target_database_schema.@lab_cohort_table lab
          WHERE lab.cohort_definition_id = 15
            AND lab.subject_id = tc.subject_id
            AND lab.cohort_start_date BETWEEN DATEADD(day, -@lab_window_before_days, tc.cohort_start_date)
                                        AND DATEADD(day, @lab_window_after_days, tc.cohort_start_date)
       )

   -- Creatinine: [8] Cr <= 1.5 ULN  OR  [7] CrCl >= 30
   AND (
         EXISTS (
               SELECT 1
                 FROM @target_database_schema.@lab_cohort_table lab
                WHERE lab.cohort_definition_id = 8
                  AND lab.subject_id = tc.subject_id
                  AND lab.cohort_start_date BETWEEN DATEADD(day, -@lab_window_before_days, tc.cohort_start_date)
                                              AND DATEADD(day, @lab_window_after_days, tc.cohort_start_date)
             )
         OR EXISTS (
               SELECT 1
                 FROM @target_database_schema.@lab_cohort_table lab
                WHERE lab.cohort_definition_id = 7
                  AND lab.subject_id = tc.subject_id
                  AND lab.cohort_start_date BETWEEN DATEADD(day, -@lab_window_before_days, tc.cohort_start_date)
                                              AND DATEADD(day, @lab_window_after_days, tc.cohort_start_date)
             )
       )

   -- Bilirubin: [22] TBil <= 1.5 ULN
   --         OR ([23] TBil > 1.5 ULN AND [9] DBil <= ULN)
   --         OR ([21] TBil <= 3 ULN AND Gilbert's syndrome [29])
   AND (
         EXISTS (
               SELECT 1
                 FROM @target_database_schema.@lab_cohort_table lab
                WHERE lab.cohort_definition_id = 22
                  AND lab.subject_id = tc.subject_id
                  AND lab.cohort_start_date BETWEEN DATEADD(day, -@lab_window_before_days, tc.cohort_start_date)
                                              AND DATEADD(day, @lab_window_after_days, tc.cohort_start_date)
             )
         OR (
               EXISTS (
                     SELECT 1
                       FROM @target_database_schema.@lab_cohort_table lab
                      WHERE lab.cohort_definition_id = 23
                        AND lab.subject_id = tc.subject_id
                        AND lab.cohort_start_date BETWEEN DATEADD(day, -@lab_window_before_days, tc.cohort_start_date)
                                                    AND DATEADD(day, @lab_window_after_days, tc.cohort_start_date)
                   )
               AND EXISTS (
                     SELECT 1
                       FROM @target_database_schema.@lab_cohort_table lab
                      WHERE lab.cohort_definition_id = 9
                        AND lab.subject_id = tc.subject_id
                        AND lab.cohort_start_date BETWEEN DATEADD(day, -@lab_window_before_days, tc.cohort_start_date)
                                                    AND DATEADD(day, @lab_window_after_days, tc.cohort_start_date)
                   )
             )
         OR ( EXISTS (
               SELECT 1
                 FROM @target_database_schema.@lab_cohort_table lab
                WHERE lab.cohort_definition_id = 21
                  AND lab.subject_id = tc.subject_id
                  AND lab.cohort_start_date BETWEEN DATEADD(day, -@lab_window_before_days, tc.cohort_start_date)
                                              AND DATEADD(day, @lab_window_after_days, tc.cohort_start_date)
             )
               AND EXISTS (   -- [29] Gilbert's syndrome gates the TBil <= 3x ULN branch
                     SELECT 1 FROM @target_database_schema.@lab_cohort_table lab
                      WHERE lab.cohort_definition_id = 29
                        AND lab.subject_id = tc.subject_id
                        AND lab.cohort_start_date <= DATEADD(day, @lab_window_after_days, tc.cohort_start_date)
                   )
             )
       )

   -- AST: [5] <= 2.5 ULN  OR  ([6] <= 5 ULN AND [28] liver metastasis)
   AND (
         EXISTS (
               SELECT 1
                 FROM @target_database_schema.@lab_cohort_table lab
                WHERE lab.cohort_definition_id = 5
                  AND lab.subject_id = tc.subject_id
                  AND lab.cohort_start_date BETWEEN DATEADD(day, -@lab_window_before_days, tc.cohort_start_date)
                                              AND DATEADD(day, @lab_window_after_days, tc.cohort_start_date)
             )
         OR (
               EXISTS (
                     SELECT 1
                       FROM @target_database_schema.@lab_cohort_table lab
                      WHERE lab.cohort_definition_id = 6
                        AND lab.subject_id = tc.subject_id
                        AND lab.cohort_start_date BETWEEN DATEADD(day, -@lab_window_before_days, tc.cohort_start_date)
                                                    AND DATEADD(day, @lab_window_after_days, tc.cohort_start_date)
                   )
               AND EXISTS (
                     SELECT 1
                       FROM @target_database_schema.@lab_cohort_table lab
                      WHERE lab.cohort_definition_id = 28
                        AND lab.subject_id = tc.subject_id
                        AND lab.cohort_start_date <= DATEADD(day, @lab_window_after_days, tc.cohort_start_date)
                   )
             )
       )

   -- ALT: [2] <= 2.5 ULN  OR  ([3] <= 5 ULN AND [28] liver metastasis)
   AND (
         EXISTS (
               SELECT 1
                 FROM @target_database_schema.@lab_cohort_table lab
                WHERE lab.cohort_definition_id = 2
                  AND lab.subject_id = tc.subject_id
                  AND lab.cohort_start_date BETWEEN DATEADD(day, -@lab_window_before_days, tc.cohort_start_date)
                                              AND DATEADD(day, @lab_window_after_days, tc.cohort_start_date)
             )
         OR (
               EXISTS (
                     SELECT 1
                       FROM @target_database_schema.@lab_cohort_table lab
                      WHERE lab.cohort_definition_id = 3
                        AND lab.subject_id = tc.subject_id
                        AND lab.cohort_start_date BETWEEN DATEADD(day, -@lab_window_before_days, tc.cohort_start_date)
                                                    AND DATEADD(day, @lab_window_after_days, tc.cohort_start_date)
                   )
               AND EXISTS (
                     SELECT 1
                       FROM @target_database_schema.@lab_cohort_table lab
                      WHERE lab.cohort_definition_id = 28
                        AND lab.subject_id = tc.subject_id
                        AND lab.cohort_start_date <= DATEADD(day, @lab_window_after_days, tc.cohort_start_date)
                   )
             )
       )

   -- Coag extrinsic limb — protocol: (INR <= 1.5 ULN OR PT <= 1.5 ULN).
   -- INR is the normalised form of PT (same coagulation pathway), so either one
   -- present-and-passing satisfies this limb; anticoagulant therapy (test 31)
   -- waives it. aPTT is a separate AND (below).
   AND (
       ( -- [18] INR <= 1.5 ULN
         EXISTS (
         SELECT 1
           FROM @target_database_schema.@lab_cohort_table lab
          WHERE lab.cohort_definition_id = 18
            AND lab.subject_id = tc.subject_id
            AND lab.cohort_start_date BETWEEN DATEADD(day, -@lab_window_before_days, tc.cohort_start_date)
                                        AND DATEADD(day, @lab_window_after_days, tc.cohort_start_date)
       )
      OR EXISTS (   -- [31] on anticoagulant therapy waives this coag criterion
               SELECT 1 FROM @target_database_schema.@lab_cohort_table lab
                WHERE lab.cohort_definition_id = 31
                  AND lab.subject_id = tc.subject_id
                  AND lab.cohort_start_date BETWEEN DATEADD(day, -@lab_window_before_days, tc.cohort_start_date)
                                              AND DATEADD(day, @lab_window_after_days, tc.cohort_start_date)
             )
       )
      OR
       ( -- [20] PT <= 1.5 ULN
         EXISTS (
         SELECT 1
           FROM @target_database_schema.@lab_cohort_table lab
          WHERE lab.cohort_definition_id = 20
            AND lab.subject_id = tc.subject_id
            AND lab.cohort_start_date BETWEEN DATEADD(day, -@lab_window_before_days, tc.cohort_start_date)
                                        AND DATEADD(day, @lab_window_after_days, tc.cohort_start_date)
       )
      OR EXISTS (   -- [31] on anticoagulant therapy waives this coag criterion
               SELECT 1 FROM @target_database_schema.@lab_cohort_table lab
                WHERE lab.cohort_definition_id = 31
                  AND lab.subject_id = tc.subject_id
                  AND lab.cohort_start_date BETWEEN DATEADD(day, -@lab_window_before_days, tc.cohort_start_date)
                                              AND DATEADD(day, @lab_window_after_days, tc.cohort_start_date)
             )
       )
   )

   -- [1] aPTT <= 1.5 ULN  (anticoagulant exception wired via test 31, below)
   AND (
         EXISTS (
         SELECT 1
           FROM @target_database_schema.@lab_cohort_table lab
          WHERE lab.cohort_definition_id = 1
            AND lab.subject_id = tc.subject_id
            AND lab.cohort_start_date BETWEEN DATEADD(day, -@lab_window_before_days, tc.cohort_start_date)
                                        AND DATEADD(day, @lab_window_after_days, tc.cohort_start_date)
       )
      OR EXISTS (   -- [31] on anticoagulant therapy waives this coag criterion
               SELECT 1 FROM @target_database_schema.@lab_cohort_table lab
                WHERE lab.cohort_definition_id = 31
                  AND lab.subject_id = tc.subject_id
                  AND lab.cohort_start_date BETWEEN DATEADD(day, -@lab_window_before_days, tc.cohort_start_date)
                                              AND DATEADD(day, @lab_window_after_days, tc.cohort_start_date)
             )
   )

   /* ----- Enfortumab-eligible ----- */

   -- HbA1c: [17] < 6%  OR  ([16] 7-8% AND (NO polyuria [35] OR NO polydipsia [36]))
   --
   -- NOTE — polyuria/polydipsia limb follows the LITERAL Cohort logics.pdf spec,
   -- which is a fixed study requirement (implemented verbatim, not by discretion):
   --   "(NO Polyuria OR NO Polydipsia)"  =>  (NOT EXISTS 35) OR (NOT EXISTS 36).
   -- This excludes a 7-8% patient ONLY if they have BOTH polyuria AND polydipsia;
   -- a single symptom still passes, so the limb almost never fires.
   -- Known concern (recorded, NOT acted on here): clinically you would expect to
   -- exclude on EITHER symptom (AND), since both are cardinal signs of
   -- uncontrolled hyperglycaemia and EV carries a hyperglycaemia risk — and the
   -- PDF itself highlights this clause as "Need to discuss". DO NOT change the OR
   -- below to AND on clinical grounds alone: it encodes a stated requirement and
   -- may only change via a requirements/protocol update. See COHORT_AUDIT.md F4.
   AND (
         EXISTS (
               SELECT 1
                 FROM @target_database_schema.@lab_cohort_table lab
                WHERE lab.cohort_definition_id = 17
                  AND lab.subject_id = tc.subject_id
                  AND lab.cohort_start_date BETWEEN DATEADD(day, -@lab_window_before_days, tc.cohort_start_date)
                                              AND DATEADD(day, @lab_window_after_days, tc.cohort_start_date)
             )
         OR (
               EXISTS (
                     SELECT 1
                       FROM @target_database_schema.@lab_cohort_table lab
                      WHERE lab.cohort_definition_id = 16
                        AND lab.subject_id = tc.subject_id
                        AND lab.cohort_start_date BETWEEN DATEADD(day, -@lab_window_before_days, tc.cohort_start_date)
                                                    AND DATEADD(day, @lab_window_after_days, tc.cohort_start_date)
                   )
               -- (NO polyuria [35] OR NO polydipsia [36]) — literal PDF; see NOTE above
               AND (
                  NOT EXISTS (SELECT 1 FROM @target_database_schema.@lab_cohort_table lab
                      WHERE lab.cohort_definition_id = 35 AND lab.subject_id = tc.subject_id
                        AND lab.cohort_start_date BETWEEN DATEADD(day, -@lab_window_before_days, tc.cohort_start_date)
                                                    AND DATEADD(day, @lab_window_after_days, tc.cohort_start_date))
                  OR NOT EXISTS (SELECT 1 FROM @target_database_schema.@lab_cohort_table lab
                      WHERE lab.cohort_definition_id = 36 AND lab.subject_id = tc.subject_id
                        AND lab.cohort_start_date BETWEEN DATEADD(day, -@lab_window_before_days, tc.cohort_start_date)
                                                    AND DATEADD(day, @lab_window_after_days, tc.cohort_start_date))
               )
             )
       )

   -- Enfortumab: no significant peripheral neuropathy (test 33); pre-existing
   -- = any record on/before index+14d.
   AND NOT EXISTS (SELECT 1 FROM @target_database_schema.@lab_cohort_table lab
          WHERE lab.cohort_definition_id = 33 AND lab.subject_id = tc.subject_id
            AND lab.cohort_start_date <= DATEADD(day, @lab_window_after_days, tc.cohort_start_date))

   -- Enfortumab: no pre-existing significant skin disorders (test 34).
   AND NOT EXISTS (SELECT 1 FROM @target_database_schema.@lab_cohort_table lab
          WHERE lab.cohort_definition_id = 34 AND lab.subject_id = tc.subject_id
            AND lab.cohort_start_date <= DATEADD(day, @lab_window_after_days, tc.cohort_start_date))
;
