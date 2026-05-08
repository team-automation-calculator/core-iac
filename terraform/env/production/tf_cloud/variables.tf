variable "auto_apply" {
  description = "When true, automatically applies successful plans triggered via the API, UI, or VCS. Should be false for production."
  type        = bool
  default     = false
}

variable "base_cluster_layer_working_directory" {
  description = "The path to the Terraform Cloud workspace for this layer's file path"
  type        = string
}

variable "cluster_addons_layer_working_directory" {
  description = "The path to the Terraform Cloud workspace for this layer's file path"
  type        = string
}

variable "enable_cluster_addons_run_trigger" {
  description = "When true, creates a run trigger so that a successful apply in the base cluster workspace automatically queues a run in the cluster addons workspace."
  type        = bool
  default     = true
}

variable "enable_route53_domains_workspace" {
  description = "When true, creates a TFC workspace for the route53-domains env config."
  type        = bool
  default     = false
}

variable "environment_name" {
  description = "The application production environment, i.e development/staging/production."
  type        = string
}

variable "route53_domains_working_directory" {
  description = "The path to the route53-domains env config directory."
  type        = string
  default     = ""
}

variable "tf_cloud_organization_name" {
  default     = "team-automation-calculator"
  description = "The Terraform Cloud organization name to use for the Terraform Cloud workspace for this layer"
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

variable "tfe_workspace_tf_version" {
  description = "Allows for version pinning of tfe workspaces that have been created, because otherwise TF Cloud just chooses the latest one."
  type        = string
  default     = "1.3.7"
}
