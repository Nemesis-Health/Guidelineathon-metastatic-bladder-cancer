# Bulk loading with DatabaseConnector

`DatabaseConnector::insertTable()` has two paths: a plain parameterized JDBC batch insert
(the default), and a dialect-specific **bulk load** (`bulkLoad = TRUE`, or globally via
`Sys.setenv(DATABASE_CONNECTOR_BULK_UPLOAD = TRUE)`). This matters here for two reasons:

- **Speed** — bulk load bypasses row-by-row JDBC parameter binding entirely.
- **The known Postgres/JDBC bug** — `R/artemis.R` already documents working around
  `insertTable()` failing on Postgres with `"parameter type 'data.frame' is ambiguous or not
  supported"` when called indirectly (via `ARTEMIS::getConDF()` → `CohortGenerator::generateCohortSet()`).
  That's the default JDBC path. Bulk load uses a completely different mechanism per dialect
  (below) that doesn't go through JDBC parameter binding at all, so it isn't exposed to that
  class of bug — worth trying wherever `insertTable()` is called directly in this codebase, not
  just as a speed optimization.

Both Postgres and Redshift bulk loading are **verified working** against our AWS targets as of
2026-09-05 (empty-table round-trip insert + select, via the exact mechanism below). Status,
what each needs, and why:

## PostgreSQL: local `psql`, no S3 involved

Mechanism (`DatabaseConnector:::bulkLoadPostgres`): writes the data frame to a local CSV, then
shells out to the **local `psql` binary** to run `\copy` directly over the same connection the
JDBC connection already has (so no separate network path or AWS involvement — same reachability
as the JDBC connection itself).

Requirement: `POSTGRES_PATH` env var, pointing at the **directory** containing `psql` (not the
binary itself).

```r
Sys.setenv(POSTGRES_PATH = "/opt/homebrew/opt/libpq/bin")   # this machine, after `brew install libpq`
```

`psql` wasn't installed on this Mac — installed via `brew install libpq` (Homebrew's client-only
package; doesn't pull in a full local Postgres server) to get it working. If running this
pipeline from a different machine, install the same way (or point `POSTGRES_PATH` at any
existing `psql`, e.g. from a full `postgresql` install or `psql --version` if it's already on
`PATH`).

```r
insertTable(connection, databaseSchema = "results", tableName = "my_table",
            data = myDataFrame, dropTableIfExists = TRUE, createTable = TRUE, bulkLoad = TRUE)
```

## Redshift: gzip CSV → S3 → `COPY`, needs a long-lived IAM key

Mechanism (`DatabaseConnector:::bulkLoadRedshift`): gzips the data frame to a temp file,
`aws.s3::put_object()`s it to S3, issues a Redshift `COPY ... CREDENTIALS
'aws_access_key_id=...;aws_secret_access_key=...'` naming that S3 object, then deletes the
staged object. Requires the `aws.s3` R package (installed 2026-09-05: `install.packages("aws.s3")`,
pulled in `aws.signature` as a dependency).

**Important limitation, confirmed against both the installed DatabaseConnector 6.4.0 and the
current `OHDSI/DatabaseConnector` GitHub `main` branch (2026-09-05, so not fixed in a newer
release either):** the Redshift `COPY` template
(`inst/sql/sql_server/redshiftCopy.sql`) has no session-token field — only
`aws_access_key_id`/`aws_secret_access_key`. **Temporary/STS session credentials (e.g. from `aws
login`) will not work here** — Redshift rejects them at the `COPY` step even though the S3
upload half succeeds fine with session creds (confirmed live: `put_object`/`delete_object`
succeed, then `COPY` 403s). This needs a genuine long-lived IAM access key.

A dedicated one now exists for exactly this: IAM user
`onco-dialect-replication-dev-redshift-bulk-load` (`onco-test-data/terraform/redshift_bulk_load_iam.tf`),
scoped to only `PutObject`/`GetObject`/`DeleteObject`/`ListBucket` on the
`dbconnector-bulk/*` prefix of the existing vocab S3 bucket — it cannot read the vocab CSVs
themselves or anything else in the account. Fetch its credentials (never stored in a file, by
design — this is the one AWS credential in this project that doesn't rotate/expire on its own):

```bash
cd onco-test-data/terraform
terraform output -raw redshift_bulk_load_access_key_id
terraform output -raw redshift_bulk_load_secret_access_key
```

Then, before sourcing `run.R` against Redshift:

```r
Sys.setenv(
  AWS_ACCESS_KEY_ID     = "<from terraform output above>",
  AWS_SECRET_ACCESS_KEY = "<from terraform output above>",
  AWS_DEFAULT_REGION    = "eu-west-2",
  AWS_BUCKET_NAME       = "onco-dialect-replication-dev-vocab-905418084644",
  AWS_OBJECT_KEY        = "dbconnector-bulk",
  AWS_SSE_TYPE          = "AES256"
)
insertTable(connection, databaseSchema = "results", tableName = "my_table",
            data = myDataFrame, dropTableIfExists = TRUE, createTable = TRUE, bulkLoad = TRUE)
```

`checkBulkLoadCredentials()` (DatabaseConnector's internal pre-flight check) calls
`aws.s3::bucket_exists()` — a plain `HeadBucket`, which IAM maps to `s3:ListBucket` on the
bucket itself, not just the object prefix. The IAM policy grants that too (condition-scoped to
the `dbconnector-bulk/*` prefix via `StringLikeIfExists`, so it doesn't open up listing of the
rest of the bucket) — found live (`403 Forbidden`) when the policy initially only had
object-level permissions.

## Not applicable here

SQL Server and Snowflake aren't in DatabaseConnector's `bulkLoad` dispatch at all (only
Redshift/PDW/Hive/Postgres/Spark are) — `insertTable()` always uses the plain JDBC path for
those two regardless of the `bulkLoad` argument.

## Enabling globally vs. per call

Per-call (`bulkLoad = TRUE` on each `insertTable()`) is what's shown above and what was tested.
`Sys.setenv(DATABASE_CONNECTOR_BULK_UPLOAD = TRUE)` (checked by `insertTable()`'s default
argument, `bulkLoad = Sys.getenv("DATABASE_CONNECTOR_BULK_UPLOAD")`) makes it the default for
every `insertTable()` call in the R session without editing call sites — worth setting globally
at the top of `run.R` if testing whether it resolves the JDBC ambiguous-parameter bug end to
end, since that failure currently happens inside `ARTEMIS::getConDF()`'s internal call chain,
not at either of this repo's own direct `insertTable()` call sites.
