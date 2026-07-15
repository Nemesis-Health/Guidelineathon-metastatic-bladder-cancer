# Docs — bladder eligibility study

## Authoritative (this project)
- [`../README.md`](../README.md) — overview + run instructions + file map.
- [`../DEVELOPMENT.md`](../DEVELOPMENT.md) — architecture, cohort logic, the
  **test-id allocation**, ordering guarantees, how to extend, known gaps.
- [`ELIGIBILITY_LOGIC.md`](ELIGIBILITY_LOGIC.md) — **plain-English construction of
  each eligibility leaf (2a–2e)** and the combination panel.

## Protocol
- `GDE_Bladder Cancer Protocol Draft_10JUN2025.docx` — the study protocol
  (source of truth for eligibility criteria and the cohort decision tree).

## Reference (`reference/`) — copied from `onco-study-modules`
> These describe the **package** pipeline (Approach B, `run_bladder_study.R`
> SECTIONs, package paths). The **protocol content and eligibility criteria are
> valid**, but implementation details (how eligibility reads the table, driver
> structure, some test-id wiring) differ from this standalone — for those, trust
> `../DEVELOPMENT.md`. Kept as background, not maintained here.

| File | Use it for |
|---|---|
| `STUDY_PLAN.md` | Protocol → code mapping; the distilled study requirements (§1). |
| `COHORT_LOGIC.md` | The full cohort tree — selection criteria, index/end dates, joins. |
| `ELIGIBILITY_IMPLEMENTATION.md` | Protocol eligibility → `test_id` → SQL; the **list of what's still missing** (tests 24–43). |
| `COHORT_REGISTRY.md` | Master T*/S* code list with implementation status and gaps. |
| `DIAGNOSTIC_COHORTS_NOTES.md` | Working notes on the diagnostic strata + test-id allocation. |
| `STAKEHOLDER_UPDATE.md` | Stakeholder-facing status summary. |

**Key deltas vs. these reference docs (this standalone):**
- Eligibility inputs (labs + ECOG + conditions) all live in **one table**
  (`bc_lab_cohort`); the package reference describes labs-only in that table.
- ECOG is split into 0/1/2/≥3 and the five conditions are wired as **exclusions**
  — the reference docs list these as "missing / second pass".
- `cohorts/02_Covariate/` here holds **only** the eligibility-input cohorts (PS,
  ECOG, conditions); the pure comorbidity/characterisation cohorts were dropped.
