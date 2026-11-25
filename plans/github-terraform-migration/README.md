# GitHub Terraform Migration Plan

Bring the settings of the `team-automation-calculator` organization's three repositories
under Terraform, by import, so that the first apply changes nothing on GitHub.

Written 2026-07-06, revised 2026-11-25. The revision drops everything that has since
landed another way and re-bases the rest on what is on `main`.

## Status

| Piece of the July plan | State on 2026-11-25 |
|---|---|
| Terraform Cloud workspace for GitHub | **Done differently** by #372: `ac_app_production_github_org`, created by `enable_github_org_workspace` in `tf_cloud_workspaces`, manual confirm (`global_workspaces_auto_apply = false`). The planned `ac_app_global_github` workspace is dropped. |
| Env config directory | **Done differently**: `terraform/env/production/github/org` exists. The planned `terraform/env/global/github` is dropped. |
| `github` provider, lock files, CI validate jobs for the env config | **Done** by #372 (`integrations/github ~> 6.13`, `validate_production_github_org`). |
| Organization membership, team and team repository permissions for the CI machine user | **Done** by #372 (`terraform/modules/github/org-ci-access`). This was out of scope in July. |
| Token | **Changed**: the workspace reads a fine-grained owner token from the `GITHUB_TOKEN` environment variable (`docs/github-ci-user.md`), not the `TF_VAR_GITHUB_TOKEN` variable set. |
| `github_repository` for the three repositories, imported | **Not done.** This is the remaining work. |
| CI validate job for `terraform/modules/aws/ci-iam-role` | **Not done.** Still has no job in `.circleci/config.yml`. |

## Scope

- **In**: one `github_repository` per repository, plus its Dependabot alert setting,
  imported exactly as it is today.
- **Out, for a later pass**: branch protection and rulesets, organization settings (the
  default repository permission is still `write`), human memberships, Dependabot
  security updates, secret scanning.
- **Left alone on purpose**: webhooks and deploy keys. CircleCI and the Terraform Cloud
  VCS connection own them.
- **Fidelity**: the configuration is made to match GitHub, never the other way round.
  Any tightening is a separate pull request after the import.

## Ground truth (captured 2026-11-25 with `gh api`)

Organization on the free plan, three public repositories, none archived. The same on
all three:

- `has_issues`, `has_wiki`, `has_projects`: true
- `has_discussions`: false
- `allow_merge_commit`, `allow_squash_merge`, `allow_rebase_merge`: true
- `allow_auto_merge`, `allow_update_branch`, `web_commit_signoff_required`: false
- merge and squash commit title and message: `MERGE_MESSAGE` / `PR_TITLE`,
  `COMMIT_OR_PR_TITLE` / `COMMIT_MESSAGES` (the provider's defaults)
- `topics`: empty

Per repository:

| Repository | Default branch | Description | Homepage | `delete_branch_on_merge` | Dependabot alerts |
|---|---|---|---|---|---|
| `automation-calculator` | `main` | none | `https://automation-calculations.io/` | true | enabled |
| `core-iac` | `main` | "Infrastructure as Code base for all apps within this project, including the main one." | none | true | disabled |
| `development_vm` | `master` | none | none | false | enabled |

Changed since the July capture: `delete_branch_on_merge` is now true on
`automation-calculator` and `core-iac` (it was false everywhere), and the API now
reports `has_downloads` false everywhere (it was true).

## Design

1. **Where it lives.** A new single-repository module,
   `terraform/modules/github/repository`, called with `for_each` over a `repositories`
   map from the existing `terraform/env/production/github/org`. No new workspace, no new
   backend, no new provider block.
2. **Token.** The workspace's owner token already carries Administration read and write,
   but only on the repositories it was scoped to: `automation-calculator` and
   `core-iac`. `development_vm` has to be added to the token's selected repositories by
   an organization owner before the import can read it (task 01).
3. **Arguments, checked against the provider 6.13.0 schema.**
   - Set explicitly: `name`, `description`, `homepage_url`, `visibility`, `has_issues`,
     `has_wiki`, `has_projects`, `has_discussions`, the three `allow_*_merge` flags,
     `allow_auto_merge`, `allow_update_branch`, `delete_branch_on_merge`,
     `archive_on_destroy`. `has_projects` matters most: it is not computed and the
     provider's default is false, so leaving it out would plan to turn Projects off.
   - Left out: `has_downloads`, `vulnerability_alerts`, `default_branch` and `private`
     (all four deprecated in 6.13), `security_and_analysis` (a 422 risk on the free
     plan), `topics` and `web_commit_signoff_required` (optional and computed, and at
     their defaults), the commit title and message arguments (at the provider's
     defaults), and the create-only arguments (`auto_init`, templates).
   - The July plan set `has_downloads` and `vulnerability_alerts` on `github_repository`.
     Both are deprecated now, so neither is set there.
4. **Dependabot alerts.** `vulnerability_alerts` on `github_repository` is deprecated in
   favour of the separate `github_repository_vulnerability_alerts` resource
   (`repository`, `enabled`). The module holds one per repository, with `enabled` taken
   from the table above and no default, so nobody can turn alerts off by omission.
5. **Default branch** stays unmanaged. `development_vm` on `master` causes no drift.
6. **Import.** `import` blocks in `terraform/env/production/github/org/import.tf`, one
   per repository with `id = "<repository name>"`, removed in the cleanup pull request.
   Whether `github_repository_vulnerability_alerts` can be imported, and with what id,
   is not confirmed; task 02 checks it before the gate numbers are fixed.
7. **Destroy safety.** `archive_on_destroy = true` and `lifecycle { prevent_destroy =
   true }` in the module. Removing a repository from the map fails at plan time; a
   deliberate removal is a `terraform state rm`.
8. **Run trigger.** Add `terraform/modules/github/repository` to the default of
   `github_org_module_directories` in `tf_cloud_workspaces`, or a later change to the
   module alone would not start a run in the workspace.

## Files

```
terraform/modules/github/repository/                         new: main.tf variables.tf outputs.tf versions.tf .terraform.lock.hcl
terraform/env/production/github/org/main.tf                  module call
terraform/env/production/github/org/variables.tf             repositories variable
terraform/env/production/github/org/terraform.tfvars         the three repositories
terraform/env/production/github/org/import.tf                new, temporary
terraform/env/production/github/org/outputs.tf               repository URLs
terraform/env/production/github/org/.terraform.lock.hcl      regenerate only if init changes it
terraform/modules/tf_cloud/tf_cloud_workspaces/variables.tf  github_org_module_directories default
.circleci/config.yml                                         validate_github_repository_module, validate_ci_iam_role_module
AGENTS.md, docs/github-ci-user.md                            layout line, token scope, what is managed
```

## Remaining tasks

| Order | Task | Who | Outcome |
|---|---|---|---|
| 1 | [task-01](task-01-token-and-ground-truth.md) | organization owner, by hand | Token can administer all three repositories; ground truth still current |
| 2 | [task-02](task-02-repository-module-and-imports.md) | agent, one pull request | Module, module call, import blocks, CI jobs, run trigger |
| 3 | [task-03](task-03-plan-gate-and-apply.md) | human, Terraform Cloud | Import-only plan read, pull request merged, run confirmed |
| 4 | [task-04](task-04-cleanup-and-docs.md) | agent, one pull request | Import blocks removed, docs updated |

The workspace is one of the global production workspaces: a merge stops at "apply
pending" and needs a confirm. It has no staging counterpart, so the two-pull-request
promotion flow in `docs/promotion.md` does not apply.

## Verification

1. Speculative plan on the task 02 pull request imports and does nothing else: no add
   other than what task 02 recorded for the alerts resource, no change, no destroy.
2. After the apply, a fresh plan in `ac_app_production_github_org` shows no changes.
3. The same `gh api` capture as task 01 returns the values in the table above.
4. The cleanup pull request's speculative plan shows no changes.

## Rollback

- Before the apply: discard the run.
- After it: `terraform state rm` on the module addresses. An import changes nothing on
  GitHub, so removing the state entries undoes all of it.

## Risks

- **An argument at the provider default overwrites a real setting.** Guarded by the
  import-only gate; `has_projects` and `delete_branch_on_merge` are the likely ones.
- **Token scope.** A repository missing from the token's selected repositories fails the
  plan with a 404 that reads like a missing repository.
- **Token expiry.** The owner token lasts at most a year. When it lapses every plan in
  the workspace fails, now for repository settings as well as CI access.
- **Deprecated arguments.** If a later provider release removes `has_downloads` or
  `vulnerability_alerts` outright nothing here changes, because neither is set.
