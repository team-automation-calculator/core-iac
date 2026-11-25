# Task 02: repository module, module call and import blocks

One pull request. Depends on task 01. Values come from the table in
[README.md](README.md).

## Patterns to copy

- Module layout and style: `terraform/modules/github/org-ci-access` (alphabetized
  variables with `description` and `type`, outputs with descriptions, `versions.tf` with
  `required_version = ">= 1.5.7"` and `integrations/github ~> 6.13`, a committed lock
  file).
- `for_each` module call with import blocks:
  `terraform/env/production/aws/us-east-1/route53-domains`.

## 1. `terraform/modules/github/repository/`

`main.tf`:

```hcl
resource "github_repository" "this" {
  allow_auto_merge       = var.allow_auto_merge
  allow_merge_commit     = var.allow_merge_commit
  allow_rebase_merge     = var.allow_rebase_merge
  allow_squash_merge     = var.allow_squash_merge
  allow_update_branch    = var.allow_update_branch
  archive_on_destroy     = true
  delete_branch_on_merge = var.delete_branch_on_merge
  description            = var.description
  has_discussions        = var.has_discussions
  has_issues             = var.has_issues
  has_projects           = var.has_projects
  has_wiki               = var.has_wiki
  homepage_url           = var.homepage_url
  name                   = var.name
  visibility             = var.visibility

  lifecycle {
    prevent_destroy = true
  }
}

# Dependabot alerts. The vulnerability_alerts argument on github_repository is
# deprecated in provider 6.13 in favour of this resource.
resource "github_repository_vulnerability_alerts" "this" {
  enabled    = var.vulnerability_alerts
  repository = github_repository.this.name
}
```

Do not add `has_downloads`, `vulnerability_alerts`, `default_branch`, `private`,
`security_and_analysis`, `topics`, `web_commit_signoff_required`, the commit title and
message arguments, or the create-only arguments. The README's design section gives the
reason for each. Put a short comment in `main.tf` saying they are left out on purpose.

`variables.tf`: one variable per argument above. Defaults are the values shared by all
three repositories (`visibility = "public"`, `has_issues`, `has_wiki` and `has_projects`
true, `has_discussions` false, the three merge methods true, `allow_auto_merge` and
`allow_update_branch` false, `description` and `homepage_url` null). **No default** for
`name`, `delete_branch_on_merge` or `vulnerability_alerts`: they differ per repository,
and a default would hide an omission.

`outputs.tf`: `full_name`, `html_url`, `node_id`, `repository_name`.

## 2. `terraform/env/production/github/org/`

`variables.tf`, added in alphabetical position:

```hcl
variable "repositories" {
  description = "Repositories whose settings are managed here, keyed by repository name. Only the settings that differ between repositories are listed; the rest are module defaults."
  type = map(object({
    delete_branch_on_merge = bool
    description            = optional(string)
    homepage_url           = optional(string)
    vulnerability_alerts   = bool
  }))
}
```

`main.tf`, next to the existing `org_ci_access` call:

```hcl
module "repositories" {
  for_each = var.repositories

  delete_branch_on_merge = each.value.delete_branch_on_merge
  description            = each.value.description
  homepage_url           = each.value.homepage_url
  name                   = each.key
  source                 = "../../../../modules/github/repository"
  vulnerability_alerts   = each.value.vulnerability_alerts
}
```

`terraform.tfvars`:

```hcl
repositories = {
  "automation-calculator" = {
    delete_branch_on_merge = true
    homepage_url           = "https://automation-calculations.io/"
    vulnerability_alerts   = true
  }
  "core-iac" = {
    delete_branch_on_merge = true
    description            = "Infrastructure as Code base for all apps within this project, including the main one."
    vulnerability_alerts   = false
  }
  "development_vm" = {
    delete_branch_on_merge = false
    vulnerability_alerts   = true
  }
}
```

`import.tf` (temporary, removed in task 04):

```hcl
import {
  to = module.repositories["automation-calculator"].github_repository.this
  id = "automation-calculator"
}

import {
  to = module.repositories["core-iac"].github_repository.this
  id = "core-iac"
}

import {
  to = module.repositories["development_vm"].github_repository.this
  id = "development_vm"
}
```

`outputs.tf`: add a map of repository name to `html_url`.

`repository_permissions` (the CI team's grants) stays as it is. It lists two
repositories and `repositories` lists three; they are separate on purpose.

## 3. Settle the alerts resource before opening the pull request

Read the provider 6.13 documentation for `github_repository_vulnerability_alerts` and
find out whether it supports import and what the id is.

- If it does, add three more import blocks. The gate is then
  `6 to import, 0 to add, 0 to change, 0 to destroy`.
- If it does not, the gate is `3 to import, 3 to add, 0 to change, 0 to destroy`, where
  each add sets alerts to the value the repository already has. Say so in the pull
  request body, with the per-repository values, so task 03 knows the adds are expected.

Write the gate line that applies into the pull request body.

## 4. Run trigger

In `terraform/modules/tf_cloud/tf_cloud_workspaces/variables.tf`, add
`"terraform/modules/github/repository"` to the default of
`github_org_module_directories`. This plans as an in-place change of
`trigger_prefixes` on the GitHub workspace in the production `tf_cloud` workspace and as
nothing in the other two environments, which do not create that workspace.

## 5. CI

In `.circleci/config.yml`, copy `validate_org_ci_access_module` to make:

- `validate_github_repository_module`, path `./terraform/modules/github/repository`
- `validate_ci_iam_role_module`, path `./terraform/modules/aws/ci-iam-role` (a gap that
  predates this plan; say so in the pull request body)

Add both to the `validate` workflow's job list. The env config already has
`validate_production_github_org`.

## 6. Lock files and formatting

```bash
terraform -chdir=terraform/modules/github/repository init
terraform -chdir=terraform/modules/github/repository providers lock -platform=linux_amd64 -platform=darwin_arm64 -platform=darwin_amd64
terraform -chdir=terraform/env/production/github/org init -backend=false
terraform fmt -recursive terraform/
```

The env config's lock file should not change: the provider and its version are the same.

## Done when

- [ ] `terraform validate` passes in the module and in the env config
- [ ] CI is green, including the two new jobs
- [ ] The pull request body states the gate line from step 3
- [ ] The speculative plan in `ac_app_production_github_org` matches that line
