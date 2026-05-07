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
  enable_route53_domains_workspace       = var.enable_route53_domains_workspace
  environment_name                       = var.environment_name
  route53_domains_working_directory      = var.route53_domains_working_directory
  source                                 = "../../../modules/tf_cloud/tf_cloud_workspaces"
  tf_cloud_organization_name             = var.tf_cloud_organization_name
  tf_cloud_workspace_vcs_repo_identifier = var.tf_cloud_workspace_vcs_repo_identifier
  tfe_oauth_client_token_id              = tfe_oauth_client.github.oauth_token_id
  tfe_workspace_tf_version               = var.tfe_workspace_tf_version
}
