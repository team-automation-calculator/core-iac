resource "tfe_workspace" "base_cluster_tfe_workspace" {
  name                      = "ac_app_${var.environment_name}_base_cluster_layer"
  organization              = var.tf_cloud_organization_name
  remote_state_consumer_ids = [tfe_workspace.cluster_addons_tfe_workspace.id]
  tag_names                 = local.shared_workspace_tags
  terraform_version         = var.tfe_workspace_tf_version
  trigger_prefixes          = concat([var.base_cluster_layer_working_directory], var.base_cluster_layer_module_directories)
  vcs_repo {
    identifier     = var.tf_cloud_workspace_vcs_repo_identifier
    oauth_token_id = var.tfe_oauth_client_token_id
  }
  working_directory = var.base_cluster_layer_working_directory
}

resource "tfe_workspace" "cluster_addons_tfe_workspace" {
  name              = "ac_app_${var.environment_name}_cluster_addons_layer"
  organization      = var.tf_cloud_organization_name
  tag_names         = local.shared_workspace_tags
  terraform_version = var.tfe_workspace_tf_version
  trigger_prefixes  = concat([var.cluster_addons_layer_working_directory], var.cluster_addons_layer_module_directories)
  vcs_repo {
    identifier     = var.tf_cloud_workspace_vcs_repo_identifier
    oauth_token_id = var.tfe_oauth_client_token_id
  }
  working_directory = var.cluster_addons_layer_working_directory
}
