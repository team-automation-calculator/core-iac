variable "base_cluster_layer_working_directory" {
  default     = ""
  description = "The path to the Terraform Cloud workspace for this layer's file path"
  type        = string
}

variable "base_cluster_layer_module_directories" {
  default     = ["terraform/modules/aws/networking", "terraform/modules/aws/base-cluster-layer"]
  description = "The list of module directories for the base cluster layer"
  type        = list(string)
}

variable "cluster_addons_layer_working_directory" {
  default     = ""
  description = "The path to the Terraform Cloud workspace for this layer's file path"
  type        = string
}

variable "cluster_addons_layer_module_directories" {
  default     = ["terraform/modules/aws/cluster-addons-layer", "terraform/modules/aws/main_rails_app", "helm/automation-calculator"]
  description = "The list of module directories for the cluster addons layer"
  type        = list(string)
}

variable "environment_name" {
  description = "The application development environment, i.e development/staging/production."
  type        = string
}

variable "tf_cloud_organization_name" {
  description = "The Terraform Cloud organization name to use for the Terraform Cloud workspace for this layer"
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
