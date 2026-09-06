# SQL Server: `bulkLoad` doesn't apply here — what you get instead

Unlike Postgres and Redshift (see `BULK_LOAD.md`), **`insertTable(..., bulkLoad = TRUE)` has no
effect for SQL Server.** Confirmed by reading `DatabaseConnector:::insertTable.default`'s
actual dispatch logic (installed version 6.4.0):

```r
useBulkLoad <- (bulkLoad && dbms %in% c("hive", "redshift") && createTable) ||
               (bulkLoad && dbms %in% c("pdw", "postgresql") && !tempTable)
```

`"sql server"` isn't in either list. Passing `bulkLoad = TRUE` against a SQL Server connection
is silently ignored — there's no error, it just falls through to the same default path used
when `bulkLoad` isn't set at all.

## What that default path actually is

Not naive row-by-row. `insertTable()`'s fallback (used by SQL Server, and by every other dbms
when bulk load isn't requested/applicable) is a genuine JDBC-native batch insert:

- A bundled Java helper class, `org.ohdsi.databaseConnector.BatchedInsert`, invoked via `rJava`.
- Builds one parameterized `INSERT INTO table (...) VALUES (?, ?, ...)` statement, then uses
  JDBC's `PreparedStatement.executeBatch()` — batched in groups of **10,000 rows** per
  `executeBatch()` call (`batchSize <- 10000` in `insertTable.default`).
- Typed column setters per R type: `setInteger`, `setBigint` (via `bit64::integer64`),
  `setNumeric`, `setDateTime` (`POSIXct`/`POSIXt`, formatted `"%Y-%m-%d %H:%M:%S"`), `setDate`
  (`Date`), `setString` (fallback for everything else).

This is a reasonable, already-batched insert path — for cohort/lab/episode-scale tables
(thousands of rows, not millions), it needs no extra setup at all: no `psql`, no S3 bucket, no
IAM credential, unlike either of the other two dialects' bulk paths.

## Connecting: the `server = "host/db"` trap

Unlike Postgres/Redshift, **do not append `/<database>` to `server`.** `run.R`'s own example
comment did this (now fixed) and it's a real, non-obvious trap: `DatabaseConnector:::connectSqlServer`
builds the JDBC URL as `paste0("jdbc:sqlserver://", server, ";port=", port)` — a plain string
concatenation, no parsing. `server = "host/omop"` produces
`jdbc:sqlserver://host/omop;port=1433`, and the Microsoft JDBC driver has **no path-style
database syntax** the way Postgres does — it treats the whole `host/omop` as one hostname to
resolve. The failure this produces is a genuine `SQLServerException`:

```
The TCP/IP connection to the host <host>/omop, port 1433 has failed. ... Make sure that an
instance of SQL Server is running on the host and accepting TCP/IP connections at the port.
```

— which reads exactly like an infra problem (network, firewall, stopped instance) and is not
one. Found live on 2026-09-05 against a genuinely `available` RDS instance (confirmed via a
direct `nc -vz` TCP check succeeding on the same host/port while the R connection failed) — cost
real time chasing what looked like a stuck RDS restart before the connection string itself
turned out to be the actual cause. Use `extraSettings = "databaseName=omop"` instead (see the
corrected block in `config/aws_targets_connectionDetails.R`):

```r
connectionDetails <- DatabaseConnector::createConnectionDetails(
  dbms = "sql server", server = "host", user = "...", password = "...",
  extraSettings = "databaseName=omop", pathToDriver = path.expand("~/.jdbc_drivers"))
```

## The known JDBC bug — does it apply here too?

`R/artemis.R` documents bypassing `ARTEMIS::getConDF()` because it internally re-generates the
cohort via `CohortGenerator::generateCohortSet()`, whose call into `insertTable()` fails on
Postgres with `"parameter type 'data.frame' is ambiguous or not supported"`. That failure is
inside `CohortGenerator`'s own call chain, not proven to be in the `BatchedInsert` code path
above. **Not reproduced against SQL Server** — a representative cohort-table-shaped insert
(int PK, `Date`, `POSIXct`, character, numeric-with-NA) via `insertTable()` directly worked fine
(see [Status](#status)), but that's a different call path than `CohortGenerator`'s own internal
one, so this isn't a full clearance of the bug for SQL Server. If it does show up here too,
there is no `bulkLoad` escape hatch the way there is for Postgres/Redshift (no dispatch branch
exists to switch to). Fallback options if it recurs:

1. **Restructure the offending data.frame's column types** before calling `insertTable()` —
   find whichever column doesn't match one of the typed setters above (integer / integer64 /
   numeric / POSIXct / Date / character) and coerce it explicitly. Likely candidates: factor
   columns, list columns, or a logical column that wasn't run through
   `DatabaseConnector::convertLogicalFields()` first.
2. **Roll a custom multi-row `INSERT`**, the same way `onco-test-data`'s own Python adapter does
   for this exact dialect (`db_adapter.py`'s `_bulk_insert_sqlserver`, written and verified this
   project) — proven working, and documents the two SQL-Server-specific traps to replicate:
   - SQL Server cap of **2,100 parameters per query** — chunk rows so
     `rows_per_chunk * num_columns` stays under that (see
     `aws_dialect_replication_plan/PHASE2_RESULTS.md` bug #6 in `onco-test-data`).
   - `SET IDENTITY_INSERT <table> ON` (and back `OFF` after) if the insert carries explicit
     values for an `IDENTITY` primary key column — SQL Server rejects those otherwise (bug #7,
     same doc).

## The other trap: `cdmDatabaseSchema`/`workDatabaseSchema` need `database.schema`, not a bare schema

Separate from the connection-string trap above, and only surfaces once `CohortGenerator`
actually runs (the diagnostics-only stage never hits it): a bare schema name like `"cdm"` or
`"results"` breaks cohort generation with

```
com.microsoft.sqlserver.jdbc.SQLServerException: Database 'results' does not exist. Make sure
that the name is entered correctly.
```

thrown from `CohortGenerator::generateCohortSet()` → its internal `.checkCohortTables()` →
`DatabaseConnector::getTableNames()`. Root cause (confirmed by reading
`DatabaseConnector:::dbListTables,DatabaseConnectorConnection-method`'s source directly, then
verifying live against `onco-dialect-replication-dev-sqlserver`, 2026-09-05): for
`dbms %in% c("sql server", "pdw")`, that function treats a **single-token (no dot)** schema
string as a **database name** and hardcodes the schema to `"dbo"` — i.e. bare `"results"` makes
it look for a database literally called `results` (JDBC `DatabaseMetaData.getTables(catalog =
"results", schema = "dbo", ...)`), not the `results` *schema* inside the `omop` database. Only a
two-part `"database.schema"` string (e.g. `"omop.results"`) takes the branch that resolves
correctly (`database = "omop"`, `schema = "results"`).

This is exactly why the raw-SQL diagnostics stage (`run_diagnostics_only.R`) doesn't trip over
it: this repo's own `sql/*.sql` templates render `@cdm_database_schema.table_name` as literal
SQL text (a plain 2-part `schema.table` reference, resolved fine against the connection's
default database set via `extraSettings = "databaseName=omop"`) and never call
`getTableNames()`/`dbListTables()` at all. `CohortGenerator::createCohortTables()` is the same
way (plain rendered `CREATE TABLE @schema.table` text) — which is why table creation itself
succeeds and prints `Created table results.bc_cohort` right before the failure. It's
specifically `generateCohortSet()`'s own metadata-based existence check that goes through the
JDBC catalog API and hits the SQL-Server-specific bare-schema convention above.

**Fix**: for SQL Server, set `cdmDatabaseSchema`, `vocabDatabaseSchema`, and
`workDatabaseSchema` to the two-part form — `"omop.cdm"` / `"omop.results"` — not bare
`"cdm"`/`"results"`. This is a 3-part identifier once a table name is appended
(`omop.cdm.person`), which plain T-SQL supports natively, so it doesn't break the raw-SQL
templates either. Already applied in `config/aws_targets_connectionDetails.R`'s SQL Server
block.

## Status

**Live-verified, 2026-09-05.** A representative cohort-table-shaped `insertTable()` call (int
PK, `Date`, `POSIXct`, character, numeric-with-NA) against
`onco-dialect-replication-dev-sqlserver` succeeded using the corrected connection string above.
`bulkLoad = TRUE` was passed and, as expected from the dispatch logic, had no effect — the
default `BatchedInsert` path handled it correctly.

Getting to that point involved a false alarm worth recording: the RDS instance had been
auto-stopped and was restarted; RDS's own event log shows the whole recovery cycle completed
within ~8.5 minutes (`recovery complete` / `DB instance started`), a normal restart time — but
`describe-db-instances` was still being observed reporting `starting` noticeably later than
that (exact cause unconfirmed: possibly a status-reporting lag, possibly just elapsed time
between checks not being tracked precisely). Whichever it was, the connection failures actually
being chased during that period were real, but caused by the `server = "host/db"`
connection-string bug above, not by the instance genuinely still starting.

## Unhibernating

Same as Postgres, more aggressive idle threshold (60 min vs. 90):

```bash
aws rds start-db-instance --db-instance-identifier onco-dialect-replication-dev-sqlserver
aws rds wait db-instance-available --db-instance-identifier onco-dialect-replication-dev-sqlserver
```

If `wait` hangs far longer than a few minutes, check `aws rds describe-events
--source-identifier onco-dialect-replication-dev-sqlserver --source-type db-instance --duration
60` for what it's actually doing before assuming it's fine.
