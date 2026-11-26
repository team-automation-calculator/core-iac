# Destroying staging to save cost, and re-creating it later

Staging is destroyed when nothing needs validating and re-created when it does. The destroy and the
re-create are both run from the Terraform Cloud UI. This document records what has to be true
before the destroy, the steps, what stops working while staging is gone, and how to bring it back.

Written 2026-11-18 from a read of the code, re-checked after the ArgoCD phase 1 and 2 merges. The
steps have not been run yet; correct
this document after the first destroy and the first re-create.

## Do a trial cycle first

Because none of this has been run, the first destroy should be followed straight away by a
re-create, and only a staging that came back correctly is destroyed for the long pause. The trial
costs an hour or two of staging downtime and little AWS spend, and it exercises what can only be
learned by running it:

- the app Ingress and ALB clean-up before the add-ons destroy (see "Destroy", step 1)
- whether the `terraform state rm` of the namespace is enough to get past `prevent_destroy`
- the snapshot restore (storage size, regenerated password, the app connecting afterwards)
- external-dns adopting the existing Route 53 records again
- the base layer bringing back the SSO permission sets and CI roles, so `./go infra-eng-sso` and
  the `-ro` kube contexts work again
- how long each step takes, which is the real cost of bringing staging back

Suggested order:

1. Merge and apply the `auto_apply = false` change (below).
2. Take a baseline with `./go env-snapshot` under `--context ac_app_staging-ro`.
3. Destroy, then re-create from the final snapshot.
4. Take a second snapshot, diff it against the baseline, and check `/health`.
5. Correct this document with what actually happened, in a PR.
6. Set a per-cycle `final_snapshot_identifier` (see "Saving and restoring the database": the
   trial's final snapshot holds the default name), then do the long-term destroy.

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

4. Do the AWS checks in the next section's step 3 with the staging profile before destroying the
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

   Tried on staging 2026-11-26 without a destroy:
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
   Application; that is expected, but has not been seen yet.
2. `ac_app_staging_cluster_addons_layer`: queue the destroy plan, review it, confirm promptly.
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
4. `ac_app_staging_base_cluster_layer`: queue the destroy plan, review it, confirm.
5. If the base destroy queues a run in the add-ons workspace through the run trigger, that run
   fails at plan because the base outputs are gone. Discard or ignore it.

## Since ArgoCD Phase 4: the app namespace blocks the destroy

Phase 4 (`docs/argocd-phase-4-secret-adoption.md`) made the `automation-calculator` namespace a
Terraform resource with `prevent_destroy = true`, because on production deleting it deletes the
Ingress and the ALB. Written from a read of the code, not yet run:

- **Destroy.** The add-ons destroy plan fails with "Instance cannot be destroyed" on
  `module.main_rails_app.kubernetes_namespace_v1.automation_calculator`. Before step 2, take the
  namespace out of the staging state (the object stays on the cluster and goes with the cluster in
  step 4):

  ```bash
  cd terraform/env/staging/aws/us-west-1/cluster-addons-layer
  terraform init
  terraform state rm module.main_rails_app.kubernetes_namespace_v1.automation_calculator
  ```

  The Ingress and the ALB are handled by the ArgoCD cascade delete in step 1, not by the
  destroy. Do not merge anything that queues a staging
  add-ons run between the `state rm` and the destroy: the next plan would try to create the
  namespace again and fail because it exists.
- **Re-create.** Nothing extra. The Phase 4 `import` blocks, which would have failed the plan
  on a cluster without the objects, were deleted once both environments had applied them (Phase 4
  runbook, section 6); Terraform creates the namespace and the Secret itself.

## What is gone, and what stays

Deleted by the ArgoCD cascade delete: the app's Deployment, Service, Ingress and ALB.

Destroyed with the add-ons layer: the add-on and ArgoCD Helm releases, the app's namespace Secret,
the RDS instance and its
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
- Staging has been on PostgreSQL 18.6 since #363 (2026-11-26), so its final snapshot will be
  18.6, matching `db_engine_version = "18.6"` in the staging add-ons `terraform.tfvars`. Keep
  `db_engine_version` at or above the snapshot's `EngineVersion` (the query above shows it) when
  restoring.

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
