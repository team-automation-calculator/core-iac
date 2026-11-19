resource "tfe_workspace" "base_cluster_tfe_workspace" {
  name              = "ac_app_${var.environment_name}_base_cluster_layer"
  organization      = var.tf_cloud_organization_name
  auto_apply        = var.auto_apply
  tag_names         = local.shared_workspace_tags
  terraform_version = var.tfe_workspace_tf_version
  trigger_prefixes  = concat([var.base_cluster_layer_working_directory], var.base_cluster_layer_module_directories)
  vcs_repo {
    identifier     = var.tf_cloud_workspace_vcs_repo_identifier
    oauth_token_id = var.tfe_oauth_client_token_id
  }
  working_directory = var.base_cluster_layer_working_directory
}

resource "tfe_workspace_settings" "base_cluster_tfe_workspace" {
  workspace_id              = tfe_workspace.base_cluster_tfe_workspace.id
  remote_state_consumer_ids = [tfe_workspace.cluster_addons_tfe_workspace.id]
}

# The Identity Center ids the Google Workspace SAML app is configured for, fed
# to the base layer's sso-infra-eng drift check. The repo is public, so the
# values are never committed: they reach this config as variables (set on the
# tf_cloud workspace, or TF_VAR_... for a local apply, like the GitHub token)
# and are written to the base cluster workspace as sensitive variables. Left
# empty, the check is skipped.
resource "tfe_variable" "expected_identity_center_instance_id" {
  category     = "terraform"
  description  = "IAM Identity Center instance id (ssoins-...) expected by the sso-infra-eng drift check. Managed by the tf_cloud config."
  key          = "expected_identity_center_instance_id"
  sensitive    = true
  value        = var.identity_center_instance_id
  workspace_id = tfe_workspace.base_cluster_tfe_workspace.id
}

resource "tfe_variable" "expected_identity_store_id" {
  category     = "terraform"
  description  = "IAM Identity Center identity store id (d-...) expected by the sso-infra-eng drift check. Managed by the tf_cloud config."
  key          = "expected_identity_store_id"
  sensitive    = true
  value        = var.identity_center_identity_store_id
  workspace_id = tfe_workspace.base_cluster_tfe_workspace.id
}

resource "tfe_run_trigger" "cluster_addons_run_trigger" {
  count         = var.enable_cluster_addons_run_trigger ? 1 : 0
  workspace_id  = tfe_workspace.cluster_addons_tfe_workspace.id
  sourceable_id = tfe_workspace.base_cluster_tfe_workspace.id
}

resource "tfe_workspace" "route53_domains_tfe_workspace" {
  count             = var.enable_route53_domains_workspace ? 1 : 0
  name              = "ac_app_${var.environment_name}_route53_domains"
  organization      = var.tf_cloud_organization_name
  auto_apply        = var.auto_apply
  tag_names         = local.shared_workspace_tags
  terraform_version = var.tfe_workspace_tf_version
  trigger_prefixes  = concat([var.route53_domains_working_directory], var.route53_domains_module_directories)
  vcs_repo {
    identifier     = var.tf_cloud_workspace_vcs_repo_identifier
    oauth_token_id = var.tfe_oauth_client_token_id
  }
  working_directory = var.route53_domains_working_directory
}

resource "tfe_workspace" "github_org_tfe_workspace" {
  count             = var.enable_github_org_workspace ? 1 : 0
  name              = "ac_app_${var.environment_name}_github_org"
  organization      = var.tf_cloud_organization_name
  auto_apply        = var.auto_apply
  tag_names         = local.shared_workspace_tags
  terraform_version = var.tfe_workspace_tf_version
  trigger_prefixes  = concat([var.github_org_working_directory], var.github_org_module_directories)
  vcs_repo {
    identifier     = var.tf_cloud_workspace_vcs_repo_identifier
    oauth_token_id = var.tfe_oauth_client_token_id
  }
  working_directory = var.github_org_working_directory
}

# Google Workspace directory objects (the group that gates the AWS Identity
# Center SAML app). The service account key is a sensitive environment
# variable set on the workspace by hand; see docs/google-workspace-terraform.md.
resource "tfe_workspace" "google_workspace_tfe_workspace" {
  count             = var.enable_google_workspace_workspace ? 1 : 0
  name              = "ac_app_${var.environment_name}_google_workspace"
  organization      = var.tf_cloud_organization_name
  auto_apply        = var.auto_apply
  tag_names         = local.shared_workspace_tags
  terraform_version = var.tfe_workspace_tf_version
  trigger_prefixes  = concat([var.google_workspace_working_directory], var.google_workspace_module_directories)
  vcs_repo {
    identifier     = var.tf_cloud_workspace_vcs_repo_identifier
    oauth_token_id = var.tfe_oauth_client_token_id
  }
  working_directory = var.google_workspace_working_directory
}

resource "tfe_workspace" "cluster_addons_tfe_workspace" {
  name              = "ac_app_${var.environment_name}_cluster_addons_layer"
  organization      = var.tf_cloud_organization_name
  auto_apply        = var.auto_apply
  tag_names         = local.shared_workspace_tags
  terraform_version = var.tfe_workspace_tf_version
  trigger_prefixes  = concat([var.cluster_addons_layer_working_directory], var.cluster_addons_layer_module_directories)
  vcs_repo {
    identifier     = var.tf_cloud_workspace_vcs_repo_identifier
    oauth_token_id = var.tfe_oauth_client_token_id
  }
  working_directory = var.cluster_addons_layer_working_directory
}
