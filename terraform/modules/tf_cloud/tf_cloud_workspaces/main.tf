resource "tfe_workspace" "base_cluster_tfe_workspace" {
  name                      = "ac_app_base_cluster_layer_${var.environment_name}"
  organization              = var.tf_cloud_organization_name
  remote_state_consumer_ids = [tfe_workspace.cluster_addons_tfe_workspace.id]
  tag_names                 = ["automation-calculator"]
  trigger_prefixes          = concat([var.base_cluster_layer_working_directory], var.base_cluster_layer_module_directories)
  vcs_repo {
    identifier     = var.tf_cloud_workspace_vcs_repo_identifier
    oauth_token_id = var.tfe_oauth_client_token_id
  }
  working_directory = var.base_cluster_layer_working_directory
}

resource "tfe_workspace" "cluster_addons_tfe_workspace" {
  name             = "ac_app_cluster_addons_layer_${var.environment_name}"
  organization     = var.tf_cloud_organization_name
  tag_names        = ["automation-calculator"]
  trigger_prefixes = concat([var.cluster_addons_layer_working_directory], var.cluster_addons_layer_module_directories)
  vcs_repo {
    identifier     = var.tf_cloud_workspace_vcs_repo_identifier
    oauth_token_id = var.tfe_oauth_client_token_id
  }
  working_directory = var.cluster_addons_layer_working_directory
}
