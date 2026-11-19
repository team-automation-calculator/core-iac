resource "tfe_oauth_client" "github" {
  api_url          = "https://api.github.com"
  http_url         = "https://github.com"
  oauth_token      = var.TF_VAR_GITHUB_TOKEN
  organization     = var.tf_cloud_organization_name
  service_provider = "github"
}

module "tf_cloud_workspaces" {
  auto_apply                             = var.auto_apply
  base_cluster_layer_working_directory   = var.base_cluster_layer_working_directory
  cluster_addons_layer_working_directory = var.cluster_addons_layer_working_directory
  enable_cluster_addons_run_trigger      = var.enable_cluster_addons_run_trigger
  enable_github_org_workspace            = var.enable_github_org_workspace
  enable_google_cloud_workspace          = var.enable_google_cloud_workspace
  enable_google_workspace_workspace      = var.enable_google_workspace_workspace
  enable_route53_domains_workspace       = var.enable_route53_domains_workspace
  environment_name                       = var.environment_name
  github_org_working_directory           = var.github_org_working_directory
  google_cloud_working_directory         = var.google_cloud_working_directory
  google_workspace_working_directory     = var.google_workspace_working_directory
  route53_domains_working_directory      = var.route53_domains_working_directory
  source                                 = "../../../modules/tf_cloud/tf_cloud_workspaces"
  tf_cloud_organization_name             = var.tf_cloud_organization_name
  tf_cloud_workspace_vcs_repo_identifier = var.tf_cloud_workspace_vcs_repo_identifier
  tfe_oauth_client_token_id              = tfe_oauth_client.github.oauth_token_id
  tfe_workspace_tf_version               = var.tfe_workspace_tf_version
}

# Terraform Cloud organization members. The organization is global, so it is
# managed once, from production (like the GitHub organization). Runbook:
# docs/tfc-org-members.md.
module "tf_cloud_org_members" {
  members           = { for key, member in var.tfc_organization_members : key => { email = member.email, owner = member.owner } }
  organization_name = var.tf_cloud_organization_name
  source            = "../../../modules/tf_cloud/tf_cloud_org_members"
}

# Members who were already in the organization before they were listed in
# var.tfc_organization_members are adopted into state instead of re-invited.
# An import block fails the plan if its target does not exist, so only entries
# with import_existing = true get one. Import blocks must live in the root module.
import {
  for_each = { for key, member in var.tfc_organization_members : key => member if member.import_existing }
  to       = module.tf_cloud_org_members.tfe_organization_membership.member[each.key]
  id       = "${var.tf_cloud_organization_name}/${each.value.email}"
}

import {
  for_each = { for key, member in var.tfc_organization_members : key => member if member.import_existing && member.owner }
  to       = module.tf_cloud_org_members.tfe_team_organization_member.owner[each.key]
  id       = "${var.tf_cloud_organization_name}/${each.value.email}/owners"
}
