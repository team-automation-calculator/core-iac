# Dependency upgrade plan, Q4 2026

Status: **proposal** (draft PR). Nothing below is implemented yet. Each phase becomes its own PR,
following the pattern of the earlier bumps: one-line tfvars changes per environment, staging first,
production after a soak, a release-note audit table in the PR body, and the matching
`version_dates/` file updated in the same PR (see #310/#311 for EKS 1.36 and #324 for the ALB
controller).

Versions below were checked on 2026-10-25 against the vendor release pages and, where the read-only
SSO roles allow it, against the live staging and production accounts.

## Why

Everything in the stack is at least one release behind, and three items have a clock on them:

- **EKS 1.36** leaves standard support on 2027-08-02. 1.37 has been GA on EKS since 2026-10-01
  and is the only version that resets the 14-month window. Both clusters report
  `upgradePolicy: EXTENDED`, so falling behind costs money rather than causing an outage, but the
  nodes are still on the 1.36.2 AMI from 2026-06-25.
- **RDS PostgreSQL 16.13**: 16.x standard support ends 2029-02-28, so there is no deadline, but
  16.14 and 16.15 (CVE fixes) exist and `auto_minor_version_upgrade = true` has not picked them up.
  Two majors (17, 18) are available and 16.13 can upgrade straight to 18.6.
- **Terraform providers and runtime**: the committed lock files pin `hashicorp/aws` 6.44.0, which
  is why `terraform-aws-modules/eks` is held at 21.22.0 (21.24.0+ needs aws >= 6.52). Helm
  provider 2.x and Kubernetes provider 2.x are both superseded by 3.x majors, the TFE provider is
  14 minor releases behind, and TFC workspaces run Terraform 1.11 while CI validates with 1.15.2
  and lints with Helm 3.10.2.

The add-ons were partly refreshed in October (ALB controller 3.6.1, official external-dns chart),
but external-dns is two chart releases behind and metrics-server (chart 3.8.3, app 0.6.2) predates
every Kubernetes version EKS still supports.

## Scope

In scope: every version pin in this repo that is not the application image. That is the EKS
control plane and node AMI, RDS engine, Terraform runtime in TFC and CI, the Helm CLI in CI, all
Terraform providers and their lock files, the three `terraform-aws-modules` modules, and the three
add-on Helm charts.

Out of scope: the app image (`app_version`, handled by the bump scripts), the ArgoCD migration
(`docs/argocd-migration-plan.md`), the development environment's cluster and database (intentionally
unprovisioned; its tfvars are kept in step so a future `apply` would not go backwards), and Helm
chart changes to `helm/automation-calculator` beyond what a tool bump forces.

## Current state

| Component | Where pinned | Current | Latest (2026-10-25) | Deadline / note |
|---|---|---|---|---|
| EKS Kubernetes (staging, prod) | `env/<env>/.../base-cluster-layer/terraform.tfvars` | 1.36 (platform eks.14, nodes 1.36.2-20260625) | 1.37 (EKS GA 2026-10-01) | 1.36 standard support ends 2027-08-02; 1.37 ends 2027-12-01 |
| EKS Kubernetes (dev) | same | 1.29 (cluster not provisioned) | 1.37 | 1.29 is past extended support; tfvars only |
| RDS PostgreSQL (staging, prod) | `env/<env>/.../cluster-addons-layer/terraform.tfvars` | 16.13, `db.t4g.micro`, gp2, `default.postgres16`, **backup retention 0** | 18.6 (16.15 / 17.11 are the latest minors) | 16 standard support ends 2029-02-28; valid targets from 16.13 include 18.6 directly |
| Terraform in TFC workspaces | `env/<env>/tf_cloud/terraform.tfvars` `tfe_workspace_tf_version` | 1.11 | 1.17.0 (2026-10-21) | 1.12 to 1.17 are all v1.0-compatible minors |
| Terraform in CI | `.circleci/config.yml` executor image | 1.15.2 | 1.17.0 | |
| Helm CLI in CI | `.circleci/config.yml` `install-helm-client` | v3.10.2 | v4.3.1 (v3.22.1 is the last 3.x line) | `helm lint --strict` is what CI runs |
| `hashicorp/aws` | `versions.tf` `~> 6.0`, lock files 6.44.0 | 6.44.0 | 6.70.0 (2026-10-21) | 6.70.0 changed the import ID of `aws_route53domains_delegation_signer_record` only |
| `hashicorp/helm` | `~> 2.9`, lock 2.17.0 | 2.17.0 | 3.3.0 (2026-09-02) | 3.0 rewrote `set` blocks as list attributes |
| `hashicorp/kubernetes` | `~> 2.16`, lock 2.38.0 | 2.38.0 | 3.4.0 (2026-10-16) | 3.0 deprecates every non-`_v1` resource; we already use `_v1` |
| `hashicorp/tfe` | pinned `0.68.2` in env configs, `<= 0.68.2` in the module | 0.68.2 | 0.82.0 (2026-10-08) | breaking entries at 0.69.0, 0.75.0, 0.80.0; none touch what we use |
| `terraform-aws-modules/eks` | `base-cluster-layer/main.tf` | 21.22.0 | 21.29.0 (2026-10-07) | pinned until aws >= 6.52 |
| `terraform-aws-modules/iam` (IRSA) | `cluster-addons-layer/main.tf` `~> 6.0` | 6.6.1 (staging last resolved) | 6.8.2 (2026-09-18) | 6.8.1 split the ALB controller AGA policy |
| aws-load-balancer-controller chart | `cluster-addons-layer/main.tf` | 3.6.1 | 3.6.1 | done in #324 |
| external-dns chart | same | 1.21.1 (app 0.21) | 1.23.0 (app 0.23.0) | 1.22.0 made `policy` required and moved A ALIAS ownership TXT to the `a-` prefix |
| metrics-server chart | same | 3.8.3 (app 0.6.2), installed in the `default` namespace | 3.14.0 (app 0.9.0) | 0.9.x supports Kubernetes 1.34+ |
| EKS default add-ons (vpc-cni, coredns, kube-proxy) | not managed (no EKS add-ons registered; `list-addons` is empty in both clusters) | whatever the 1.36 upgrade left | per-version recommended | updated by hand after each control-plane bump |

Secondary providers (`random` 3.8.1, `tls` 4.2.1, `time` 0.13.1, `null` 3.2.4, `cloudinit` 2.3.7)
ride along with the lock-file refresh in Phase 2 and need no review.

## Decisions

| Decision | Choice | Why |
|---|---|---|
| Order | Tooling first (Terraform runtime, CI), then providers and modules, then add-on charts, then EKS 1.37, then RDS 18 | Each later phase is validated by the tooling of the earlier ones. Provider bumps are reversible; EKS is reversible for 7 days; RDS majors are not, so it goes last and gets a snapshot gate. |
| Terraform target | 1.17.0 in both TFC and CI, not 1.16.x | 1.17.0 is the current stable line (2026-10-21). 1.12 to 1.17 upgrade guides list no configuration-affecting changes; the only notes are a container parallelism change (1.14) and `terraform test` variable blocks (1.13), neither used here. State written by 1.17 is still readable by 1.11 under the v1.0 compatibility promise, so TFC rollback is a tfvars revert. |
| Helm CLI in CI | v4.3.1, with v3.22.1 as the fallback if `helm lint --strict` disagrees with the chart | Helm 4 is the maintained line (4.0 shipped 2025-11). Lint is the only CI use. The chart is `apiVersion: v2` with `apps/v1`, `v1` and `networking.k8s.io/v1` templates, which Helm 4 renders unchanged. |
| Helm provider | 3.3.0 (`~> 3.3`), in its own PR, after aws/tfe/kubernetes | 3.0 changes `set {}` / `set_sensitive {}` blocks to `set = [{...}]` lists, which touches 16 `set`, 6 `set_sensitive` and one `dynamic "set"` block across two modules. Expect a zero-change plan; this is a config rewrite, not an infra change. 3.1.0+ required for `upgrade_install`, 3.0.2+ for the plan-inconsistency fixes. |
| Kubernetes provider | 3.4.0 (`~> 3.4`) | Only `_v1` resources are used (two `kubernetes_service_account_v1`, two `kubernetes_secret_v1`), so 3.0's deprecations do not apply. 3.3.0 and 3.4.0 reject null label/annotation values on Namespace and Role, neither of which we create. |
| AWS provider | `~> 6.0` kept, lock files to 6.70.0 | No major. 6.70.0's one breaking change is a `aws_route53domains_delegation_signer_record` import ID, not used. Unblocks the EKS module. |
| TFE provider | 0.82.0, replacing the exact `0.68.2` pin and the module's `<= 0.68.2` with `~> 0.82` | Nothing between 0.69.0 and 0.82.0 touches `tfe_workspace` (only `hyok_enabled` became read-only, which we do not set), `tfe_workspace_settings`, `tfe_run_trigger` or `d/tfe_outputs`. 0.69.0 moved to protocol 6 (Terraform >= 1.0, fine). |
| EKS module | 21.29.0 | Pure additions since 21.22.0 (control-plane egress mode, scheduler and controller-manager config, warm pools, Karpenter trust condition). No default changes for managed node groups. Still 21.x, no upgrade guide needed. |
| RDS target | 18.6, directly from 16.13 | RDS lists 18.6 as a valid target for 16.13 and `db.t4g.micro` is orderable for 18.6 in us-west-1. Going to 17 first doubles the downtime for no benefit; the 17 and 18 incompatibility lists contain nothing a Rails app with the default extensions hits. |
| RDS backups | Set `backup_retention_period = 7` (new module variable) **before** the major upgrade, and take a manual snapshot in each env as the explicit rollback point | Both instances have retention 0 and `skip_final_snapshot = true`, so today RDS would take **no** pre-upgrade snapshot and `terraform destroy` would take none either. This is a pre-existing gap the upgrade should close first. |
| RDS minor pin style | Keep the full `major.minor` pin in tfvars; do not switch to a `"18"` prefix | Matches every previous bump PR and keeps the change visible in git. The cost is a drift plan if `auto_minor_version_upgrade` ever fires; the fix is a one-line bump PR. |
| external-dns | 1.23.0 with an explicit `policy = upsert-only`, rolled out alone with a `--dry-run` check first | `policy` lost its default in chart 1.22.0 and the AWS provider moved A ALIAS ownership to the `a-` TXT prefix in 0.22.0. After the October TXT-prefix incident, this is the one add-on bump that gets its own staging soak and ownership drift test. |
| metrics-server | 3.14.0, namespace left as is | The release has no `namespace` argument and therefore lives in `default`. Moving it to `kube-system` is a delete-and-recreate; not worth coupling to a version bump. Nothing in this repo consumes the Metrics API (no HPA), so the risk is confined to `kubectl top`. |
| Shared-module blast radius | Every module bump merges into all three env configs at once; staging applies automatically, production's queued plan is discarded and re-run fresh | Same rule as #324. The env addons workspaces all trigger on `terraform/modules/aws/cluster-addons-layer`. |

## Phases

### Phase 0: baseline (staging and production)

No PR. Capture before touching anything, and keep the output in `tmp/` for the PR bodies.

```bash
cd ../automation-calculator && ./go smoke staging && ./go smoke prod   # expect 49 pass / 0 fail / 2 pending
export AWS_PROFILE=ac-ci-staging-ro
aws eks describe-cluster --region us-west-1 --name ac_app_staging --query 'cluster.[version,platformVersion,upgradePolicy.supportType]'
aws eks describe-nodegroup --region us-west-1 --cluster-name ac_app_staging --nodegroup-name "$(aws eks list-nodegroups --region us-west-1 --cluster-name ac_app_staging --query 'nodegroups[0]' --output text)" --query 'nodegroup.[version,releaseVersion]'
aws rds describe-db-instances --region us-west-1 --query 'DBInstances[].[DBInstanceIdentifier,EngineVersion,BackupRetentionPeriod,PendingModifiedValues]'
kubectl --context "$STG" -n kube-system get deploy -o wide                  # coredns, external-dns, aws-load-balancer-controller images
kubectl --context "$STG" -n kube-system get ds kube-proxy aws-node -o wide
kubectl --context "$STG" -n default get deploy metrics-server -o wide       # v0.6.2
kubectl --context "$STG" top nodes                                          # proves the Metrics API works before the bump
helm --kube-context "$STG" -n kube-system history external-dns
helm --kube-context "$STG" -n default history metrics-server
```

Repeat for production with `AWS_PROFILE=ac-ci-prod-ro` and `$PRD`.

### Phase 1: Terraform runtime and CI tooling (one PR, all envs)

Files: `terraform/env/<env>/tf_cloud/terraform.tfvars` (`tfe_workspace_tf_version = "1.17"`),
`.circleci/config.yml` (`hashicorp/terraform:1.17.0`, `install-helm-client` `version: 'v4.3.1'`),
`version_dates/terraform_version_dates.json` (add 1.16 and 1.17, mark 1.17 as the TFC/CI version).

- The `tfe_workspace_tf_version` change applies through each env's `tf_cloud` workspace (apply
  order step 1). It sets `terraform_version` on all three per-env workspaces. The next run of each
  workspace then uses 1.17.0; the state file version does not change.
- CI: the PR's own CircleCI run is the test. `helm lint --strict` under 4.3.1 must stay green. If
  it reports something the chart cannot reasonably fix, pin `v3.22.1` instead and note why.
- Also bump the orbs (`circleci/terraform`, `circleci/helm`) to their current majors in the same
  PR if the pipeline still resolves; otherwise leave them.
- Rollback: revert the PR. TFC workspaces can be set back to 1.11 because 1.12 to 1.17 do not
  change the state format.

### Phase 2: providers and modules (three PRs, all envs)

**2a: aws 6.70.0, tfe 0.82.0, EKS module 21.29.0, IAM module 6.8.2, lock-file refresh.**

- `terraform/modules/aws/base-cluster-layer/main.tf`: EKS module `version = "21.29.0"`, drop the
  "pinned until aws >= 6.52" comment.
- `terraform/modules/aws/cluster-addons-layer/main.tf`: IRSA module `~> 6.8`.
- `terraform/modules/tf_cloud/tf_cloud_workspaces/versions.tf` and the three
  `terraform/env/<env>/tf_cloud/versions.tf`: tfe `~> 0.82`.
- Regenerate every lock file: `terraform init -upgrade` in each module directory,
  `terraform init -upgrade -backend=false` in each env directory (needs `TFE_TOKEN` only for the
  normal init, see CLAUDE.md). Commit all lock files. Keep `registry.terraform.io` sources; the three
  `tf_cloud` env lock files currently point at `registry.opentofu.org` and should be regenerated so
  they match the module.
- `version_dates/aws_provider_version_dates.json` and `tfe_provider_version_dates.json`: add the
  new versions.
- Expected plan per workspace: **no resource changes**. The EKS module adds optional inputs only.
  The IAM module 6.8.1 change splits the ALB controller AGA policy into its own managed policy; if
  the IRSA plan shows a new `aws_iam_policy` attached to the existing role, that is expected and
  additive. Anything that proposes to replace the node group or the cluster is a stop.
- Rollout: merge, watch the staging base and addons runs apply (the base workspace must apply before
  the addons workspace because of the run trigger), discard the queued production runs, start
  fresh production runs and confirm them the same day so the EKS token in the plan does not expire.

**2b: kubernetes provider 3.4.0.** `~> 3.4` in `cluster-addons-layer/versions.tf` and the env
configs; lock refresh. Plan should be empty apart from a possible one-time state refresh of the
four `_v1` resources. Once applied or refreshed, rollback to 2.x requires restoring state from a
TFC state version, so run the local speculative plan first.

**2c: helm provider 3.3.0.** `~> 3.3` in `cluster-addons-layer/versions.tf`,
`main_rails_app/versions.tf` and the env configs; rewrite:

```hcl
# before (2.x)                             # after (3.x)
provider "helm" {                          provider "helm" {
  kubernetes {                               kubernetes = {
    host = ...                                 host = ...
  }                                          }
}                                          }

set {                                      set = [
  name  = "provider.name"                    { name = "provider.name", value = "aws" },
  value = "aws"                              ...
}                                          ]
```

The `dynamic "set"` block for `txtPrefix` becomes a `concat()` of the static list and a
conditional one-element list. Six `set_sensitive` blocks in `main_rails_app` become one
`set_sensitive = [...]` list. Plan must be empty in every workspace; a non-empty plan means a value
was dropped in the rewrite. Rollback before apply is a revert; after apply, 3.x has rewritten the
state schema and going back needs a TFC state restore.

### Phase 3: add-on charts (two PRs, all envs)

**3a: metrics-server 3.8.3 to 3.14.0.** One-line version change. The 3.9 to 3.14 changelog is
additive (addon-resizer option, PodSecurity labels, default resource requests of 100m/200Mi,
PDB option, `hostUsers`, cert-manager hooks). The 3.14.0 ClusterRole is renamed from
`metrics-server.name` to `metrics-server.fullname`, which with the default release name renders the
same string. App 0.9.0 requires Kubernetes 1.34+, satisfied. Validate with `kubectl top nodes` and
`kubectl get apiservice v1beta1.metrics.k8s.io` showing `Available=True`. Rollback:
`helm -n default rollback metrics-server <previous revision>` and revert.

**3b: external-dns 1.21.1 to 1.23.0.** Changes in `cluster-addons-layer/main.tf`: version, plus a
new `policy = "upsert-only"` entry (required from 1.22.0; the comment that says the chart default is
`upsert-only` is no longer true). Audit, chart 1.22.0 and 1.23.0 / app 0.22.0 and 0.23.0:

| Change | Affects us? |
|---|---|
| `policy` has no default and is required | Yes. Set `upsert-only` explicitly, matching today's effective value. Anything else risks deletes. |
| Default annotation prefix is now `external-dns.kubernetes.io/`, no fallback | No. The app chart sets no external-dns annotations; hostnames come from Ingress rules. |
| AWS A ALIAS ownership TXT uses the `a-` prefix instead of `cname-` | **Yes.** Our prefix is `%{record_type}-extdns.`, so today's owner records are `cname-extdns.<host>` and `aaaa-extdns.<host>`. 0.22.0 still reads the `cname-` record, UPSERTs a new `a-extdns.<host>` TXT on the first sync, and leaves the old one with a warning. Ownership is preserved. The old records are removed later with the upstream `scripts/aws-cleanup-legacy-txt-records.py --alias-cname-cleanup`, which only deletes a `cname-` record whose `a-` twin exists. |
| TXT registry deletes by stored value (0.23.0) | Behavioral; no config. |
| `crd` registry namespace flag (0.23.0) | No. We use the `txt` registry. |
| Removed providers (Gandi, Akamai, Plural, Transip), Pi-hole v5, Gateway/Ambassador API moves | No. |
| `replicaCount` and `service.enabled` values added | Defaults (1, true) match today. |

Rollout, staging first:
1. Render locally and diff: `helm template` 1.21.1 vs 1.23.0 with our values, confirm the only
   pod-spec differences are the image tag and the explicit `--policy=upsert-only`.
2. Before merging, run the new controller in dry-run mode against staging: `helm upgrade` the
   staging release to 1.23.0 by hand with the existing values plus `--set dryRun=true` (a
   `helm template --dry-run` is not enough; what matters is the controller's own change log). The
   log must show only the `a-extdns.*` TXT UPSERTs and no DELETE or apex A UPSERT. The apex-loop
   symptom from the October incident (`cname-automation-calculations.io` falling outside the zone)
   must not reappear. Roll the manual release back to revision N before merging so Terraform's
   apply is the real upgrade.
3. Merge; staging auto-applies. Discard the queued production run.
4. Validate: `kubectl -n kube-system logs deploy/external-dns --since=15m` shows one sync with the
   `a-extdns` UPSERTs and then `All records are already up to date`; `aws route53
   list-resource-record-sets` shows both `cname-extdns.*` and `a-extdns.*` TXT records with the
   same owner value; rerun the ownership drift test from
   `docs/external-dns-txt-prefix-migration.md`; `./go smoke staging`.
5. Soak at least two days (the apex loop in October took a sync cycle to show up, but the
   orphan-cleanup bug in 0.22 was only visible on records that lost their A twin).
6. Production: fresh TFC run, same validation, `./go smoke prod`.
7. After both envs are clean for a week, delete the legacy `cname-extdns.*` TXT records for alias
   A names in a separate PR using the upstream cleanup script with `--dry-run` first, and record
   the inverse batch in `tmp/` as was done for the prefix migration.

Rollback: `helm -n kube-system rollback external-dns <revision>` restores 0.21, which still owns
through the `cname-extdns` records (they are never deleted by 0.22/0.23), so no DNS is lost.

### Phase 4: EKS 1.37 (staging PR, then production PR)

One-line tfvars change per env plus the `version_dates/eks_version_dates.json` entry
(1.37: GA 2026-10-01, standard support ends 2027-12-01, extended support ends 2028-12-01). Dev's
tfvars move from 1.29 to 1.37 in the staging PR so the file is not left at a version EKS no longer
offers.

Audit of the EKS 1.37 release notes against this repo:

| 1.37 change | Impact here |
|---|---|
| `SELinuxMount` on by default: pods sharing a volume with different SELinux labels stay in `ContainerCreating` | None expected. No `seLinuxOptions` or shared volumes in the chart, and this repo installs no CSI driver; confirm with `kubectl get csidriver` in Phase 0. AL2023 nodes do not run SELinux enforcing. |
| EKS Auto Mode NodePool `consolidationPolicy` default | Not Auto Mode. |
| DRA device taints GA, HPA configurable tolerance GA, HPA scale-to-zero beta | No DRA, no HPA. |
| kubelet refuses deprecated cAdvisor flags; `container_cpu_load_average_10s` and `container_tasks_state` metrics removed; `eventRecordQPS: 0` now unlimited | EKS-optimized AMI with no custom kubelet args (`use_custom_launch_template = false`). CloudWatch alarms in cluster-addons-layer use ALB metrics, not cAdvisor. |
| kubelet logs its full config at startup | Node logs readable only through the SSO roles. |
| Metrics API | metrics-server 0.9.0 from Phase 3a is built against the 1.36 client libraries; 0.6.2 is from 2022 and three majors behind the compatibility matrix. Do Phase 3a first. |

Add-on compatibility: ALB controller 3.6.1 (needs 1.22+), external-dns 0.23 and metrics-server
0.9.0 are all current. The three default add-ons are not EKS-managed add-ons here, so after each
control-plane upgrade update them by hand to the versions the EKS docs recommend for 1.37
(vpc-cni, CoreDNS, kube-proxy), the same step the 1.36 PRs recorded. Consider registering them
as EKS add-ons in a follow-up so Terraform can version them.

Rollout per env: apply `base-cluster-layer`; the control plane upgrades in place (needs five free
IPs in the cluster subnets), then the managed node group rolls onto the 1.37 AL2023 AMI
(`maxUnavailablePercentage: 33` on a one-node group means the node is replaced, so expect a few
minutes of app downtime on the single `t3.medium`; schedule accordingly). Then update the default
add-ons, `kubectl get nodes` shows 1.37, `./go smoke <env>`. EKS now allows a rollback to 1.36
within 7 days of the upgrade, so the "one-way" note from the 1.36 PRs no longer applies; outside
that window it is one-way.

### Phase 5: RDS 16.13 to 18.6 (backup PR, then staging PR, then production PR)

**5a: backups first (all envs).** Add `backup_retention_period` (default 7) to
`main_rails_app` and set it; optionally `skip_final_snapshot = false` with a
`final_snapshot_identifier`. This is a modify with no downtime. Once retention is non-zero RDS
takes its own before/after snapshots during a major upgrade.

**5b: staging, then 5c: production.** `db_engine_version = "18.6"` in the env's
cluster-addons-layer tfvars; `version_dates/rds_postgres_version_dates.json` already lists 18.

Pre-upgrade checks (run through `scripts/launch_psql_pod.sh`):

```sql
SELECT count(*) FROM pg_catalog.pg_prepared_xacts;                       -- 0
SELECT * FROM pg_replication_slots WHERE slot_type <> 'physical';         -- none
SELECT datname FROM pg_database WHERE datconnlimit = -2;                  -- none
SELECT extname, extversion FROM pg_extension;                             -- expect plpgsql only
SELECT count(*) FROM pg_largeobject_metadata;                             -- small
```

Incompatibility audit, PostgreSQL 17 and 18 release notes against a Rails app on the default
parameter group:

| Change | Affects us? |
|---|---|
| 18: data checksums default on for `initdb` | RDS instances already have checksums; `pg_upgrade` in RDS handles it. |
| 18: MD5 passwords deprecated (warning only) | The production instance dates from 2023 and its master password may still be MD5-hashed. Check with `SELECT rolpassword LIKE 'SCRAM%' FROM pg_authid WHERE rolname = current_user`; if false, `terraform apply -replace` of the `random_password` (or a manual `ALTER ROLE ... PASSWORD`) re-hashes it under `scram-sha-256` before the upgrade. Warning only on 18 either way. |
| 18: `VACUUM`/`ANALYZE` recurse into inheritance children by default | No inheritance/partitioned tables. |
| 18: `COPY ... CSV` no longer treats `\.` as EOF; trigger role timing; FTS collation provider | No `COPY` in app code, no triggers, no full-text indexes (verify against `schema.rb`). |
| 18: virtual generated columns are the new default | No generated columns in the schema (verify). |
| 17: safe `search_path` for maintenance; `ago` placement in intervals; `SET SESSION AUTHORIZATION` | No expression-index functions, no interval literals, no role switching. |
| 17: catalog/stat view renames (`pg_stat_statements`, `pg_stat_bgwriter`, collation columns) | Nothing in this repo queries them. |
| RDS: `plrust` removed in 18, `postgis_topology` unavailable on 18.1/18.2 | Neither installed. |
| RDS: instance class support | `db.t4g.micro` is orderable for postgres 18.6 in us-west-1 (checked). |
| App: `pg` gem / ActiveRecord adapter | Check the `pg` gem and Rails versions in the app repo's Gemfile.lock against their PostgreSQL 18 support notes, and run the app's test suite against a local 18 image before the staging bump. |

Rollout per env:
1. Manual snapshot with a name that records the version, wait for `available`.
2. Merge the tfvars PR. `allow_major_version_upgrade = true` and `apply_immediately = true` are
   already set, so the TFC apply starts the upgrade at once. The parameter group moves to
   `default.postgres18` automatically. Budget 15 to 30 minutes of database downtime on a micro
   instance (measure it on staging and record the number in the production PR); the app's
   `/health` will fail during it, so do staging first and production in a quiet window.
3. After `available`: `ANALYZE VERBOSE;` in the app database (RDS does not carry statistics over),
   check `pg_upgrade_precheck.log` / `pg_upgrade_internal.log` in the RDS log viewer, then
   `./go smoke <env>`.
4. Soak staging for at least a week of app deploys before production.

Rollback: none in place. Restore the manual snapshot as a new instance and repoint
`db_subnet_group`/security group by importing it, or accept the upgraded instance. This is why the
snapshot and the app-test-suite gate come first.

### Phase 6: housekeeping (one PR)

- CLAUDE.md provider table (Helm `~> 3.3`, Kubernetes `~> 3.4`, TFE `~> 0.82`) and the
  lock-file note.
- `version_dates/*.json` entries that earlier phases did not already add.
- Drop the stale comments: EKS module pin reason, external-dns "chart defaults" comment.

## Risks and mitigations

- **Stale TFC plans for production** (helm and kubernetes resources embed a 15-minute EKS token at
  plan time). Mitigation: every production apply is a fresh run confirmed immediately; queued runs
  from merges are discarded.
- **Helm state-on-failure**: a failed `helm_release` apply can leave TFC state ahead of the cluster.
  Mitigation: after every addons apply, compare `helm history` with the TFC plan, as #324 did.
- **external-dns ownership**: the `a-` prefix migration is the one change in this plan that rewrites
  Route 53 ownership records. Mitigation: dry run, staging soak, drift test, legacy records kept
  until a separate cleanup PR, documented inverse batch.
- **Provider 3.x state schema**: Helm 3.x and Kubernetes 3.x upgrade state on first plan/refresh;
  going back needs a TFC state restore. Mitigation: local speculative plans before merge; one
  provider per PR so a restore is small.
- **Single node, single AZ database**: both the node AMI roll in Phase 4 and the RDS upgrade in
  Phase 5 take the app down for minutes. Mitigation: staging first, announce the production window,
  smoke immediately after.
- **No RDS backups today**: Phase 5a closes it before the irreversible step. Do not reorder.
- **Shared modules apply everywhere**: a module bump cannot be staged by env. Mitigation: the
  env-level pins (tfvars) are per env; the module-level changes are the ones proven to produce an
  empty plan before merge.

## Verification checklist (per env, after each phase)

```bash
./go smoke <env>                                                    # from ../automation-calculator, 49/0/2
kubectl --context "$CTX" get nodes -o wide                          # version matches control plane
kubectl --context "$CTX" -n kube-system get deploy,ds -o wide       # images at the expected tags
kubectl --context "$CTX" top nodes                                  # Metrics API serving
kubectl --context "$CTX" -n kube-system logs deploy/external-dns --since=15m | grep -ci 'error'   # 0
helm --kube-context "$CTX" list -A                                  # every release "deployed", chart versions as pinned
aws rds describe-db-instances --region us-west-1 --query 'DBInstances[].[EngineVersion,BackupRetentionPeriod,DBInstanceStatus]'
curl -fsS https://<host>/health
```

## Follow-ups (not in scope)

- Register vpc-cni, CoreDNS and kube-proxy as EKS managed add-ons in `base-cluster-layer` so the
  post-upgrade manual step goes away.
- Move metrics-server into `kube-system` (delete-and-recreate).
- Decide whether `auto_minor_version_upgrade` should stay on with a full-version pin, or the pin
  should become a major prefix.
- A second node or Multi-AZ RDS if the downtime windows in Phases 4 and 5 stop being acceptable.
- A Renovate or Dependabot config for the lock files and chart versions so this document does not
  need to be rewritten in a year.
