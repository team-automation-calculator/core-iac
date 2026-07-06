# Task 02 — Bootstrap the `ac_app_global_github` TFC workspace

Delegatable to an agent. One PR (PR 2 in the sequence), then a manual TFC apply +
one manual TFC console step.

## Context

Workspaces are created by `terraform/modules/tf_cloud/tf_cloud_workspaces/`, called
from per-env `terraform/env/<env>/tf_cloud/` configs. The count-gated
`route53_domains_tfe_workspace` resource in the module (gated by
`enable_route53_domains_workspace`, enabled only in production tfvars) is the exact
precedent to copy.

## Changes

### 1. `terraform/modules/tf_cloud/tf_cloud_workspaces/main.tf`

Add (mirroring the route53 workspace resource):

```hcl
resource "tfe_workspace" "github_tfe_workspace" {
  count             = var.enable_github_workspace ? 1 : 0
  name              = "ac_app_global_github"
  organization      = var.tf_cloud_organization_name
  auto_apply        = false # org-critical: always require manual confirm
  tag_names         = ["automation-calculator", "global"]
  terraform_version = var.tfe_workspace_tf_version
  trigger_prefixes  = concat([var.github_working_directory], var.github_module_directories)

  vcs_repo {
    identifier     = var.tf_cloud_workspace_vcs_repo_identifier
    oauth_token_id = var.tfe_oauth_client_token_id
  }

  working_directory = var.github_working_directory
}
```

Note `auto_apply` is hardcoded `false`, NOT `var.auto_apply`. Note tags use literal
`"global"`, not `var.environment_name`.

### 2. `terraform/modules/tf_cloud/tf_cloud_workspaces/variables.tf`

Add, keeping the file alphabetized (there is a `scripts/sort_tfvars.sh` convention;
variables.tf is hand-sorted):

- `enable_github_workspace` — bool, default `false`, description noting it should be
  enabled from exactly one env (production) since the workspace is global
- `github_module_directories` — list(string), default
  `["terraform/modules/github/repository"]`
- `github_working_directory` — string, default `""`

### 3. `terraform/env/production/tf_cloud/`

- `main.tf`: pass the three new vars to the module call
- `variables.tf`: declare the three vars (alphabetized, with descriptions/types,
  same defaults)
- `terraform.tfvars`: set `enable_github_workspace = true` and
  `github_working_directory = "terraform/env/global/github"` (keep file alphabetized)

## Before committing

```bash
terraform fmt -recursive terraform/
```

No provider changes, so lock files should not change (TFE pinned 0.68.2).

## PR

Branch + draft PR via `gh` (never push main, never use hub). Title:
"Add global GitHub management TFC workspace (bootstrap for GitHub TF migration)".
Link `plans/github-terraform-migration/README.md` in the body.

## After merge (manual, human-in-the-loop)

1. Queue/confirm the run in the **production tf_cloud bootstrap workspace** in TFC
   (it is not auto-applied). This creates `ac_app_global_github`.
2. In the TFC console: attach the existing variable set containing
   `TF_VAR_GITHUB_TOKEN` (and `TFE_TOKEN`) to `ac_app_global_github`.
3. Confirm the workspace's exact name is `ac_app_global_github` — the backend block
   in task-03 must match it verbatim (route53 has a rename-mismatch precedent).
4. The working directory `terraform/env/global/github` doesn't exist on main yet —
   harmless; no runs will trigger until task-03 merges.

## Acceptance criteria

- [ ] CI validate jobs green (fmt + validate)
- [ ] Plan in production tf_cloud workspace shows exactly 1 workspace to add,
      nothing changed/destroyed
- [ ] `ac_app_global_github` exists in TFC with the variable set attached
