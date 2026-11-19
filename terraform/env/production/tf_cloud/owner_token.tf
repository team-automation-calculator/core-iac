# The credential this workspace runs with. Managing organization members needs
# owner rights, which the shared TFE_TOKEN variable set does not have, so this
# workspace gets its own owners team token as a workspace-level TFE_TOKEN
# (a workspace variable overrides a variable set). The other tf_cloud
# workspaces keep the variable set. Bootstrap and rotation:
# docs/tfc-org-members.md.
data "tfe_team" "owners" {
  name         = "owners"
  organization = var.tf_cloud_organization_name
}

# This workspace is hand-made (README, Setup step 2), so it is looked up, not
# managed.
data "tfe_workspace" "tf_workspaces" {
  name         = "ac_app_${var.environment_name}_tf_workspaces"
  organization = var.tf_cloud_organization_name
}

# Token descriptions must be unique within a team, and rotation creates the new
# token before deleting the old one, so the expiry is part of the description.
resource "tfe_team_token" "tf_workspaces" {
  team_id     = data.tfe_team.owners.id
  description = "${data.tfe_workspace.tf_workspaces.name} expires ${var.tfc_owner_token_expired_at}"
  expired_at  = var.tfc_owner_token_expired_at

  lifecycle {
    create_before_destroy = true
  }
}

resource "tfe_variable" "tf_workspaces_tfe_token" {
  category     = "env"
  description  = "Owners team token, managed by terraform/env/${var.environment_name}/tf_cloud. Expires ${var.tfc_owner_token_expired_at}."
  key          = "TFE_TOKEN"
  sensitive    = true
  value        = tfe_team_token.tf_workspaces.token
  workspace_id = data.tfe_workspace.tf_workspaces.id
}
