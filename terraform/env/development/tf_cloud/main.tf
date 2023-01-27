provider "tfe" {
  hostname = "app.terraform.io"
}

resource "tfe_oauth_client" "github" {
  organization     = var.tfe_organization_name
  api_url          = "https://api.github.com"
  http_url         = "https://github.com"
  service_provider = "github"
  oauth_token      = var.TF_VAR_GITHUB_TOKEN
}

module "tf_cloud_workspaces" {
  source                                 = "../../modules/tf_cloud_workspaces"
  environment_name                       = var.environment_name
  tf_cloud_organization_name             = var.tf_cloud_organization_name
  tf_cloud_workspace_vcs_repo_identifier = var.tf_cloud_workspace_vcs_repo_identifier
  tfe_oauth_client_token_id              = tfe_oauth_client.github.id
  tfe_organization_name                  = var.tfe_organization_name
}
