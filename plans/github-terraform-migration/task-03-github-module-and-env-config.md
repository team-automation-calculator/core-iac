# Task 03 — GitHub repository module + global env config + import blocks

Delegatable to an agent. Part of PR 3 (together with task-04's CI changes).
Depends on: task-01 (captured values + token verified), task-02 (workspace exists).

## Context

- Pattern to mirror: `terraform/modules/aws/route53-domain/` (single-resource module)
  called with `for_each` from
  `terraform/env/production/aws/us-east-1/route53-domains/main.tf`, with import
  blocks in `import.tf` addressing `module.x["key"].resource.this`.
- Module style template: `terraform/modules/aws/ci-iam-role/` — `versions.tf` with
  `required_version = ">= 1.5.7"`, alphabetized `variables.tf` with descriptions +
  types, populated `outputs.tf` with descriptions, committed `.terraform.lock.hcl`.
- Captured ground truth: see `plans/github-terraform-migration/README.md`.

## New files

### `terraform/modules/github/repository/`

`versions.tf`:

```hcl
terraform {
  required_version = ">= 1.5.7"

  required_providers {
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }
  }
}
```

`main.tf`:

```hcl
resource "github_repository" "this" {
  allow_auto_merge            = var.allow_auto_merge
  allow_merge_commit          = var.allow_merge_commit
  allow_rebase_merge          = var.allow_rebase_merge
  allow_squash_merge          = var.allow_squash_merge
  allow_update_branch         = var.allow_update_branch
  archive_on_destroy          = true
  delete_branch_on_merge      = var.delete_branch_on_merge
  description                 = var.description
  has_downloads               = var.has_downloads
  has_issues                  = var.has_issues
  has_projects                = var.has_projects
  has_wiki                    = var.has_wiki
  homepage_url                = var.homepage_url
  name                        = var.name
  visibility                  = var.visibility
  vulnerability_alerts        = var.vulnerability_alerts
  web_commit_signoff_required = var.web_commit_signoff_required

  lifecycle {
    prevent_destroy = true
  }
}
```

Deliberately OMIT: `security_and_analysis` (Optional+Computed; free-plan 422 risk),
`auto_init` / `gitignore_template` / `license_template` / `template` (create-only),
deprecated `private`, `topics` (all repos have none; Optional+Computed),
`default_branch` (not in provider v6; default branches intentionally unmanaged),
merge/squash commit title/message args (all repos match provider defaults).

`variables.tf`: one variable per argument above, alphabetized, each with
`description` + `type`. Sensible defaults matching org-wide reality
(`visibility = "public"`, `has_issues = true`, `has_wiki = true`,
`has_projects = true`, `has_downloads = true`, allow_* merge flags `true`,
`allow_auto_merge = false`, `allow_update_branch = false`,
`delete_branch_on_merge = false`, `web_commit_signoff_required = false`,
`description = null`, `homepage_url = null`). `vulnerability_alerts` and `name`
have NO default (force explicit values).

`outputs.tf`: `repository_name`, `full_name`, `node_id`, `html_url` — each with a
description.

### `terraform/env/global/github/`

`versions.tf`:

```hcl
terraform {
  required_version = ">= 1.5.7"

  required_providers {
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }
  }

  backend "remote" {
    hostname     = "app.terraform.io"
    organization = "team-automation-calculator"

    workspaces {
      name = "ac_app_global_github"
    }
  }
}
```

`provider.tf`:

```hcl
provider "github" {
  owner = "team-automation-calculator"
  token = var.TF_VAR_GITHUB_TOKEN
}
```

`variables.tf`:

```hcl
variable "repositories" {
  description = "GitHub repositories to manage, keyed by repository name."
  type = map(object({
    description          = optional(string)
    homepage_url         = optional(string)
    vulnerability_alerts = bool
  }))
}

variable "TF_VAR_GITHUB_TOKEN" {
  description = "GitHub token with admin access to org repositories. Supplied by the TFC variable set."
  sensitive   = true
  type        = string
}
```

(Only per-repo-varying settings go in the object; org-wide-uniform flags ride on the
module defaults. If a future repo diverges, promote that setting into the object.)

`main.tf`:

```hcl
module "github_repositories" {
  for_each = var.repositories
  source   = "../../../modules/github/repository"

  description          = each.value.description
  homepage_url         = each.value.homepage_url
  name                 = each.key
  vulnerability_alerts = each.value.vulnerability_alerts
}
```

`terraform.tfvars` (from captured ground truth — README.md):

```hcl
repositories = {
  "automation-calculator" = {
    description          = null
    homepage_url         = "https://automation-calculations.io/"
    vulnerability_alerts = true
  }
  "core-iac" = {
    description          = "Infrastructure as Code base for all apps within this project, including the main one."
    homepage_url         = null
    vulnerability_alerts = false
  }
  "development_vm" = {
    description          = null
    homepage_url         = null
    vulnerability_alerts = true
  }
}
```

`import.tf` (TEMPORARY — removed in task-06):

```hcl
import {
  to = module.github_repositories["automation-calculator"].github_repository.this
  id = "automation-calculator"
}

import {
  to = module.github_repositories["core-iac"].github_repository.this
  id = "core-iac"
}

import {
  to = module.github_repositories["development_vm"].github_repository.this
  id = "development_vm"
}
```

`outputs.tf`: map of repo name → html_url from the module instances.

## Lock files

```bash
cd terraform/modules/github/repository && terraform init
cd ../../../env/global/github && terraform init -backend=false
terraform providers lock -platform=linux_amd64 -platform=darwin_arm64
```

(TFC runs on linux_amd64; local dev is darwin_arm64.) Commit both
`.terraform.lock.hcl` files. Do NOT commit `.terraform/` directories.

## Before committing

```bash
terraform fmt -recursive terraform/
```

## Acceptance criteria

- [ ] `terraform validate` passes in both new dirs (module: plain init;
      env config: `init -backend=false`)
- [ ] Lock files committed for both dirs, covering linux_amd64 + darwin_arm64
- [ ] Combined with task-04 in one draft PR via `gh`
- [ ] TFC speculative plan on the PR: **"3 to import, 0 to add, 0 to change,
      0 to destroy"** — iterate on arguments until true (task-05 gates the merge)
