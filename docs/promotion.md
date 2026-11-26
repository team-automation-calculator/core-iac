# Promotion: staging in one pull request, production in the next

Every app and infrastructure change reaches production in two pull requests. The first changes
staging and is verified there. The second changes production and is merged only if staging went
well. **Merging the production pull request is the deploy**: the production cluster workspaces
apply on merge, with no confirm in Terraform Cloud.

The app follows the same rule. ArgoCD deploys it, and production's Application renders the chart
and `values-production.yaml` from **one pinned commit**, `argocd_app_target_revision` in
production's add-ons `terraform.tfvars`, not from `main`. Staging tracks `main`. The production
pull request moves the pin to the `main` commit verified on staging; merging it applies the pin
through the production add-ons workspace, and ArgoCD's automated sync rolls the app out. No one
runs `argocd app sync`. Between ArgoCD migration Phase 8 and the pin, production tracked `main` on
manual sync instead (`docs/argocd-phase-8-production.md` section 8).

## How it is wired

| | Staging | Production |
|---|---|---|
| `ac_app_<env>_base_cluster_layer`, `ac_app_<env>_cluster_addons_layer` | auto-apply | **auto-apply** |
| What triggers them | the environment's working directories and the shared modules | **production's own files only**: the two working directories |
| The app chart and its values files | trigger no workspace since ArgoCD migration Phase 9 | trigger no workspace |
| App rollout | ArgoCD, from `main`, automated sync | ArgoCD, from the pinned commit (`argocd_app_target_revision`), automated sync |
| Route 53 domains, GitHub organization, Google Workspace, Google Cloud | (production only) | manual confirm, unchanged: they exist once and have no staging to rehearse on |

The settings are `auto_apply`, `trigger_on_shared_code` and `global_workspaces_auto_apply` on
`terraform/modules/tf_cloud/tf_cloud_workspaces`, set in `terraform/env/<env>/tf_cloud`.

The narrow production trigger is what makes two pull requests possible for shared code. A change
to a module merges once, and without it that merge would apply to staging
and production at the same moment. With it, the merge applies to staging only, and production
picks the change up when a production pull request merges.

## The two pull requests

| Change | Staging pull request | Production pull request |
|---|---|---|
| App image | `./go bump-app-docker-image-version-branch <tag> <sha>` (or the watcher): every values file, `values-production.yaml` included; production does not move | `./go bump-app-docker-image-version-branch <tag> <sha> production`: moves the pin (and the add-ons `promoted_ref`) to the `main` commit whose `values-production.yaml` carries the tag |
| A chart change (templates, `values.yaml`) | the change itself | `./go promote-to-production addons`: moves the pin; or let the next image promotion carry it |
| A per-environment setting (tfvars, a version pin, a toggle) | staging's `terraform.tfvars` | production's `terraform.tfvars` |
| A new capability in a module | the module change, off by default behind a variable, and the toggle in staging's tfvars | the toggle in production's tfvars |
| Shared Terraform code with nothing per-environment to change (a module refactor, a module version bump) | the change itself | `./go promote-to-production <base\|addons\|both>`: writes the verified `main` commit to `promoted_ref` in the production working directory, which is the file the pull request changes; `addons` and `both` move the app pin to the same commit |
| A provider or lock file bump | staging's env config directory | production's env config directory |

**One commit decides what production runs.** The pin covers the chart, `values.yaml` and
`values-production.yaml` together, so `values-production.yaml` on `main` is what production runs
*next*, after the following promotion, and not what it runs now. Moving the pin from `A` to `B`
brings every chart change merged between them. The promote script prints that `git log`
range and the chart files changed, and the production pull request carries them; anything beyond
the image tag and hash is a chart change to understand before merging. It was verified on
staging, which tracks `main`. The chart `version` in `Chart.yaml` does not decide whether a
change applies (under the Terraform `helm_release` it did: #474 sat unapplied on production until
the version was bumped).

**Why automated sync is safe on production now.** While production tracked `main`, automated sync
would have deployed every chart change to production at merge, together with staging. Pinned, a
merge to `main` cannot reach production until a production pull request moves the pin, and
self-heal puts back any hand edit to the app's objects.

**Rollback** is a production pull request that moves the pin back: `./go promote-to-production
addons <earlier commit>`. The script marks it ROLLBACK and lists the commits it takes off
production. `argocd app rollback` no longer works on its own: automated sync reverts it to the
pinned commit within minutes. In an emergency, merge the rollback pull request; it applies on merge.
The pin only accepts commits on `main` (the script refuses others), so a production fix that must
not bring along unverified work merged after the pin goes like this: revert that work on `main`,
merge the fix, verify on staging, promote. Rule 3 keeps that rare.

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
   (staging applies it), then promote the revert. For the app, the fastest production rollback is
   moving the pin back (above); the revert on `main` follows so staging matches.
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
  that changes production's add-ons `terraform.tfvars` gets no
  `ac_app_production_cluster_addons_layer` status, the pattern is wrong and nothing will apply
  on merge.
- **The staging bump has no plan; the production promotion does.** The chart triggers no
  workspace, so the staging bump pull request gets no Terraform Cloud status. The production pull
  request changes the add-ons `terraform.tfvars` and gets a speculative plan in
  `ac_app_production_cluster_addons_layer`, which should change only the `argocd-apps` release
  (the Application's `targetRevision`). It also carries any production Terraform change waiting on
  `main` (rule 2).
- **An image deploy now runs the production add-ons workspace.** About three minutes of Terraform
  Cloud plan and apply come before ArgoCD sees the new pin and syncs (within its 3 minute poll,
  usually at once because the Application spec changed).
- **The base layer's run trigger still fires.** A production base-layer apply queues an add-ons
  run, which now applies too.
- **Docs-only and script-only pull requests** trigger nothing, as before.
- **Staging while destroyed.** `docs/staging-destroy-and-recreate.md` turns staging's auto-apply
  off. With no staging to verify on, production pull requests lose their rehearsal; say so in
  them.
