# Destroying staging to save cost, and re-creating it later

Staging is destroyed when nothing needs validating and re-created when it does. The destroy and the
re-create are both run from the Terraform Cloud UI. This document records what has to be true
before the destroy, the steps, what stops working while staging is gone, and how to bring it back.

Written 2026-11-18 from a read of the code at `9094061`. The steps have not been run yet; correct
this document after the first destroy and the first re-create.

## Why `auto_apply` is off for staging

`terraform/env/staging/tf_cloud/terraform.tfvars` sets `auto_apply = false`. It was `true` until
this plan.

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

1. Merge the PR that sets `auto_apply = false`.
2. Apply `terraform/env/staging/tf_cloud` locally. That config has no remote backend, so it is
   applied from a machine that has its state and the environment variables listed in `AGENTS.md`.
   The plan should change `auto_apply` on the two staging workspaces and nothing else.
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

## What is gone, and what stays

Destroyed with the add-ons layer: the app and add-on Helm releases, the RDS instance and its
automated backups, the ACM certificate and its validation records, the IRSA roles.

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
  `ac_app_staging_cluster_addons_layer` plan status. That includes every app image bump, because
  the bump scripts edit the staging `terraform.tfvars`. Terraform Cloud statuses are not required
  checks on `main`, so merges are not blocked. Keep bumping staging so its tfvars are current when
  it comes back.
- Pull requests touching the base paths get a staging plan that adds everything. After merge the
  same plan waits for confirmation in the workspace. Discard it.
- The `deploy-image` and `validate-infra-rollout` skills have no staging step to run. Changes go
  to production without a staging pass, or wait for staging to be re-created.

## Re-create

1. `ac_app_staging_base_cluster_layer`: discard any waiting runs, start a new run, confirm the
   apply.
2. The run trigger queues `ac_app_staging_cluster_addons_layer` when the base apply succeeds.
   Confirm it promptly, for the same token reason as above. If no run was queued, start one.
3. Refresh local access: `scripts/infra_eng_sso.py`, then check `/health` on
   `staging.automation-calculations.io`.

Notes for the re-create:

- The database comes back empty. `main_rails_app` has no input for restoring from a snapshot, so
  the final snapshot is not used. Add one before re-creating if the old staging data is wanted.
- The database password and the Rails `secret_key_base` are regenerated, so existing sessions are
  invalid.
- external-dns in staging uses the TXT prefix from `terraform.tfvars`, and the prefixed ownership
  records are still in Route 53, so it should adopt the existing records. If DNS does not update,
  read `docs/external-dns-txt-prefix-migration.md` before changing anything.
- Staging does not enable the CloudWatch alarms (`cloudwatch_alarms_enabled` defaults to false and
  only production sets it), so there is no alarm bootstrap step.
- Before destroying staging a second time, delete the earlier final snapshot or change
  `final_snapshot_identifier`.
- If staging should apply on merge again while it is up, set `auto_apply = true` and apply
  `tf_cloud`. Set it back to `false` before the next destroy.
