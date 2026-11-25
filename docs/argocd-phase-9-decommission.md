# ArgoCD migration Phase 9: decommission the Terraform Helm release

Companion to Phase 9 of `argocd-migration-plan.md`. After Phase 6 (staging) and Phase 8
(production) neither cluster-addons workspace holds `helm_release.automation-calculator` in its
state and neither cluster has a Helm release for the app any more: the ArgoCD `Application` is the
only controller of the Service, Deployment and Ingress. This phase deletes the code that is dead as
a result, and stops chart changes from queueing TFC runs. **It changes nothing on the app.** The
applies are in-place updates of the triggers on the three cluster-addons TFC workspaces
(`trigger_prefixes` on staging and development, `trigger_patterns` on production; made by the
`tf_cloud` workspaces), the state-only destroy of the dead `terraform_data` ordering handle, and
the `atomic` flip on the ArgoCD release (a no-op `helm upgrade`, section 3).

The one rule: **the resource block may only be deleted from a module whose every consumer has
already forgotten the resource.** Deleting a resource block for an instance that is still in state
plans a destroy, and the `prevent_destroy` guard goes away with the block, so nothing would stop
that destroy: it would be `helm uninstall`, which deletes the Ingress and the ALB. Section 2 is
how to prove the precondition before merging; both environments auto-apply, so it must be proven
**before** the merge, not watched after.

**This PR applies to staging and production in one merge**, an exception to the two-PR rule of
`docs/promotion.md`. Deleting a module variable needs every caller to stop passing it in the same
commit, so the PR edits production's working directory (`main.tf`, `variables.tf`,
`terraform.tfvars`), and that triggers production's add-ons run alongside staging's, with no
confirm on either. Both speculative plans are on the PR; read both. Production's plan also
carries any shared code on `main` that production has not applied yet: promote that first
(`scripts/promote_to_production.sh addons`) so the plan here is only what section 3 lists. If
the `atomic` flip should be seen on staging before production gets it, move that one line to
its own PR ahead of this one and promote it the usual way.

## 1. What the PR changes

- `terraform/modules/aws/main_rails_app/`
  - `main.tf`: `helm_release.automation-calculator` (with its `count`, `depends_on`, `values`
    and `prevent_destroy`) and the Phase 6 `moved` block are deleted. The namespace, the Secret,
    the RDS instance, its security group and subnet group, the two `random_password`s, the ACM
    certificate and its validation records stay exactly as they were. The Secret keeps the Helm
    labels and annotations it mirrored in Phase 4: they are inert, dropping them would be a
    metadata update on both live Secrets for nothing, and they are what makes the re-adoption in
    section 6 possible.
  - `main.tf` also loses `terraform_data.cluster_addons`, the ordering handle #404 added so the
    release could wait for the ALB controller and external-dns without a module-level `depends_on`.
    With the release gone it orders nothing. It is a state-only resource (it holds the two add-on
    release names and talks to no API), so its destroy in section 3 touches nothing outside
    Terraform. The env's `module "main_rails_app"` still has no `depends_on`: that would bring back
    the ACM validation-record churn #404 fixed. The Application that creates the Ingress is in
    `module.argocd`, which keeps its own `depends_on = [module.cluster_addons]`.
  - `variables.tf`: `manage_helm_release`, `automation_calculator_helm_release_local_path` and
    `addons_dependency` are deleted. Everything that feeds the Secret, RDS or ACM stays (`environment_name` still names
    the DB subnet group).
  - `values.yml` (the `ingress.certificateArn` template) is deleted; nothing reads it.
  - `versions.tf`: the `helm` provider requirement is gone (nothing in the module uses it);
    `kubernetes`, `aws` and `random` stay. `.terraform.lock.hcl` loses the `hashicorp/helm`
    block and nothing else (`terraform init` plus `terraform providers lock` for the three
    platforms verified the rest unchanged).
  - `outputs.tf`: the certificate ARN output's description no longer mentions the release.
- Each env's `terraform/env/<env>/aws/us-west-1/cluster-addons-layer/`
  - `main.tf`: `module "main_rails_app"` no longer passes
    `automation_calculator_helm_release_local_path`, `manage_helm_release` or `addons_dependency`.
- `terraform/modules/aws/cluster-addons-layer/outputs.tf`: the `app_helm_release_dependencies`
  output (#404), whose only consumer was `addons_dependency`, is deleted. Outputs plan nothing.
  - `variables.tf`: `manage_app_helm_release` is deleted; the `argocd_application_automated_sync`
    description no longer refers to it.
  - `terraform.tfvars` (staging and production): `manage_app_helm_release = false` is deleted.
  - `imports_argocd_phase4.tf` (staging and production) is not part of this PR: #463 deleted
    both files on 2026-11-19, once both envs had applied the Phase 4 imports (section 2 still
    checks that the two objects are in state).
- `terraform/modules/tf_cloud/tf_cloud_workspaces/locals.tf`: production's add-ons
  `trigger_patterns` (#477) lose `helm/automation-calculator/values-production.yaml`, and the
  `app_chart_directory` variable that named it is deleted. A production bump PR then triggers no
  workspace: the file is read by ArgoCD only.
- `terraform/modules/tf_cloud/tf_cloud_workspaces/variables.tf` and
  `terraform/env/development/tf_cloud/variables.tf`: `helm/automation-calculator` leaves
  `cluster_addons_layer_module_directories`. **`terraform/modules/aws/main_rails_app` stays** in
  that list on purpose: the module still owns the namespace, the Secret, RDS and ACM in all three
  addons workspaces, so a change to it must still queue their runs. The plan's Phase 9 bullet
  listed both directories for removal when it assumed the module would be emptied of
  cluster-facing resources; it was not.
- `terraform/modules/aws/argocd/main.tf`: `helm_release.argocd` becomes `atomic = true`. It was
  non-atomic for the Phase 2 and Phase 8 installs on purpose (an atomic first install is
  uninstalled on failure, and the likely failure was the plan-time EKS token expiring during the
  900-second wait, which a non-atomic retry repaired in place). With both clusters installed, a
  failed upgrade should roll back to the working ArgoCD instead. This is the one change in the PR
  that is not a no-op on the clusters: see section 3.
- Documentation: `AGENTS.md` (the tool-neutral half of `CLAUDE.md` since #437; layout, apply order, how a deploy works, scripts), `README.md`
  (setup steps), the plan's status line and Phase 9 section, and this runbook.
- `.circleci/config.yml` is unchanged: `helm lint` still guards the chart ArgoCD deploys,
  `validate_main_rails_app_module` still validates a module that exists, and
  `validate_app_docker_image_versions` already reads the chart values files.
- `scripts/argocd_phase1_render_diff.sh` is kept: it reads the pre-Phase-1 `values.yml` and
  tfvars from a git ref (`git show`), not from the working tree, so it still runs after this
  deletion. Its header says that the diff has grown since Phase 4 (the chart no longer renders
  the Secret for a real env).

## 2. Preconditions, proven before merging (read-only)

All of these must hold on **both** staging and production. Do not merge on a partial result.

### 2.1 No Helm release for the app on either cluster

```bash
eval "$(scripts/infra_eng_sso.py up --environment staging)"      # then again with --environment production
kubectl config current-context                                    # the right cluster
helm -n automation-calculator list                                # empty
kubectl -n automation-calculator get secret -l owner=helm,name=automation-calculator   # No resources found
argocd app get automation-calculator                              # Synced, Healthy (CLI port-forward and login as in the Phase 2 runbook, section 4.2)
scripts/argocd_staging_verify.sh                                  # staging: Verify OK
scripts/argocd_staging_verify.sh --env production                 # production: Verify OK, without --expect-helm-release
```

A non-empty `helm list` means the Phase 6 or Phase 8 history deletion never happened in that env;
finish that runbook (its step 5) first. It also means section 2.2 is almost certainly failing.

### 2.2 Neither workspace state holds the release; both hold the Phase 4 objects

From the PR branch checkout with `TFE_TOKEN` set (`terraform state list` reads the remote state
and needs no cluster credentials):

```bash
cd terraform/env/staging/aws/us-west-1/cluster-addons-layer
terraform init
terraform state list | grep -c 'helm_release.automation-calculator'   # 0
terraform state list | grep 'module.main_rails_app.kubernetes_'       # exactly the namespace and the Secret
cd ../../../../../production/aws/us-west-1/cluster-addons-layer
terraform init
terraform state list | grep -c 'helm_release.automation-calculator'   # 0
terraform state list | grep 'module.main_rails_app.kubernetes_'       # exactly the namespace and the Secret
```

Expected in both: no `helm_release.automation-calculator` at any address (indexed or not), and
both `module.main_rails_app.kubernetes_namespace_v1.automation_calculator` and
`module.main_rails_app.kubernetes_secret_v1.app_secrets` present.

If the release **is** in state in an env, stop: that env has not run its Phase 6 / Phase 8
`state rm`. Run that runbook to completion first (the `state rm`, the toggle merge, the history
deletion), then come back. Never merge this PR to "fix" it.

If either Phase 4 object is **missing** from a state, stop: with `imports_argocd_phase4.tf`
gone since #463, the next plan would try to **create** the namespace and the Secret, and the apply
would fail on the existing objects (or, worse, overwrite the Secret's data on a provider that
allows it). Re-run the Phase 4 runbook for that env, restoring its import file first.

### 2.3 The speculative plans say so too

Terraform reads the state during a plan, so the plans are the same proof from the other side. From
the PR branch checkout, with `TFE_TOKEN` set (speculative remote runs; nothing is applied):

```bash
cd terraform/env/staging/aws/us-west-1/cluster-addons-layer
terraform plan | tee ../../../../../../tmp/phase9-staging.txt          # 1 to change (atomic), 1 to destroy (terraform_data)
cd ../../../../../production/aws/us-west-1/cluster-addons-layer
terraform plan | tee ../../../../../../tmp/phase9-production.txt       # 1 to change (atomic), 1 to destroy (terraform_data)
```

The only acceptable changes in either plan are `atomic: false => true` on
`module.argocd[0].helm_release.argocd` and the destroy of
`module.main_rails_app.terraform_data.cluster_addons`. Anything else touching
`module.main_rails_app` means a precondition in 2.1 or 2.2 is not actually met: stop.

The speculative runs TFC attaches to the PR show the same. **Stop and do not merge** if either
plan shows:

- `module.main_rails_app.helm_release.automation-calculator[0] will be destroyed` (or the
  un-indexed address): the release is still in state (section 2.2). With the block deleted there
  is no guard; on staging the merge would auto-apply a `helm uninstall`.
- `module.main_rails_app.kubernetes_namespace_v1.automation_calculator will be created` or
  `kubernetes_secret_v1.app_secrets will be created`: a Phase 4 object is not in state.
- Anything on `module.argocd[0]` other than the `atomic` flip, or on `module.cluster_addons`:
  not this PR. A replacement of the ACM validation records means a module-level `depends_on`
  came back onto `main_rails_app` (#404).

Also check in the TFC UI that both addons workspaces are idle (no run planning or applying) and
that their latest runs applied or planned no changes.

## 3. Expected TFC plans

| Workspace | Expected plan for the merge |
|---|---|
| `ac_app_staging_cluster_addons_layer` | **1 to change**, in place: `module.argocd[0].helm_release.argocd`, `atomic: false => true`. **1 to destroy**: `module.main_rails_app.terraform_data.cluster_addons` (state only, no API call). Nothing else. Auto-applies: the provider runs a `helm upgrade` with the same chart and values, which records a new Helm revision and changes no objects (no pod restarts; `argocd app get` stays Synced/Healthy). The release deletion itself plans nothing: the resource left state in Phase 6. |
| `ac_app_production_cluster_addons_layer` | **1 to change**, in place: the same `atomic` flip, and the same **1 to destroy** of `terraform_data.cluster_addons`. Auto-applies at the same merge, because the PR changes production's working directory (the `helm upgrade` is the same no-op as on staging). Nothing from the release deletion: it left state in Phase 8. |
| `ac_app_development_cluster_addons_layer` | No cluster: fails at `data.aws_eks_cluster` as it did before this PR. |
| each env's `tf_cloud` workspace | **1 to change**, in place: `module.tf_cloud_workspaces.tfe_workspace.cluster_addons_tfe_workspace`. On staging and development `trigger_prefixes` loses `helm/automation-calculator`; on production `trigger_patterns` loses `/helm/automation-calculator/values-production.yaml`. Nothing else: no replacement, no change to the base-cluster workspace or the run trigger. |

The `tf_cloud` workspaces do not auto-apply; confirm each one. There is no staleness concern here:
the `tfe` provider talks only to Terraform Cloud, never to EKS, so the plan does not expire with
the 15-minute token. (Staging's and production's `tf_cloud` configs take the module default for
`cluster_addons_layer_module_directories`; development passes its own variable with the same
value, which is why both files change.)

## 4. Merge

With section 2 green: merge. There is no ordering constraint and no window on the app side: the
only addons change is the `atomic` flip on the ArgoCD release (section 3), and the `tf_cloud`
applies touch workspace settings only. The staging and production addons runs auto-apply; watch
both (`python3 -I scripts/wait_commit_status.py` on the merge commit). Then confirm the three
`tf_cloud` runs when they come up.

## 5. After the merge

```bash
helm -n automation-calculator list                                # still empty, both clusters
kubectl -n automation-calculator get deploy,svc,ingress,secret    # all four, both clusters
argocd app get automation-calculator                              # Synced, Healthy, both clusters
```

In TFC, the staging and development cluster-addons workspaces' settings now list
`terraform/env/<env>/aws/us-west-1/cluster-addons-layer`, `terraform/modules/aws/cluster-addons-layer`,
`terraform/modules/aws/main_rails_app` and `terraform/modules/aws/argocd` as trigger prefixes, and
not `helm/automation-calculator`. Production's lists one trigger pattern, its own working
directory.

The proof that the decommission did what it set out to do is the **next deploy**: neither the
staging bump PR nor the production bump PR gets a Terraform Cloud status, and merging them queues
no cluster-addons run (before this phase each queued a 0-change run in its environment). Staging
syncs itself within ArgoCD's polling interval; production is synced by hand as in
`argocd-phase-8-production.md` section 8. A change under `terraform/modules/aws/main_rails_app`
(a DB engine version, a Secret value expression) still runs on staging at merge and on production
with its promotion PR, as it must.

## 6. Rollback

Nothing on either cluster changes in this phase, so there is nothing to roll back **for the app**;
a bad deploy is a git revert of the bump (synced by ArgoCD) or, on production,
`argocd app rollback` (Phase 8 section 8).

**Reverting this PR is safe and plans nothing beyond `atomic: true => false`** on both addons
workspaces (that flip is an in-place `helm upgrade` with unchanged values): the revert brings the
resource block back with `count = var.manage_helm_release ? 1 : 0` *and* brings back
`manage_app_helm_release = false` in both tfvars, so the count is 0 and the state still has no
release. The chart goes back onto the workspace triggers (three `tf_cloud` runs, 1 to change
each). That is the whole revert; it only restores dead code. Like this PR, the revert changes
production's working directory, so it applies to both environments at its merge.

**Putting the app back under Terraform is hard, and is not a revert.** The state has no release
and the clusters have no Helm history, so there is nothing to import. It is the path of last
resort from Phase 6 section 6.3 / Phase 8 section 9.5, for a broken ArgoCD only, and in this
order:

1. Stop ArgoCD reconciling the app first: on staging revert the automated-sync flip (the three
   `argocd_application_*` tfvars to false, one in-place change on `module.argocd[0]`), or
   `argocd app delete automation-calculator --cascade=false` (**never** without
   `--cascade=false`: the Application carries no finalizer, but the flag is the belt and braces).
   Production is already manual.
2. Revert this PR so the module has the resource block again (its plan re-creates the state-only `terraform_data.cluster_addons` and reverts the `atomic` flip; nothing else).
3. Re-adopt the live objects into a Helm release by hand. It works because the Service,
   Deployment, Ingress and Secret still carry `meta.helm.sh/release-name`, `release-namespace`
   and `app.kubernetes.io/managed-by: Helm`:

   ```bash
   helm -n automation-calculator upgrade --install automation-calculator helm/automation-calculator \
     -f helm/automation-calculator/values.yaml -f helm/automation-calculator/values-<env>.yaml \
     --set ingress.certificateArn=<ACM ARN from the workspace's main_rails_app output>   # same values ArgoCD renders: no rollout
   ```

4. Import the release at the **indexed** address (the reverted module has `count`), then set
   `manage_app_helm_release = true` in that env's tfvars; the plan must be 0 changes:

   ```bash
   cd terraform/env/<env>/aws/us-west-1/cluster-addons-layer
   terraform init
   terraform import 'module.main_rails_app.helm_release.automation-calculator[0]' automation-calculator/automation-calculator
   terraform plan   # 0 changes with manage_app_helm_release = true on the branch
   ```

Any mistake in that order makes two controllers reconcile the Deployment, or makes Terraform plan
a `helm install` over live objects. What **not** to do, ever: `helm uninstall
automation-calculator`; `kubectl delete namespace automation-calculator`; `argocd app delete`
without `--cascade=false`; adding a `helm_release` for the app back to the module to "redeploy".

## 7. Done when

- Section 2 held on both envs before the merge (keep the `tmp/phase9-*.txt` plan transcripts
  until the merge is done; they hold no secrets).
- The merge planned exactly **1 to change** (the `atomic` flip on `module.argocd[0].helm_release.argocd`)
  and **1 to destroy** (`module.main_rails_app.terraform_data.cluster_addons`), nothing to add, on both `ac_app_staging_cluster_addons_layer` and
  `ac_app_production_cluster_addons_layer`, and both applied; `helm -n argocd history argocd` shows
  one new revision per cluster with no pod restarts. The three `tf_cloud` runs applied one in-place
  change each and no workspace's triggers list the chart or a values file any more.
- `helm -n automation-calculator list` is empty and `argocd app get automation-calculator` is
  Synced and Healthy on both clusters, same pods as before the merge.
- The next staging and production bump PRs queued no cluster-addons run.
- `argocd-migration-plan.md` says implemented, with the PR per phase.
