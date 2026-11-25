# Promotion: staging in one pull request, production in the next

Every app and infrastructure change reaches production in two pull requests. The first changes
staging and is verified there. The second changes production and is merged only if staging went
well. **Merging the production pull request is the deploy**: the production cluster workspaces
apply on merge, with no confirm in Terraform Cloud.

The app image is the one exception since ArgoCD migration Phase 8. ArgoCD deploys the app, and
production's Application is on manual sync: merging the production pull request changes what
`main` says production should run, and the image rolls out when `argocd app sync` is run
afterwards (`docs/argocd-phase-8-production.md` section 8).

## How it is wired

| | Staging | Production |
|---|---|---|
| `ac_app_<env>_base_cluster_layer`, `ac_app_<env>_cluster_addons_layer` | auto-apply | **auto-apply** |
| What triggers them | the environment's working directories, the shared modules and the app chart | **production's own files only**: the two working directories and `helm/automation-calculator/values-production.yaml` |
| App rollout | ArgoCD, from `main`, automated sync | ArgoCD, from `main`, on a manual `argocd app sync` |
| Route 53 domains, GitHub organization, Google Workspace, Google Cloud | (production only) | manual confirm, unchanged: they exist once and have no staging to rehearse on |

The settings are `auto_apply`, `trigger_on_shared_code` and `global_workspaces_auto_apply` on
`terraform/modules/tf_cloud/tf_cloud_workspaces`, set in `terraform/env/<env>/tf_cloud`.

The narrow production trigger is what makes two pull requests possible for shared code. A change
to a module or a chart template merges once, and without it that merge would apply to staging
and production at the same moment. With it, the merge applies to staging only, and production
picks the change up when a production pull request merges.

## The two pull requests

| Change | Staging pull request | Production pull request |
|---|---|---|
| App image | `scripts/bump_app_docker_image_version_branch.sh <tag> <sha>` (or the watcher): `values-staging.yaml`, plus the chart default and `values-development.yaml` | `scripts/bump_app_docker_image_version_branch.sh <tag> <sha> production`: `values-production.yaml`, then `argocd app sync` |
| A per-environment setting (tfvars, a version pin, a toggle) | staging's `terraform.tfvars` | production's `terraform.tfvars` |
| A new capability in a module | the module change, off by default behind a variable, and the toggle in staging's tfvars | the toggle in production's tfvars |
| Shared code with nothing per-environment to change (a module refactor, a chart template, a chart or module version bump) | the change itself | `scripts/promote_to_production.sh <base\|addons\|both>`: writes the verified `main` commit to `promoted_ref` in the production working directory, which is the file the pull request changes |
| A provider or lock file bump | staging's env config directory | production's env config directory |

**A chart change reaches production at the next `argocd app sync`.** ArgoCD renders the chart
from `main`. Staging syncs by itself, so a template or `values.yaml` change applies there at
merge. Production's manual sync applies everything on `main` at once: every chart change merged
since the last sync comes along with the image in `values-production.yaml`, and no promotion pull
request is involved. `argocd app diff automation-calculator` before the sync is the review, and
anything in it beyond the tag and the hash is a chart change to understand first. The chart
`version` in `Chart.yaml` no longer decides whether a change applies (under the Terraform
`helm_release` it did: #474 sat unapplied on production until the version was bumped).

Prefer a per-environment variable over `promoted_ref` when the change can be written that way:
the production pull request then says what it turns on.

## Rules

1. **The production pull request's speculative plan is the review.** Nothing stops between merge
   and apply, so read the plan on the pull request before merging. It shows everything the merge
   will apply.
2. **A production plan contains everything on `main` that production has not applied yet**, not
   only what the pull request changes. Shared changes merged since production last ran come
   along. If the plan shows more than the pull request describes, either the extra is a staging
   change that was verified and is waiting (say so in the pull request and promote it together),
   or it is not ready and the production pull request waits.
3. **Promote before starting the next change.** Leaving verified changes unpromoted is how rule
   2 becomes a surprise. `terraform plan` output on any production pull request, or a manual
   speculative run in the workspace, shows what is waiting.
4. **Never merge the production pull request before staging is verified** with the same change:
   the `deploy-image` skill for images, `validate-infra-rollout` for everything else.
5. **A base-layer production plan may carry a node roll.** The node group's AMI `release_version`
   moves whenever AWS has published a newer AMI, and it now applies without anyone confirming.
   Check for it in the plan and pick the merge time accordingly.
6. **Rollback is a revert pull request**, production first. For shared code, revert on `main`
   (staging applies it), then promote the revert.
7. **A manual run is still possible** from the Terraform Cloud UI for either production
   workspace, and it auto-applies too. Use a plan-only run to look.

## What the old confirm did, and what replaces it

| The confirm in the Terraform Cloud UI gave | Now |
|---|---|
| A gate between staging and production | the production pull request, merged only after staging is verified |
| A last look at the production plan | the speculative plan on the production pull request |
| A person choosing the moment of a production change | the merge of the production pull request |
| A 15 minute EKS token that expired while a run waited | gone: the run applies as soon as it has planned |

What is lost: a second chance after merging. A production pull request merged by mistake applies.

## Caveats

- **Trigger patterns are new here.** Production's workspaces use `trigger_patterns` (globs)
  where staging uses `trigger_prefixes`. The first production pull request after this lands
  should show a speculative plan in each workspace whose files it touches; if a pull request
  that changes `values-production.yaml` gets no `ac_app_production_cluster_addons_layer`
  status, the pattern is wrong and nothing will apply on merge.
- **The base layer's run trigger still fires.** A production base-layer apply queues an add-ons
  run, which now applies too.
- **Docs-only and script-only pull requests** trigger nothing, as before.
- **Staging while destroyed.** `docs/staging-destroy-and-recreate.md` turns staging's auto-apply
  off. With no staging to verify on, production pull requests lose their rehearsal; say so in
  them.
