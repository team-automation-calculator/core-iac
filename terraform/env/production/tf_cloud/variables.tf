variable "environment_name" {
  description = "The application production environment, i.e production/production/production."
  type        = string
}

variable "tf_cloud_organization_name" {
  default     = "team-automation-calculator"
  description = "The Terraform Cloud organization name to use for the Terraform Cloud workspace for this layer"
  type        = string
}

variable "base_cluster_layer_working_directory" {
  description = "The path to the Terraform Cloud workspace for this layer's file path"
  type        = string
}

variable "cluster_addons_layer_working_directory" {
  description = "The path to the Terraform Cloud workspace for this layer's file path"
  type        = string
}

variable "tf_cloud_workspace_vcs_repo_identifier" {
  default     = "team-automation-calculator/core-iac"
  description = "The VCS repo identifier for the Terraform Cloud workspace for this layer's version control/github source"
  type        = string
}

variable "TF_VAR_GITHUB_TOKEN" {
  description = "Environment variable for the GitHub Personal Access Token to be used by Terraform Cloud to access the GitHub repository"
  type        = string
  sensitive   = true
}
