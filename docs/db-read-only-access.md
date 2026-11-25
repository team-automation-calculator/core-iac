# Read-only access to the app database

For looking at the data during a deploy or an incident without the master password. Where
`db_read_only_access_enabled = true` is applied in both of an environment's tfvars
(base-cluster-layer and cluster-addons-layer), the database has two read-only roles:

| Role | For | AWS identity that may sign in as it | Profile |
|---|---|---|---|
| `ac_read_only_infra_eng_<env>` | a person | the `InfraEng<Env>` and `InfraEng<Env>ReadOnly` permission sets | `infra-eng-<env>-ro` |
| `ac_read_only_ci_<env>` | CI and agents | the read-only CI role `ac_ci_terraform_<env>_read_only` | `ac-ci-<env>-ro` |

Two roles so that the PostgreSQL log says who ran what. An agent always uses `--as ci`.

```bash
./go db-read-only-psql staging --as infra-eng                  # interactive psql
./go db-read-only-psql staging --as ci -- -c "select count(*) from users"
```

The script needs `aws`, `kubectl`, `psql` (macOS: `brew install libpq`) and an `aws sso login`.

## What the roles can and cannot do

Both are members of `ac_read_only`, which holds the grants:

- `SELECT` on every table, view and sequence in schema `public` of `automation_calculator_app`,
  which is everything the app has. Default privileges cover tables a later migration adds.
- Nothing else. No insert, update, delete, truncate or DDL, no temporary tables, no connection to
  the `postgres`, `template1` or `rdsadmin` databases, and no membership of `rds_superuser`,
  `pg_monitor`, `pg_read_all_stats` or `pg_signal_backend`. They cannot see other sessions' query
  text in `pg_stat_activity` or cancel a backend.
- Like every PostgreSQL role they can read the system catalogs (`pg_class`, `pg_roles` and so
  on). PostgreSQL has no supported way to hide those.

**The tables hold user data** (`users` has email addresses and credential hashes). The repo is
public: never paste rows into a pull request, an issue or a commit.

Each role also has session defaults that keep an observer from making an incident worse:
`default_transaction_read_only = on`, `statement_timeout = 30s`, `lock_timeout = 5s`,
`idle_in_transaction_session_timeout = 60s`, `idle_session_timeout = 30min`, and a connection
limit of 3 (the instance allows 79). A `SELECT` holds a lock that blocks a migration's DDL, which
is why a statement or an idle open transaction is cut short. A session can change these defaults;
the grants are the boundary, not the defaults.

To let the roles do this, the SQL also takes three default rights away from `PUBLIC`, that is from
every role: `CREATE` on schema `public` (the database predates PostgreSQL 15), every right on the
app database (connect is granted back to `ac_read_only` only), and `CONNECT` on `postgres` and
`template1`. The app is unaffected: it connects as the owner.

## How a sign-in works

1. **Token.** There are no passwords. The roles are members of `rds_iam`, so RDS accepts only an
   IAM token, valid for 15 minutes to open a connection, over TLS. `rds-db:connect` on the role's
   name decides who may ask for one: `terraform/modules/aws/sso-infra-eng` and
   `terraform/modules/aws/ci-iam-role`. The instance id in those policies is a wildcard (the base
   layer is applied before the database exists); the environment in the role name does the
   scoping, since staging and production share an AWS account.
2. **Network.** The database is in private subnets and its security group admits the cluster
   only. A small HAProxy pod, `db-read-proxy` in namespace `ac-db-access`, relays TCP to the RDS
   endpoint. The read-only CI role may `kubectl port-forward` to pods in that namespace and
   nowhere else. The pod holds no credential and cannot read the traffic.
3. **psql** connects to the local end of the forward with `sslmode=verify-full` against the RDS
   endpoint's name, using the AWS certificate bundle (downloaded once to `tmp/rds-ca/`).

The forwarder has a negative pod priority: on a full node (17 pod slots, see
`scripts/argocd_preflight.sh`) it is the first pod evicted and it never evicts another. If the
script reports that the port-forward exited, look at
`kubectl --context ac_app_<env>-ro -n ac-db-access get pods`: a `Pending` forwarder means the
node has no free slot.

## Who did what

Every statement the two roles run is logged (`log_statement = all`, set per role), and the RDS
log line carries the user name. The log is on the instance, kept three days:

```bash
aws rds describe-db-log-files --profile ac-ci-staging-ro --region us-west-1 \
  --db-instance-identifier <instance id>
aws rds download-db-log-file-portion --profile ac-ci-staging --region us-west-1 \
  --db-instance-identifier <instance id> --log-file-name <name> --output text \
  | grep ac_read_only_
```

Downloading needs the read-write profile (`rds:DownloadDBLogFilePortion` is not a `Describe`,
`Get` or `List` action). The log shows which of the two roles ran a statement, not which person:
requesting a token is a local signature and leaves no CloudTrail event. Connections are not
logged separately (`log_connections` is instance-wide and off). Exporting the PostgreSQL log to
CloudWatch Logs would keep it longer and make it readable under the `-ro` profile; that is not
done yet.

The Job that creates the roles prints a `statements_logged` column. If it is `f`, RDS refused the
per-role setting and the logging has to come from a parameter group instead.

## Where it is defined

| Piece | Where |
|---|---|
| IAM authentication on the instance, the roles Job, the forwarder, the port-forward Role | `terraform/modules/aws/main_rails_app` (`db_read_only_access.tf`, `db_read_only_roles.sql`, `db_read_proxy_haproxy.cfg`) |
| `rds-db:connect` for the read-only CI role | `terraform/modules/aws/ci-iam-role` |
| `rds-db:connect` for the InfraEng permission sets | `terraform/modules/aws/sso-infra-eng` |
| The client | `scripts/db_read_only_psql.py` |

Terraform Cloud cannot reach the database, so the roles are created by a Kubernetes Job that runs
`db_read_only_roles.sql` as the master user from the app Secret. The Job's name carries a hash of
the SQL, the role names and the instance, and it runs again when any of them changes. The SQL can
be run any number of times. Read its result with
`kubectl --context ac_app_<env>-ro -n automation-calculator logs job/<name>`.

Setting `db_read_only_access_enabled` back to `false` removes the forwarder and turns IAM
authentication off. The roles stay in the database and can no longer sign in. To remove them,
as the master user: `DROP OWNED BY <role>; DROP ROLE <role>;` for the two login roles and then
`ac_read_only`.

A database restored from a snapshot keeps its roles. A staging database restored from a
production snapshot would carry the `_production` roles, which no staging identity can use; the
Job adds the `_staging` ones.
