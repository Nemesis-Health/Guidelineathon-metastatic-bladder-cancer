# Eligibility cohort logic (2a–2e) — plain-English

How each eligibility leaf is constructed in `sql/eligibility_2*.sql`. This is the
human-readable companion to the SQL; for the table plumbing (test-id allocation,
Approach A) see [DEVELOPMENT.md](../DEVELOPMENT.md).

## How to read this

- Every criterion is checked against the **unified eligibility table**
  `bc_lab_cohort`, by `test_id`. `[N]` below is that test-id.
- Unless noted, a criterion means **"the patient has a qualifying row within ±14
  days of their Target 1A (metastasis) index date."** A few conditions
  (liver-mets, neuropathy, skin, hearing) instead use **"any record on or before
  index + 14 days"** (pre-existing).
- The leaves are **mutually exclusive by construction**: 2b excludes enfortumab-
  eligible patients, 2c excludes enfortumab- and cisplatin-eligible, 2d is the
  "not combination-eligible" branch, and **2e is everyone in Cohort 1 not placed
  in 2a–2d**.
- All of 2a–2d also require the **washout** and the base **Cohort 1** membership.

---

## Building block 1 — Washout (2a–2d)

The patient must have **no prior systemic anti-cancer regimen** overlapping the
window `[index − 365 days, index − 30 days)` (from the ARTEMIS episode table). In
plain terms: no systemic therapy in the year before mBC, allowing a 30-day grace
window around the index.

## Building block 2 — Combination-therapy panel

Required in full by **2a, 2b, 2c** (and *negated* for 2d). The patient must meet
**every** one of these:

| Criterion | Logic |
|---|---|
| Performance status | ECOG 0, 1, **or** 2 `[24/25/26]` |
| Renal (GFR) | GFR ≥ 30 mL/min `[14]` |
| Neutrophils | ANC ≥ 1500/µL `[4]` |
| Platelets | PLT ≥ 100,000/µL `[19]` |
| Haemoglobin | Hb ≥ 9.0 g/dL `[15]` (mmol/L folds in via unit normalisation) |
| Creatinine | Cr ≤ 1.5× ULN `[8]` **OR** CrCl ≥ 30 mL/min `[7]` |
| Bilirubin | TBil ≤ 1.5× ULN `[22]` **OR** (TBil > 1.5× `[23]` **AND** DBil ≤ ULN `[9]`) **OR** (TBil ≤ 3× ULN `[21]` **AND** Gilbert's syndrome `[29]`) |
| AST | AST ≤ 2.5× ULN `[5]` **OR** (AST ≤ 5× ULN `[6]` **AND** liver metastasis `[28]`) |
| ALT | ALT ≤ 2.5× ULN `[2]` **OR** (ALT ≤ 5× ULN `[3]` **AND** liver metastasis `[28]`) |
| INR | INR ≤ 1.5× ULN `[18]` **OR** on anticoagulant therapy `[31]` |
| PT | PT ≤ 1.5× ULN `[20]` **OR** on anticoagulant therapy `[31]` |
| aPTT | aPTT ≤ 1.5× ULN `[1]` **OR** on anticoagulant therapy `[31]` |

One caveat baked into this panel:
- **Anticoagulant exception is approximate** — being on anticoagulant therapy
  `[31]` waives INR/PT/aPTT, but the protocol's "…as long as PT/aPTT is in
  therapeutic range" is not checked (no therapeutic-range concept).

---

## 2a — Enfortumab-eligible (EV)

**Cohort 1 + washout + full combination panel + these enfortumab criteria:**

- **HbA1c:** < 6% `[17]` **OR** ( 7–8% `[16]` **AND** no polyuria `[not 35]`
  **AND** no polydipsia `[not 36]` ).
- **No** significant peripheral neuropathy `[not 33]`.
- **No** pre-existing significant skin disorders `[not 34]`.

In words: a combination-eligible patient whose diabetes control is acceptable
(or well-controlled without osmotic symptoms) and who has neither significant
neuropathy nor significant skin disease.

## 2b — Cisplatin-eligible

**Cohort 1 + washout + full combination panel + NOT enfortumab-eligible + these
cisplatin criteria:**

- **NOT enfortumab-eligible**: the patient is **not in cohort 2a** (exact
  anti-join on the real EV cohort — so it reflects the *full* EV definition:
  HbA1c **and** neuropathy **and** skin, not just one signal).
- **ECOG 0–1** `[24/25]`.
- **GFR > 60** mL/min `[13]`.
- **NYHA class < III** — **IGNORED** (assume-pass; no NYHA concept set).
- **No** significant audiometric hearing loss `[not 40]`.
- **No** significant peripheral neuropathy `[not 33]`.

## 2c — Carboplatin-eligible

**Cohort 1 + washout + full combination panel + NOT enfortumab + NOT cisplatin +
at least one carboplatin-qualifying factor:**

- **NOT enfortumab-eligible**: not in cohort 2a (exact anti-join, as in 2b).
- **NOT cisplatin-eligible**: the patient is **not in cohort 2b** (exact anti-join
  on the real cisplatin cohort — reflects the full cisplatin definition, not just
  ECOG/GFR).
- **At least one of** (the reasons a patient can't get cisplatin but can get
  carboplatin):
  - ECOG 2 `[26]`, **or**
  - 30 < GFR < 60 mL/min `[11]`, **or**
  - NYHA class ≥ III — **IGNORED**, **or**
  - significant hearing loss `[40]`, **or**
  - significant peripheral neuropathy `[33]`.

## 2d — PD-L1-eligible (pembrolizumab / atezolizumab)

**Cohort 1 + washout + NOT combination-eligible + a renal/PS reason + PD-L1
biomarker:**

- **NOT combination-therapy eligible** — expressed as "fails **at least one**
  combination criterion" (De Morgan of the panel above). The coagulation part is
  anticoag-aware: failing INR means *both* INR > 1.5× **and** not on
  anticoagulants.
- **At least one of:**
  - GFR < 30 mL/min `[10]`, **or**
  - ECOG ≥ 3 `[27]`, **or**
  - ( ECOG 2 `[26]` **AND** GFR < 60 `[12]` ), **or**
  - comorbidity grade > 2 — **not encoded** (TODO; omitted).
- **PD-L1 biomarker** (CPS ≥ 10 Dako 22C3 **OR** TIC ≥ 5% Ventana SP142) —
  **IGNORED** (assume-pass; set always-true). So 2d currently accepts anyone who
  is not combination-eligible and has a qualifying renal/PS reason, **without** a
  real PD-L1 check.

## 2e — Ineligible for any recommendation

**Cohort 1 members who are not in 2a, 2b, 2c, or 2d** (a straight anti-join on the
cohort table). Generated last, after 2a–2d exist. Everyone the tree can't place on
a recommended path lands here.

---

## What this means for the counts

- Because the combination panel requires INR **and** PT (unless on anticoagulants)
  — and those had no data at HUS — **2a–2c will be ~0 there** except for
  anticoagulated patients. See [DEVELOPMENT.md §9](../DEVELOPMENT.md#9-known-gaps--decisions).
- The `NOT enfortumab` / `NOT cisplatin` exclusions are **exact anti-joins** on
  the real 2a / 2b cohorts (like 2e), so the arms are cleanly mutually exclusive
  in strict priority order — no patient double-counts, and none is dropped for a
  not-looked-at reason.
- `2d` is broad while PD-L1 is ignored; treat its counts as "not-combination-
  eligible with a renal/PS reason," not "true PD-L1-eligible."
