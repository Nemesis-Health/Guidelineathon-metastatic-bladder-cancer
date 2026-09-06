# Handoff: connecting and testing this pipeline against all OMOP targets

Single entry point for an agent (or person) testing this study pipeline (`run.R`) against
Postgres, SQL Server, Redshift, Snowflake, and BigQuery — five comparison targets, plus a
sixth, non-comparison Redshift provisioned test cluster (see row below). Everything here is
either live-verified (2026-09-04 through 2026-09-06) or explicitly marked as unconfirmed — no
guessing. Deep-dive docs: [`BULK_LOAD.md`](BULK_LOAD.md) (Postgres/Redshift bulk insert),
[`SQL_SERVER.md`](SQL_SERVER.md) (SQL Server connection gotcha + `bulkLoad` status),
[`REDSHIFT.md`](REDSHIFT.md) (Redshift is dramatically slower than the other dialects, but
confirmed *correct* — same output as everything else; an RPU bump and a `DISTSTYLE ALL` change
were both tried and confirmed NOT to fix the slowness; a provisioned cluster is the current "to
test next"). This doc is the TL;DR that ties them together; BigQuery's own gotchas are
documented inline in `config/aws_targets_connectionDetails.R` (three of them, all load-bearing
— see §6 below) rather than in a separate file.

## 0. What's already there

All five comparison targets currently hold the **same seeded dataset**: `bladder_mbc.yaml`
profile, `--seed 42`, 560 patients, byte-identical row counts and content across all five
(verified in `onco-test-data/aws_dialect_replication_plan/PHASE2_RESULTS.md`). If your test
doesn't need different data, there's nothing to regenerate — just connect and query.

## 1. Connect: pick a target

Ready-to-paste `connectionDetails` + `settings` blocks for all of these live in
`config/aws_targets_connectionDetails.R` (gitignored — real host/port/schema values, passwords
read from env vars, never hardcoded there). Copy one block into `run.R`'s CONFIG section in
place of `connectionDetails <- NULL` and the `cdmDatabaseSchema`/`vocabDatabaseSchema`/
`workDatabaseSchema` lines.

| Target | `dbms` | Host | Port | DB | CDM schema | Write schema |
|---|---|---|---|---|---|---|
| PostgreSQL | `postgresql` | `onco-dialect-replication-dev-postgres.chcom6646563.eu-west-2.rds.amazonaws.com` | 5432 | `omop` | `cdm` | `results` |
| SQL Server | `sql server` | `onco-dialect-replication-dev-sqlserver.chcom6646563.eu-west-2.rds.amazonaws.com` | 1433 | `omop` | `omop.cdm`† | `omop.results`† |
| Redshift (Serverless) | `redshift` | `onco-dialect-replication-dev.905418084644.eu-west-2.redshift-serverless.amazonaws.com` | 5439 | `omop` | `cdm` | `results` |
| Redshift (provisioned, non-comparison‡) | `redshift` | `onco-dialect-replication-dev-redshift-test.curyjdn8it7n.eu-west-2.redshift.amazonaws.com` | 5439 | `omop` | `cdm` | `results` |
| Snowflake | `snowflake` | account `dcdrrgj-yi99084`, warehouse `compute_wh` | n/a | `OMOP` | `CDM` (not `CDM_LEGACY` — see below) | `OMOP_RESULTS` |
| BigQuery | `bigquery` | GCP project `omop-test-data` (not AWS) | n/a | n/a | `cdm` | `results` |

All AWS resources: account `905418084644`, region `eu-west-2`, user `omop_admin` (Postgres/SQL
Server/both Redshifts). BigQuery: service account `omop-bigquery@omop-test-data.iam.gserviceaccount.com`.
Snowflake: user `ALIZAAMLANI1`.

‡ The provisioned Redshift cluster was a one-off, 2026-09-06, testing whether Redshift
Serverless's query-compile-latency problem (see `REDSHIFT.md`) is Serverless-specific — not
part of the five-way parity set, and not meant to be a permanent fixture (see §2 for its
pause/resume commands). **Result: it does not come back clean** — full pipeline run against it
took ~56 min, matching Serverless stage for stage, so this does NOT replace the Serverless row
above. Kept only as a reference for the "cheapest node type still shows the same latency"
finding; see `REDSHIFT.md` and `onco-test-data/aws_dialect_replication_plan/
REDSHIFT_QUERY_PERFORMANCE.md` for the full numbers.

† SQL Server's schema settings need the two-part `database.schema` form, not a bare schema —
`DatabaseConnector::getTableNames()` (called by `CohortGenerator::generateCohortSet()`) treats a
single-token schema as a *database* name on this dialect and hardcodes `dbo` as the schema,
breaking cohort generation with `"Database 'results' does not exist"` the moment it runs (found
live, 2026-09-05). Full explanation in [`SQL_SERVER.md`](SQL_SERVER.md).

**⚠️ SQL Server connection-string trap**: do **not** write `server = "host/omop"` the way
Postgres/Redshift examples do. SQL Server's JDBC driver has no path-style database syntax —
that produces a `"TCP/IP connection... has failed"` error that looks exactly like a
stopped/unreachable instance but isn't (cost real debugging time finding this, 2026-09-05). Use
`server = "host"` plus `extraSettings = "databaseName=omop"` instead. Full explanation in
[`SQL_SERVER.md`](SQL_SERVER.md).

### Passwords

Postgres/SQL Server/both Redshifts use AWS-managed master passwords — never plaintext in
Terraform state or any repo. Fetch on demand:

```bash
aws secretsmanager get-secret-value --secret-id <arn> --query SecretString --output text | jq -r .password
```

| Target | Secret ARN |
|---|---|
| Postgres | `arn:aws:secretsmanager:eu-west-2:905418084644:secret:rds!db-ce6b0a05-a4ec-480f-b734-18f75b4dca00-ITPuXf` |
| SQL Server | `arn:aws:secretsmanager:eu-west-2:905418084644:secret:rds!db-f2e6cae8-0151-43dd-a252-4e2997c1b51b-HsR5E9` |
| Redshift (Serverless) | `arn:aws:secretsmanager:eu-west-2:905418084644:secret:redshift!onco-dialect-replication-dev-omop_admin-fgEyTK` |
| Redshift (provisioned test) | `arn:aws:secretsmanager:eu-west-2:905418084644:secret:redshift!onco-dialect-replication-dev-redshift-test-omop_admin-8SuvqY` |

Snowflake's password isn't AWS-managed — it's in `onco-test-data/db_config.yaml` (gitignored
there too) or ask the user directly.

BigQuery doesn't use a password at all — its credential is a service-account key file,
`~/.bigquery_service_account.json` (outside any git repo, `chmod 600`). If missing:

```bash
cd onco-test-data/terraform
terraform output -raw bigquery_service_account_key_json | base64 -d > ~/.bigquery_service_account.json
chmod 600 ~/.bigquery_service_account.json
```

## 2. Unhibernate if needed

Postgres and SQL Server auto-stop when idle (Postgres: 90 min, SQL Server: 60 min — more
aggressive since SQL Server License-Included billing is the dominant cost line here). **Assume
both are stopped unless you just used them.** A connection failure that looks like "instance
unreachable" is very likely just this (or, for SQL Server specifically, the connection-string
trap above — check both).

```bash
aws rds start-db-instance --db-instance-identifier onco-dialect-replication-dev-postgres
aws rds wait db-instance-available --db-instance-identifier onco-dialect-replication-dev-postgres

aws rds start-db-instance --db-instance-identifier onco-dialect-replication-dev-sqlserver
aws rds wait db-instance-available --db-instance-identifier onco-dialect-replication-dev-sqlserver
```

`wait` normally returns in under 10 minutes. If `describe-db-instances` still reports
`starting` well past that, cross-check `aws rds describe-events --source-identifier <id>
--source-type db-instance --duration 60` — RDS's own event log (`recovery complete` / `DB
instance started`) is the more reliable signal; the status field has been observed lagging it.

Redshift Serverless has no on/off state (bills per query-second) — nothing to start. Snowflake
has its own separate warehouse-level auto-suspend, handled transparently by the connector — no
action needed. BigQuery has no instance/idle state either — always reachable, billing is
usage-based per query-bytes-processed (confirmed on).

The provisioned Redshift test cluster auto-**pauses** (not stops) after 30 idle minutes, same
idle-check Lambda as the RDS targets above:

```bash
aws redshift resume-cluster --cluster-identifier onco-dialect-replication-dev-redshift-test
aws redshift wait cluster-available --cluster-identifier onco-dialect-replication-dev-redshift-test
```

## 3. Bulk loading (`insertTable(..., bulkLoad = TRUE)`)

Relevant if you hit the known JDBC bug (`R/artemis.R` documents it: `"parameter type
'data.frame' is ambiguous or not supported"`, inside `CohortGenerator::generateCohortSet()`'s
call chain) or just want faster inserts. Status per dialect — full detail in
[`BULK_LOAD.md`](BULK_LOAD.md) and [`SQL_SERVER.md`](SQL_SERVER.md):

| Target | `bulkLoad` support | Setup needed |
|---|---|---|
| PostgreSQL | ✅ verified working | `Sys.setenv(POSTGRES_PATH = "/opt/homebrew/opt/libpq/bin")` (this machine — `psql` installed via `brew install libpq`) |
| Redshift (either cluster) | ✅ verified working | Source the credentials file below first |
| SQL Server | ❌ not supported by `DatabaseConnector` at all — flag is silently ignored | None — falls back to the default JDBC batch path (already reasonably fast; see `SQL_SERVER.md`) |
| Snowflake | ❌ not in `DatabaseConnector`'s bulk dispatch either | None — same default JDBC path |
| BigQuery | ❌ not in the `bulkLoad` dispatch either, **but** uses a different, BigQuery-specific insert path (`ctasHack`) regardless of the flag — verified working | `tempEmulationSchema = "results"` required on any `insertTable()` call creating a new table (or set the global option, see §6) |

### Redshift: source the credentials file, don't re-derive them

A dedicated, narrowly-scoped IAM user (`onco-dialect-replication-dev-redshift-bulk-load`,
`onco-test-data/terraform/redshift_bulk_load_iam.tf`) was created specifically for this — its
key/secret already live in **`~/.redshift_bulk_load_credentials.env`** (dotenv-format, `chmod
600`, not inside any git repo). This exists because `DatabaseConnector`'s Redshift `COPY` step
has no session-token support (confirmed against the installed release and current
`OHDSI/DatabaseConnector` GitHub `main`, 2026-09-05), so the short-lived `aws login` session
credentials used everywhere else in this project can't authenticate it — this is the one
long-lived AWS credential in the whole project, scoped to only `dbconnector-bulk/*` in the
existing vocab S3 bucket (it cannot read the vocab CSVs or anything else in the account).

```r
readRenviron("~/.redshift_bulk_load_credentials.env")   # sets AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY,
                                                          # AWS_DEFAULT_REGION, AWS_BUCKET_NAME,
                                                          # AWS_OBJECT_KEY, AWS_SSE_TYPE
insertTable(connection, databaseSchema = "results", tableName = "my_table",
            data = myDataFrame, dropTableIfExists = TRUE, createTable = TRUE, bulkLoad = TRUE)
```

(Bash equivalent, if scripting outside R: `set -a; source ~/.redshift_bulk_load_credentials.env; set +a`.)

If that file is missing (different machine, fresh checkout), regenerate it — never by typing
values into a file directly, always by piping straight from `terraform output`:

```bash
cd onco-test-data/terraform
{
  echo "AWS_ACCESS_KEY_ID=$(terraform output -raw redshift_bulk_load_access_key_id)"
  echo "AWS_SECRET_ACCESS_KEY=$(terraform output -raw redshift_bulk_load_secret_access_key)"
  echo "AWS_DEFAULT_REGION=eu-west-2"
  echo "AWS_BUCKET_NAME=onco-dialect-replication-dev-vocab-905418084644"
  echo "AWS_OBJECT_KEY=dbconnector-bulk"
  echo "AWS_SSE_TYPE=AES256"
} > ~/.redshift_bulk_load_credentials.env
chmod 600 ~/.redshift_bulk_load_credentials.env
```

### Postgres: local `psql`, no AWS involved

`bulkLoad = TRUE` shells out to the local `psql` binary (`\copy` over the existing connection —
no S3, no separate credential). Needs `POSTGRES_PATH` pointing at the directory containing
`psql`:

```r
Sys.setenv(POSTGRES_PATH = "/opt/homebrew/opt/libpq/bin")   # after `brew install libpq` on a Mac without a full Postgres install
```

## 4. Prerequisites this all assumes are installed

Already set up on this machine as of 2026-09-06 — if working from a different one, replicate:

- R packages: `DatabaseConnector`, `aws.s3` + `aws.signature` (Redshift bulk load only).
- JDBC drivers for all five dialects in `~/.jdbc_drivers` (fetch missing ones with
  `DatabaseConnector::downloadJdbcDrivers(dbms = "<postgresql|sql server|redshift|bigquery>", pathToDriver = path.expand("~/.jdbc_drivers"))`
  — Snowflake's must be added the same way if starting fresh; BigQuery's is the Simba driver,
  `GoogleBigQueryJDBC42.jar`, ~37MB).
- `psql` on `PATH` or reachable via `POSTGRES_PATH` (Postgres bulk load only) —
  `brew install libpq` on a Mac.
- `gcloud`/`gsutil`/`bq` CLIs (`brew install --cask google-cloud-sdk`) — only needed for
  provisioning/managing the BigQuery project itself (`onco-test-data/terraform/bigquery.tf`),
  not for the R pipeline to connect and query, which only needs the JDBC driver + service
  account key above.

## 5. Snowflake: two schemas, know the difference

`OMOP.CDM` is the regenerated test data (safe to write to — what this whole handoff is about).
`OMOP.CDM_LEGACY` is the original real data (530 patients, pre-dates this project's changes) —
**read-only**, never point `cdmDatabaseSchema`/`workDatabaseSchema` at it.

## 6. BigQuery: connection gotchas and one IAM gap, all load-bearing

None of these are optional — omitting any one produces a real, misleading-sounding error.
Full detail on the first three (including the exact error text each produces) is in the
comment block above the BigQuery `connectionDetails` in `config/aws_targets_connectionDetails.R`;
summary:

1. **`EnableSession=1`** in the connection string — without it, even a bare `SELECT` fails
   ("Transaction control statements are supported only in scripts or sessions").
2. **`Location=EU`** in the connection string — the `cdm`/`results` datasets are in the `EU`
   multi-region, but the driver defaults to querying in `US` ("Not found: Dataset
   omop-test-data:cdm was not found in location US" otherwise).
3. **`tempEmulationSchema`** (explicit parameter, or `options(sqlRenderTempEmulationSchema = "results")`
   globally) on any `insertTable()` call that creates a new table — BigQuery has no real temp
   tables, and `DatabaseConnector`'s BigQuery-specific insert path (`ctasHack`, a third
   mechanism distinct from both `bulkLoad` and SQL Server's plain batched insert) needs a real
   dataset to emulate one in ("tempEmulationSchema is required to use insertTable with bigquery
   when inserting into a new table" otherwise).
4. **`roles/bigquery.readSessionUser` on the service account** — fixed 2026-09-06, was missing
   until a full pipeline run surfaced it ~11 minutes in (past diagnostics and the main cohort
   tree): the Simba JDBC driver's Storage Read API path (used for larger result sets) calls
   `bigquery.readsessions.create`, which neither `dataEditor` nor `jobUser` grants. Two
   driver-level workarounds were tried first and confirmed not to avoid the call — the
   permission grant (`onco-test-data/terraform/bigquery.tf`) was the actual fix, confirmed by
   fetching all 17,662 rows of `drug_exposure` afterward. Already applied — nothing to do here
   unless working against a differently-provisioned service account.
