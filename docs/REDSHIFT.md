# Redshift: much slower than the other three dialects — root cause found, partially fixed

Redshift correctly runs this pipeline (no functional bugs found), but is dramatically slower
than Postgres/SQL Server/Snowflake against the exact same byte-identical seeded data
(`bladder_mbc.yaml`, `--seed 42`, 560 patients). Same `00_setup.sql` diagnostics query, four
dialects:

| Target | `00_setup.sql` time |
|---|---|
| SQL Server | 16.9 secs |
| Snowflake | 1.49 mins |
| Postgres | 1.72 mins |
| **Redshift** | **7.09 mins** |

The gap persists (and gets worse in relative terms) once cohort generation starts: individual
Circe-generated cohort queries that took low single-digit seconds on the other three dialects
took **47 secs - 2 min each** on Redshift (found live, 2026-09-05, full `run.R` pipeline run).

## Root cause: two independent, compounding factors

**1. Redshift Serverless was provisioned at the absolute minimum compute tier.**
`aws redshift-serverless list-workgroups` showed `baseCapacity: 8` — 8 RPU is the AWS floor for
Redshift Serverless; production workloads typically run 32-512+ RPU. This is a "dev" environment
sized for cost, not throughput.

**2. The OMOP vocabulary tables are large regardless of patient count, and have no real
distribution/sort keys.** Redshift has no traditional indexes — it uses `DISTKEY`/`SORTKEY`
instead, and Circe-generated cohort SQL (for any concept set that expands to descendant
concepts, i.e. most of them) joins against these. Queried `svv_table_info` (`cdm` schema)
directly:

| Table | Rows | Distribution |
|---|---|---|
| `concept_ancestor` | 80,876,374 | `AUTO(EVEN)` — round-robin, no real key |
| `concept_relationship` | 40,208,768 | `AUTO(EVEN)` |
| `concept` | 5,187,881 | `AUTO(EVEN)` |
| `person` (for comparison) | 560 | `AUTO(ALL)` |

`concept_ancestor`/`concept_relationship` are the full OMOP vocabulary, sized independently of
the 560-patient cohort — a query joining against an 80M-row table with no join-key colocation,
on 8 RPU of compute, is exactly the kind of thing that costs ~1-2 minutes per query regardless
of how small the actual patient population is. This also explains a pattern seen in the
`run.R` log itself: within stage (c) (main cohort tree), the first 4 cohorts — which build the
population fresh off raw CDM tables — took ~2 min each, while the next 29 — which mostly filter
the now-small, already-materialized cohort tables instead of re-touching `concept_ancestor` —
dropped to 4-13 sec each. Stage (h) (19 fresh comorbidity/covariate cohorts, each its own
concept-set expansion) went back up to ~47-55 sec each, consistent with the same cause
recurring per fresh concept-set query rather than being a one-time cold-start cost.

## What was done

Bumped the workgroup's base capacity **8 -> 32 RPU**, live via:

```bash
aws redshift-serverless update-workgroup --workgroup-name onco-dialect-replication-dev --base-capacity 32
```

and persisted the change so a future `terraform apply` doesn't silently revert it — updated the
`default` on `redshift_base_capacity_rpu` in `onco-test-data/terraform/variables.tf` (no
`.tfvars` override exists for this variable, so the default is what's actually deployed).

**⚠️ Do not change `base_capacity` while a connection to this workgroup is open.** The bump was
first applied mid-run (while a full `run.R` pass against Redshift was already executing). That
session did not speed up afterward, then over the following ~11 minutes went completely silent
(confirmed via Redshift's own `sys_query_history` -- zero queries submitted by that session in
that window) before finally dying with:

```
com.amazon.redshift.util.RedshiftException: An I/O error occurred while sending to the backend.
```

on the next cohort query (mid-run, on a comorbidity cohort -- not data-dependent, just whichever
cohort happened to run next after the capacity change). Leading explanation (not confirmed by
AWS documentation, but consistent with every symptom observed): `update-workgroup` likely
tears down/reprovisions the compute behind the workgroup, which breaks any already-open
connection to it outright -- the ~11 min of silence being however long the JDBC driver's
default TCP timeouts took to notice the socket was dead, not the query actually running that
whole time. **Apply any Redshift Serverless capacity change BEFORE opening the connection for
that run, never mid-session** -- confirmed safe when done that way (see Status below).

## Status: 32 RPU confirmed *not* to fix it — the bottleneck isn't compute size

Re-ran the full `run.R` pipeline against Redshift from a **fresh connection**, opened only after
the workgroup had been sitting `AVAILABLE` at 32 RPU for several minutes (the correct sequencing
per the warning above). Result: **no meaningful speedup.** `00_setup.sql` took 6.62 min (vs. 7.09
min at 8 RPU); the stage (h) covariate-cohort queries were still ~47-55 sec each, statistically
indistinguishable from the original 8 RPU run. 4x the compute bought effectively nothing.

The run did complete correctly this time (all 33 main-tree + 19 covariate cohorts generated, no
errors), and — the actual point of this whole exercise — **its output is byte-identical to
Postgres/SQL Server/Snowflake** across every file checked (`cohort_counts.csv`,
`outcome_os_summary.csv`, `charlson_cci.csv`, `guideline_adherence.csv`,
`treatment_pattern_untreated.csv`). So Redshift is fully *correct*, just slow, and now confirmed
not RPU-bound.

**Decision (2026-09-05, explicit user call)**: keep the workgroup at 32 RPU rather than revert —
per `onco-test-data/aws_dialect_replication_plan/REDSHIFT_QUERY_PERFORMANCE.md`'s cost
breakdown, the difference is only ~$11 per hour-long full pipeline test run at eu-west-2's
on-demand rate ($0.467/RPU-hr), not "hugely expensive" for occasional testing.

## `DISTSTYLE ALL` on the vocabulary tables — also tested live, also confirmed NOT sufficient

Applied `ALTER TABLE ... ALTER DISTSTYLE ALL` + a real `SORTKEY` live to the currently-deployed
`cdm.concept`/`concept_ancestor`/`concept_relationship`/`concept_synonym`/`drug_strength` (+5
smaller reference tables) — full mechanism/reasoning in
`onco-test-data/aws_dialect_replication_plan/REDSHIFT_QUERY_PERFORMANCE.md`. Confirmed applied
(`svv_table_info` showed `DISTSTYLE = ALL`, real `SORTKEY1`/`SORTKEY_NUM` afterward), then
re-ran the full pipeline from a fresh connection. **Result: no meaningful speedup either.**
`00_setup.sql` took 6.59 min (statistically identical to both 7.09 min @ 8 RPU and 6.62 min @ 32
RPU beforehand); main-tree cohorts 1-4 were still ~1.83-2.03 min each. Two independent, plausible
theories (compute, distribution) now both directly falsified by live testing.

## The actual root cause: found via `sys_query_history`, not guessing

Rather than propose a third theory, pulled the real server-side timing breakdown for the slow
queries directly (`SELECT ... FROM sys_query_history`, which — unlike the more commonly-known
`stl_query`/`svl_compile` — exposes `compile_time`, `planning_time`, `queue_time`, and
`execution_time` separately per query). Two distinct, unrelated mechanisms turned up, together
explaining every slow point observed above:

**1. `DatabaseConnector::insertTable()`'s Redshift-specific `ctasHack()` fallback (fixed).**
`insertTable.default`'s dispatch (`useCtasHack <- dbms %in% c("pdw", "redshift", "bigquery",
"hive") && createTable && !useBulkLoad`) means Redshift — unlike Postgres/SQL Server, which use
an efficient parameterized batch insert regardless — builds a literal `CREATE TABLE ... AS WITH
data (...) AS (SELECT 'x','y',... UNION ALL SELECT ...)` for every row whenever `insertTable()`
is called without `bulkLoad = TRUE`. For a 1618-row reference table, `sys_query_history` showed
**`elapsed_time` 220 sec, of which `planning_time` alone was 215 sec** (`compile_time` 0.08 sec,
`execution_time` 2.6 sec) — Redshift's query *planner*, not its executor, scales very badly with
UNION ALL branch count. Two call sites in this repo hit it: `R/01_artemis.R` (the `regimenClass`
reference table) and `R/artemis.R` (`writeArtemisEpisodes()`'s episode-staging table). **Fixed**
by turning on `insertTable()`'s own built-in bulk-load switch (`Sys.getenv
("DATABASE_CONNECTOR_BULK_UPLOAD")`, applied automatically without either call site needing to
check which backend it's talking to) — confirmed live, 2026-09-05: `"Bulk load to Redshift took
3.12 secs"` / `"2.97 secs"`, down from tens-of-seconds-to-minutes. See README.md's matching note
for the `Sys.setenv(...)` this requires (a long-lived IAM key — session/SSO credentials don't
work for
Redshift's `COPY`).

**2. Fixed per-statement round-trip latency, multiplied by statement count (NOT fixed — mostly
not ours to fix).** `00_setup.sql` executes as **157 sequential statements**
(`DatabaseConnector::executeSql()`/`SqlRender::splitSql()`). Cross-checking consecutive
statements' `start_time` in `sys_query_history` during this run: gaps between statements were
consistently **~1.8-2 seconds apart**, while each statement's own `elapsed_time` was under 0.2
sec — i.e. the time isn't server-side query cost at all, it's overhead *between* statements.
**Update, 2026-09-06**: this is NOT Serverless-specific — the same pattern, and near-identical
total timing, was confirmed live on a provisioned cluster too (see "Provisioned cluster tested"
below). 157 statements × ~2 sec ≈
5-6 min, matching the observed ~6.6 min almost exactly. This same mechanism, not distribution or
compute, also explains the cohort-generation timings: main-tree cohorts 1-4 (which Circe expands
into dozens of sequential temp-table/inclusion-stat statements each) at ~2 min match ~50-60
statements × ~2 sec; cohorts 5-33 (simple filters, a handful of statements each) at 4-13 sec
match; the 19 covariate cohorts (~47-55 sec each, moderate statement count) match too. **Not
fixed**: `00_setup.sql`'s 157 statements are ours and could in principle be rewritten to use
fewer round-trips (batching, CTEs instead of temp tables) — a real but substantial rewrite, not
attempted here. The cohort-generation statement counts are CirceR/CohortGenerator's own internal
SQL generation (external OHDSI packages) — not something this pipeline can rewrite directly.

## Provisioned cluster tested (2026-09-06) — NOT Serverless-specific

Ran this full pipeline against a single-node provisioned Redshift cluster (`rg.large`,
`onco-dialect-replication-dev-redshift-test`, see `onco-test-data`'s Terraform) with the same
seeded CDM. **Total time ~56 min, matching Serverless (~50-58 min) stage for stage** — no
meaningful difference (`00_setup.sql` 6.56 min vs. 6.59-7.09 min; main-tree cohorts 1-4 ~1.8-2
min either way; covariates ~15 min either way). This was a genuine surprise: an independent
engineer's report of Serverless-specific compile-latency weirdness, and OHDSI's historical use of
provisioned Redshift without this problem, both pointed toward "Serverless-specific" — that
hypothesis is refuted by this live test.

One real difference, even though the total didn't change: `sys_query_history` on the provisioned
cluster attributed the time to genuine `compile_time` (~56% of elapsed, correctly instrumented),
with almost no unexplained residual (~0.002 sec median/statement) — unlike Serverless, where
`compile_time` was near-zero and the ~2 sec/statement gap was entirely unattributed. Same
outcome, different (and more legible) mechanism. This leaves one thing still untested: `rg.large`
is the cheapest available node type, chosen deliberately for a like-for-like comparison — a
genuinely bigger node (more cores/memory to compile in parallel) might still help, since this
mechanism is actually compute-bound on the provisioned side, unlike Serverless's RPU-proof gap.
Full numbers and sourcing in `onco-test-data/aws_dialect_replication_plan/REDSHIFT_QUERY_PERFORMANCE.md`.

## Net result

The `insertTable()` bulk-load fix is a genuine, confirmed win (minutes saved, zero downside,
already landed in this repo). It does not, by itself, close most of the gap to
Postgres/SQL Server/Snowflake — the majority of the remaining slowness is Circe/CohortGenerator's
own multi-statement cohort-generation SQL running into a per-statement latency/compile cost that
affects Redshift **regardless of Serverless vs. provisioned deployment**, confirmed by direct
test rather than assumption. `DISTSTYLE`, the RPU bump, and switching to a provisioned cluster
have all been tried and confirmed not to close this gap. Options still open: try a genuinely
larger provisioned node (untested, and the one remaining lead given the compile-time mechanism
found there); rewrite `00_setup.sql` to use materially fewer round-trips (scoped, feasible, ours
to do, but doesn't touch Circe/CohortGenerator's own multi-statement SQL); or accept Redshift as
the slow-but-correct dialect for this pipeline's execution style and move on.
