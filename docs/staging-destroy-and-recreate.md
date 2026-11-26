# Destroying staging to save cost, and re-creating it later

Staging is destroyed when nothing needs validating and re-created when it does. The destroy and the
re-create are both run from the Terraform Cloud UI. This document records what has to be true
before the destroy, the steps, what stops working while staging is gone, and how to bring it back.

Written 2026-11-18 from a read of the code, re-checked after the ArgoCD phase 1 and 2 merges. The
steps have not been run yet; correct
this document after the first destroy and the first re-create.

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
3. Check that no RDS snapshot named `automation-calculator-staging-final` exists. Staging has
   `skip_final_snapshot = false`, so the destroy takes a final snapshot with that name and fails if
   the name is taken. Delete the old one, or set `final_snapshot_identifier` in the staging
   add-ons `terraform.tfvars`.

   ```bash
   aws rds describe-db-snapshots --profile ac-ci-staging-ro --region us-west-1 \
     --db-snapshot-identifier automation-calculator-staging-final
   ```

4. Do the AWS checks in the next section's step 2 with the staging profile before destroying the
   base layer. The base layer destroy removes the roles that profile uses.

## Destroy

Order matters: add-ons first, then base. The add-ons config reads the cluster name, VPC and
subnets from the base workspace's outputs and cannot plan once the base is gone.

In each workspace use **Settings > Destruction and Deletion > Queue destroy plan**. Do not use
**Delete workspace**. The workspaces cost nothing, and their variables hold the OAuth secrets and
the AWS credentials needed to re-create staging.

1. `ac_app_staging_cluster_addons_layer`: queue the destroy plan, review it, confirm promptly.
   A run that waits too long between plan and apply can outlive its 15 minute EKS token and fail
   with a Kubernetes credentials error (seen on 2026-11-05 with a queued run). If that happens,
   queue the destroy again.
2. Confirm the app load balancer is gone before touching the base layer. The app's Ingress owns
   the ALB `ac-app-staging`, and the load balancer controller deletes it when the app release is
   uninstalled. If the controller is removed before it finishes, the ALB and its security groups
   are left behind. They keep costing money and block the VPC delete.

   ```bash
   aws elbv2 describe-load-balancers --profile ac-ci-staging-ro --region us-west-1 \
     --query 'LoadBalancers[?LoadBalancerName==`ac-app-staging`].[LoadBalancerArn,State.Code]'
   ```

   An empty list is the expected result. Check too that the RDS instance is gone and the final
   snapshot is `available`.
3. `ac_app_staging_base_cluster_layer`: queue the destroy plan, review it, confirm.
4. If the base destroy queues a run in the add-ons workspace through the run trigger, that run
   fails at plan because the base outputs are gone. Discard or ignore it.

## Since ArgoCD Phase 4: the app namespace blocks the destroy

Phase 4 (`docs/argocd-phase-4-secret-adoption.md`) made the `automation-calculator` namespace a
Terraform resource with `prevent_destroy = true`, because on production deleting it deletes the
Ingress and the ALB. Written from a read of the code, not yet run:

- **Destroy.** The add-ons destroy plan fails with "Instance cannot be destroyed" on
  `module.main_rails_app.kubernetes_namespace_v1.automation_calculator`. Before step 1, take the
  namespace out of the staging state (the object stays on the cluster and goes with the cluster in
  step 3):

  ```bash
  cd terraform/env/staging/aws/us-west-1/cluster-addons-layer
  terraform init
  terraform state rm module.main_rails_app.kubernetes_namespace_v1.automation_calculator
  ```

  The app release is still uninstalled by the destroy, which deletes the Ingress and lets the
  load balancer controller remove the ALB as before. Do not merge anything that queues a staging
  add-ons run between the `state rm` and the destroy: the next plan would try to create the
  namespace again and fail because it exists.
- **Re-create.** Nothing extra. The Phase 4 `import` blocks, which would have failed the plan
  on a cluster without the objects, were deleted once both environments had applied them (Phase 4
  runbook, section 6); Terraform creates the namespace and the Secret itself.

## What is gone, and what stays

Destroyed with the add-ons layer: the app, add-on and ArgoCD Helm releases, the RDS instance and its
automated backups, the ACM certificate and its validation records, the IRSA roles, and the app
log group `/ac/staging/app` with every stored log event (`docs/app-logs.md`). A re-created
staging starts with an empty group; nothing needs to be saved unless staging's log history
matters to you.

Destroyed with the base layer: the EKS cluster and node group, the VPC, subnets, NAT gateway and
its Elastic IP, the `ac_ci_terraform_staging` and `ac_ci_terraform_staging_read_only` roles, and
the `InfraEngStaging` and `InfraEngStagingReadOnly` SSO permission sets and assignments.

Left behind:

- The final RDS snapshot `automation-calculator-staging-final`.
- The `staging.automation-calculations.io` records and their external-dns TXT ownership records
  in Route 53. external-dns runs with `policy = upsert-only` and never deletes records. They point
  at a deleted ALB until staging is re-created, when external-dns updates them.
- The two Terraform Cloud workspaces and their variables.

## While staging is destroyed

- The `ac-ci-staging` and `ac-ci-staging-ro` AWS profiles and the staging kube contexts do not
  work. Anything that used the staging profile for account-level reads needs the production
  profile.
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

1. To bring the old data back, set `db_snapshot_identifier` in
   `terraform/env/staging/aws/us-west-1/cluster-addons-layer/terraform.tfvars` to the final
   snapshot's name and merge that first. Skip this step for an empty database. Details are in
   "Saving and restoring the database" below.

   ```hcl
   db_snapshot_identifier = "automation-calculator-staging-final"
   ```

2. `ac_app_staging_base_cluster_layer`: discard any waiting runs, start a new run, confirm the
   apply.
3. The run trigger queues `ac_app_staging_cluster_addons_layer` when the base apply succeeds.
   Check that the plan creates `aws_db_instance.automation_calculator_app` with the expected
   `snapshot_identifier`, then confirm it promptly, for the same token reason as above. If no run
   was queued, start one.
4. Refresh local access: `./go infra-eng-sso`, then check `/health` on
   `staging.automation-calculations.io`.

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
exposes it; development and production do not. Not yet exercised: the first staging re-create is
its first use.

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
  aws rds describe-db-snapshots --profile ac-ci-production --region us-west-1 \
    --db-snapshot-identifier automation-calculator-staging-final \
    --query 'DBSnapshots[].[DBSnapshotIdentifier,AllocatedStorage,EngineVersion,Status]'
  ```

  The staging profiles are gone at that point, so this uses the production profile, which reads
  the same account.
- The snapshot is PostgreSQL 16.13. Keep `db_engine_version` at or above that when restoring. I
  have not checked whether a restore can cross a major version in one step; if staging is still
  down when the PostgreSQL 18 upgrade lands, restore on 16 first and upgrade after.

Final snapshot names collide on the second cycle: an instance restored from
`automation-calculator-staging-final` cannot write a final snapshot with that same name on the
next destroy. Before destroying staging again, set `final_snapshot_identifier` in the staging
`terraform.tfvars` to a per-cycle name (for example `automation-calculator-staging-final-2027-01`)
and apply it. Delete the older snapshot once the newer one exists.

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
