# App log persistence: collect, store and read the app pods' logs

Status: **in progress**. This plan is the first PR of a stack; each stage below is its own PR and
nothing is live until that stage's PR is merged and applied. The stage table says what each one
changes and which Terraform Cloud workspace applies it.

Prices were checked on 2026-11-24 against the AWS public price list for CloudWatch in US West
(N. California, `us-west-1`), bulk CSV version `20261124145303`. Monthly figures use the
measured log volume below and are rounded to the nearest ten cents. Log volume was measured on
2026-11-24 with `kubectl logs` under the `-ro` contexts. Anything marked **verify** could not be
confirmed from a public page, the API or this repo.

## Summary and recommendation

- **Nothing keeps the app's logs today.** Rails writes to stdout (`RAILS_LOG_TO_STDOUT`), the
  kubelet keeps one roughly 10 MB file per container, and that is all there is. `kubectl logs`
  reached back about 3 hours on production and about 8 hours on staging when measured. A pod
  replacement keeps one previous container's file; a node roll (every EKS upgrade, every AMI
  release) deletes everything. The moments that most need logs are the ones that destroy them.
- **Recommended: Fluent Bit as a DaemonSet shipping the `automation-calculator` namespace to one
  CloudWatch Logs group per environment, `/ac/<env>/app`, kept 90 days.** The collector is the
  `aws-for-fluent-bit` Helm chart from the `eks-charts` repository the ALB controller already
  comes from, installed by `cluster-addons-layer` like the other add-ons.
- **No new secret anywhere.** The collector writes through an IRSA role that can only create
  streams and put events in that one log group. Readers use what already exists: SSO, then the
  `InfraEng<Env>` or `InfraEng<Env>ReadOnly` permission set, then optionally the
  `ac_ci_terraform_<env>_read_only` role. Both read-only policies already allow `logs:Get*`,
  `logs:Describe*` and `logs:List*`, which covers reading a stream but **not searching**:
  `logs:FilterLogEvents`, `logs:StartQuery` and `logs:StopQuery` match none of those patterns.
  Stage 1 adds exactly those three, to the CI read-only role and to the permission sets assigned
  to `steven.uray@automation-calculations.net`, so the human identity and the agents read logs
  the same way.
- **Logs stay private.** They never leave the AWS account, access is IAM only, CloudWatch Logs
  encrypts at rest by default, and no third party is involved.
- **Cost: about $3 per month for both environments at list price ($35 per year), and under $1
  per month if the account's CloudWatch free tier applies (verify).** Maintenance is about one
  day to set up and one to two hours per quarter for the chart bump.
- **An error alarm comes with it.** A metric filter counts the app's `Completed 5xx` lines and
  alarms to the existing `ac-app-<env>-alarms` SNS topic on the first one. It exists only where
  that topic does: production (`cloudwatch_alarms_enabled`), not staging. The ALB 5xx alarm
  needs more than 10 errors a minute for two minutes; this one catches a single failure.
- **More than half of the volume is noise, and removing it is an app change, not this repo's.**
  `config/environments/production.rb` in the app sets `config.log_level = :debug`, and every
  request in the production sample was a health check. See "Cutting the volume".

## Current state (measured 2026-11-24)

| | production | staging |
|---|---|---|
| App pods | 1 | 1 |
| Log rate | 0.78 MB in 13.5 min, about 3.5 MB/h | 0.94 MB/h |
| Per day / per month | 83 MB / **2.5 GB** | 23 MB / **0.7 GB** |
| Lines | about 370 per minute | about 100 per minute |
| `DEBUG` lines | 38% | 20% |
| What the requests were | 61% `GET /` from `15.177.x` (Route 53 health checkers, verify), 39% `GET /health` from the VPC (kubelet probes, ALB health checks) | almost all `/health` |
| `FATAL` or `ERROR` lines, 5xx responses | none in the sample | none in 8 hours |
| How far back `kubectl logs` reaches | about 3 hours | about 8 hours |
| Pods on the node (of 17 on `t4g.medium`) | 9 | 13 |

The production sample is 13.5 minutes long, because that is all the current log file held, so
the monthly figure is an extrapolation. It is a floor for real traffic and a fair estimate for
the health-check baseline that dominates it.

Line format, from `Logger::Formatter` with the request id tag:

```
I, [2026-11-24T23:25:34.975108 #1]  INFO -- : [d42fb0eb-...] Started GET "/" for 15.177.62.59 at 2026-11-24 23:25:34 +0000
I, [2026-11-24T23:25:34.978391 #1]  INFO -- : [d42fb0eb-...] Completed 200 OK in 3ms (Views: 2.4ms | ActiveRecord: 0.0ms ...)
```

What the logs contain: client IP addresses, request paths, request ids, controller and view
names, SQL at debug level. The app's `filter_parameter_logging.rb` already filters `passw`,
`email`, `secret`, `token`, `_key`, `crypt`, `salt`, `certificate`, `otp`, `ssn`, `cvv` and
`cvc`, so OAuth callbacks and sign-in forms do not write credentials or email addresses.

## Design

```
app pod stdout
  -> /var/log/containers/<pod>_automation-calculator_<container>-<id>.log   (kubelet, on the node)
  -> Fluent Bit DaemonSet pod in kube-system                                (tails only that namespace)
  -> CloudWatch Logs group /ac/<env>/app, one stream per pod (app-<pod name>), 90 days
       -> metric filter "Completed 5" -> AcApp/<env> AppServerErrors -> alarm -> ac-app-<env>-alarms
       <- read: scripts/app_logs.py under the -ro profile (humans and agents)
```

**Collector.** `helm_release.fluent_bit` in `terraform/modules/aws/cluster-addons-layer`, chart
`aws-for-fluent-bit` 0.2.1 (image `public.ecr.aws/aws-observability/aws-for-fluent-bit:3.2.1`),
behind a per-environment `app_logs_enabled` variable so staging goes first. Settings that
matter:

- `input.path = /var/log/containers/*_automation-calculator_*.log`. Pod names cannot contain an
  underscore, so the pattern can only match the namespace segment. Add-on, ArgoCD and
  Fluent Bit's own logs are not shipped; they are a later decision with its own volume estimate.
- `cloudWatchLogs.logKey = log`. Only the application's line is sent. Without it every event
  carries the Kubernetes metadata as JSON, which is three to four times the bytes for 150-byte
  lines, and ingestion is the main cost.
- `cloudWatchLogs.logStreamTemplate = app-$kubernetes['pod_name']`, so a stream is one pod's
  life and a deploy shows up as a new stream.
- `cloudWatchLogs.autoCreateGroup = false`. Terraform owns the group and its retention; the
  collector's role cannot create or change groups.
- Chart default resources: requests 50m CPU and 50 Mi, limit 250 Mi. One pod per node: 10 of 17
  pod slots on production, 14 of 17 on staging. ArgoCD on production (Phase 8) takes it to 14.
- The tail position database is on the node (`/var/log/flb_kube.db`), so a collector restart
  resumes where it stopped. A file that appears later (new pod, rotation) is read from its start.

**What is still lost.** Lines written in the seconds before a node is terminated, if Fluent Bit
has not flushed them (flush interval is 5 seconds by default). Lines longer than the tail
buffer are skipped (`Skip_Long_Lines On`). Nothing from before the collector's first start is
backfilled except the current container file.

**Storage.** `aws_cloudwatch_log_group.app` in the same module, Standard class, retention from
`app_log_retention_days` (default 90). The Infrequent Access class halves ingestion ($0.335 per
GB) but does not support metric filters (and, verify, restricts reads to Logs Insights), so it
loses the alarm for a saving of about $1 per month. Not used.

The group lives in `cluster-addons-layer`, so a `terraform destroy` of an environment deletes
its log history with it. That is acceptable for the planned staging destroy
(`docs/staging-destroy-and-recreate.md`): a recreated staging starts with an empty group. If
staging's history ever matters, export it first.

**Encryption.** CloudWatch Logs encrypts every group at rest with a service-managed key. A
customer-managed KMS key adds $1 per key per month (verify) and a key policy that must name the
Logs service and every reader, in exchange for an audit trail of decrypts and the ability to
revoke. Not adopted; the IAM boundary is the same either way.

**Errors.** `aws_cloudwatch_log_metric_filter.app_server_errors` matches the literal
`"Completed 5"`, which Rails writes once per request that ends in a 5xx
(`Completed 500 Internal Server Error in 12ms`). It publishes `AppServerErrors` in namespace
`AcApp/<env>` with a default of 0. `aws_cloudwatch_metric_alarm.app_server_errors` fires when
the 5-minute sum reaches `app_server_error_alarm_threshold` (default 1) and notifies the
existing SNS topic. Matching `FATAL` lines instead was rejected: a request for an unknown path
(`ActionController::RoutingError`) is logged at `FATAL` by Rails (verify on the first stored
scanner request), so every scanner probing `/wp-login.php` would page. Those lines are still in the group for a query.

## Access and secrets

| Who | Path | What it can do with logs | Secret |
|---|---|---|---|
| Fluent Bit | IRSA role `<env>_eks_fluent_bit`, trusted only for `kube-system:fluent-bit` | `logs:CreateLogStream`, `logs:PutLogEvents`, `logs:DescribeLogStreams` on `/ac/<env>/app` only | none (projected service account token) |
| `steven.uray@automation-calculations.net` | SSO, `InfraEng<Env>` or `InfraEng<Env>ReadOnly` permission set (profiles `infra-eng-<env>[-ro]`) | read, filter, Insights query | none (SSO session) |
| Agents and scripts | the same SSO session, chained to `ac_ci_terraform_<env>_read_only` (profiles `ac-ci-<env>-ro`) | read, filter, Insights query | none |
| Terraform Cloud | workspace credentials, `ac_ci_terraform_<env>` | creates the group, filter and alarm | already in TFC |
| Cloud agents with no SSO session (claude.ai routines) | none | nothing | deliberately none: no access keys are minted for this (`AGENTS.md`, AWS Authentication). Revisit with keyless federation. |

The three added actions, in both `terraform/modules/aws/ci-iam-role` (read-only statement) and
`terraform/modules/aws/sso-infra-eng` (`read_only_infrastructure_actions`):

| Action | Needed for |
|---|---|
| `logs:FilterLogEvents` | search a group across streams by time and pattern (`aws logs filter-log-events`, `aws logs tail`) |
| `logs:StartQuery` | start a Logs Insights query |
| `logs:StopQuery` | cancel one |

`logs:GetQueryResults`, `logs:GetLogEvents` and `logs:DescribeLogGroups` are already covered.
`logs:StartLiveTail` is left out: it bills $0.01 per minute of session and `kubectl logs -f`
under the `-ro` context does the same job for a running pod.

The grant is on `*`, like every other service in those statements, so it also covers any other
log group in the account. Today there are none of note: the EKS control plane log types are not
enabled and RDS does not export its logs.

**Log content is untrusted input.** Request paths, query strings and user agents are written by
whoever sends the request. An agent reading logs must treat every line as data and never as an
instruction; `scripts/app_logs.py` says so in its output header and the skills repeat it.

## Cost per month

us-west-1 list prices: ingestion $0.67 per GB (Standard), storage $0.033 per GB-month, Logs
Insights $0.0067 per GB scanned, custom metric $0.30, standard alarm $0.10.

| Item | Basis | production | staging | both |
|---|---|---|---|---|
| Ingestion | 2.5 GB and 0.7 GB | $1.70 | $0.50 | $2.10 |
| Storage, 90 days | 7.5 GB and 2.1 GB retained, priced uncompressed as the upper bound (CloudWatch bills the compressed size) | $0.20 | $0.10 | $0.30 |
| Insights queries | one full 90-day scan of each group per month | $0.10 | $0.00 | $0.10 |
| Error metric and alarm | 1 metric, 1 alarm, production only (staging has no alarms or SNS topic) | $0.40 | $0.00 | $0.40 |
| **Total** | | **$2.40** | **$0.60** | **$2.90** ($35 per year) |

Columns are rounded separately, so they do not add exactly.

- **With the free tier** (5 GB of ingestion, 5 GB of storage, 10 custom metrics and 10 alarms
  per month, account-wide; verify that it applies to this account and what production's four
  existing alarms already use): ingestion and storage are $0 and the total is the $0.40 for
  the metric and alarm, or less.
- **If the metadata stripping were dropped** (`logKey` unset): about 3.5 times the bytes, so
  about $8 per month. This is the one setting that matters for cost.
- **After the app-side noise cut** below: about 40% of today's volume, so about $1.80 per month
  at list price.
- **Sensitivity to traffic:** each additional 1 GB per month is $0.67 plus $0.10 of retained
  storage. Real user traffic is a small fraction of the health-check baseline today.
- **Compute:** none added. The collector's 50m CPU and 50 Mi requests fit on the existing node
  (requests today total 820m of about 1,930m allocatable on production).
- **Staging while destroyed:** $0; the group goes with the workspace.

## Maintenance cost

| Work | When | Effort |
|---|---|---|
| Build and roll out the five stages | once | about 1 day, most of it rollout watching |
| Chart bump (`aws-for-fluent-bit`) | with the quarterly dependency pass (`docs/dependency-upgrade-plan-2026-q4.md` pattern) | 1 to 2 hours per quarter, staging then production through `validate-infra-rollout` |
| Storage, retention, backups, patching of the store | never | $0, CloudWatch is managed |
| Alarm tuning | if the 5xx alarm is noisy | minutes: `app_server_error_alarm_threshold` in tfvars |
| Node pod-slot budget | when adding add-ons | the collector is one more pod per node; the limit is 17 on `t4g.medium` |

Failure modes to know about: if the collector is down, the app is unaffected and logs queue on
the node's disk up to the kubelet's rotation, then are lost. If CloudWatch rejects writes
(role or group missing), Fluent Bit retries and logs the error in its own pod log, which
`kubectl logs -n kube-system -l app.kubernetes.io/name=aws-for-fluent-bit` shows.

## Cutting the volume (app repository, not part of this stack)

Both changes are in `team-automation-calculator/automation-calculator`, ship as a normal image
bump, and together remove more than half of the bytes:

1. `config.log_level = :debug` to `ENV.fetch('RAILS_LOG_LEVEL', 'info')` in
   `config/environments/production.rb`. Debug lines are 38% of production's lines (view
   rendering and SQL for health checks). The chart can then set `RAILS_LOG_LEVEL` per
   environment if staging should stay at debug.
2. Silence the health checks: `config.silence_healthcheck_path = '/health'` (a Rails 8 setting,
   the app is on 8.1; verify against the app's Rails version) removes the `/health` lines. The `GET /` checks from `15.177.x` are a
   Route 53 health check on the apex; pointing it at `/health` would silence those too.

Shipping first and cutting second is deliberate: the stored logs are how the cut is measured.

## Alternatives considered

| Option | $ per month | Why not |
|---|---|---|
| **Fluent Bit to CloudWatch Logs** (chosen) | $2.90 | |
| `amazon-cloudwatch-observability` EKS add-on | $2.90 plus Container Insights, roughly $10 or more per node (verify) | bundles the CloudWatch agent and Container Insights metrics nobody asked for; two DaemonSets instead of one |
| Loki in the cluster, chunks in S3 | about $1 of S3 | 2 to 4 more pods on a 17-pod node, an upgrade path to own, and agent access through a `kubectl port-forward` instead of IAM; the `-ro` role cannot port-forward |
| SaaS (Grafana Cloud, Datadog, Better Stack, Sentry for errors) | $0 on free tiers at this volume | logs leave the account, and every reader including each agent needs a stored API token: a new secret to hold, scope and rotate |
| Firehose to S3, queried with Athena | under $1 | minutes of delivery latency, so useless for watching a deploy; nothing to save at 3 GB |
| Do nothing, rely on `kubectl logs` | $0 | the current state: 3 hours of history, none across a node roll |

## Stages

Each stage is a PR stacked on the previous one. Staging auto-applies on merge; production
waits for a confirm in Terraform Cloud.

| Stage | PR contents | Applied by | Expected plan | Verify |
|---|---|---|---|---|
| 0 | this plan | nothing | none | |
| 1 | `logs:FilterLogEvents`, `logs:StartQuery`, `logs:StopQuery` on the CI read-only policy and both InfraEng permission sets | `ac_app_<env>_base_cluster_layer`, all provisioned environments | 3 to change per environment (one IAM policy, two permission set inline policies), plus the known node group AMI `release_version` drift | `aws logs filter-log-events` under `ac-ci-<env>-ro` and `infra-eng-<env>-ro` stops returning AccessDenied |
| 2 | `cluster-addons-layer`: log group, IRSA role, service account, Fluent Bit release, 5xx metric filter and alarm (only where `cloudwatch_alarms_enabled`, so not on staging), all behind `app_logs_enabled`; `true` in staging's tfvars | `ac_app_staging_cluster_addons_layer` (production and development plan no changes) | staging: the new resources to add, nothing to change or destroy | DaemonSet ready, streams named `app-<pod>` appear in `/ac/staging/app` within a minute |
| 3 | `scripts/app_logs.py`, tests, `docs/app-logs.md`, `AGENTS.md`, the two rollout skills | nothing (no Terraform) | none | `./go validate`; the script against staging |
| 4 | `app_logs_enabled = true` in production's tfvars | `ac_app_production_cluster_addons_layer` | the same additions as staging, plus the metric filter and the alarm | as stage 2, plus the alarm in `OK`, through `validate-infra-rollout` |
| 5 | app repository: log level and health-check silencing | image bump | none here | bytes per day in the group before and after |

**Stage 1 and the node roll.** Every `base-cluster-layer` plan currently carries one extra
change, the node group's `release_version` moving to the newest AMI, and applying it rolls the
single node (about 90 seconds of app outage, measured on the arm64 move). Staging's base layer
auto-applies on merge, so merging stage 1 rolls staging's node; on production the roll happens
when the run is confirmed. That is the existing behaviour of any base-layer change, not
something this stack adds, but it decides when to merge stage 1. Stage 1 before stage 2 means
the first node roll after stage 2 is the first one whose logs survive.

**Rollback.** Stage 2 and 4: set `app_logs_enabled = false`. Terraform uninstalls the release
and deletes the group with its contents, the role, the filter and the alarm; the app is not
touched at any point. To keep the stored logs while removing the collector, remove only the
release from the module instead. Stage 1: revert the PR; reads that worked before still work.

## Risks and interactions

- **Pod slots.** One more pod per node. During a node roll the managed node group surges to 2
  or 3 nodes and each gets its own collector pod; that does not consume slots on the old node.
- **ArgoCD.** The collector is a Terraform `helm_release` in `kube-system`, outside the
  `automation-calculator` Application, so ArgoCD's prune and self-heal never see it.
- **First start duplicates nothing but is not a backfill.** On first install Fluent Bit reads
  the existing container file from its current end (`Read_from_Head` is off), so history starts
  at install time.
- **The 5xx alarm on a deploy.** A rolling deploy with one replica has a short window where the
  ALB returns 502 or 503; those are ALB responses, never `Completed 5xx` lines from Rails, so
  they do not trip this alarm.
- **Helm provider first plan.** A new `helm_release` plans as a plain add; the "re-adds all set
  values" artifact only affects releases that existed before the provider 3.x bump.
- **Free tier figure.** The cost table's list-price total is the number to budget; the free
  tier is a possible reduction, not an assumption.

## Sources

- AWS Price List bulk file, `AmazonCloudWatch`, `us-west-1`, version `20261124145303`
  (`https://pricing.us-east-1.amazonaws.com/offers/v1.0/aws/AmazonCloudWatch/current/us-west-1/index.csv`).
- `aws-for-fluent-bit` chart 0.2.1 from `https://aws.github.io/eks-charts`: `values.yaml` and
  `templates/configmap.yaml`, read from a download in `tmp/`.
- App repository at `main` on 2026-11-24: `config/environments/production.rb`,
  `config/initializers/filter_parameter_logging.rb`, `Gemfile` (Rails `~> 8.1.0`).
- `kubectl logs --timestamps` on `deploy/automation-calculator` under `ac_app_production-ro` and
  `ac_app_staging-ro`, 2026-11-24.
- `terraform/modules/aws/ci-iam-role/main.tf` and `terraform/modules/aws/sso-infra-eng/main.tf`
  for the read-only action lists.
