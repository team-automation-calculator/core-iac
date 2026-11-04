# GitHub Terraform Migration Plan

Bring the `team-automation-calculator` GitHub organization's assets under Terraform
control in this repo, importing existing assets so the first apply is a pure import
with **zero changes**.

## Scope (decided)

- **In scope**: the 3 repositories and their settings (`github_repository` resources only).
- **Out of scope (this pass)**: branch protection, org settings, org memberships,
  per-repo collaborators.
- **Deliberately excluded**: webhooks and deploy keys — they are owned by CircleCI and
  Terraform Cloud's VCS integration; importing them would fight those systems.
- **Fidelity**: codify settings exactly as-is. Any policy tightening (e.g.
  delete-branch-on-merge, protecting `development_vm`) comes later as separate PRs.
- **Backend**: VCS-connected Terraform Cloud workspace `ac_app_global_github`,
  org `team-automation-calculator`, following the repo's existing tf_cloud conventions.

## GitHub ground truth (captured 2026-07-06 via `gh api`)

Org `team-automation-calculator` (free plan). 3 public repos, all with:

- `has_issues = true`, `has_wiki = true`
- `has_projects = true`, `has_downloads = true` ← **provider defaults are false; must set explicitly**
- `has_discussions = false`, `allow_update_branch = false`
- `allow_merge_commit / allow_squash_merge / allow_rebase_merge = true`, `allow_auto_merge = false`
- `delete_branch_on_merge = false`, `web_commit_signoff_required = false`, `topics = []`
- merge/squash commit title/message settings equal provider defaults
  (`MERGE_MESSAGE`/`PR_TITLE`, `COMMIT_OR_PR_TITLE`/`COMMIT_MESSAGES`)

| Repo | default branch | description | homepage_url | vulnerability_alerts |
|---|---|---|---|---|
| automation-calculator | main | — | https://automation-calculations.io/ | **enabled** |
| core-iac | main | "Infrastructure as Code base for all apps within this project, including the main one." | — | **disabled** |
| development_vm | master | — | — | **enabled** |

## Design decisions

1. **Placement**: env config at `terraform/env/global/github/`; module at
   `terraform/modules/github/repository/` (single-repo module called with `for_each`
   over a `map(object)` variable — mirrors `terraform/modules/aws/route53-domain/` +
   `terraform/env/production/aws/us-east-1/route53-domains/`).
2. **Workspace bootstrap**: extend `terraform/modules/tf_cloud/tf_cloud_workspaces/`
   with a count-gated `tfe_workspace.github_tfe_workspace`
   (`enable_github_workspace`, default `false`) — same precedent as
   `enable_route53_domains_workspace`. Enabled only from
   `terraform/env/production/tf_cloud/`. Workspace name `ac_app_global_github`, tags
   `["automation-calculator", "global"]`, `terraform_version` from
   `var.tfe_workspace_tf_version` ("1.11"), **`auto_apply = false` hardcoded**
   (org-critical), `vcs_repo` + `working_directory`/`trigger_prefixes` like the
   other workspaces.
3. **Provider/auth**: `integrations/github` `~> 6.0` (matches the AWS `~> 6.0`
   convention). Reuse the existing sensitive TF variable literally named
   `TF_VAR_GITHUB_TOKEN`:
   `provider "github" { owner = "team-automation-calculator", token = var.TF_VAR_GITHUB_TOKEN }`.
   The existing TFC variable set gets attached to the new workspace — zero new
   secrets. **Precondition**: that token must have admin on all 3 repos.
4. **Import mechanism**: Terraform `import` blocks in
   `terraform/env/global/github/import.tf` targeting
   `module.github_repositories["<name>"].github_repository.this` with
   `id = "<repo-name>"` — same shape as the existing `route53-domains/import.tf`.
   Removed in a cleanup PR after apply.
5. **Backend**: `backend "remote"` block in the env config's `versions.tf` pointing
   at workspace `ac_app_global_github` (route53-domains precedent). CI validates
   without backend credentials.
6. **Zero-diff guardrails on `github_repository`**: set explicitly
   `has_projects = true`, `has_downloads = true`, and per-repo
   `vulnerability_alerts` (all differ from provider defaults or are non-computed —
   omitting `vulnerability_alerts` would make Terraform disable Dependabot alerts).
   Omit `security_and_analysis` (Optional+Computed; free-plan 422 risk),
   `auto_init`/template args (create-only), deprecated `private`, and `topics`
   (empty; Optional+Computed). **Default branch is intentionally unmanaged**
   (provider v6 dropped it from `github_repository`; `development_vm`'s `master`
   causes no drift).
7. **Destroy safety**: `archive_on_destroy = true` +
   `lifecycle { prevent_destroy = true }` in the module. Removing a repo from the
   tfvars map errors at plan time; deliberate removal requires editing the module
   lifecycle or `terraform state rm`.

## File tree (new ✚ / modified ✎)

```
plans/github-terraform-migration/                              ✚ this folder
terraform/modules/github/repository/                           ✚ main.tf variables.tf outputs.tf versions.tf .terraform.lock.hcl
terraform/env/global/github/                                   ✚ main.tf variables.tf provider.tf versions.tf
                                                               ✚ terraform.tfvars import.tf(temp) outputs.tf .terraform.lock.hcl
terraform/modules/tf_cloud/tf_cloud_workspaces/main.tf         ✎ + github workspace
terraform/modules/tf_cloud/tf_cloud_workspaces/variables.tf    ✎ + 3 vars (alphabetized)
terraform/env/production/tf_cloud/main.tf                      ✎ pass-through
terraform/env/production/tf_cloud/variables.tf                 ✎ + 3 vars
terraform/env/production/tf_cloud/terraform.tfvars             ✎ enable + working dir
.circleci/config.yml                                           ✎ + validate jobs (github module, global/github env, missing ci-iam-role)
CLAUDE.md                                                      ✎ layout tree, provider table (+ GitHub ~> 6.0), unmanaged-attrs note
```

## Phase / PR sequence

Every PR: branch + `gh` draft PR, never push main. Run
`terraform fmt -recursive terraform/` before every commit.

| Phase | PR | Task file | Summary |
|---|---|---|---|
| 0 | PR 1 | (this folder) | Commit the plan + task files |
| 1 | — | [task-01](task-01-capture-github-state.md) | Ground truth captured (done); verify token admin rights |
| 2 | PR 2 | [task-02](task-02-tf-cloud-workspace.md) | TFC workspace bootstrap via tf_cloud module |
| 3 | PR 3 | [task-03](task-03-github-module-and-env-config.md), [task-04](task-04-ci-validate-jobs.md) | GitHub module + env config + import blocks + CI jobs |
| 4 | apply | [task-05](task-05-import-plan-and-apply.md) | Speculative-plan gate, merge, manual apply |
| 5 | PR 4 | [task-06](task-06-cleanup-and-docs.md) | Remove import.tf, update docs |

## Verification

1. PR 3 speculative plan: exactly **"3 to import, 0 to add, 0 to change, 0 to destroy"** (hard merge gate).
2. Post-apply: queue a fresh TFC plan → "No changes. Your infrastructure matches the configuration."
3. PR 4 speculative plan → "No changes."
4. CI green including the new validate jobs.
5. Smoke test: toggle `has_wiki` on one repo in the GitHub UI, queue a plan, confirm
   Terraform detects the drift, revert in the UI.

## Rollback

- Pre-apply: discard the TFC run.
- Post-apply: `terraform state rm 'module.github_repositories'` (state ops work on
  VCS workspaces with `TFE_TOKEN`) — imports made no GitHub-side changes, so removal
  fully reverts Terraform's involvement.

## Known risks / gotchas

- **Perpetual-drift arguments**: `has_projects`, `has_downloads`,
  `vulnerability_alerts` — must come from captured values, never provider defaults.
- **Workspace-name mismatch precedent**: route53-domains' backend says
  `ac_app_route53_domain_production` while the module creates
  `ac_app_production_route53_domains` — a workspace was renamed manually. Confirm the
  actual TFC workspace name matches the backend block before PR 3.
- Token rotation in the TFC variable set now also breaks GitHub plans, not just VCS
  connections — noted in docs (task-06).
