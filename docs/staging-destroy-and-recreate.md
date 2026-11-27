# Destroying staging to save cost, and re-creating it later

Staging is destroyed when nothing needs validating and re-created when it does. The destroy and the
re-create are both run from the Terraform Cloud UI. This document records what has to be true
before the destroy, the steps, what stops working while staging is gone, and how to bring it back.

Written 2026-11-18 from a read of the code. Corrected after the trial cycle of 2026-11-26 (destroy,
re-create from the final snapshot, destroy again for the long pause), which ran every step below.

## The 2026-11-26 trial cycle

Staging was destroyed, re-created from the final snapshot, verified, and destroyed again. What it
found, each fixed or written into the steps below:

- **The base destroy needs two runs.** The first run errors at the end on the `sso_infra_eng`
  permission sets with `waiting for SSO Permission Set ... provision: unexpected state 'FAILED'
  ... 404 Assignment not found`. Deleting an inline policy re-provisions the permission set to
  accounts whose assignments the same run already deleted. Everything else is gone by then; a
  second destroy run deletes what is left (Destroy, step 5). Seen on both base destroys.
- **A cluster created today had no CNI.** EKS module v21 creates clusters with
  `bootstrap_self_managed_addons = false`, so the re-created node group never became Ready until
  vpc-cni and CoreDNS were added. Fixed in #514: staging registers both as managed add-ons
  (`vpc_cni_addon_version`, `coredns_addon_version`).
- **Terraform had no access to the new cluster.** v21 also gives the identity Terraform runs as no
  access entry, so the first add-ons apply failed with `Unauthorized` on every kubernetes and helm
  resource (its AWS resources, including the RDS restore, applied). Fixed in #514:
  `enable_cluster_creator_admin_permissions = true` for staging. Production's entry was made by
  hand; production needs the same three settings, and an import of that entry, before it is ever
  re-created.
- **The ArgoCD Application comes back with the add-ons layer**, so `./go argocd-app-down-up up`
  only waits for it after a re-create (Re-create, step 4).
- **The snapshot restore works**: a 10 GB, PostgreSQL 18.6 snapshot restored in 10 min 10 s, the
  app connected with the regenerated password, and the row counts were intact.
- **external-dns adopted the existing Route 53 records** within seconds of the new Ingress getting
  its address.

Timings (Terraform Cloud apply times):

| Step | Trial cycle | Long-term destroy |
|---|---|---|
| `argocd-app-down-up down` | 3 min 16 s (tried before the trial) | 54 s |
| Add-ons destroy, including the final snapshot | about 10 min | about 5 min 30 s |
| Base destroy, first run (errors on SSO) | 11 min 35 s | about 13 min |
| Base destroy, second run | 40 s | 46 s |
| Base re-create | 35 min, about 20 of them the node group waiting for a CNI | |
| Add-ons re-create | 10 min 40 s (RDS restore 10 min 10 s), plus a 3 min 30 s retry after the access fix | |
| Application Healthy, ALB active and `/health` 200, after the add-ons apply | about 2 min | |

With #514 in place, expect a re-create to take about 30 minutes of applies plus the confirms.

## Why `auto_apply` is off for staging

`terraform/env/staging/tf_cloud/terraform.tfvars` sets `auto_apply = false`. It was `true` until
the staging destroy was planned, and it has to be `false`, and applied, before staging is
destroyed.

The staging base workspace triggers on its own directory and on
`terraform/modules/aws/networking` and `terraform/modules/aws/base-cluster-layer`. With
auto-apply on, the first merge touching any of those after a destroy would plan a full re-create
of the VPC, NAT gateway and EKS cluster and apply it with nobody confirming. The run trigger would
then queue the add-ons workspace, which would re-create the add-ons, the app and RDS.

With auto-apply off, such a merge leaves a plan waiting for confirmation. Discard it.

The setting lives in code, not only in the workspace UI, because the next apply of
`terraform/env/staging/tf_cloud` would otherwise turn auto-apply back on.

Consequence while staging is up: staging applies need a confirm in the UI, as production applies
already do.

## Before the destroy

1. Confirm the PR that set `auto_apply = false` is merged.
2. Merging it queued a run in the `ac_app_staging_tf_workspaces` workspace, which runs
   `terraform/env/staging/tf_cloud`. The plan should change `auto_apply` on the two staging
   workspaces and nothing else (a trial plan of that change on 2026-11-18 showed "0 to add, 2 to
   change"). Confirm the apply in the UI if that workspace does not auto-apply, then check that
   both staging workspaces show auto-apply off under **Settings > General**. That workspace is not
   defined in this repo, so whether it auto-applies is only visible in the UI.
3. Check that no RDS snapshot has the name in `final_snapshot_identifier` (staging add-ons
   `terraform.tfvars`; `automation-calculator-staging-final-3` for the next destroy). Staging has
   `skip_final_snapshot = false`, so the destroy takes a final snapshot with that name and fails if
   the name is taken. See "Saving and restoring the database" for the names used so far.

   ```bash
   aws rds describe-db-snapshots --profile ac-ci-staging-ro --region us-west-1 \
     --db-snapshot-identifier automation-calculator-staging-final-3
   ```

4. Take the row counts (`./go db-read-only-psql staging --as ci`, counts only) and an
   `./go env-snapshot`, to compare with after the next re-create.
5. Do the AWS checks in the next section's step 3 with the staging profile before destroying the
   base layer. The base layer destroy removes the roles that profile uses.

## Destroy

Order matters: add-ons first, then base. The add-ons config reads the cluster name, VPC and
subnets from the base workspace's outputs and cannot plan once the base is gone.

In each workspace use **Settings > Destruction and Deletion > Queue destroy plan**. Do not use
**Delete workspace**. The workspaces cost nothing, and their variables hold the OAuth secrets and
the AWS credentials needed to re-create staging.

1. Delete the app's objects through ArgoCD, and wait for the ALB to go, before any Terraform
   destroy. Since ArgoCD migration Phase 9 the app has no Helm release, so the add-ons destroy
   uninstalls nothing of the app. The `automation-calculator` Application deliberately carries no
   `resources-finalizer.argocd.argoproj.io` (`terraform/modules/kubernetes/argocd/main.tf`), so
   the destroy deleting the Application leaves the Deployment, Service and Ingress in place. The
   load balancer controller is then removed, and the ALB `ac-app-staging` and its security groups
   stay behind: they keep costing money and block the VPC delete in the base destroy. Deleting
   only the Ingress does not work either, because staging's Application has self-heal on and
   ArgoCD puts it back.

   Use `./go argocd-app-down-up` (`scripts/argocd_app_down_up.py`). It needs the read-write
   staging kube context (`./go infra-eng-sso`), not an ArgoCD login. It adds the resources
   finalizer to the Application and deletes it, which is what `argocd app delete --cascade` does,
   then waits until the Application, the Ingress and the ALB are gone:

   ```bash
   ./go argocd-app-down-up up staging     # dry run: says whether the argocd-apps release
                                          # manifest still matches the live Application
   ./go argocd-app-down-up down staging --apply
   ```

   `down` saves the live Application to `tmp/argocd-app/` first. The file holds the certificate
   ARN, so keep it out of git. To bring the app back without a re-create (an aborted destroy, or
   a test of this step), run `./go argocd-app-down-up up staging --apply`. It re-creates the
   Application from the `argocd-apps` release manifest, with Helm's ownership metadata, and waits
   for Synced/Healthy, the ALB, the Route 53 alias and `/health`. `--from-file` takes a file
   saved by `down` instead.

   Tried on staging 2026-11-26 without a destroy, then used for both destroys of the trial cycle
   (the long-term destroy's `down` took 54 s):
   - **down:** the Ingress was gone in 25 s and the Application in 3 min 16 s (the pods'
     preStop sleep and grace period), and the ALB had already disappeared by then. Staging's
     target group and TargetGroupBinding went with it. The Terraform-managed namespace and app
     Secret stayed.
   - **up:** the Application was Synced/Healthy in 24 s and the new ALB was active about 2 min
     later. external-dns repointed the Route 53 aliases within seconds of the Ingress getting its
     address, and `/health` through the ALB answered 200.
   - **DNS caching:** a resolver that looked the host up while the ALB was gone can keep the
     negative answer for longer. This Mac's resolver still failed to resolve staging 13 minutes
     after Route 53 had been updated, while the ISP's resolvers already answered correctly.
     Allow for that before deciding the app is down.

   The add-ons destroy then uninstalls the `argocd-apps` release, which no longer finds the
   Application; both destroys of 2026-11-26 did that without an error.
2. Take the app namespace out of the add-ons state (next section), then in
   `ac_app_staging_cluster_addons_layer` queue the destroy plan, review it, confirm promptly. The
   plan deletes everything (44 resources on 2026-11-26) and nothing else; check that
   `aws_db_instance.automation_calculator_app` is deleted with `skip_final_snapshot = false` and
   the expected `final_snapshot_identifier`.
   A run that waits too long between plan and apply can outlive its 15 minute EKS token and fail
   with a Kubernetes credentials error (seen on 2026-11-05 with a queued run). If that happens,
   queue the destroy again.
3. Confirm the app load balancer is gone before touching the base layer:

   ```bash
   aws elbv2 describe-load-balancers --profile ac-ci-staging-ro --region us-west-1 \
     --query 'LoadBalancers[?LoadBalancerName==`ac-app-staging`].[LoadBalancerArn,State.Code]'
   ```

   An empty list is the expected result. Check too that the RDS instance is gone and the final
   snapshot is `available`.
4. `ac_app_staging_base_cluster_layer`: queue the destroy plan, review it, confirm. The plan
   deletes everything (65 resources on 2026-11-26).
5. The first base destroy run errors at the end on the SSO permission sets (see "The 2026-11-26
   trial cycle"), leaving one or two permission sets and their inline policies in the state.
   Queue the destroy plan again; the second run deletes them in under a minute and leaves the
   state empty.
6. If the base destroy queues a run in the add-ons workspace through the run trigger, that run
   fails at plan because the base outputs are gone (seen 2026-11-26). Discard or ignore it.
7. Check that nothing of staging is left, with the production read-only profile (the staging
   profiles are gone): no `ac_app_staging` EKS cluster, no VPC tagged `Environment=staging`, no
   NAT gateway or Elastic IP of it, no IAM role with `staging` in its name.

   ```bash
   aws eks list-clusters --profile ac-ci-prod-ro --region us-west-1
   aws ec2 describe-vpcs --profile ac-ci-prod-ro --region us-west-1 \
     --filters Name=tag:Environment,Values=staging --query 'Vpcs[].VpcId'
   aws iam list-roles --profile ac-ci-prod-ro \
     --query 'Roles[?contains(RoleName,`staging`)].RoleName'
   ```

## Since ArgoCD Phase 4: the app namespace blocks the destroy

Phase 4 (`docs/argocd-phase-4-secret-adoption.md`) made the `automation-calculator` namespace a
Terraform resource with `prevent_destroy = true`, because on production deleting it deletes the
Ingress and the ALB. Done on both destroys of 2026-11-26:

- **Destroy.** The add-ons destroy plan fails with "Instance cannot be destroyed" on
  `module.main_rails_app.kubernetes_namespace_v1.automation_calculator`. Before step 2, take the
  namespace out of the staging state (the object stays on the cluster and goes with the cluster in
  step 4):

  ```bash
  cd terraform/env/staging/aws/us-west-1/cluster-addons-layer
  terraform init
  terraform state rm module.main_rails_app.kubernetes_namespace_v1.automation_calculator
  ```

  The add-ons directory's backend names the real workspace. The base directory's does not: its
  `versions.tf` names `ac_app_base_cluster_layer_staging`, an old workspace, while Terraform Cloud
  runs `ac_app_staging_base_cluster_layer`, so a local `terraform state` command in the base
  directory sees an empty state. Read the base state through the Terraform Cloud UI or API.

  The Ingress and the ALB are handled by the ArgoCD cascade delete in step 1, not by the
  destroy. Do not merge anything that queues a staging
  add-ons run between the `state rm` and the destroy: the next plan would try to create the
  namespace again and fail because it exists.
- **Re-create.** Nothing extra. The Phase 4 `import` blocks, which would have failed the plan
  on a cluster without the objects, were deleted once both environments had applied them (Phase 4
  runbook, section 6); Terraform creates the namespace and the Secret itself. Keep it that way:
  an `import` block in a staging config fails the plan on a re-created cluster, which is why #515
  deleted the one-time add-on imports of #514.

## What is gone, and what stays

Deleted by the ArgoCD cascade delete: the app's Deployment, Service, Ingress and ALB.

Destroyed with the add-ons layer: the add-on and ArgoCD Helm releases, the app's namespace Secret,
the RDS instance and its
automated backups, the ACM certificate and its validation records, the IRSA roles, and the app
log group `/ac/staging/app` with every stored log event (`docs/app-logs.md`). A re-created
staging starts with an empty group; nothing needs to be saved unless staging's log history
matters to you.

Destroyed with the base layer: the EKS cluster, its node group, managed add-ons and KMS key alias,
the VPC, subnets, NAT gateway and its Elastic IP, the `ac_ci_terraform_staging` and
`ac_ci_terraform_staging_read_only` roles, and the `InfraEngStaging` and `InfraEngStagingReadOnly`
SSO permission sets and assignments.

Left behind:

- The final RDS snapshot (the name in `final_snapshot_identifier` at the destroy).
- The `staging.automation-calculations.io` records and their external-dns TXT ownership records
  in Route 53. external-dns runs with `policy = upsert-only` and never deletes records. They point
  at a deleted ALB until staging is re-created, when external-dns updates them.
- The two Terraform Cloud workspaces and their variables.

## While staging is destroyed

- The `ac-ci-staging` and `ac-ci-staging-ro` AWS profiles and the staging kube contexts do not
  work: the base layer created the roles they assume. Anything that used the staging profile for
  account-level reads needs `ac-ci-prod-ro`, which reads the same account.
- Every pull request touching the staging add-ons paths gets a failed
  `ac_app_staging_cluster_addons_layer` plan status. Terraform Cloud statuses are not required
  checks on `main`, so merges are not blocked. App image bumps are not affected: since ArgoCD
  migration Phase 9 the chart and its values files trigger no workspace. Keep bumping staging so
  its values file is current when it comes back.
- Pull requests touching the base paths get a staging plan that adds everything. After merge the
  same plan waits for confirmation in the workspace. Discard it.
- The `deploy-image` and `validate-infra-rollout` skills have no staging step to run. Changes go
  to production without a staging pass, or wait for staging to be re-created.

## Re-create

1. Check the staging add-ons `terraform.tfvars` in
   `terraform/env/staging/aws/us-west-1/cluster-addons-layer/`:
   - `db_snapshot_identifier` names the newest final snapshot, to bring the data back (null for an
     empty database). Details are in "Saving and restoring the database" below.
   - `final_snapshot_identifier` is a name no snapshot has yet, for the next destroy.

   Merge any change first. Since the long-term destroy of 2026-11-26 the file holds
   `db_snapshot_identifier = "automation-calculator-staging-final-2"` and
   `final_snapshot_identifier = "automation-calculator-staging-final-3"`.
2. `ac_app_staging_base_cluster_layer`: discard any waiting runs, start a new run, confirm the
   apply. The plan creates everything, including the vpc-cni, CoreDNS and kube-proxy add-ons and
   the `cluster_creator` access entry (#514). If the node group sits at "Still creating" for more
   than 10 minutes, check `aws eks list-addons --cluster-name ac_app_staging` for vpc-cni.
3. The run trigger queues `ac_app_staging_cluster_addons_layer` when the base apply succeeds.
   Check that the plan creates `aws_db_instance.automation_calculator_app` with the expected
   `snapshot_identifier`, then confirm it promptly, for the same token reason as above. If no run
   was queued, start one. An apply that fails with `Unauthorized` on the kubernetes and helm
   resources means the access entry is missing: its AWS resources stay applied, and the next run
   after the fix creates only what is missing.
4. Refresh local access: `./go infra-eng-sso`, then
   `aws eks update-kubeconfig --name ac_app_staging --profile ac-ci-staging` (the cluster has a new
   endpoint and CA). The add-ons apply re-creates the ArgoCD Application, so
   `./go argocd-app-down-up up staging --apply` finds it in place and only waits for
   Synced/Healthy, the ALB, the Route 53 alias and `/health`. A local resolver may still hold the
   negative answer from while staging was gone; the script checks `/health` through the ALB.
5. Take an after-snapshot with `./go env-snapshot`, diff it against the one taken before the
   destroy, and compare row counts with `./go db-read-only-psql staging --as ci` (counts only).
   Take the counts before the destroy too, or there is nothing to compare with.

Notes for the re-create:

- The database password and the Rails `secret_key_base` are regenerated, so existing sessions are
  invalid.
- external-dns in staging uses the TXT prefix from `terraform.tfvars`, and the prefixed ownership
  records are still in Route 53, so it should adopt the existing records. If DNS does not update,
  read `docs/external-dns-txt-prefix-migration.md` before changing anything.
- Staging does not enable the CloudWatch alarms (`cloudwatch_alarms_enabled` defaults to false and
  only production sets it), so there is no alarm bootstrap step.
- If staging should apply on merge again while it is up, set `auto_apply = true` in the staging
  `tf_cloud` tfvars. Set it back to `false` before the next destroy.

## Saving and restoring the database

Saving: the destroy takes the final snapshot, because staging has `skip_final_snapshot = false`.

Restoring: `main_rails_app` has a `db_snapshot_identifier` variable (default `null`), passed to
`snapshot_identifier` on `aws_db_instance.automation_calculator_app`. The staging add-ons config
exposes it; development and production do not. Used on 2026-11-26: a 10 GB snapshot restored in
10 min 10 s, the app connected, and the data was intact.

How it behaves, checked against the AWS provider source (`internal/service/rds/instance.go`,
`main` on 2026-11-18):

- The value is read only when the instance is created. `snapshot_identifier` forces replacement
  when it changes, so the resource has `lifecycle { ignore_changes = [snapshot_identifier] }`:
  setting, editing or clearing the variable on a running database plans no change. Leaving the
  value in `terraform.tfvars` after the restore is harmless, but clear it once it is stale so the
  next re-create does not restore an old snapshot by accident.
- The restored instance keeps the snapshot's master username and database name, which match the
  config. After the restore the provider modifies the instance to the configured values,
  including the newly generated password. The app's `DATABASE_URL` is built from that password,
  so the app connects without further work.
- That modify also sets `allocated_storage` to the configured 10 GB. If storage autoscaling grew
  the instance past 10 GB before the destroy, the modify fails because RDS cannot shrink storage.
  Check the snapshot's size before the re-create and raise `allocated_storage` in the module if
  it is larger.

  ```bash
  aws rds describe-db-snapshots --profile ac-ci-prod-ro --region us-west-1 \
    --db-snapshot-identifier automation-calculator-staging-final-2 \
    --query 'DBSnapshots[].[DBSnapshotIdentifier,AllocatedStorage,EngineVersion,Status]'
  ```

  The staging profiles are gone at that point, so this uses the production profile, which reads
  the same account.
- Staging has been on PostgreSQL 18.6 since #363 (2026-11-26), so its final snapshot will be
  18.6, matching `db_engine_version = "18.6"` in the staging add-ons `terraform.tfvars`. Keep
  `db_engine_version` at or above the snapshot's `EngineVersion` (the query above shows it) when
  restoring.

Final snapshot names collide: a destroy fails if a snapshot with its `final_snapshot_identifier`
already exists. Give every cycle its own name in the staging `terraform.tfvars` before the
re-create that precedes the destroy (the value is read only at destroy time, so it plans no
change). The cycles so far:

| Snapshot | Taken by | Restored by |
|---|---|---|
| `automation-calculator-staging-final` | trial destroy, 2026-11-26 18:40 UTC | the trial re-create |
| `automation-calculator-staging-final-2` | long-term destroy, 2026-11-27 02:03 UTC | the next re-create |
| `automation-calculator-staging-final-3` | the next destroy | |

Delete an older snapshot once a newer one exists and has been restored or checked.

Cost of keeping the snapshot: manual and final snapshots are billed per GB-month of used storage
and kept until deleted. The instance has 10 GB allocated, so this is small. I have not looked up
the us-west-1 rate.

### Alternatives

#### Logical dump and restore

Before the destroy, `pg_dump` the database from a pod (`./go launch-psql-pod`) and keep the
file. After the re-create, load it with `pg_restore` into the new, empty instance.

- No Terraform change, and it works across PostgreSQL major versions.
- It is manual on both sides, the dump has to be stored somewhere outside the cluster, and it
  must be taken before the add-ons destroy, while the cluster and database still exist.
- The final snapshot is still taken, so it remains as a fallback.

#### Start empty

Re-create with an empty database and let the app set up its schema. No work now. I did not find a
migration step in the Helm chart, so check how the schema gets created on a fresh database before
relying on this.

#### Not suitable

- Retained automated backups (`delete_automated_backups = false`) with a point-in-time restore:
  they expire after the 7 day retention period, which is shorter than the pause.
- Stopping the instance in place of destroying it: RDS starts a stopped instance again after 7
  days, storage is still billed, and it cannot outlive the VPC, which the base destroy removes.
