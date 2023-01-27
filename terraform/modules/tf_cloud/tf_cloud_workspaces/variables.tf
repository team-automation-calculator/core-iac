variable "tf_cloud_organization_name" {
  description = "The Terraform Cloud organization name to use for the Terraform Cloud workspace for this layer"
  type        = string
}

variable "tf_cloud_workspace_path" {
  description = "The path to the Terraform Cloud workspace for the base cluster layer"
  type        = string
}

variable "tf_cloud_workspace_vcs_repo_identifier" {
  description = "The VCS repo identifier for the Terraform Cloud workspace for the base cluster layer"
  type        = string
}

variable "tfe_oauth_client_token_id" {
  description = "tfe_oauth_client token id used to connect terraform cloud workspaces to github repos"
  type        = string
  sensitive   = true
}

variable "TF_VAR_GITHUB_TOKEN" {
  description = "Environment variable for the GitHub Personal Access Token to be used by Terraform Cloud to access the GitHub repository"
  type        = string
  sensitive   = true
}
