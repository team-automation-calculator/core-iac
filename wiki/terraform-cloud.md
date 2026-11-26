# Terraform Cloud behaviour

Verified: 2026-11-26

How the `team-automation-calculator` organization's runs behave, as observed. The workspace
settings themselves are in `docs/promotion.md` and `terraform/modules/tf_cloud/tf_cloud_workspaces`.

## Queueing and token expiry

- **The organization runs one run at a time.** Speculative plans for a PR queued about 12 minutes
  behind a base-layer apply on 2026-11-25.
- **A queued apply can outlive its EKS token.** Cluster-addons runs carry an EKS token of about
  15 minutes. On 2026-11-05 the staging add-ons apply for #416 waited behind production's #361 base
  apply and then failed with a Kubernetes credentials error, with nothing applied. Do not merge two
  PRs whose applies land in different workspaces within the same 15 minutes, or expect the second to
  need a new run, queued by hand in the Terraform Cloud UI. The same limit applies to a run waiting
  for a confirm (`docs/staging-destroy-and-recreate.md`).

## Commit statuses

- **A merge commit's status turns `success` when the plan finishes, before the apply.** It then
  goes back to `pending` ("Terraform apply pending") and turns `success` again with a description
  starting "Terraform apply:" (#496, 2026-11-25, on both environments). Wait with
  `./go wait-commit-status <full sha> --until-applied` (#498) before taking an after-snapshot.
  Pass the full sha: `HEAD` resolves to `main`'s head on GitHub.
- Statuses for a merge on `main` can appear up to about 10 minutes late (#445, 2026-11-19).
- A run queued by hand posts no GitHub status; watch the effects (`/health`, pods) or read the run
  through the API.
- An empty commit on a PR branch re-triggers its speculative plans.
- Only PRs based on `main` get speculative plans; a PR stacked on another branch gets none (the
  ArgoCD stack #378 to #388).
- HCP Terraform never plans PRs from forks.
- `gh api repos/.../commits/<sha>/statuses` returns 30 per page; pass `per_page=100`.
- A CircleCI status can stay `pending` on GitHub after the workflow finished; the CircleCI v2
  workflow endpoint is public and shows the real result.

## The tf_workspaces runs

The `ac_app_<env>_tf_workspaces` workspaces, which run `terraform/env/<env>/tf_cloud`, were made by
hand and are not defined in the repo. Their runs stop at a plan and need a confirm. Their Terraform
version is set in the UI, not by the repo: 1.17.0 since 2026-11-18, because a version below 1.5 has
no `import` blocks (#445's first plans errored).

## Reading a plan

A user API token from `terraform login` (stored in `~/.terraform.d/credentials.tfrc.json`) can read
plans. Take the run id from the commit status `target_url`, `GET /api/v2/runs/<run-id>?include=plan`,
then `GET /api/v2/plans/<plan-id>/json-output-redacted` (follow redirects) and list the
`resource_changes` whose actions are not `no-op`; `resource_drift` lists changes made outside
Terraform. `sanitized-plan` returns 404 to a user token. Plan logs are JSON lines (`type` is
`planned_change` or `resource_drift`). The status description's counts leave out imports.

`terraform login` needs an interactive terminal; a stale token shows as "unauthorized" at
`terraform init`.
