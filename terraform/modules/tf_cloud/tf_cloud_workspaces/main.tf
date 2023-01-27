resource "tfe_workspace" "base_cluster_tfe_workspace" {
  name         = "ac_app_base_cluster_layer_${var.environment_name}"
  organization = var.tf_cloud_organization_name
  vcs_repo {
    identifier     = var.tf_cloud_workspace_vcs_repo_identifier
    oauth_token_id = var.tfe_oauth_client_token_id
  }
  tag_names         = ["automation-calculator"]
  working_directory = var.tf_cloud_workspace_path
}

resource "tfe_workspace" "cluster_addons_tfe_workspace" {
  name         = "ac_app_cluster_addons_layer_${var.environment_name}"
  organization = var.tf_cloud_organization_name
  vcs_repo {
    identifier     = var.tf_cloud_workspace_vcs_repo_identifier
    oauth_token_id = var.tfe_oauth_client_token_id
  }
  tag_names         = ["automation-calculator"]
  working_directory = var.tf_cloud_workspace_path
}
