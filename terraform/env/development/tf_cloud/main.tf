provider "tfe" {
  hostname = "app.terraform.io"
}

resource "tfe_oauth_client" "github" {
  api_url          = "https://api.github.com"
  http_url         = "https://github.com"
  oauth_token      = var.TF_VAR_GITHUB_TOKEN
  organization     = var.tf_cloud_organization_name
  service_provider = "github"
}

module "tf_cloud_workspaces" {
  source                                 = "../../../modules/tf_cloud/tf_cloud_workspaces"
  environment_name                       = var.environment_name
  tf_cloud_organization_name             = var.tf_cloud_organization_name
  tf_cloud_workspace_path                = var.tf_cloud_workspace_path
  tf_cloud_workspace_vcs_repo_identifier = var.tf_cloud_workspace_vcs_repo_identifier
  tfe_oauth_client_token_id              = tfe_oauth_client.github.id
  TF_VAR_GITHUB_TOKEN                    = var.TF_VAR_GITHUB_TOKEN
}
