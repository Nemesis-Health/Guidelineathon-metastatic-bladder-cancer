# BigQuery: every real bug found and fixed, full pipeline verified end to end

BigQuery is the fifth comparison target (`bladder_mbc.yaml`, `--seed 42`, 560 patients, same
seeded dataset as Postgres/Redshift/SQL Server/Snowflake). Unlike those four, this pipeline had
never actually been run against it before 2026-09-06. Getting a full `run.R` pass (diagnostics
plus eligibility steps (a)-(l)) green took six distinct, real bug root causes — most in how
`SqlRender` translates this pipeline's own SQL for the `bigquery` dialect (one of which recurred
across several files, §2 and §9), two in genuine BigQuery/GoogleSQL restrictions this pipeline's
SQL was tripping over (§3, §8), one in `CohortGenerator`'s BigQuery parameter binding (§7) — all
found live, root-caused, and fixed. It also surfaced one infrastructure blocker (a missing GCP IAM
permission), reported rather than guessed at per this project's standing rule, and since resolved
by the user granting the permission (§6). The diagnostics-stage bugs are §1-4; the
eligibility-stage bugs found finishing steps (a)-(l) are §7-9. **As of this pass, the full
pipeline (diagnostics + all 12 eligibility steps) runs to completion on BigQuery and matches the
other four dialects row-for-row and value-for-value** (§5, §10).

The connection-string gotchas (`EnableSession=1`, `Location=EU`, `tempEmulationSchema`) are
already covered in `docs/HANDOFF.md` §6 and `config/aws_targets_connectionDetails.R` — this doc
is about what broke *after* the connection was live.

## 0. What passed cleanly

Every one of the 42 pre-study diagnostics chunks (`sql/prestudy/chunks/*.sql`, run via
`run_diagnostics_only.R`) runs correctly against BigQuery and produces **row-for-row and
value-for-value identical output** to Postgres/Redshift/SQL Server/Snowflake — see §5. With §6's
IAM permission granted and §7-9's eligibility-stage bugs fixed, the full `run.R` pass — the main
cohort tree (33 cohorts), ARTEMIS regimen alignment and episode building, all 19 covariate
cohorts (Charlson comorbidities, including Renal Disease — see the parenthetical note just below), outcomes,
guideline adherence, baseline characterization + Charlson CCI, and treatment patterns — now also
runs correctly end to end, live-verified twice (§10). (The Renal Disease covariate cohort — the
subject of a separate, pre-existing, dialect-independent slow-query investigation — generated
normally in both full runs, alongside the other 18 covariate cohorts, with no special hang or
slowness; that issue was fixed independently, in `cohorts/02_Covariate/Renal_Disease.json` itself,
outside this pass.)

## 1. SqlRender's BigQuery translator corrupts UNION ALL branches that each have their own GROUP BY

**Symptom (varies):** either a `java.sql.SQLException` like `Column 2 in UNION ALL has
incompatible types: STRING, STRING, ..., INT64, INT64` (a real column silently replaced with a
small integer literal makes its type disagree with the matching column in the first branch), or
— more dangerous — no error at all, because the replacement's type happens to still typecheck,
and the query runs to completion writing **wrong values** into a real column.

**Root cause.** Decompiled `SqlRender.jar`'s `org.ohdsi.sql.BigQuerySparkTranslate` (installed
`SqlRender` 1.19.4). Its BigQuery-only pass rewrites `GROUP BY <expr>` into `GROUP BY <ordinal>`
wherever `<expr>` is a compound expression matching something in the SELECT list (needed because
BigQuery is stricter than the other four dialects about repeating a computed `GROUP BY`
expression verbatim). The matcher, `bigQueryConvertSelectListReferences()`, finds this via a
single textual pattern search for `select @@s from @@b group by @@r ;` (also tried with `)`,
` having`, ` order by` as the terminator) — `@@s`/`@@b`/`@@r` are wildcards with no awareness of
statement or UNION-branch boundaries. In a multi-branch `UNION ALL` where **more than one**
branch has its own `GROUP BY`, this one textual match can bind `@@s` (the SELECT list used to
resolve ordinals) to one branch while writing the resulting ordinal into a *different* branch's
SELECT list — silently replacing a real value (a real `concept_id`, a `COUNT(*)`, a literal
`''`) with a small integer.

**Minimal repro** (reproduces on the installed `SqlRender` 1.19.4, independent of this project's
SQL or of DatabaseConnector):

```r
library(SqlRender)
sql <- "
SELECT a, b, COUNT(*) FROM t1 GROUP BY a, b
UNION ALL
SELECT a, b, COUNT(*) FROM t2 GROUP BY a, b;
"
cat(SqlRender::translate(sql, targetDialect = "bigquery"))
```

```
select a, b, count(*)  from t1  group by  1, b
union all
 select a, 2, count(*)  from t2  group by  1, 2 ;
```

The second branch's real column `b` has been replaced by the literal `2` in its SELECT list —
not just in `GROUP BY` (where an ordinal is expected and correct), but in the actual row data
that would be inserted.

**Fix**: wrap each UNION ALL branch in its own `SELECT * FROM (...) bN` subquery. This gives
each branch's `GROUP BY` its own bounded scope (closed by its own `)`), which the translator's
textual match can no longer reach across:

```r
sql <- "
SELECT * FROM (SELECT a, b, COUNT(*) FROM t1 GROUP BY a, b) b1
UNION ALL
SELECT * FROM (SELECT a, b, COUNT(*) FROM t2 GROUP BY a, b) b2
;"
cat(SqlRender::translate(sql, targetDialect = "bigquery"))
```

```
select * from ( select a, b, count(*)  from t1  group by  1, 2 ) b1
union all
select * from ( select a, b, count(*)  from t2  group by  1, 2 ) b2
;
```

Both branches now correctly resolve their own `GROUP BY` ordinals against their own SELECT list.

**This subquery-wrap fix was later found to break SQL Server, and was replaced** (2026-09-06,
same day, after review) — see §1b. The corrected fix is a genuine restructuring (tag-then-
aggregate-once), used everywhere the UNION ALL branches were pure counts; the subquery-wrap +
full column aliasing is still used for the one file with genuinely heterogeneous branches that
can't be merged into a single `GROUP BY` (`17_e_obs_period_integrity.sql`, see §1b).

## 1a. A first attempt at verifying this fix was unreliable, and nearly shipped a false "revert"

Before the SQL Server regression was found, each fixed statement in `00_setup.sql` was
re-verified by extracting it as an isolated fragment and running `SqlRender::translate()` on
just that fragment. Three of `00_setup.sql`'s five fixed statements
(`#event_code_counts_before_after`, `#event_code_counts_before_after_first_met`, `#followup_long`)
showed **no corruption** under this isolated test and were reverted as unnecessary — along with
`12_l01_gap_buckets.sql` (a genuinely separate, standalone file, where the isolated test *is*
faithful — see below).

That revert was wrong for the three `00_setup.sql` statements, and the reason matters:
`runSqlFile()` (used for `00_setup.sql` specifically, as opposed to `querySqlFile()` used for
every other, single-statement chunk file) calls `SqlRender::translate()` **once on the entire
157-statement file**, not once per statement. The BigQuery translator's textual, non-scope-aware
matching (§1) can bleed forward across *statement* boundaries within that one call, not just
across UNION ALL branches within one statement — so a statement can test clean in isolation and
still corrupt when translated as part of the complete file. Confirmed live: re-running the full,
current `00_setup.sql` (after the restructured `#event_code_counts` immediately above it) showed
real corruption in `#event_code_counts_before_after` that the isolated-fragment test had missed
entirely.

**Takeaway, going forward**: for any statement inside `00_setup.sql`, only a test against the
*complete current file* (or a live run of it) is trustworthy — an extracted fragment is not, no
matter how it looks in isolation. For every other chunk file (each its own separate
`translate()` call via `querySqlFile()`), testing the complete file's own content in isolation
*is* faithful, since there is no other statement in the same `translate()` call for anything to
bleed across. `12_l01_gap_buckets.sql`'s revert (a genuinely standalone, single-statement file)
was tested this correct way and stands: the original, unqualified `subgroup` in its `GROUP BY`
was already producing correct output, so no fix was needed there.

**Where the restructuring fix ended up applied** (tag-then-aggregate-once — see §1b for what
this looks like and why it's preferred over the subquery-wrap):
- `sql/prestudy/chunks/00_setup.sql` — `#event_code_counts`, `#event_code_counts_before_after`,
  `#event_code_counts_before_after_first_met`, `#followup_long`.
- `sql/prestudy/chunks/03_directionality_buckets.sql`.
- `sql/prestudy/chunks/05_timing_by_year.sql`.
- `sql/prestudy/chunks/14_death_gap_buckets.sql`.

**Where the subquery-wrap + full column aliasing is still used** (heterogeneous branches that
can't be merged into one `GROUP BY` — see §1b):
- `sql/prestudy/chunks/17_e_obs_period_integrity.sql`'s `metrics` CTE (4 of 5 branches; the first
  branch, never reached by the bug, is left unwrapped).

**Confirmed genuinely unaffected, no fix needed** (tested as complete, standalone files — see the
note above on why this test is faithful for these): `12_l01_gap_buckets.sql`,
`01_population_prevalence.sql`'s own UNION-free query, `06_odx_gdx_directional_prevalence.sql`,
`06b_odx_gdx_directional_cdf.sql`, `07_l01_treatment_windows.sql`, `09_demographics.sql`,
`13_death_gap_summary.sql`, `16_e_obs_period_observability.sql`, `18_f_index_event_record_counts.sql`,
`36_a_record_count_percentiles.sql`, `38_g_dx_intercode_percentiles.sql`,
`39_b_obs_past_death_percentiles.sql`, `41_f_odx_gdx_met_anchored_split.sql`.

## 1b. The SQL Server regression, and the restructuring that replaced the subquery-wrap fix

**Symptom**: the subquery-wrap fix (§1) made `00_setup.sql` fail outright on SQL Server —
`com.microsoft.sqlserver.jdbc.SQLServerException: No column name was specified for column 1 of
'b1'`. SQL Server requires every column of a derived table (a `FROM (subquery) alias`) to have
an inferable name; a bare literal (`'INDEX'`) or an unaliased aggregate (`COUNT(*)`) doesn't have
one. This was caught by live-running the full diagnostics stage against SQL Server and diffing
against `results/AWS_SQLSERVER` — SQL Server is this project's reference/gold-standard dialect
(most OHDSI network sites run it), so a fix that breaks it is treated as a hard blocker, not a
tradeoff to accept.

**The better fix**: restructure so each `UNION ALL` branch only tags raw rows (no per-branch
`COUNT`/`GROUP BY` at all), and aggregate **once**, outside the union:

```sql
-- Before (works on BigQuery, breaks SQL Server):
SELECT * FROM (SELECT 'INDEX', 'DX', concept_id, COUNT(*), COUNT(DISTINCT person_id)
               FROM t1 GROUP BY concept_id) b1
UNION ALL
SELECT * FROM (SELECT 'INDEX', 'ODX', concept_id, COUNT(*), COUNT(DISTINCT person_id)
               FROM t2 GROUP BY concept_id) b2

-- After (works on all five dialects, no wrapping needed):
SELECT anchor_event, event_family, concept_id, COUNT(*) AS n_records, COUNT(DISTINCT person_id) AS n_patients
FROM (
    SELECT 'INDEX' AS anchor_event, 'DX' AS event_family, concept_id, person_id FROM t1
    UNION ALL
    SELECT 'INDEX', 'ODX', concept_id, person_id FROM t2
) all_events
GROUP BY anchor_event, event_family, concept_id
```

This has only ONE `GROUP BY` in the whole statement, so §1's cross-branch (and cross-statement,
§1a) bleed has nothing left to bleed into or out of — confirmed correct on BigQuery (live) and
byte-for-byte/value-for-value identical to the SQL Server gold standard (live, both before and
after this restructuring — SQL Server was never broken by the *bug*, only by the *first fix*).
Only the very first UNION ALL branch needs column aliases (`AS anchor_event`), which is
completely standard SQL — no per-dialect special-casing anywhere.

Where the source rows need real per-row aggregation (not just a count), e.g. `#followup_long`'s
per-person `MAX(observation_period_end_date)`, the same principle still applies: union the raw
joined rows carrying every column the final aggregation needs, and do the aggregation once,
outside the union.

**A second bug found in this fix itself, while restructuring `#followup_long`**: the restructured
version initially failed live on BigQuery — `Column 3 contains an aggregation function, which is
not allowed in GROUP BY`. Root cause: the outer `GROUP BY` included `anchor_date`, a plain
passthrough grouping key not itself present in the outer SELECT list — but the *name*
`anchor_date` also appears as a substring inside the SELECT list's
`DATEDIFF(DAY, anchor_date, MAX(obs_end))` expression, and SqlRender's textual GROUP-BY-to-ordinal
matcher (§2's `IsSingleColumnReference()` path) matched that embedded occurrence instead of
failing to match at all, silently mis-numbering `anchor_date` to that expression's own ordinal.
Fixed the same way as §2: qualify every outer reference with the derived table's alias
(`r.anchor_date`, not bare `anchor_date`) so the matcher recognizes it as an already-qualified
column and copies it through untouched. Confirmed live afterward: `03_directionality_buckets.sql`,
`05_timing_by_year.sql`, and `14_death_gap_buckets.sql`'s equivalent outer `GROUP BY`s were
individually re-checked via `translate()` and do **not** have this problem (their GROUP BY items
are either not embedded inside another SELECT-list expression, or — for
`05_timing_by_year.sql`'s `index_year_int` inside `CAST(index_year_int AS VARCHAR(4))` — the
embedded occurrence happens to be the one legitimately intended target, so the mis-match and the
correct match coincide).

**Where this was found and fixed**: same file/statement list as the "restructuring fix" bullet
above in §1a.

**Confirmed unaffected on the other four dialects**: the wrapped/restructured forms translate to
byte-identical SQL on Postgres/Redshift/Snowflake (static `translate()` check — none of these
rewrite `GROUP BY` at all for a bare column, so the extra structure is inert), and SQL Server was
verified by full live execution (§5).

## 2. Same translator, a second manifestation: a bare column mixed with a complex GROUP BY expression gets mis-numbered

**Symptom:** wrong (not just corrupted-to-error) `GROUP BY` ordinals — rows silently grouped by
the wrong columns, with no exception at all. Much quieter than §1's type-mismatch errors.

**Root cause**, same Java class: `CommaListIterator.IsSingleColumnReference()` only recognizes an
already-**qualified** `alias.column` reference (exactly 3 tokens: identifier, `.`, identifier) as
safe to copy straight through untouched. A **bare** column name (no table/alias qualifier) fails
that check and falls into the same textual "search the SELECT list, use whichever position
matches" path as a full expression — and when a `GROUP BY` list mixes a bare column with a
genuine expression (e.g. a `CASE WHEN ... END` also needing ordinal conversion), the bare column
can get assigned the position of the *other* item instead of its own.

**Minimal repro:**

```r
SqlRender::translate(
  "SELECT a, CASE WHEN x=1 THEN 'y' ELSE 'n' END AS b, COUNT(*) FROM t
   GROUP BY a, CASE WHEN x=1 THEN 'y' ELSE 'n' END ORDER BY a;",
  targetDialect = "bigquery")
```

```
select a, case when x=1 then 'y' else 'n' end as b, count(*)    from t   group by  2, 2   order by  1 ;
```

`a` (select position 1) is wrongly grouped as position `2` (the `CASE` expression's own
position) — the query runs without error but silently double-groups by the `CASE` expression and
drops `a` from the effective grouping.

**Fix**: qualify the bare column with its table/derived-table alias in the `GROUP BY` clause
(`t.a` instead of `a`) — this satisfies `IsSingleColumnReference()` and the translator copies it
straight through, no ordinal-search path involved:

```r
SqlRender::translate(
  "SELECT t.a, CASE WHEN x=1 THEN 'y' ELSE 'n' END AS b, COUNT(*) FROM t t
   GROUP BY t.a, CASE WHEN x=1 THEN 'y' ELSE 'n' END ORDER BY t.a;",
  targetDialect = "bigquery")
```
`group by  t.a, 2` — correct.

**Where fixed**: `sql/prestudy/chunks/15_l01_day_count_buckets.sql` (outer `GROUP BY subgroup,
CASE...` → `GROUP BY x.subgroup, CASE...`, `x` being the existing derived-table alias), and
`sql/prestudy/chunks/00_setup.sql`'s `#followup_long` (see §1b — the same class of bug, but
triggered by an embedded substring match rather than a mixed bare-column/expression list).

`sql/prestudy/chunks/12_l01_gap_buckets.sql` was *also* given this fix initially, but see §1a:
tested properly (as its own complete file — a standalone, single-statement chunk, so this test
is faithful), its original bare `subgroup` was never actually corrupted, and the fix was reverted
as unnecessary.

## 3. BigQuery statically rejects a `GROUPING SETS` column reached only via a `GROUPING()`-guarded branch

**Symptom:** `SELECT list expression references column <col> which is neither grouped nor
aggregated`, even though the reference is inside a `CASE WHEN GROUPING(...) = 1 THEN 'OVERALL'
ELSE CAST(<col> ...) END` — i.e. the `ELSE` branch that references `<col>` bare is only ever
*reached* for the grouping set where `<col>` really is grouped.

**Root cause**: this is a genuine BigQuery/GoogleSQL restriction (not a SqlRender bug) — its
query validator checks SELECT-list expressions statically against the grouping sets, not per
`CASE` branch at runtime. A column that isn't part of *every* grouping set can't appear bare
anywhere in the SELECT list, even behind a `GROUPING()` guard that would make the reference safe
at execution time. Postgres/Redshift/SQL Server/Snowflake all accept this pattern; BigQuery does
not.

**Fix**: wrap the reference in an aggregate (`MAX(...)`) — a semantic no-op (the column is
already unique per row in the grouping set where the `ELSE` branch actually fires, and that
branch never runs for the grouping set where it wouldn't be), but it satisfies BigQuery's static
check on every dialect (confirmed via `SqlRender::translate()` for all five — no behavior change
elsewhere).

**Where fixed**: `sql/prestudy/chunks/00_setup.sql`'s two `#death_stratum_counts` INSERTs
(`YEAR(c.index_date)` / `YEAR(ms.first_met_date)`) and
`sql/prestudy/chunks/01_population_prevalence.sql` (`YEAR(index_date)`) — all three use the same
`GROUP BY GROUPING SETS ((), (YEAR(...)))` "OVERALL + per-year" idiom.

## 4. `IN (subquery)` inside a JOIN's `ON` predicate — rejected outright by BigQuery

**Symptom:** `IN subquery is not supported inside join predicate` — again a genuine BigQuery
restriction, not a SqlRender translation issue; the other four dialects all accept a subquery
inside a JOIN's `ON` clause.

**Where found**: `sql/prestudy/chunks/40_d_treatment_availability_met_subset.sql`'s `dtp_flags`
CTE —
```sql
LEFT JOIN @cdm_database_schema.procedure_occurrence po
  ON po.person_id = ms.person_id
 AND po.procedure_concept_id IN (SELECT concept_id FROM #dtp_concepts)
```

**Fix**: pre-filter `procedure_occurrence` to DTP concepts via a real join in a derived table,
then LEFT JOIN *that* to the patient population — semantically identical (still preserves every
`met_subset` patient, matching or not), portable to every dialect:
```sql
LEFT JOIN (
    SELECT po.person_id, po.procedure_date
    FROM @cdm_database_schema.procedure_occurrence po
    JOIN #dtp_concepts dc ON dc.concept_id = po.procedure_concept_id
) po ON po.person_id = ms.person_id
```

## 5. Diagnostics comparison: row-for-row AND value-for-value identical to all four other targets

With §1-4 fixed (and the SQL Server regression from the first §1 fix resolved per §1b), every
one of the 44 `sql/prestudy/chunks/*.sql` outputs (`results/BIGQUERY/diagnostics/*.csv`) was
diffed against `results/AWS_PG`, `results/AWS_REDSHIFT`, `results/AWS_SQLSERVER` (this project's
gold-standard/reference dialect — see §1b), `results/SNOWFLAKE` — with **both** BigQuery and SQL
Server independently re-run live end-to-end (not just spot-checked) after every fix in this file,
specifically because the first fix attempt broke SQL Server without breaking BigQuery, so passing
on one dialect alone was established as insufficient evidence:

- **Row counts**: all 44 files match exactly across all five targets. Zero mismatches.
- **Content** (sorted, order-independent full-value diff, not just row counts): 41 of 44 files
  are byte-for-byte identical on BigQuery (SQL Server: 44/44 byte-identical, no exceptions). The
  remaining 3 BigQuery files (`09_demographics.csv`, `36_a_record_count_percentiles.csv`,
  `37_c_met_intercode_percentiles.csv`) differ **only** in floating-point string precision — e.g.
  `33.3442` (Postgres/Redshift/SQL Server/Snowflake, apparently truncated on serialization) vs
  `33.34428473648186` (BigQuery, full `FLOAT64` precision) for the exact same underlying
  computation; `1.2351851851851852` vs `...54` (last-digit binary floating-point noise). Every
  such diff is confirmed to be the same value to well beyond any digit that matters for this
  study — **not a correctness issue**, and not touched here (rounding it away would be cosmetic,
  and would have to be applied even-handedly across all five dialects to mean anything, which is
  out of scope for a BigQuery-specific pass).

Timing: `00_setup.sql` (157 sequential statements) took **7.7-8.0 minutes** consistently across
five separate runs on BigQuery — essentially the same order of magnitude as Redshift Serverless's
documented ~6.6-7.1 minutes (see `docs/REDSHIFT.md`), and dramatically slower than SQL Server
(16.9 secs), Snowflake (1.49 min), or Postgres (1.72 min). This is consistent with the same root
cause `REDSHIFT.md` identified for Redshift: fixed per-statement/per-job submission latency
multiplied by 157 sequential statements, not query complexity or data volume — both BigQuery and
Redshift Serverless charge a real, similar-magnitude round-trip cost per job/statement submitted,
which dominates for a script built as many small sequential statements rather than a few large
ones. Not investigated further here (out of scope for this pass; `REDSHIFT.md` §"Net result"
already covers the tradeoffs of rewriting `00_setup.sql` to fewer round-trips).

## 6. RESOLVED: BigQuery Storage Read API permission denied

**Status: fixed by a GCP IAM grant, confirmed live.** The full `run.R` pass (diagnostics +
eligibility step (a), ARTEMIS regimen alignment) initially got through diagnostics, the main
cohort tree (540 subjects), and ARTEMIS regimen loading (1508/1617 regimens kept) before failing
on a query building the ARTEMIS "valid drugs" reference set:

```sql
SELECT DISTINCT ca.descendant_concept_id AS concept_id
FROM cdm.concept a
JOIN cdm.concept_ancestor ca ON ca.ancestor_concept_id = a.concept_id
WHERE a.vocabulary_id = 'ATC' AND a.concept_class_id = 'ATC 2nd'
  AND a.concept_code IN ('L01', 'L02', 'L03', 'L04')
```

```
java.sql.SQLException: [Simba][BigQueryJDBCDriver](100210) Error initializing the Storage API.
Message: io.grpc.StatusRuntimeException: PERMISSION_DENIED: request failed: the user does not
have 'bigquery.readsessions.create' permission for 'projects/omop-test-data'
```

This is the Simba JDBC driver deciding, on its own, to fetch this query's result set via the
BigQuery Storage Read API rather than the standard REST API — a gRPC-based path that needs the
`bigquery.readsessions.create` permission (part of the predefined `roles/bigquery.readSessionUser`
role), which the service account `omop-bigquery@omop-test-data.iam.gserviceaccount.com` does not
currently have.

**Two documented driver flags were tried and confirmed NOT sufficient** (tested directly against
a standalone connection running exactly the failing query, isolated from the rest of the
pipeline, so the result is unambiguous):
- `EnableHighThroughputAPI=0` in the connection string (the connector's own guide documents this
  as the flag that disables Storage API use outright, and states its *default* is already `0`) —
  added explicitly anyway; the same permission error still occurred.
- `HighThroughputMinTableSize=999999999` (raising the row-count activation threshold far above
  anything in this dataset) — combined with the above; same result. (This test also required
  dropping `EnableSession=1` to isolate the property, which broke the connection outright with a
  different, unrelated error — `EnableSession=1` is independently required per `docs/HANDOFF.md`
  §6, so it can't be removed to test around this.)

Since the query that fails here isn't unusually large by this dataset's standards (the actual
result set is a small, filtered list of ATC-descendant concept IDs) and the documented
size-based activation flags made no difference, this looks like either a driver-version
discrepancy from its own documentation or an unconditional path tied to session-mode
(`EnableSession=1`) rather than result size — not something resolvable from the R/SQL side.

**Not fixed from the code side** — per this project's standing rule (see `docs/HANDOFF.md`'s
framing), an IAM grant is a GCP-side infrastructure change, not a code fix, so this was reported
rather than guessed at. **Resolution**: the user granted
`omop-bigquery@omop-test-data.iam.gserviceaccount.com` the `roles/bigquery.readSessionUser` role
on project `omop-test-data` (the specific role documented above as containing
`bigquery.readsessions.create`). Re-running `run.R` from a fresh session afterward got past this
query with no further changes needed — confirmed by two full, independent live runs all the way
through eligibility step (l) (§10).

**Blast radius while open**: this had blocked eligibility step (a) (`R/01_artemis.R`) onward —
i.e. the entire eligibility/feasibility half of the pipeline (steps a-l,
`results/BIGQUERY/eligibility/`). Pre-study diagnostics (§0, §5) were unaffected throughout.

## 7. `CohortGenerator::insertInclusionRuleNames()` passes a double where BigQuery needs a strict INT64

**Symptom:** `java.sql.SQLException: [Simba][BigQueryJDBCDriver](100032) ... Unparseable query
parameter \`\` in type \`TYPE_INT64\`, Bad int64 value: 1.0 value: '1.0'` — thrown from
`insertTable()`'s parameterized-batch-insert path, not from any SQL this pipeline wrote directly.

**Root cause:** `CohortGenerator:::getCohortInclusionRules()` (an upstream OHDSI package function,
called by the exported `insertInclusionRuleNames()`) builds its result with
`cohortDefinitionId = as.numeric(cohortDefinitionSet$cohortId[i])` — an R **double**, even though
the column is a whole-number cohort id. `DatabaseConnector::insertTable()` binds this as a
parameterized query value; every other dialect's JDBC driver coerces a double-valued INT64
parameter (serialized as e.g. `"1.0"`) back to an integer on insert. BigQuery's driver does not —
a query parameter with a decimal point is rejected outright for an `INT64` column, regardless of
its numeric value.

**Fix:** at the one call site in this pipeline (`R/03_main_cohorts.R`), branch on
`.getDbms(connection) == "bigquery"` and replicate `insertInclusionRuleNames()`'s own logic
(truncate the table, call the still-exported `CohortGenerator::getCohortInclusionRules()`,
`insertTable()` the result) with one difference: `inclusionRules$cohortDefinitionId <-
as.integer(inclusionRules$cohortDefinitionId)` before the insert. Every other dialect keeps using
`CohortGenerator::insertInclusionRuleNames()` unmodified, so this is a zero-behavior-change
branch everywhere except BigQuery.

**Where fixed:** `R/03_main_cohorts.R`, immediately after `CohortGenerator::getCohortTableNames()`
is called for the main cohort tree's inclusion-rule attrition table.

## 8. A window function can't `PARTITION BY` a `FLOAT64` column on BigQuery

**Symptom:** `Partitioning by expressions of type FLOAT64 is not allowed` — a genuine BigQuery
restriction (not a SqlRender issue); the other four dialects all partition by a float column
without complaint.

**Where found:** `sql/lab_cohorts.sql`'s lab-unit-resolution pipeline, which partitions by
`measurement.range_low`/`range_high` (both OMOP `FLOAT` columns, aliased `rlo`/`rhi`) to group
same-reference-range measurements together — 8 `OVER (PARTITION BY ...)` clauses across two
`SELECT`s (`grp_ranked`'s percentile ranking, and the per-unit scale-resolution ranking further
down the same file).

**Fix:** `CAST(rlo AS VARCHAR(50))` / `CAST(rhi AS VARCHAR(50))` in every affected `PARTITION BY`
list (not in the `SELECT` list or anywhere else the real float values are used) — a no-op on the
actual partitioning outcome, since two floats land in the same partition under this cast exactly
when they would have anyway (same value -> same string), and it's valid, portable SQL on every
dialect (confirmed via `SqlRender::translate()` for all five).

**Where fixed:** `sql/lab_cohorts.sql`, both `PARTITION BY` sites (8 window functions total).

## 9. The bare-column/complex-expression `GROUP BY` bug (§2) recurs across the eligibility-stage SQL, sometimes landing on an aggregate's position

**Symptom (two variants, same root cause as §2):** either silently wrong grouping (no error), or
— when the mis-resolved ordinal happens to land on a column that's itself an aggregate expression
— a hard failure: `Column N contains an aggregation function, which is not allowed in GROUP BY`.

Two concrete manifestations found running eligibility steps (a)-(l) live:

- **`sql/demographics.sql`**'s "index year" branch: `GROUP BY cohort_definition_id,
  CAST(index_year AS VARCHAR(4)), index_year` translated to `GROUP BY 1, 3, 3` (duplicated,
  dropping the real 3rd grouping column) instead of `1, 3, 4` — the bare `index_year` at the true
  4th position textually collided with the *earlier* `CAST(index_year AS VARCHAR(4))` expression
  (which contains the substring `index_year`), so the ordinal-resolution search matched that
  expression's position instead of continuing on to its own.
- **`sql/demographics_continuous.sql`**, and the same shared pattern in
  `sql/baseline_vitals.sql`, `sql/cohort_counts_stratified.sql`,
  `sql/lab_timing_to_index_portable.sql`, `sql/lab_value_distribution_portable.sql` (all built on
  `subject_strata.sql`'s stratified-aggregate idiom — see that file's header for the full
  consumer list): `GROUP BY stratum_type, stratum_value, cohort_definition_id` translated to
  `GROUP BY 8, 8, 3` — both bare `stratum_type` and `stratum_value` resolved to the *same* wrong
  position (an aggregate `SUM(...)` expression further down the SELECT list), which BigQuery then
  rejected outright since an aggregate can't be a `GROUP BY` target.

**Fix**, the same as §2: qualify every bare column in the affected `GROUP BY` with its source
CTE/table name (`coh.index_year`, `ranked.stratum_type`, `tagged.stratum_type`, ...) so it reads
as an already-qualified `alias.column` reference and is copied straight through untouched instead
of going through the substring-search path at all. Confirmed via `SqlRender::translate()` that
each fix produces the intended, correct ordinals with no behavior change on the other four
dialects.

**Where fixed:** `sql/demographics.sql`, `sql/demographics_continuous.sql`,
`sql/baseline_vitals.sql`, `sql/cohort_counts_stratified.sql`,
`sql/lab_timing_to_index_portable.sql`, `sql/lab_value_distribution_portable.sql`.

**Audited and confirmed NOT affected** (same "stratified aggregate" shape, already qualified from
the start, or single/non-colliding bare items — checked by rendering + translating each complete
file and inspecting the resulting `GROUP BY`/`PARTITION BY` clauses, not just by inspection):
`sql/covariate_overlap.sql`, `sql/eligibility_input_coverage.sql`, `sql/ps_overlap.sql`,
`sql/charlson_components.sql`, `sql/lab_cohort_counts.sql`, `sql/lab_results_rollup_portable.sql`,
`sql/lab_results_summary_portable.sql`. (`sql/lab_value_distribution.sql`,
`sql/lab_results_summary.sql`, `sql/lab_results_rollup.sql` — the non-`_portable` siblings of some
of these — aren't referenced by any `R/*.R` file and weren't touched.)

## 10. Full pipeline comparison: diagnostics + eligibility, both row-for-row and value-for-value

With §1-4 and §7-9 fixed and §6's IAM permission granted, the complete `run.R` pipeline
(diagnostics + all 12 eligibility steps) was run live against BigQuery **twice**, independently,
end to end. The second run was specifically a re-verification against the repo's fully current,
committed state, since the diagnostics-stage fix (§1) was independently refined (restructured to
also fix a SQL Server regression the original subquery-wrap approach had introduced — see §1b)
partway through this pass, and everything downstream of `00_setup.sql` depends on the temp tables
it builds, so a fresh end-to-end run was the only way to be sure the refined version didn't change
anything for the eligibility stage. Both runs completed with no errors and produced identical
results. Total elapsed wall-clock time for the full pipeline (diagnostics + steps a-l), each run:
**~59 minutes**.

**Diagnostics** (`results/BIGQUERY/diagnostics/*.csv`, 44 files) vs.
`results/AWS_PG`/`results/AWS_REDSHIFT`/`results/AWS_SQLSERVER`/`results/SNOWFLAKE`:
- Row counts: 44/44 match exactly. Zero mismatches.
- Content (sorted, order-independent full-value diff): 41/44 byte-identical; the remaining 3
  (`09_demographics.csv`, `36_a_record_count_percentiles.csv`,
  `37_c_met_intercode_percentiles.csv`) differ only in floating-point display precision — see §5's
  detail, unchanged by this section's re-run.

**Eligibility** (`results/BIGQUERY/eligibility/{labs,characterization,artemis,
treatment_patterns,guideline,outcomes}/*.csv`, 52 files across all six subfolders) vs. the same
four targets:
- Row counts: 52/52 match exactly. Zero mismatches.
- Content: 47/52 byte-identical. The remaining 5 (`labs/lab_results_rollup.csv`,
  `labs/lab_results_summary.csv`, `labs/lab_timing_to_index.csv`,
  `labs/lab_value_distribution.csv`, `characterization/demographics_age_continuous.csv`) differ
  only in floating-point display precision — the same class of non-issue as the diagnostics-stage
  3, e.g. `25.3` vs `25.30000000000001`, `20.041717647259713` vs `20.041717647259716` (BigQuery
  serializing full `FLOAT64` precision where the other four dialects' drivers truncate on
  display). Every such diff was individually confirmed to be the same value well beyond any digit
  that matters for this study's percentile/mean/SD outputs — not touched here, for the same
  reason given in §5 (cosmetic, and would need an even-handed pass across all five dialects to be
  meaningful).

Every cohort count, demographics breakdown, outcome summary (OS/TTNT/TTD/TFI/DTI), guideline
adherence rollup, Charlson CCI, and treatment-pattern table BigQuery produced is therefore
confirmed identical to what Postgres/Redshift/SQL Server/Snowflake already produce from the same
seeded data.
